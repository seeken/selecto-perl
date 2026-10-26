use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util ();
use DBI;
use Selecto;
use Selecto::BoundedQuery;
use lib 't/lib';
use TestSelecto;

# Read guards (bounded streams and savepoint query budgets) and managed
# writes never start on a connection whose transaction they cannot account
# for, and never roll back anything they cannot prove is their own: an
# aborted host transaction stays aborted, a pending host result stays the
# host's, and a transaction the host took over is left alone.

sub code_of {
    my ($run) = @_;
    return 'ok' if eval { $run->(); 1 };
    my $error = $@;
    return Scalar::Util::blessed($error) && $error->isa('Selecto::Error') ? $error->code : "$error";
}
sub statement {
    my ($sql, $columns) = @_;
    return Selecto::Statement->new(sql => $sql, params => [], columns => $columns // ['n'],
        adapter_name => 'postgresql');
}

subtest 'SQLite: write savepoints are uniquely named' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE guard_items (id integer primary key, name text not null)');
    my $domain = TestSelecto::writable_domain(name => 'Items', table => 'guard_items',
        fields => {id => 'integer', name => 'string'});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my @savepoints;
    $dbh->sqlite_trace(sub { push @savepoints, $1 if $_[0] =~ /\ASAVEPOINT (\S+)/ });
    $dbh->begin_work;
    for my $id (1, 2) {
        $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'guard_items',
            assignments => {id => $id, name => "item $id"}, expected_count => 1));
    }
    is(scalar(@savepoints), 2, 'each write inside the host transaction takes a savepoint');
    isnt($savepoints[0], $savepoints[1], 'no two guards share a savepoint name');
    like($_, qr/\Aselecto_write_[0-9a-f]+_[0-9a-f]{8}\z/, 'savepoint names stay recognizable') for @savepoints;
    $dbh->rollback;
    is($dbh->selectrow_array('SELECT COUNT(*) FROM guard_items'), 0, 'the host still owns the outcome');
};

my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
unless ($db && eval { require DBD::Pg; DBD::Pg->import(':async'); 1 }) {
    done_testing;
    exit 0;
}

my $connect = sub {
    return DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, @_});
};
my $dbh = $connect->();
my $observer = $connect->();
$dbh->do('SET client_min_messages TO warning');
my $table = 'selecto_perl_test_guard_items';
my $domain = TestSelecto::writable_domain(name => 'Items', table => $table,
    fields => {id => 'integer', name => 'string'});
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $page = $engine->query->select('id')->order_by('id')->limit(5);
my $committed = sub { [map { $_->[0] } @{$observer->selectall_arrayref("SELECT id FROM $table ORDER BY id")}] };
my $insert = sub { $dbh->do("INSERT INTO $table VALUES ($_[0], 'host $_[0]')") };
my $fail = sub { eval { $dbh->do('SELECT 1/0') }; };
my $stream = sub { $adapter->stream_query(statement('SELECT n FROM generate_series(1,5) n'), bounded => 1, @_) };
my $write = sub {
    $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => $table,
        assignments => {id => $_[0], name => "selecto $_[0]"}, expected_count => 1));
};
my $reset = sub {
    eval { $dbh->pg_result } if $dbh->{pg_async_status};
    $dbh->rollback unless $dbh->{AutoCommit};
    $dbh->do('ROLLBACK') if $dbh->pg_ping >= 3;
    delete $dbh->{private_selecto_query_budget_poisoned};
    delete $dbh->{private_selecto_bounded_stream_poisoned};
    $dbh->do("DROP TABLE IF EXISTS $table");
    $dbh->do("CREATE TABLE $table (id integer primary key, name text not null)");
    $dbh->do("INSERT INTO $table VALUES (100, 'baseline')");
};
my $healthy = sub {
    my ($label) = @_;
    ok(!$dbh->{private_selecto_query_budget_poisoned} && !$dbh->{private_selecto_bounded_stream_poisoned},
        "$label: no guard was left poisoned");
    my $rows = eval { Selecto::BoundedQuery->all($engine, $page)->{rows} } // "$@";
    is_deeply($rows, [map { [$_] } @{$committed->()}], "$label: a later bounded read works");
};

