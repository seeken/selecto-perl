package Selecto::PostgreSQL::Stream;

use 5.034;
use strict;
use warnings;
use parent 'Selecto::Stream';
use JSON::PP ();
use Scalar::Util ();
use Selecto::Error ();

my $SERIAL = 0;
# R64: session code run by anything else on the connection between fetches can
# CLOSE this cursor and DECLARE another of the same name, read from pg_cursors.
# Its statement and creation time identify it: no DECLARE can reproduce the
# time. Each batch checks them before its FETCH. The time is read as an epoch, so
# a changed TimeZone is the session check's to report, not a replacement.
# While a stream runs in a transaction of its own (a handle with none open), the handle
# is the stream's until it closes: anything else run on it would run in that
# transaction and be rolled back with it. So nothing else may reach the server through
# it (handle_owned_by_stream). $PASS is set while the stream's own code runs.
our $PASS = 0;
my %OWNED_ALLOWED = map { ($_ => 1) } qw(FETCH EXISTS FIRSTKEY NEXTKEY err errstr state set_err trace trace_msg
    parse_trace_flag parse_trace_flags quote quote_identifier can disconnect clone DESTROY private_attribute_info
    visit_child_handles debug);
my %CHILD_BLOCKED = map { ($_ => 1) } qw(execute execute_array execute_for_fetch);
my $CURSOR_SQL = q{SELECT c.statement, CAST(EXTRACT(EPOCH FROM c.creation_time) AS pg_catalog.text) FROM pg_catalog.pg_cursors c }
    . q{WHERE c.name OPERATOR(pg_catalog.=) CAST($1 AS pg_catalog.text)};

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
    $adapter->_pg_require_utf8($scope) if $adapter->_pg_session_checked;
    # Chosen here and declared explicitly, so the cursor is identified by this
    # name and never by searching pg_cursors. Not guessable ahead of time; one
    # that is pre-declared fails the DECLARE, and the stream does not open.
    my $name = Selecto::SQL::_savepoint_name('selecto_stream_' . $$ . '_' . ++$SERIAL);
    my $fetch_size = int($args{fetch_size} // 1);
    my $self = bless {adapter => $adapter, dbh => $dbh, name => $name,
        locks => Scalar::Util::blessed($args{statement}) && $args{statement}{_selecto_row_lock} ? 1 : 0,
        columns => $args{statement}->columns, closed => 0, buffer => [],
        canonical_values => $args{canonical_values} ? 1 : 0}, $class;
    # A stream that locks rows is not read only, and on an idle handle it would run in a
    # transaction of Selecto's that is rolled back at the close: whatever the host wrote
    # on the handle between fetches would join it and be lost, each write reporting OK.
    # Its locks need the host's transaction, as they would last no longer than the read.
    Selecto::Error->throw('query_rule_not_evaluable',
        "a bounded stream that locks rows needs the host's transaction: begin one, then stream",
        {reason => 'row_lock_needs_transaction'}) if $self->{locks} && $scope ne 'host';
    $dbh->{private_selecto_bounded_stream} = $name;
    my $ok = eval {
        # The scope is recorded only once the savepoint or transaction exists,
        # so a failed start never rolls back anything.
        # (Together, whatever a host's alarm does: see _pg_uninterrupted.) A hand-built
        # statement that locks rows refuses here: its FETCH would hold no lock past the
        # batch's rollback, and its DECLARE is not under the read-only mode.
        $adapter->_pg_hold_relations($args{statement}) if $scope eq 'host' && Selecto::PostgreSQL::_pg_hand_built($args{statement});
        if ($scope eq 'host') {
            Selecto::PostgreSQL::_pg_uninterrupted(sub {
                $adapter->_savepoint_command(create => $name);
                $self->{scope} = 'host';
                $self->{opening} = 1;
            });
        } else {
            # The transaction's virtual id proves at close that it is still
            # this stream's own before it is rolled back. No statement can
            # forge it, unlike a GUC marker (item 57).
            Selecto::PostgreSQL::_pg_uninterrupted(sub {
                $adapter->_begin_transaction;
                $self->{scope} = 'own';
                # (A stream that locks rows cannot be read only.)
                _do($dbh, 'SET TRANSACTION READ ONLY, NOT DEFERRABLE') unless $self->{locks};
                $self->{transaction} = $adapter->_virtual_transaction_id;
            });
            die 'stream transaction identity is unavailable' unless defined $self->{transaction};
        }
        # search_path and the result-affecting settings pinned for the
        # stream (R30, R35); then temp shadows refused and the session snapshot
        # taken before the cursor; every FETCH is compared with it (items 56,
        # 61). In its own transaction the pin lasts to the end. Inside the
        # host's, it lasts only while the stream's own statements run: the host's
        # values are back before the opening savepoint is released, and each
        # FETCH sets the pin again under its batch savepoint. The host's own
        # statements between fetches run under the host's settings.
        # (Not a hand-built statement's, which runs in the host's session: R71.)
        if ($adapter->_pg_session_checked && !Selecto::PostgreSQL::_pg_hand_built($args{statement})) {
            {
                local $adapter->{_selecto_reset_operation} = {};
                $adapter->_pg_check_relations($args{statement});
                $self->{pin} = $adapter->_pg_pin_search_path(0, $args{statement});
            }
            $self->{session} = $adapter->_pg_admit_session($args{statement}, read => 1);
        }
        my $declaration = $dbh->prepare('DECLARE ' . $name . ' NO SCROLL CURSOR WITHOUT HOLD FOR '
            . $adapter->_query_transport_sql($args{statement}));
        die 'cursor declaration could not be prepared' unless $declaration;
        defined($adapter->_execute_statement($declaration, $args{statement}->params))
            or die 'cursor declaration failed';
        $self->{declared} = 1;
        $declaration->finish;
        if ($adapter->_pg_session_checked) {
            my @cursor = $dbh->selectrow_array($CURSOR_SQL, undef, $name);
            die 'stream cursor identity is unavailable' unless @cursor && defined $cursor[1];
            $self->{cursor} = \@cursor;
        }
        # One FETCH result is all that libpq can buffer, so fetch_size rows
        # (default 1) bound DBD::Pg's eager result allocation. RowCacheSize
        # alone cannot.
        $self->{sth} = $dbh->prepare("FETCH FORWARD $fetch_size FROM $name")
            or die 'cursor fetch could not be prepared';
        # The savepoint only guards the opening. The cursor outlives it; the pin does
        # not, since a RELEASE keeps what SET LOCAL set and the host's values are put
        # back first. From here the stream holds nothing the host could release or
        # roll back to, and nothing a failure could take the host's own work back to.
        Selecto::PostgreSQL::_pg_uninterrupted(sub {
            _do($dbh, ($self->{pin} ? _settings_sql($dbh, $self->{pin}{host}) . '; ' : '') . "RELEASE SAVEPOINT $name");
            delete $self->{opening};
        }) if $self->{opening};
        1;
    };
    if (!$ok) {
        my $error = $adapter->normalize_error($@);
        # Nothing but this stream's own statements ran since the state check.
        my $origin = $self->_failure_origin;
        my $cleanup = eval { $self->_close($origin); 1 } ? undef : $@;
        die _cleanup_error($cleanup) // $error;
    }
    # In its own transaction, the handle is the stream's until it closes (see $PASS).
    $self->{pid} = $$;
    $self->_own_handle if $self->{scope} eq 'own';
    return $self;
}

