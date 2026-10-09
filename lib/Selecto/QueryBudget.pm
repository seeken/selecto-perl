package Selecto::QueryBudget;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Selecto::Error ();

my %ACTIVE;
sub _now { clock_gettime(CLOCK_MONOTONIC) }

# Sets a transaction-scoped statement_timeout of the stricter of $1 milliseconds and the
# current setting (0 is none). The subquery is evaluated first, so it reads the setting
# in force before this statement changes it.
use constant TRANSACTION_TIMEOUT_SQL => q{SELECT set_config('statement_timeout', }
    . q{CAST(CASE WHEN current_ceiling.ms > 0 AND current_ceiling.ms < CAST($1 AS bigint) }
    . q{THEN current_ceiling.ms ELSE CAST($1 AS bigint) END AS text) || 'ms', true) }
    . q{FROM (SELECT CAST(setting AS bigint) AS ms FROM pg_settings }
    . q{WHERE name = 'statement_timeout' OFFSET 0) AS current_ceiling};

sub supported {
    my ($class, $adapter) = @_;
    my $name = $adapter->name;
    my $dbh = $adapter->dbh;
    return 0 unless eval { $dbh->isa('DBI::db') };
    return $dbh->can('sqlite_progress_handler') && $dbh->can('sqlite_busy_timeout') ? 1 : 0
        if $name eq 'sqlite';
    return 1 if $name =~ /\A(?:postgresql|mysql|mariadb)\z/;
    return defined(eval { $dbh->{odbc_query_timeout} }) ? 1 : 0 if $name eq 'mssql';
    return 0;
}

sub begin {
    my ($class, $adapter, %options) = @_;
    my $ms = $options{timeout_ms};
    Selecto::Error->throw('invalid_query_budget', 'query timeout must be a positive bounded integer')
        unless defined($ms) && !ref($ms) && "$ms" =~ /\A[1-9]\d{0,8}\z/;
    Selecto::Error->throw('query_budget_unsupported', 'adapter cannot enforce a database query deadline')
        unless $class->supported($adapter);
    my $dbh = $adapter->dbh;
    my $identity = refaddr($dbh);
    Selecto::Error->throw('query_budget_busy', 'database handle already has an active query budget')
        if $ACTIVE{$identity};
    Selecto::Error->throw('query_budget_unavailable', 'database handle requires recovery after a budget restore failure')
        if $dbh->{private_selecto_query_budget_poisoned};
    my $self = bless {dbh => $dbh, identity => $identity, deadline => _now() + $ms / 1000,
        closed => 0, restore => sub {}}, $class;
    $ACTIVE{$identity} = $self;
    weaken($ACTIVE{$identity});
    my $name = $adapter->name;
    my $ok = eval {
        if ($name eq 'sqlite') {
            my $busy = $dbh->sqlite_busy_timeout;
            my $prior = $adapter->query_budget_progress_handler;
            Selecto::Error->throw('invalid_query_budget', 'configured SQLite progress handler is invalid')
                if defined($prior) && (ref($prior) ne 'HASH' || ref($prior->{callback}) ne 'CODE'
                    || !defined($prior->{opcodes}) || "$prior->{opcodes}" !~ /\A[1-9]\d{0,8}\z/);
            $self->{restore} = sub {
                $dbh->sqlite_progress_handler($prior ? $prior->{opcodes} : 0,
                    $prior ? $prior->{callback} : undef);
                $dbh->sqlite_busy_timeout($busy);
            };
            my $deadline = $self->{deadline};
            my $callback = $prior ? $prior->{callback} : undef;
            $dbh->sqlite_busy_timeout($busy && $busy < $ms ? $busy : $ms);
            my $interval = $prior && $prior->{opcodes} < 1000 ? $prior->{opcodes} : 1000;
            $dbh->sqlite_progress_handler($interval, sub {
                return 1 if _now() >= $deadline;
                return $callback ? $callback->() : 0;
            });
        } elsif ($name eq 'postgresql' && !$dbh->{AutoCommit}) {
            # Inside a transaction: SET LOCAL semantics. The setting lasts until the host's
            # transaction ends, when PostgreSQL drops it, so nothing is read back or restored,
            # and no budget can leave a session-wide timeout behind (a session-scoped restore
            # would read back a transaction-scoped value and keep it). One statement reads the
            # current ceiling and applies the stricter of it and the budget, so a stricter
            # host ceiling is never replaced; re-arming the same way can only tighten it.
            my $arm = sub {
                my ($limit_ms) = @_;
                defined(scalar $dbh->selectrow_array(TRANSACTION_TIMEOUT_SQL, undef, $limit_ms))
                    or die 'query timeout configuration failed';
            };
            $arm->($ms);
            $self->{rearm} = $arm;
        } elsif ($name eq 'postgresql') {
            my ($prior) = $dbh->selectrow_array(q{SELECT current_setting('statement_timeout')});
            $self->{restore} = sub {
                defined($dbh->do(q{SELECT set_config('statement_timeout', ?, false)}, undef, $prior))
                    or die 'query timeout restoration failed';
            };
            # PostgreSQL exposes a typed millisecond conversion independent of
            # display units. Never replace a stricter existing host ceiling.
            my ($prior_ms) = $dbh->selectrow_array(q{SELECT setting::bigint FROM pg_settings WHERE name = 'statement_timeout'});
            my $effective = $prior_ms && $prior_ms < $ms ? $prior_ms : $ms;
            defined($dbh->do(q{SELECT set_config('statement_timeout', ?, false)}, undef, $effective . 'ms'))
                or die 'query timeout configuration failed';
            $self->{rearm} = sub {
                my ($remaining) = @_;
                $remaining = $prior_ms if $prior_ms && $prior_ms < $remaining;
                defined($dbh->do(q{SELECT set_config('statement_timeout', ?, false)}, undef, $remaining . 'ms'))
                    or die 'query timeout configuration failed';
            };
        } elsif ($name eq 'mysql' || $name eq 'mariadb') {
            my $setting = $name eq 'mysql' ? 'max_execution_time' : 'max_statement_time';
            my ($prior) = $dbh->selectrow_array('SELECT @@SESSION.' . $setting);
            my $value = $name eq 'mysql' ? 0 + $ms : $ms / 1000;
            $value = $prior if $prior && $prior < $value;
            $self->{restore} = sub {
                defined($dbh->do('SET SESSION ' . $setting . ' = ?', undef, $prior))
                    or die 'query timeout restoration failed';
            };
            defined($dbh->do('SET SESSION ' . $setting . ' = ?', undef, $value))
                or die 'query timeout configuration failed';
        } elsif ($name eq 'mssql') {
            my $prior = $dbh->{odbc_query_timeout};
            my $seconds = int(($ms + 999) / 1000);
            $seconds = $prior if $prior && $prior < $seconds;
            $self->{restore} = sub { $dbh->{odbc_query_timeout} = $prior; };
            $dbh->{odbc_query_timeout} = $seconds;
            die 'query timeout configuration failed' unless $dbh->{odbc_query_timeout} == $seconds;
        }
        1;
    };
    if (!$ok) {
        eval { $self->close };
        Selecto::Error->throw('query_budget_unavailable', 'database query deadline could not be configured');
    }
    return $self;
}

