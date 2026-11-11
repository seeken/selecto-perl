package Selecto::PostgreSQL::Stream;

use 5.034;
use strict;
use warnings;
use parent 'Selecto::Stream';
use JSON::PP ();
use Scalar::Util ();
use Selecto::Error ();

my $SERIAL = 0;
# Handles a stream holds in a read-only transaction of its own (AutoCommit was
# on), and handles with a stream open at all, by the handle's identity: a clone
# copies a handle's attributes and is not held for that. Selecto's own reads,
# writes and streams on a held handle refuse (handle_owned_by_stream); hosts
# such as selecto-perl-kit read %OWNED without sending anything.
our (%OWNED, %STREAMING);

sub new {
    my ($class, %args) = @_;
    my $adapter = $args{adapter};
    my $dbh = $adapter->dbh;
    my $key = Scalar::Util::refaddr($dbh);
    Selecto::Error->throw('stream_busy', 'database handle already has an active bounded stream') if $STREAMING{$key};
    # 'own' (AutoCommit on): a READ ONLY transaction of the stream's, rolled back
    # at the close. 'host': the host's transaction, which the cursor ends with.
    my $scope = $adapter->_read_guard_scope;
    $adapter->_admit_hand_built($args{statement});
    if ($scope eq 'host') {
        $adapter->_refuse_hand_built_write($args{statement});
        $adapter->_pg_require_utf8;
    }
    my $locks = Scalar::Util::blessed($args{statement}) && $args{statement}{_selecto_row_lock} ? 1 : 0;
    # Locks taken in a transaction rolled back at the close would protect nothing.
    Selecto::Error->throw('query_rule_not_evaluable',
        "a bounded stream that locks rows needs the host's transaction: begin one, then stream",
        {reason => 'row_lock_needs_transaction'}) if $locks && $scope ne 'host';
    my $fetch_size = int($args{fetch_size} // 1);
    my $self = bless {adapter => $adapter, dbh => $dbh, key => $key, scope => $scope, pid => $$,
        name => Selecto::SQL::_savepoint_name('selecto_stream_' . $$ . '_' . ++$SERIAL),
        columns => $args{statement}->columns, closed => 0, buffer => [],
        canonical_values => $args{canonical_values} ? 1 : 0}, $class;
    $STREAMING{$key} = $self->{name};
    my $ok = eval {
        if ($scope eq 'own') {
            $dbh->begin_work;
            $self->{began} = 1;
            $adapter->_pg_begin_read(0);
        }
        my $declaration = $dbh->prepare("DECLARE $self->{name} NO SCROLL CURSOR WITHOUT HOLD FOR "
            . $adapter->_query_transport_sql($args{statement}));
        die 'cursor declaration could not be prepared' unless $declaration;
        defined($adapter->_execute_statement($declaration, $args{statement}->params)) or die 'cursor declaration failed';
        $declaration->finish;
        $self->{declared} = 1;
        # One FETCH result is all that libpq buffers, so fetch_size rows (default
        # 1) bound DBD::Pg's result allocation. RowCacheSize alone cannot.
        $self->{sth} = $dbh->prepare("FETCH FORWARD $fetch_size FROM $self->{name}")
            or die 'cursor fetch could not be prepared';
        1;
    };
    unless ($ok) {
        my $error = $adapter->normalize_error($@);
        # (Nothing but the stream's own statements ran since it began.)
        die($self->_finish(0, 'opening') // $error);
    }
    $OWNED{$key} = 1 if $scope eq 'own';
    return $self;
}

sub next {
    my ($self) = @_;
    return undef if $self->{closed};
    return shift @{$self->{buffer}} if @{$self->{buffer}};
    $self->_refuse_host_state;
    my $rows;
    my $ok = eval {
        require Selecto::QueryBudget;
        Selecto::QueryBudget->before_blocking($self->{dbh});
        my $sth = $self->{sth};
        defined($sth->execute) or die 'cursor fetch failed';
        $self->{types} //= [$self->{adapter}->_column_types($sth)];
        $rows = $sth->fetchall_arrayref;
        die 'cursor row fetch failed' if !$rows || $sth->err;
        $sth->finish;
        $self->{adapter}->_decode_rows($rows, $self->{types}) if $self->{canonical_values};
        1;
    };
    unless ($ok) {
        # (Read first, the failure before the handle's state: an eval resets $@, and
        # the cleanup clears the handle's error.)
        my $error = $self->{adapter}->normalize_error($@);
        my $state = eval { $self->{dbh}->state } // '';
        die($self->_finish(0, $state) // $error);
    }
    if (!@$rows) {
        $self->close;
        return undef;
    }
    $self->{buffer} = $rows;
    return shift @{$self->{buffer}};
}

sub close {
    my ($self) = @_;
    return $self if $self->{closed};
    $self->_refuse_host_state;
    my $error = $self->_finish(1);
    die $error if $error;
    return $self;
}

# In the host's transaction, a pending result or an aborted transaction is the
# host's: the stream ends without sending anything, and says so, typed.
sub _refuse_host_state {
    my ($self) = @_;
    return unless $self->{scope} eq 'host';
    my $refused = eval { $self->{adapter}->_read_guard_scope; 1 } ? undef : $@;
    return unless $refused;
    $self->_finish(0);
    die $refused;
}

# Ends the stream: its own transaction is rolled back, once it is proven still
# its own; in the host's transaction its cursor is closed when $close_cursor
# asks and the transaction is healthy and still holds it (a failure, the host's
# ROLLBACK TO or the end of its transaction already took it, and an aborted
# transaction is the host's to roll back). $failed is the SQLSTATE of the
# stream's own failure, if any. Returns an error, or undef.
sub _finish {
    my ($self, $close_cursor, $failed) = @_;
    $self->{closed} = 1;
    my $dbh = $self->{dbh};
    eval { $self->{sth}->finish } if $self->{sth};
    delete $OWNED{$self->{key}};
    delete $STREAMING{$self->{key}};
    return undef unless eval { $dbh->{Active} };
    if ($self->{scope} eq 'own') {
        return undef unless $self->{began};
        my $own = $self->_own_transaction($failed);
        return Selecto::Error->new(code => 'transaction_state_unsafe',
            message => 'the host took over the connection while the stream was open; its transaction was left alone',
            details => {state => 'ownership_lost'}) unless $own;
        return undef if $own eq '1' && eval { local $dbh->{PrintError} = 0; local $dbh->{RaiseError} = 1; $dbh->rollback; 1 };
        # A transaction that cannot be ended, or proven its own, is not left for
        # the host to commit: the connection goes.
        # (A cancel on the ROLLBACK itself leaves DBI no SQLSTATE: its message says so.)
        my $cancelled = (grep { ($_ // '') eq '57014' } $failed, $self->{check_state}, eval { $dbh->state })
            || (eval { $dbh->errstr } // '') =~ /canceling statement due to (?:user request|statement timeout)/;
        eval { local $dbh->{PrintError} = 0; $dbh->disconnect };
        return Selecto::Error->new(code => 'stream_cleanup_failed',
            message => 'the stream could not end its transaction: the connection was closed',
            details => {connection_closed => JSON::PP::true, ($cancelled ? (category => 'query_canceled') : ())});
    }
    return undef unless $close_cursor && $self->{declared} && (eval { $dbh->pg_ping } // 0) == 3;
    my $ok = eval {
        local $dbh->{PrintError} = 0;
        local $dbh->{RaiseError} = 1;
        my ($open) = $dbh->selectrow_array(
            q{SELECT pg_catalog.count(*) FROM pg_catalog.pg_cursors WHERE name OPERATOR(pg_catalog.=) $1}, undef, $self->{name});
        $dbh->do("CLOSE $self->{name}") if $open;
        1;
    };
    return $ok ? undef : $self->{adapter}->normalize_error($@);
}

# Whether the open transaction is still the stream's own. A host that rolled it
# back (and perhaps began its own) took the cursor with it: an idle connection,
# no cursor of this name, or a FETCH that found none (34000) says so. After the
# stream's own failure the transaction cannot answer, and that failure proves it;
# during the opening nothing else can have run. 'unknown' when the check itself
# fails (a cancel landing on it).
sub _own_transaction {
    my ($self, $failed) = @_;
    my $dbh = $self->{dbh};
    return 1 if defined($failed) && $failed eq 'opening';
    return 0 if defined($failed) && $failed eq '34000';
    my $status = eval { $dbh->pg_ping } // 0;
    return 1 if $status == 4 && defined $failed;
    return 0 unless $status == 3;
    my $open;
    my $checked = eval {
        local $dbh->{PrintError} = 0;
        local $dbh->{RaiseError} = 1;
        ($open) = $dbh->selectrow_array(q{SELECT pg_catalog.count(*) FROM pg_catalog.pg_cursors WHERE name OPERATOR(pg_catalog.=) $1},
            undef, $self->{name});
        1;
    };
    $self->{check_state} = eval { $dbh->state } unless $checked;
    return 'unknown' unless $checked;
    return $open ? 1 : 0;
}

# Destruction cannot raise: a stream dropped open is closed, and a failure warns.
# A forked copy ends nothing on the server (the connection is the parent's).
sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT' || $self->{closed};
    if (defined($self->{pid}) && $self->{pid} != $$) {
        delete $OWNED{$self->{key}};
        delete $STREAMING{$self->{key}};
        $self->{closed} = 1;
        return;
    }
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
deadlines remain separate requirements. Rows hold the driver's values; with
C<< canonical_values => 1 >> each batch is decoded to canonical values column
by column (see L<Selecto::PostgreSQL/RESULT VALUES>).

On a handle with AutoCommit on, the stream begins a C<READ ONLY> transaction of its
own and rolls it back at the close. Until then Selecto's own reads, writes and
streams on the handle refuse with C<handle_owned_by_stream>. The host's own DBI calls
on it would run inside that transaction (a write fails as read-only; C<begin_work>
fails as DBI is already in a transaction), so call C<begin_work> before the stream
to use the handle between fetches. A stream that locks rows (C<for_update>,
C<for_share>) needs the host's transaction (C<row_lock_needs_transaction>).

Inside the host's transaction the cursor is the host's like any statement: the host
may write between fetches, a failed fetch leaves the transaction for the host to roll
back, and a C<ROLLBACK TO> a savepoint taken before the stream, or the end of the
transaction, takes the cursor away (the next fetch fails). The close closes a cursor
that is still open.

Only one bounded stream may be active on a handle. It closes on exhaustion, failure or
destruction; call C<close> explicitly on early termination. A stream whose own
transaction cannot be rolled back closes the connection (C<stream_cleanup_failed>,
details C<connection_closed>), so a later C<COMMIT> fails rather than reports success.
A forked child's copy of the stream ends nothing on the server.

=cut
