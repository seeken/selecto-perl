package Selecto::PostgreSQL::Stream;

use 5.034;
use strict;
use warnings;
use parent 'Selecto::Stream';
use Scalar::Util ();
use Selecto::Error ();

my $SERIAL = 0;

sub new {
    my ($class, %args) = @_;
    my $adapter = $args{adapter};
    my $dbh = $adapter->dbh;
    Selecto::Error->throw('stream_busy', 'database handle already has an active bounded stream')
        if $dbh->{private_selecto_bounded_stream};
    Selecto::Error->throw('stream_unavailable', 'database handle requires recovery after stream cleanup failed')
        if $dbh->{private_selecto_bounded_stream_poisoned};
    # Refuses a pending result, an aborted transaction or an unknown state
    # before anything is sent.
    my $scope = $adapter->_read_guard_scope;
    my $name = 'selecto_stream_' . $$ . '_' . ++$SERIAL;
    my $fetch_size = int($args{fetch_size} // 1);
    my $self = bless {adapter => $adapter, dbh => $dbh, name => $name,
        columns => $args{statement}->columns, closed => 0, buffer => [],
        canonical_values => $args{canonical_values} ? 1 : 0}, $class;
    $dbh->{private_selecto_bounded_stream} = $name;
    my $ok = eval {
        # The scope is recorded only once the savepoint or transaction exists,
        # so a failed start never rolls back anything.
        if ($scope eq 'host') {
            $adapter->_savepoint_command(create => $name);
            $self->{scope} = 'host';
        } else {
            $adapter->_begin_transaction;
            $self->{scope} = 'own';
            _do($dbh, 'SET TRANSACTION READ ONLY');
            # The transaction's virtual id proves at close that it is still
            # this stream's own before it is rolled back. No statement can
            # forge it, unlike a GUC marker (item 57).
            $self->{transaction} = $adapter->_virtual_transaction_id;
            die 'stream transaction identity is unavailable' unless defined $self->{transaction};
        }
        # Temp shadows refused and the session snapshot taken before the
        # cursor; every FETCH is compared with it (items 56, 61).
        $self->{session} = $adapter->_pg_admit_session($args{statement})
            if $adapter->_pg_session_checked;
        my $declaration = $dbh->prepare('DECLARE ' . $name . ' NO SCROLL CURSOR WITHOUT HOLD FOR '
            . $adapter->_query_transport_sql($args{statement}));
        die 'cursor declaration could not be prepared' unless $declaration;
        defined($adapter->_execute_statement($declaration, $args{statement}->params))
            or die 'cursor declaration failed';
        $self->{declared} = 1;
        $declaration->finish;
        # One FETCH result is all that libpq can buffer, so fetch_size rows
        # (default 1) bound DBD::Pg's eager result allocation. RowCacheSize
        # alone cannot.
        $self->{sth} = $dbh->prepare("FETCH FORWARD $fetch_size FROM $name")
            or die 'cursor fetch could not be prepared';
        1;
    };
    if (!$ok) {
        my $error = $adapter->normalize_error($@);
        # Nothing but this stream's own statements ran since the state check.
        my $origin = $self->_failure_origin;
        my $cleanup = eval { $self->_close($origin); 1 } ? undef : $@;
        die _cleanup_error($cleanup) // $error;
    }
    return $self;
}

sub next {
    my ($self) = @_;
    return undef if $self->{closed};
    return shift @{$self->{buffer}} if @{$self->{buffer}};
    my $rows;
    my $ok = eval {
        my $sth = $self->{sth};
        require Selecto::QueryBudget;
        Selecto::QueryBudget->before_blocking($self->{dbh});
        defined($sth->execute) or die 'cursor fetch failed';
        $self->{types} //= [$self->{adapter}->_column_types($sth)];
        $rows = $sth->fetchall_arrayref;
        die 'cursor row fetch failed' if !$rows || $sth->err;
        $sth->finish;
        # Nothing of a batch is handed out before its session check: a
        # function the statement calls may have switched search_path or made
        # a temp relation while the server produced it.
        if ($self->{session}) {
            my $after = eval { $self->{adapter}->_pg_session_state };
            unless ($after && $after->{snapshot} eq $self->{session}{snapshot}) {
                $self->{session_changed} = 1;
                die 'session state changed';
            }
        }
        $self->{adapter}->_decode_rows($rows, $self->{types}) if $self->{canonical_values};
        1;
    };
    if (!$ok) {
        # Capture PostgreSQL's error state before transaction recovery clears it.
        my $error = $self->{adapter}->normalize_error($@);
        # A changed session is the stream's own work to undo: its savepoint
        # or its own transaction is rolled back, which reverts the change.
        my $origin = $self->{session_changed} ? 'own' : $self->_failure_origin;
        $error = eval { Selecto::PostgreSQL::_session_changed(); 1 } ? $error : $@ if $self->{session_changed};
        my $cleanup = eval { $self->_close($origin); 1 } ? undef : $@;
        die _cleanup_error($cleanup) // $error;
    }
    if (!@$rows) {
        $self->close;
        return undef;
    }
    $self->{buffer} = $rows;
    return shift @{$self->{buffer}};
}

# Whose failure this is, read before anything else is sent:
# 'own'     PostgreSQL rejected this stream's own statement (or Selecto's
#           deadline statement for it), aborting the transaction;
# 'local'   the failure was in Perl (decoding, say), and the transaction is
#           as healthy as the last successful fetch left it;
# 'foreign' anything else: the transaction was already aborted by the host
#           (in_failed_sql_transaction), the host has a pending result, or
#           the driver refused locally. Such a failure is never this stream's
#           to roll back.
sub _failure_origin {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return 'foreign' if eval { $dbh->{pg_async_status} };
    my $err = eval { $dbh->err };
    my $state = eval { $dbh->state } // '';
    return 'local' unless $err || length $state;
    return 'foreign' unless $state =~ /\A[0-9A-Z]{5}\z/ && $state ne 'S1000' && $state ne '25P02';
    # Its cursor missing means its own transaction is gone (the host took the
    # connection over); inside the host's transaction it is the stream's own
    # FETCH that failed.
    return 'foreign' if $state eq '34000' && ($self->{scope} // '') eq 'own';
    return 'own';
}

sub close { return $_[0]->_close(); }

# $failure is undefined for an ordinary close, otherwise the failure's
# origin (see _failure_origin). The stream only ever rolls back what it can
# prove is its own: its own transaction, by its marker, or its own savepoint,
# by its unique name, and never an aborted transaction it did not abort.
# Otherwise it leaves the connection exactly as it is and reports
# transaction_state_unsafe: the host keeps its error, and its commit fails.
sub _close {
    my ($self, $failure) = @_;
    return $self if $self->{closed};
    $self->{closed} = 1;
    my ($dbh, $adapter, $name) = @{$self}{qw(dbh adapter name)};
    eval { $self->{sth}->finish } if $self->{sth};
    my $unsafe;
    my $ok = eval {
        # A disconnected handle has already lost its server cursor/transaction.
        if ($dbh->{Active} && $self->{scope}) {
            my $foreign = defined($failure) && $failure eq 'foreign';
            if ($foreign || eval { $dbh->{pg_async_status} }) {
                $unsafe = 'the host aborted or took over the transaction while the stream was open';
            } elsif ($self->{scope} eq 'own') {
                $unsafe = $self->_own_transaction_unproven($failure);
                # A read-only stream never commits work on behalf of its caller.
                $dbh->rollback or die 'stream transaction rollback failed' unless $unsafe;
            } elsif (defined $failure) {
                $adapter->_savepoint_command(rollback => $name);
                $adapter->_savepoint_command(release => $name);
            } else {
                if ($self->{declared}) {
                    my $closed = eval { _do($dbh, "CLOSE $name"); 1 };
                    unless ($closed) {
                        # A CLOSE refused because the host had already aborted
                        # the transaction is not the stream's failure to undo.
                        my $state = eval { $dbh->state } // '';
                        $unsafe = 'the host aborted the transaction while the stream was open'
                            if $state eq '25P02' || eval { $dbh->{pg_async_status} };
                        $adapter->_savepoint_command(rollback => $name) unless $unsafe;
                    }
                }
                $adapter->_savepoint_command(release => $name) unless $unsafe;
            }
        }
        1;
    };
    delete $dbh->{private_selecto_bounded_stream};
    if ($unsafe) {
        Selecto::Error->throw('transaction_state_unsafe',
            "$unsafe; its savepoint or transaction was left for the host to roll back",
            {state => 'ownership_lost'});
    }
    if (!$ok) {
        $dbh->{private_selecto_bounded_stream_poisoned} = 1;
        Selecto::Error->throw('stream_cleanup_failed', 'database stream could not restore its transaction scope');
    }
    return $self;
}

# Undef when the open transaction is provably the one this stream began,
# otherwise why it is not. After the stream's own statement failed the
# transaction is aborted and can answer nothing, but that failure proves its
# cursor, and so its transaction, was still there; otherwise the marker it
# set when it began must still be in force.
sub _own_transaction_unproven {
    my ($self, $failure) = @_;
    return undef if defined($failure) && $failure eq 'own';
    my $dbh = $self->{dbh};
    my $marker = eval {
        local $dbh->{RaiseError} = 1;
        local $dbh->{PrintError} = 0;
        $self->{adapter}->_virtual_transaction_id;
    };
    return undef if defined($marker) && defined($self->{transaction}) && $marker eq $self->{transaction};
    return 'the host took over the connection while the stream was open';
}

# A failed cleanup outranks the failure that caused it: the transaction may
# now be aborted or not the stream's, and the host must learn that before it
# commits (a COMMIT of an aborted transaction silently rolls back).
sub _cleanup_error {
    my ($error) = @_;
    return undef unless defined $error;
    return Scalar::Util::blessed($error) && $error->isa('Selecto::Error') ? $error
        : Selecto::Error->new(code => 'stream_cleanup_failed',
            message => 'database stream could not restore its transaction scope');
}

sub _do {
    my ($dbh, $sql) = @_;
    defined($dbh->do($sql)) or die 'stream transaction control failed';
    return;
}

# Destruction cannot raise. A cleanup that failed, or that left the host's
# transaction to the host, is reported as a warning, and the handle keeps
# its state (an aborted transaction stays aborted, a failed cleanup poisons
# later bounded streams), so an abandoned stream never looks clean.
sub DESTROY {
    my ($self) = @_;
    return if $self->{closed};
    local $@;
    return if eval { $self->close; 1 };
    my $error = $@;
    warn 'Selecto bounded stream abandoned: '
        . (Scalar::Util::blessed($error) && $error->can('message') ? $error->message : 'cleanup failed') . "\n";
}

1;

__END__

=head1 NAME

Selecto::PostgreSQL::Stream - bounded PostgreSQL server cursor

=head1 DESCRIPTION

C<< $engine->stream($query, bounded => 1, fetch_size => $n) >> uses a
PostgreSQL C<NO SCROLL> cursor and fetches C<$n> rows per round trip (default
1), handing them out one at a time. This bounds the number of result rows
buffered by DBD::Pg to C<$n>; an individual row and the server's query plan
can still consume substantial memory. Row limits, byte budgets and database
deadlines remain separate requirements, and a caller's per-row checks see a
batch only after it has been fetched. Rows hold the driver's values; with
C<< canonical_values => 1 >> each batch is decoded to canonical values column
by column (see L<Selecto::PostgreSQL/RESULT VALUES>).

The stream owns an idle handle's read-only transaction and rolls it back on
close. Inside an existing transaction it owns a uniquely named savepoint:
normal close releases it, while a fetch/decode failure rolls back to it and
then releases it, preserving work from before the stream opened. Raw
C<BEGIN> is detected. A stream does not open on a connection with a pending
host result, an aborted transaction or an unknown state
(C<transaction_state_unsafe>; see L<Selecto::PostgreSQL/TRANSACTION STATE>).

A stream rolls back only what it can prove is its own. Its own transaction
is identified by its virtual transaction id (C<pg_locks.virtualxid>), which
must still be the open transaction's at close; its own savepoint is rolled back only after its own statement failed.
When the host aborted the transaction while the stream was open (a failing
statement, or a failing asynchronous query whose result is still pending),
or took the connection over (C<ROLLBACK>, C<BEGIN>, its own writes), the
stream's C<next> or C<close> fails with C<transaction_state_unsafe> and
leaves the connection exactly as it is: an aborted transaction stays
aborted, with the stream's savepoint on it, for the host to roll back, and
the host's new transaction is never touched. Rolling back there would have
silently undone the host's error, so its commit went through, or destroyed
the host's new transaction. (A C<FETCH> after a takeover still fails, since
the cursor has gone, and so aborts the host's new transaction; the host
then sees the failure.)
Keep the handle exclusively assigned to the stream until it closes; do not
interleave host writes or transaction control. Only one bounded stream may
be active on a handle. It closes on exhaustion, failure or destruction; call
C<close> explicitly on early termination. Cleanup failure disables further
bounded streams on that handle, which must be discarded or recovered by the
host. A disconnected handle has already lost its server transaction.

=cut