subtest 'PostgreSQL 18d: a pending host result refuses every guard before anything is sent' => sub {
    for my $raw (1, 0) {
        my $how = $raw ? 'raw BEGIN' : 'begin_work';
        for my $guard (
            [stream => sub { $stream->() }],
            [bounded_read => sub { Selecto::BoundedQuery->all($engine, $page) }],
            [savepoint_budget => sub { $adapter->begin_query_budget(timeout_ms => 1000, savepoint => 1) }],
            [managed_write => sub { $write->(7) }],
        ) {
            $reset->();
            $raw ? $dbh->do('BEGIN') : $dbh->begin_work;
            $insert->(1);
            $dbh->do("SELECT pg_sleep(0.05); INSERT INTO $table VALUES (2, 'host async')", {pg_async => DBD::Pg::PG_ASYNC()});
            is(code_of($guard->[1]), 'transaction_state_unsafe', "$how, $guard->[0]: refused with a typed error");
            ok($dbh->{pg_async_status}, "$how, $guard->[0]: the host's result is still pending");
            $dbh->pg_result;
            $insert->(3);
            $raw ? $dbh->do('COMMIT') : $dbh->commit;
            is_deeply($committed->(), [1, 2, 3, 100], "$how, $guard->[0]: every host write commits, in one transaction");
            ok($dbh->{AutoCommit} && $dbh->pg_ping == 1, "$how, $guard->[0]: the connection is idle afterwards");
        }
    }
    $reset->();
    $dbh->do("SELECT pg_sleep(0.05)", {pg_async => DBD::Pg::PG_ASYNC()});
    is(code_of(sub { $stream->() }), 'transaction_state_unsafe', 'an idle handle with a pending result is refused too');
    $dbh->pg_result;
    $healthy->('after a pending result');
};

subtest 'PostgreSQL 18c: an aborted host transaction is never reopened by a guard' => sub {
    for my $guard (
        [stream => sub { $stream->() }],
        [bounded_read => sub { Selecto::BoundedQuery->all($engine, $page) }],
        [savepoint_budget => sub { $adapter->begin_query_budget(timeout_ms => 1000, savepoint => 1) }],
    ) {
        $reset->();
        $dbh->begin_work;
        $insert->(1);
        $fail->();
        is(code_of($guard->[1]), 'transaction_state_unsafe', "$guard->[0]: refused with a typed error");
        is($dbh->pg_ping, 4, "$guard->[0]: the host transaction is still aborted");
        ok(!eval { $insert->(2); 1 }, "$guard->[0]: the host's next write still fails");
        $dbh->commit;
        is_deeply($committed->(), [100], "$guard->[0]: nothing of the failed transaction commits");
        $healthy->($guard->[0]);
    }
};

subtest 'PostgreSQL 18b/18e: a host failure mid-stream is never rolled back by the stream' => sub {
    for my $case (
        [sync_next => sub { $fail->() }, sub { $_[0]->next }],
        [sync_close => sub { $fail->() }, sub { $_[0]->close }],
        [async_next => sub { $dbh->do('SELECT 1/0', {pg_async => DBD::Pg::PG_ASYNC()}) }, sub { $_[0]->next }],
        [async_close => sub { $dbh->do('SELECT 1/0', {pg_async => DBD::Pg::PG_ASYNC()}) }, sub { $_[0]->close }],
    ) {
        my ($name, $host_failure, $stream_step) = @$case;
        $reset->();
        $dbh->begin_work;
        $insert->(1);
        my $open = $stream->();
        is_deeply($open->next, [1], "$name: the stream reads inside the host transaction");
        $insert->(2);
        $host_failure->();
        is(code_of(sub { $stream_step->($open) }), 'transaction_state_unsafe', "$name: the stream fails with a typed error");
        ok($open->closed, "$name: the stream is closed");
        if ($dbh->{pg_async_status}) {
            ok(!eval { $dbh->pg_result; 1 }, "$name: the host still receives its own error");
        }
        is($dbh->pg_ping, 4, "$name: the host transaction stays aborted");
        ok(!eval { $insert->(3); 1 }, "$name: the host's later write fails");
        $dbh->commit;
        is_deeply($committed->(), [100], "$name: none of the failed transaction commits");
        $healthy->($name);
    }

    $reset->();
    $dbh->begin_work;
    $insert->(1);
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $abandoned = $stream->();
        $abandoned->next;
        $fail->();
    }
    like("@warnings", qr/bounded stream abandoned: the host aborted/, 'abandoning it warns instead of looking clean');
    is($dbh->pg_ping, 4, 'an abandoned stream leaves the aborted host transaction aborted');
    $dbh->commit;
    is_deeply($committed->(), [100], 'and nothing of it commits');

    # The stream's own transaction, aborted by a host statement run inside it.
    $reset->();
    my $own = $stream->();
    $own->next;
    $fail->();
    is(code_of(sub { $own->next }), 'transaction_state_unsafe', 'own transaction aborted by the host: typed failure');
    is($dbh->pg_ping, 4, 'and the connection is left for the host to roll back');
    $dbh->rollback;
    $healthy->('own transaction aborted by the host');
};

