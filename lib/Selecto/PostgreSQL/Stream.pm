package Selecto::PostgreSQL::Stream;

use 5.034;
use strict;
use warnings;
use parent 'Selecto::Stream';
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
    my $name = 'selecto_stream_' . $$ . '_' . ++$SERIAL;
    my $fetch_size = int($args{fetch_size} // 1);
    my $self = bless {adapter => $adapter, dbh => $dbh, name => $name,
        columns => $args{statement}->columns, closed => 0, buffer => []}, $class;
    $dbh->{private_selecto_bounded_stream} = $name;
    my $ok = eval {
        if ($adapter->_transaction_open) {
            $adapter->_savepoint_command(create => $name);
            $self->{scope} = 'host';
        } else {
            $adapter->_begin_transaction;
            $self->{scope} = 'own';
            _do($dbh, 'SET TRANSACTION READ ONLY');
        }
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
        eval { $self->_close(1) };
        die $error;
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
        defined($sth->execute) or die 'cursor fetch failed';
        $self->{types} //= [$self->{adapter}->_column_types($sth)];
        $rows = $sth->fetchall_arrayref;
        die 'cursor row fetch failed' if !$rows || $sth->err;
        $self->{adapter}->_decode_rows($rows, $self->{types});
        $sth->finish;
        1;
    };
    if (!$ok) {
        # Capture PostgreSQL's error state before transaction recovery clears it.
        my $error = $self->{adapter}->normalize_error($@);
        eval { $self->_close(1) };
        die $error;
    }
    if (!@$rows) {
        $self->close;
        return undef;
    }
    $self->{buffer} = $rows;
    return shift @{$self->{buffer}};
}

sub close { return $_[0]->_close(0); }

sub _close {
    my ($self, $failed) = @_;
    return $self if $self->{closed};
    $self->{closed} = 1;
    my ($dbh, $adapter, $name) = @{$self}{qw(dbh adapter name)};
    eval { $self->{sth}->finish } if $self->{sth};
    my $ok = eval {
        # A disconnected handle has already lost its server cursor/transaction.
        if ($dbh->{Active} && $self->{scope}) {
            if ($self->{scope} eq 'own') {
                # A read-only stream never commits work on behalf of its caller.
                $dbh->rollback or die 'stream transaction rollback failed';
            } else {
                if ($failed) {
                    $adapter->_savepoint_command(rollback => $name);
                } elsif ($self->{declared}) {
                    my $closed = eval { _do($dbh, "CLOSE $name"); 1 };
                    unless ($closed) {
                        $adapter->_savepoint_command(rollback => $name);
                    }
                }
                $adapter->_savepoint_command(release => $name);
            }
        }
        1;
    };
    delete $dbh->{private_selecto_bounded_stream};
    if (!$ok) {
        $dbh->{private_selecto_bounded_stream_poisoned} = 1;
        Selecto::Error->throw('stream_cleanup_failed', 'database stream could not restore its transaction scope');
    }
    return $self;
}

sub _do {
    my ($dbh, $sql) = @_;
    defined($dbh->do($sql)) or die 'stream transaction control failed';
    return;
}

sub DESTROY { my ($self) = @_; local $@; eval { $self->close } unless $self->{closed}; }

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
batch only after it has been fetched. Each batch is decoded column by column
(see C<_decode_rows> in L<Selecto::SQL>).

The stream owns an idle handle's read-only transaction and rolls it back on
close. Inside an existing transaction it owns a savepoint: normal close
releases it, while a fetch/decode failure rolls back to it and then releases
it, preserving work from before the stream opened. Raw C<BEGIN> is detected.
Keep the handle exclusively assigned to the stream until it closes; do not
interleave host writes or transaction control. Only one bounded stream may
be active on a handle. It closes on exhaustion, failure or destruction; call
C<close> explicitly on early termination. Cleanup failure disables further
bounded streams on that handle, which must be discarded or recovered by the
host. A disconnected handle has already lost its server transaction.

=cut