sub next {
    my ($self) = @_;
    local $PASS = 1;
    return undef if $self->{closed};
    # Under SELECTO_PG_SQL_LINT, the stream's own statements are Selecto's.
    local $self->{dbh}{private_selecto_lint_depth} = 1 if $ENV{SELECTO_PG_SQL_LINT};
    return shift @{$self->{buffer}} if @{$self->{buffer}};
    my $rows;
    my $ok = eval {
        my $sth = $self->{sth};
        require Selecto::QueryBudget;
        Selecto::QueryBudget->before_blocking($self->{dbh});
        # Before the FETCH: during it the portal is active and cannot be closed,
        # so nothing can replace it after this check. A replacement of another
        # width would also crash the driver's fetch (DBI's field count).
        # Only a cursor of this name that differs is a replacement. No answer,
        # or no such cursor, is the transaction's state, not a replacement: the
        # FETCH then fails and _failure_origin says whose failure that is (the
        # host may have rolled back, aborted or moved on). It is never ours to
        # assume, because the cleanup would act on the host's transaction.
        # R55: a stream's own transaction is READ ONLY. Inside the host's, the host
        # may write between fetches, so each FETCH is read-only under a savepoint
        # of its own, which is rolled back; a cursor keeps its position through
        # that. The pin is set again under it, and the rollback takes it away: in the
        # stream's own transaction too, so the host's statements between fetches see
        # the host's settings. One that locks rows is not read only, and its savepoint
        # is released, so the locks last to the host's commit: the host's values are
        # put back first.
        # The cursor check is in the same message, under the savepoint (R72): a cancel
        # on it is rolled back to. (The SAVEPOINT itself can still be cancelled; the
        # transaction is then aborted and the cancel reaches the host as one.)
        my $batch = $self->{adapter}->_pg_session_checked && ($self->{scope} // '') eq 'host' ? "$self->{name}_batch" : undef;
        my @now;
        if (defined $batch) {
            Selecto::PostgreSQL::_pg_uninterrupted(sub {
                my $dbh = $self->{dbh};
                my $pin = $self->{pin};
                $self->{batch} = $batch;
                my $open = "SAVEPOINT $batch" . ($pin && !$self->{locks} ? '; ' . _settings_sql($dbh, $pin->{applied}) : '')
                    . ($self->{locks} ? '' : '; SET LOCAL transaction_read_only = on');
                if ($self->{cursor}) { @now = $self->_cursor_now($open) } else { _do($dbh, $open) }
                $self->{batch_host} = $self->_pin_capturing_host if $pin && $self->{locks};
            });
        } elsif ($self->{cursor}) {
            @now = $self->_cursor_now;
        }
        # Before the FETCH: during it the portal is active and cannot be closed,
        # so nothing can replace it after this check. A replacement of another
        # width would also crash the driver's fetch (DBI's field count).
        # Only a cursor of this name that differs is a replacement. No answer,
        # or no such cursor, is the transaction's state, not a replacement: the
        # FETCH then fails and _failure_origin says whose failure that is (the
        # host may have rolled back, aborted or moved on). It is never ours to
        # assume, because the cleanup would act on the host's transaction.
        Selecto::Error->throw('query_rule_not_evaluable', "the stream's cursor was replaced while it was open",
            {reason => 'stream_cursor_replaced'})
            if $self->{cursor} && @now && defined($now[1]) && !($now[0] eq $self->{cursor}[0] && $now[1] eq $self->{cursor}[1]);
        defined($sth->execute) or die 'cursor fetch failed';
        $self->{types} //= [$self->{adapter}->_column_types($sth)];
        $rows = $sth->fetchall_arrayref;
        die 'cursor row fetch failed' if !$rows || $sth->err;
        $sth->finish;
        # Nothing of a batch is handed out before its session check: a
        # function the statement calls may have switched search_path or made
        # a temp relation while the server produced it.
        if ($self->{session}) {
            my $after = eval { $self->{adapter}->_pg_session_state(undef, read => 1) };
            # (A cancel is a cancel: no answer is not a changed session.)
            die $@ if !$after && Scalar::Util::blessed($@) && ($@->details->{category} // '') eq 'query_canceled';
            unless ($after && $after->{snapshot} eq $self->{session}{snapshot}) {
                $self->{session_changed} = 1;
                die 'session state changed';
            }
        }
        if (defined $batch) {
            Selecto::PostgreSQL::_pg_uninterrupted(sub {
                my $host = $self->{batch_host};
                _do($self->{dbh}, ($self->{locks} ? ($host ? _settings_sql($self->{dbh}, $host) . '; ' : '')
                    : "ROLLBACK TO SAVEPOINT $batch; ") . "RELEASE SAVEPOINT $batch");
                delete @{$self}{qw(batch batch_host)};
            });
        }
        $self->{adapter}->_decode_rows($rows, $self->{types}) if $self->{canonical_values};
        1;
    };
    if (!$ok) {
        # Capture PostgreSQL's error state before transaction recovery clears it.
        # (Read first: what follows clears the handle's state.)
        my $gone = ($self->{scope} // '') eq 'host' && (eval { $self->{dbh}->state } // '') =~ /\A(?:34000|25P01)\z/;
        my $error = $self->{adapter}->normalize_error($@);
        # A changed session is the stream's own work to undo: its savepoint
        # or its own transaction is rolled back, which reverts the change.
        my $origin = $self->{session_changed} ? 'own' : $self->_failure_origin;
        $error = eval { Selecto::PostgreSQL::_session_changed(); 1 } ? $error : $@ if $self->{session_changed};
        my $cleanup = eval { $self->_close($origin); 1 } ? undef : $@;
        my $raised = _cleanup_error($cleanup) // $error;
        # The cursor or the transaction is gone because the host ended its transaction
        # (or rolled back past the stream): that is the host's transaction, not a fault.
        $raised = Selecto::Error->new(code => 'transaction_state_unsafe',
            message => 'the host ended its transaction while the stream was open; nothing was left for the stream to end',
            details => {state => 'ownership_lost'}) if $gone && !defined $cleanup;
        die $raised;
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
    local $PASS = 1;
    my ($dbh, $adapter, $name) = @{$self}{qw(dbh adapter name)};
    eval { $self->{sth}->finish } if $self->{sth};
    my ($unsafe, $ran, $broken, $cancelled, $finished);
    # (Closed only from here: a host's alarm before this leaves it for DESTROY to end.)
    my $end = sub {
        $ran = 1;
        $self->{closed} = 1;
        # A disconnected handle has already lost its server cursor/transaction.
        $finished = 1, return unless $dbh->{Active} && $self->{scope};
        if ((defined($failure) && $failure eq 'foreign') || eval { $dbh->{pg_async_status} }) {
            $unsafe = 'the host aborted or took over the transaction while the stream was open';
        } elsif ($self->{scope} eq 'own') {
            $unsafe = $self->_own_transaction_unproven($failure);
            if (defined($unsafe) && $unsafe eq 'unknown') {
                ($unsafe, $broken, $cancelled) = (undef, 1, 1);
            } elsif (!$unsafe) {
                # A read-only stream never commits work on behalf of its caller. A cancel
                # can land on the ROLLBACK itself: DBI then counts the transaction over,
                # the server does not. So, as a read does, it is tried again as a
                # statement, and a cancel that stops even that stays a cancel.
                unless (eval { local $dbh->{PrintError} = 0; local $dbh->{RaiseError} = 1; $dbh->rollback }) {
                    my $state = eval { $dbh->state } // '';
                    my $rolled;
                    for my $attempt (1 .. 5) {
                        last if $rolled = (eval { $dbh->pg_ping } // 0) == 1;
                        last if $rolled = eval { local $dbh->{PrintError} = 0; local $dbh->{RaiseError} = 1; $dbh->do('ROLLBACK'); 1 };
                        $state = eval { $dbh->state } // '';
                        last unless $state eq '57014';
                    }
                    if ($rolled) { eval { $dbh->{AutoCommit} = 1; $dbh->{BegunWork} = 0 } }
                    else { ($broken, $cancelled) = (1, $state eq '57014' ? 1 : $cancelled) }
                }
            }
        } elsif ($self->{opening}) {
            # Nothing of the host's can be after this savepoint yet.
            $self->_savepoint_undone($name) or $broken = 1;
        } elsif ((eval { $dbh->pg_ping } // 0) == 1) {
            # The host ended its own transaction (COMMIT or ROLLBACK, by handle or by
            # text): the cursor, the savepoints and the pin went with it, and nothing of
            # the stream's is left to end. The connection is the host's and stays.
            delete $self->{batch};
            $unsafe = 'the host ended its transaction while the stream was open';
        } else {
            # Only the batch is the stream's: a refusal never undoes the host's work
            # between fetches. That savepoint is the one it holds.
            $self->_savepoint_undone(delete $self->{batch}) or $broken = 1 if defined $self->{batch};
            my $status = eval { $dbh->pg_ping } // 0;
            if ($status == 4) {
                # Aborted, with nothing of the stream's to go back to: the failure that
                # did it is on its way to the host, or the host did it.
                $unsafe = 'the host aborted the transaction while the stream was open' unless defined $failure;
            } elsif (!$broken) {
                my $ended = $self->_end_in_transaction;
                # A cancel on its very first statement failed the transaction, with no
                # savepoint yet to go back to. An exception tells the host; DESTROY cannot.
                if ($ended eq '0 cancelled' && !$self->{destroying}) { $cancelled = 1 }
                elsif ($ended eq '1 cancelled') { $cancelled = 1 unless $self->{destroying} }
                elsif ($ended ne '1') { $broken = 1 }
            }
        }
        $finished = 1;
    };
    # (A host's alarm cannot part these: one on its way is taken before they start, one
    # held back arrives after, and it stands once this is done.)
    my $alarm;
    for my $attempt (1 .. 3) {
        my $clean = eval { Selecto::PostgreSQL::_pg_uninterrupted($end); 1 };
        $alarm //= $@ unless $clean;
        last if $ran;
    }
    my $ok = $finished;
    # The handle is the host's again, however this ends.
    $self->_release_handle;
    delete $dbh->{private_selecto_bounded_stream};
    if ($unsafe) {
        Selecto::Error->throw('transaction_state_unsafe',
            "$unsafe; its savepoint or transaction was left for the host to roll back",
            {state => 'ownership_lost'});
    }
    Selecto::Error->throw('query_error', 'Execution failed', {cause => 'database_error', sqlstate => '57014', category => 'query_canceled'})
        if $cancelled && !$broken && !defined $failure;
    if (!$ok || $broken) {
        # What cannot be ended is not left to look fine: a host that goes on to COMMIT
        # would be told it worked. The connection goes, and says so.
        eval { local $dbh->{PrintError} = 0; $dbh->disconnect };
        Selecto::Error->throw('stream_cleanup_failed', 'database stream could not restore its transaction scope: the connection was closed',
            {state => 'unknown', connection_closed => JSON::PP::true, ($cancelled ? (category => 'query_canceled') : ())});
    }
    die $alarm if defined $alarm && !defined $failure;
    return $self;
}

# The handle becomes the stream's: DBI callbacks refuse anything that would reach the
# server through it, on it and on every statement handle prepared from it, before or
# during the stream (handle_owned_by_stream). The host's own callbacks still run after
# the check, and are what is restored.
sub _own_handle {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return unless eval { $dbh->isa('DBI::db') };
    local $PASS = 1;
    my $owner = {owned => 1};
    my $refuse = sub {
        my ($what) = @_;
        Selecto::Error->throw('handle_owned_by_stream',
            "the handle belongs to an open bounded stream until it closes ($what): with no transaction open, the stream "
            . 'runs one of its own on it, and anything else run there would be rolled back with it. Call begin_work '
            . 'before the stream to use the handle between fetches', {method => "$what"});
    };
    my $on_handle = sub {
        return if $PASS || !$owner->{owned} || $OWNED_ALLOWED{$_};
        return if $_ eq 'STORE' && ($_[1] // '') !~ /\A(?:AutoCommit|BegunWork)\z/;
        $refuse->($_);
    };
    my $on_statement = sub {
        return if $PASS || !$owner->{owned} || !($CHILD_BLOCKED{$_} || /\Apg_/);
        $refuse->("statement $_");
    };
    my $merge = sub {
        my ($check, $host) = @_;
        my %merged = ref($host) eq 'HASH' ? %$host : ();
        for my $key (grep { $_ ne 'ChildCallbacks' } keys %merged) {
            my $theirs = $merged{$key};
            $merged{$key} = ref($theirs) eq 'CODE' ? sub { $check->(@_); goto &$theirs } : $check;
        }
        $merged{'*'} //= $check;
        return \%merged;
    };
    my $host = $dbh->{Callbacks};
    my $mine = $merge->($on_handle, $host);
    $mine->{ChildCallbacks} = $merge->($on_statement, ref($host) eq 'HASH' ? $host->{ChildCallbacks} : undef);
    my @children;
    for my $sth (grep { defined } @{$dbh->{ChildHandles} // []}) {
        my $before = $sth->{Callbacks};
        push @children, [$sth, $before];
        Scalar::Util::weaken($children[-1][0]);
        $sth->{Callbacks} = $merge->($on_statement, $before);
    }
    $self->{owned} = {owner => $owner, callbacks => $host, children => \@children};
    $dbh->{Callbacks} = $mine;
    $dbh->{private_selecto_stream_owned} = 1;
    return;
}

sub _release_handle {
    my ($self) = @_;
    my $owned = delete $self->{owned} or return;
    $owned->{owner}{owned} = 0;
    local $PASS = 1;
    my $dbh = $self->{dbh};
    # (Exactly as they were: undef where the host had none, which DBI stores with a warning.)
    no warnings 'uninitialized';
    eval { $dbh->{Callbacks} = $owned->{callbacks}; delete $dbh->{private_selecto_stream_owned} };
    for my $child (@{$owned->{children}}) { eval { $child->[0]{Callbacks} = $child->[1] } if defined $child->[0] }
    return;
}

# Rolls back to a savepoint of the stream's and releases it. A cancel is tried again.
# 3B001 is a savepoint never taken, or one the host has already released. Anything
# else is a failure: returns false.
sub _savepoint_undone {
    my ($self, $name) = @_;
    my $dbh = $self->{dbh};
    for my $attempt (1 .. 5) {
        return 1 if eval { local $dbh->{PrintError} = 0; local $dbh->{RaiseError} = 1; $dbh->do("ROLLBACK TO SAVEPOINT $name; RELEASE SAVEPOINT $name"); 1 };
        my $state = eval { $dbh->state } // '';
        return 1 if $state eq '3B001';
        return 0 unless $state eq '57014';
    }
    return 0;
}

# The end of a stream in the host's transaction: its cursor goes (the pin went with
# the opening and with each batch), under a
# savepoint of their own, so a cancel costs the host nothing. A cursor already gone
# went with a host's ROLLBACK TO, which is legal. Returns whether it is done.
sub _end_in_transaction {
    my ($self) = @_;
    my ($dbh, $adapter, $name) = @{$self}{qw(dbh adapter name)};
    my $end = "${name}_end";
    for my $attempt (1 .. 5) {
        my $done = eval {
            local $dbh->{PrintError} = 0;
            local $dbh->{RaiseError} = 1;
            $dbh->do("SAVEPOINT $end");
            if ($self->{declared}) {
                my @cursor = $dbh->selectrow_array($CURSOR_SQL, undef, $name);
                $dbh->do("CLOSE $name") if @cursor;
            }
            $dbh->do("RELEASE SAVEPOINT $end");
            1;
        };
        # (A cancel that landed on an earlier try is still a cancel: R66(d).)
        return $self->{end_cancelled} ? '1 cancelled' : 1 if $done;
        my $state = eval { $dbh->state } // '';
        my $cancelled = $state eq '57014' || (Scalar::Util::blessed($@) && ($@->details->{category} // '') eq 'query_canceled');
        $self->{end_cancelled} = 1 if $cancelled;
        return 0 unless $self->_savepoint_undone($end);
        return $cancelled ? '0 cancelled' : 0 unless (eval { $dbh->pg_ping } // 0) == 3;
        return 0 unless $cancelled;
    }
    return 0;
}

# Undef when the open transaction is provably the one this stream began,
# otherwise why it is not. After the stream's own statement failed the
# transaction is aborted and can answer nothing, but that failure proves its
# cursor, and so its transaction, was still there; otherwise the marker it
# set when it began must still be in force. The marker is read under a savepoint, so a
# cancel on it costs nothing and it is read again. 'unknown': a cancel stopped even
# that, and nothing can be proved.
sub _own_transaction_unproven {
    my ($self, $failure) = @_;
    return undef if defined($failure) && $failure eq 'own';
    my $dbh = $self->{dbh};
    my $mark = "$self->{name}_mark";
    for my $attempt (1 .. 5) {
        my $marker;
        my $read = eval {
            local $dbh->{RaiseError} = 1;
            local $dbh->{PrintError} = 0;
            $dbh->do("SAVEPOINT $mark");
            $marker = $self->{adapter}->_virtual_transaction_id;
            $dbh->do("RELEASE SAVEPOINT $mark");
            1;
        };
        return defined($marker) && defined($self->{transaction}) && $marker eq $self->{transaction}
            ? undef : 'the host took over the connection while the stream was open' if $read;
        return 'the host took over the connection while the stream was open' unless (eval { $dbh->state } // '') eq '57014';
        return 'unknown' unless eval { local $dbh->{RaiseError} = 1; local $dbh->{PrintError} = 0; $dbh->do("ROLLBACK TO SAVEPOINT $mark; RELEASE SAVEPOINT $mark"); 1 };
    }
    return 'unknown';
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

# This stream's cursor as pg_cursors has it now, read after $prefix in one message
# when there is one. (An error here fails this batch, as the FETCH would.)
sub _cursor_now {
    my ($self, $prefix) = @_;
    my $dbh = $self->{dbh};
    (my $sql = $CURSOR_SQL) =~ s/\$1/$dbh->quote($self->{name})/e;
    my @now;
    eval { local $dbh->{RaiseError} = 1; local $dbh->{PrintError} = 0;
        @now = $dbh->selectrow_array(defined($prefix) ? "$prefix; $sql" : $sql); 1 } or die $@;
    return @now;
}

# The statement that sets each setting to its value for the transaction. Values are
# literals: one round trip with the statements around it.
sub _settings_sql {
    my ($dbh, $pairs) = @_;
    return 'SELECT ' . join(', ', map { "pg_catalog.set_config('$_->[0]', " . $dbh->quote($_->[1]) . ', true)' } @$pairs);
}

# A locking batch: sets the pin and returns the host's values it replaced, read first
# in the same statement, for its RELEASE to put back.
sub _pin_capturing_host {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    my @pairs = @{$self->{pin}{applied}};
    my $sql = 'WITH h AS MATERIALIZED (SELECT '
        . join(', ', map { "pg_catalog.current_setting('$pairs[$_][0]') AS s$_" } 0 .. $#pairs) . ') SELECT '
        . join(', ', (map { "h.s$_" } 0 .. $#pairs),
            map { "pg_catalog.set_config('$pairs[$_][0]', " . $dbh->quote($pairs[$_][1]) . ', true)' } 0 .. $#pairs) . ' FROM h';
    my @row = $dbh->selectrow_array($sql);
    die "the host's settings could not be read\n" unless @row == 2 * @pairs && !grep { !defined } @row;
    return [map { [$pairs[$_][0], $row[$_]] } 0 .. $#pairs];
}

sub _do {
    my ($dbh, $sql) = @_;
    defined($dbh->do($sql)) or die 'stream transaction control failed';
    return;
}

# Destruction cannot raise. A cleanup that failed has closed the connection, so the
# host's next statement fails rather than a COMMIT reporting success; one that left the
# host's transaction to the host warns, and an aborted transaction stays aborted.
sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT' || $self->{closed};
    # A forked copy ends nothing on the server: the connection is the parent's. It only
    # gives its copy of the handle back.
    if (defined($self->{pid}) && $self->{pid} != $$) { $self->_release_handle; $self->{closed} = 1; return }
    local $@;
    $self->{destroying} = 1;
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

On a handle with no transaction open the stream begins a read-only transaction of
its own and rolls it back at the close, and the handle is the stream's until then.
Anything else that would reach the server through it (a statement, a prepared
statement's C<execute>, C<begin_work>, C<commit>, C<rollback>, a C<ping>, a driver
method, Selecto's own reads and writes) fails at once with C<handle_owned_by_stream>,
before it is sent; quoting, C<err>, C<state> and attributes still work. The handle is
the host's again once the stream drains, closes, fails or is dropped, with the host's
own DBI callbacks as they were (they run after the check meanwhile). A forked child's
copy of the stream ends nothing on the server. Call C<begin_work> first to use the
handle between fetches. A stream that locks rows (C<for_update>, C<for_share>)
refuses there (C<row_lock_needs_transaction>): it needs the host's transaction.

Inside an existing transaction the host can write between fetches. A savepoint guards
the opening and is released at once; after that the stream holds no savepoint between
fetches, so a host's C<SAVEPOINT>, C<RELEASE> and C<ROLLBACK TO> are its own business.
Each fetch runs read only under a savepoint of its own, rolled back afterwards; a
generated stream that locks rows keeps its locks instead, to the host's commit. A
failed fetch ends only that fetch, and then the stream: nothing the host did between
fetches is undone, and the error reaches the host. A hand-built statement that locks
rows refuses. A C<ROLLBACK TO> that takes the cursor away ends the stream at its next
fetch, with the transaction intact. A host that ends its transaction mid-stream
(C<COMMIT> or C<ROLLBACK>) ends the stream with C<transaction_state_unsafe>, and keeps
its connection. The stream's search_path and result settings are pinned for its own
statements only: between fetches the host's statements run under the host's settings,
and in the host's transaction what the host sets there is still in force after the
close.

A stream does not open on a connection with a pending host result, an aborted
transaction or an unknown state (C<transaction_state_unsafe>; see
L<Selecto::PostgreSQL/TRANSACTION STATE>). Raw C<BEGIN> is detected.

A stream rolls back only what it can prove is its own. Its own transaction is
identified by its virtual transaction id (C<pg_locks.virtualxid>), which must still be
the open transaction's at close. When the host aborted the transaction while the
stream was open (a failing statement, or a failing asynchronous query whose result is
still pending), or took the connection over (C<ROLLBACK>, C<BEGIN>), the stream's
C<next> or C<close> fails with C<transaction_state_unsafe> and leaves the connection
exactly as it is: an aborted transaction stays aborted for the host to roll back, and
the host's new transaction is never touched.

Only one bounded stream may be active on a handle. It closes on exhaustion, failure or
destruction; call C<close> explicitly on early termination. A cancel on any of its
statements is tried again. An ending that still cannot be finished closes the
connection (C<stream_cleanup_failed>, details C<connection_closed>), so that a later
C<COMMIT> fails rather than reports success.

=cut