subtest 'PostgreSQL 18f: a transaction the host took over is never rolled back' => sub {
    for my $takeover (
        [dbi => sub { $dbh->rollback; $dbh->begin_work; $insert->(5) }, sub { $dbh->commit }],
        [raw => sub { $dbh->do('ROLLBACK'); $dbh->do('BEGIN'); $insert->(5) }, sub { $dbh->do('COMMIT') }],
    ) {
        my ($name, $take, $commit) = @$takeover;
        $reset->();
        my $open = $stream->();
        is_deeply($open->next, [1], "$name: the stream reads in its own transaction");
        $take->();
        is(code_of(sub { $open->close }), 'transaction_state_unsafe', "$name: close reports the lost transaction");
        ok($open->closed, "$name: the stream is closed");
        $commit->();
        is_deeply($committed->(), [5, 100], "$name: the host's new transaction and its write survive");
        $healthy->($name);
    }
};

subtest 'PostgreSQL 18g: a cleanup that leaves the host transaction aborted always raises' => sub {
    no warnings 'redefine';
    my $original_do = \&Selecto::PostgreSQL::Stream::_do;
    my $original_savepoint = \&Selecto::SQL::_savepoint_command;
    # The stream's own close statement times out: its own failure, undone by
    # its savepoint, so the host's transaction and earlier write survive.
    $reset->();
    $dbh->begin_work;
    $insert->(1);
    my $open = $stream->();
    $open->next;
    {
        local *Selecto::PostgreSQL::Stream::_do = sub {
            my ($handle, $sql) = @_;
            return $original_do->(@_) unless $sql =~ /\ACLOSE /;
            $handle->do(q{SET LOCAL statement_timeout = '20ms'});
            $handle->do('SELECT pg_sleep(0.2)');
        };
        is(code_of(sub { $open->close }), 'ok', 'a close-time timeout of the stream\'s own is recovered');
    }
    is($dbh->pg_ping, 3, 'the host transaction is healthy, not silently aborted');
    $insert->(2);
    $dbh->commit;
    is_deeply($committed->(), [1, 2, 100], 'and the host\'s earlier and later writes commit');

    # The same timeout when the savepoint cannot be rolled back: the
    # transaction stays aborted, so close must say so.
    for my $abandon (0, 1) {
        $reset->();
        $dbh->begin_work;
        $insert->(1);
        $open = $stream->();
        $open->next;
        my @warnings;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            local *Selecto::PostgreSQL::Stream::_do = sub {
                my ($handle, $sql) = @_;
                return $original_do->(@_) unless $sql =~ /\ACLOSE /;
                $handle->do(q{SET LOCAL statement_timeout = '20ms'});
                $handle->do('SELECT pg_sleep(0.2)');
            };
            local *Selecto::PostgreSQL::_savepoint_command = sub {
                die "savepoint rollback refused\n" if $_[1] eq 'rollback';
                return $original_savepoint->(@_);
            };
            if ($abandon) {
                undef $open;
            } else {
                is(code_of(sub { $open->close }), 'stream_cleanup_failed', 'close raises a typed error');
            }
        }
        my $how = $abandon ? 'abandoned' : 'closed';
        like("@warnings", qr/bounded stream abandoned/, "$how: abandonment warns") if $abandon;
        is($dbh->pg_ping, 4, "$how: the host can see its transaction is aborted");
        ok($dbh->{private_selecto_bounded_stream_poisoned}, "$how: the handle refuses further bounded streams");
        is(code_of(sub { Selecto::BoundedQuery->all($engine, $page) }), 'transaction_state_unsafe',
            "$how: and every later guard refuses");
        $dbh->rollback;
        is_deeply($committed->(), [100], "$how: nothing was committed behind the host's back");
    }
    $reset->();
};