sub check {
    my ($self, %options) = @_;
    my $remaining = $self->{deadline} - _now();
    Selecto::Error->throw('query_budget_exceeded', 'query time budget exceeded')
        if $self->{closed} || $remaining <= 0;
    # A server statement timeout resets for each FETCH. Shrink it before the
    # next blocking operation so later statements share the same wall budget.
    # A caller whose next blocking operation is a bounded stream FETCH may
    # defer that to the stream, which re-arms just before it fetches; rows
    # already buffered then cost no round trip.
    return 1 unless $self->{rearm};
    if ($options{defer_rearm}) {
        $self->{rearm_pending} = 1;
        return 1;
    }
    $self->_rearm($remaining);
    return 1;
}

# Applies a deferred re-arm for the budget active on $dbh, if any, right before
# a blocking operation. The deadline is checked again at that moment.
sub before_blocking {
    my ($class, $dbh) = @_;
    my $self = $ACTIVE{refaddr($dbh)};
    return 1 unless ref($self) && $self->{rearm_pending};
    my $remaining = $self->{deadline} - _now();
    Selecto::Error->throw('query_budget_exceeded', 'query time budget exceeded')
        if $self->{closed} || $remaining <= 0;
    $self->_rearm($remaining);
    return 1;
}

sub _rearm {
    my ($self, $remaining) = @_;
    my $ms = int($remaining * 1000);
    $ms = 1 if $ms < 1;
    eval { $self->{rearm}->($ms); 1 }
        or Selecto::Error->throw('query_budget_unavailable', 'database query deadline could not be refreshed');
    $self->{rearm_pending} = 0;
    return;
}

sub close {
    my ($self) = @_;
    return if $self->{closed};
    $self->{closed} = 1;
    my $ok = eval { $self->{restore}->(); 1 };
    delete $ACTIVE{$self->{identity}};
    if (!$ok) {
        $self->{dbh}{private_selecto_query_budget_poisoned} = 1;
        Selecto::Error->throw('query_budget_restore_failed', 'database query deadline could not be restored');
    }
    return;
}

sub DESTROY { my ($self) = @_; local $@; eval { $self->close } unless $self->{closed}; }
1;

__END__

=head1 NAME

Selecto::QueryBudget - scoped driver and server query deadlines

=head1 DESCRIPTION

Obtain a guard with C<< $adapter->begin_query_budget(timeout_ms => 5000) >>.
On PostgreSQL inside a transaction (C<AutoCommit> off), the server timeout is
set with C<SET LOCAL> semantics in one round trip: it applies to the rest of
that transaction (never loosening a stricter setting) and PostgreSQL drops it
when the transaction ends, so C<close> restores nothing. Outside a transaction
the session setting is set and restored on C<close>.
Keep it alive through execution and fetch, call C<check> between application
operations, and call C<close> after closing result streams. Between rows of a
bounded stream, C<< check(defer_rearm => 1) >> checks the wall deadline but
leaves refreshing the server timeout to the stream, which does it right before
its next FETCH (C<before_blocking>); buffered rows then need no round trip.
Use it only when the stream's FETCH is the next blocking operation. Close restores
host settings and is idempotent. A driver interruption is normalized by the
adapter; C<check> reports C<query_budget_exceeded> after the wall deadline.

Supported drivers configure a database interruption mechanism in addition to
the monotonic application deadline. A capability does not promise that the
driver incrementally buffers results; use C<bounded_stream_supported> for that.
An overlapping guard on the same handle is refused. Failed restoration poisons
the handle for future budgets, requiring deliberate host recovery or replacement.

SQLite hosts with an existing progress callback must register it through the
adapter's C<query_budget_progress_handler> option or use a dedicated handle.
Do not mutate timeout/progress settings while a guard is active. See
F<docs/security-boundaries.md> for limits and migration details.

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.
Licensed under the Artistic License 2.0 (GPL Compatible).

=cut