subtest 'PostgreSQL: nested guards each own a unique savepoint' => sub {
    $reset->();
    $dbh->begin_work;
    $insert->(1);
    my $outer = $stream->();
    is_deeply($outer->next, [1], 'a stream holds a savepoint in the host transaction');
    is_deeply(Selecto::BoundedQuery->all($engine, $page)->{rows}, [[1], [100]],
        'a bounded read nested inside it takes and releases its own savepoint');
    is_deeply($outer->next, [2], 'the stream is undisturbed');
    $fail->();
    is(code_of(sub { Selecto::BoundedQuery->all($engine, $page) }), 'transaction_state_unsafe',
        'after the host fails, a nested guard refuses instead of rolling back to any savepoint');
    is(code_of(sub { $outer->close }), 'transaction_state_unsafe', 'and the stream leaves its savepoint to the host');
    is($dbh->pg_ping, 4, 'the host transaction is still aborted');
    $dbh->commit;
    is_deeply($committed->(), [100], 'nothing of it commits');
    $healthy->('nested guards');
};

subtest 'PostgreSQL: healthy guards behave as before' => sub {
    $reset->();
    my $own = $stream->();
    ok(!$dbh->{AutoCommit}, 'an idle handle gets the stream\'s own transaction');
    is(($dbh->selectrow_array('SHOW transaction_read_only'))[0], 'on', 'which is read only');
    is_deeply([map { $own->next } 1 .. 5], [[1], [2], [3], [4], [5]], 'every row');
    is($own->next, undef, 'exhaustion closes it');
    ok($dbh->{AutoCommit} && $dbh->pg_ping == 1, 'and rolls its own transaction back');
    $own = $stream->();
    $own->close;
    ok($dbh->{AutoCommit} && $dbh->pg_ping == 1, 'an early close does too');

    for my $raw (0, 1) {
        $raw ? $dbh->do('BEGIN') : $dbh->begin_work;
        $insert->(1);
        my $open = $stream->();
        $open->next;
        $open->close;
        $insert->(2);
        is_deeply(Selecto::BoundedQuery->all($engine, $page)->{rows}, [[1], [2], [100]],
            ($raw ? 'raw BEGIN' : 'begin_work') . ': guards inside the host transaction release their savepoints');
        $write->(3);
        $raw ? $dbh->do('COMMIT') : $dbh->commit;
        is_deeply($committed->(), [1, 2, 3, 100], ($raw ? 'raw BEGIN' : 'begin_work') . ': the host commits all of it');
        $dbh->do("DELETE FROM $table WHERE id < 100");
    }

    # The stream's own failure inside the host transaction is still undone,
    # keeping the host's transaction usable.
    $dbh->begin_work;
    $insert->(1);
    $dbh->do(q{SET LOCAL statement_timeout = '50ms'});
    my $slow = $adapter->stream_query(statement('SELECT pg_sleep(0.3)'), bounded => 1);
    is(code_of(sub { $slow->next }), 'query_error', 'the stream\'s own timeout is its own error');
    is($dbh->pg_ping, 3, 'and its savepoint rollback leaves the host transaction healthy');
    $dbh->do(q{SET LOCAL statement_timeout = 0});
    $insert->(2);
    $dbh->commit;
    is_deeply($committed->(), [1, 2, 100], 'the host commits its work around the failed stream');

    $dbh->do(q{SET statement_timeout = '50ms'});
    $slow = $adapter->stream_query(statement('SELECT pg_sleep(0.3)'), bounded => 1);
    is(code_of(sub { $slow->next }), 'query_error', 'a timeout in the stream\'s own transaction');
    ok($dbh->{AutoCommit} && $dbh->pg_ping == 1, 'rolls back its own transaction');
    $dbh->do(q{SET statement_timeout = 0});
    $healthy->('healthy guards');
};

$dbh->do("DROP TABLE IF EXISTS $table");
done_testing;
