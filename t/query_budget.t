use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Statement;

subtest 'SQLite enforces execution time and restores host settings' => sub {
    plan skip_all => 'SQLite driver unavailable' unless eval { require DBI; require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1, PrintError=>0});
    my $calls = 0;
    my $callback = sub { ++$calls; 0 };
    $dbh->sqlite_progress_handler(1000, $callback);
    $dbh->sqlite_busy_timeout(1234);
    my $adapter = Selecto->adapter(sqlite => (dbh=>$dbh,
        query_budget_progress_handler=>{opcodes=>1000, callback=>$callback}));
    ok $adapter->query_budget_supported, 'driver supports enforceable budget';
    my $guard = $adapter->begin_query_budget(timeout_ms=>5);
    eval { $adapter->begin_query_budget(timeout_ms=>10) };
    is $@->code, 'query_budget_busy', 'same-handle overlapping budget refuses';
    my $ok = eval { $dbh->selectrow_array(q{
        WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<100000000)
        SELECT SUM(n) FROM numbers
    }); 1 };
    ok !$ok, 'long database operation interrupted by driver progress hook';
    eval { $guard->check };
    is $@->code, 'query_budget_exceeded', 'wall deadline also expires';
    $guard->close;
    is $dbh->sqlite_busy_timeout, 1234, 'busy timeout restored';
    my $before = $calls;
    $dbh->selectrow_array(q{WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000) SELECT SUM(x) FROM n});
    ok $calls > $before, 'configured host progress callback restored';
    my $again = $adapter->begin_query_budget(timeout_ms=>1000);
    ok $again->check, 'next budget can start';
    $again->close;
    $again->close;
};

subtest 'PostgreSQL server timeout bounds blocking execution' => sub {
    my $database=$ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all => 'disposable PostgreSQL unavailable' unless $database && eval {require DBI;require DBD::Pg;1};
    my $dbh=DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0});
    my $adapter=Selecto->adapter(postgresql=>(dbh=>$dbh));
    $dbh->do(q{SET statement_timeout='2s'});
    my $guard=$adapter->begin_query_budget(timeout_ms=>10);
    my $ok=eval {$dbh->do('SELECT pg_sleep(0.1)');1};
    ok !$ok, 'server interrupts blocking query';
    $guard->close;
    is(($dbh->selectrow_array(q{SHOW statement_timeout}))[0], '2s', 'host timeout restored');
    $dbh->do(q{SET statement_timeout='5ms'});
    $guard=$adapter->begin_query_budget(timeout_ms=>50);
    is(($dbh->selectrow_array(q{SHOW statement_timeout}))[0], '5ms', 'stricter host deadline is preserved');
    $guard->close;
    $dbh->do(q{SET statement_timeout=0});
    $guard=$adapter->begin_query_budget(timeout_ms=>150);
    $dbh->do('SELECT pg_sleep(0.10)');
    $guard->check;
    my ($remaining)=$dbh->selectrow_array(q{SELECT setting::bigint FROM pg_settings WHERE name='statement_timeout'});
    cmp_ok $remaining,'<',100,'later operations get remaining wall budget';
    $ok=eval{$dbh->do('SELECT pg_sleep(0.10)');1};
    ok !$ok,'second blocking operation cannot restart the original budget';
    $guard->close;

    # Deferred re-arm: per-row checks between buffered rows send nothing; the
    # stream refreshes the server timeout right before its next FETCH.
    $dbh->do(q{SET statement_timeout=0});
    my $timeout=sub {($dbh->selectrow_array(q{SELECT setting::bigint FROM pg_settings WHERE name='statement_timeout'}))[0]};
    $guard=$adapter->begin_query_budget(timeout_ms=>5000);
    my $armed=$timeout->();
    my $stream=$adapter->stream_query(Selecto::Statement->new(sql=>'SELECT n FROM generate_series(1,6) n',params=>[],
        columns=>['n'],adapter_name=>'postgresql'),bounded=>1,fetch_size=>3);
    is_deeply $stream->next,[1],'first row of the first batch';
    select undef,undef,undef,0.05;
    ok $guard->check(defer_rearm=>1),'deferred check passes the wall deadline';
    is $timeout->(),$armed,'deferred check leaves the server timeout untouched';
    $stream->next for 1..2;
    is $timeout->(),$armed,'buffered rows need no re-arm';
    is_deeply $stream->next,[4],'next batch fetched';
    cmp_ok $timeout->(),'<',$armed,'re-armed with the remaining budget right before the FETCH';
    $stream->close;
    $guard->close;

    $guard=$adapter->begin_query_budget(timeout_ms=>60);
    $stream=$adapter->stream_query(Selecto::Statement->new(sql=>'SELECT n FROM generate_series(1,4) n',params=>[],
        columns=>['n'],adapter_name=>'postgresql'),bounded=>1,fetch_size=>2);
    $stream->next;
    $guard->check(defer_rearm=>1);
    select undef,undef,undef,0.08;
    $stream->next;
    $ok=eval{$stream->next;1};
    is $ok ? 'ok' : $@->code,'query_budget_exceeded','an expired deadline stops the next FETCH';
    ok $stream->closed,'the stream closes when its deadline expires';
    $guard->close;
    is(($dbh->selectrow_array(q{SHOW statement_timeout}))[0], '0', 'host timeout restored after deferred re-arm');
    $dbh->disconnect;
};

subtest 'PostgreSQL budgets inside a transaction restore its timeout' => sub {
    my $database=$ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all => 'disposable PostgreSQL unavailable' unless $database && eval {require DBI;require DBD::Pg;1};
    my $dbh=DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>0});
    my $adapter=Selecto->adapter(postgresql=>(dbh=>$dbh));
    my $timeout=sub {($dbh->selectrow_array(q{SHOW statement_timeout}))[0]};
    # As a bounded write probe does: a budget under a savepoint that is then released.
    $dbh->do('SAVEPOINT probe');
    my $guard=$adapter->begin_query_budget(timeout_ms=>300);
    is $timeout->(),'300ms','the budget applies inside the transaction';
    $dbh->do('SELECT pg_sleep(0.05)');
    $guard->check;
    cmp_ok(($dbh->selectrow_array(q{SELECT setting::bigint FROM pg_settings WHERE name='statement_timeout'}))[0],'<',300,
        're-armed with the time left');
    $guard->close;
    $dbh->do('RELEASE SAVEPOINT probe');
    is $timeout->(),'0','closing restores the timeout, so the write after the probe runs under its own';
    ok eval {$dbh->do('SELECT pg_sleep(0.4)');1},'a statement longer than the budget then runs';
    $dbh->do(q{SET LOCAL statement_timeout='7s'});
    $guard=$adapter->begin_query_budget(timeout_ms=>300);
    $guard->close;
    is $timeout->(),'7s','a transaction-scoped host timeout is restored as it was';
    $dbh->commit;
    is $timeout->(),'0','and no budget changed the session setting';
    $dbh->do(q{SET statement_timeout='2s'});
    $dbh->commit;
    $guard=$adapter->begin_query_budget(timeout_ms=>300,savepoint=>1);
    my $ok=eval {$dbh->do('SELECT pg_sleep(0.5)');1};
    ok !$ok,'a savepoint budget interrupts its statement';
    $guard->close;
    is_deeply [$dbh->selectrow_array('SELECT 1')],[1],'and its savepoint keeps the transaction usable';
    is $timeout->(),'2s','with the session timeout in force again';
    $dbh->do('SET statement_timeout=0');
    $dbh->commit;
    $dbh->disconnect;
};

subtest 'savepoint budgets need PostgreSQL' => sub {
    plan skip_all => 'SQLite driver unavailable' unless eval { require DBI; require DBD::SQLite; 1 };
    my $adapter = Selecto->adapter(sqlite => (dbh=>DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1, PrintError=>0})));
    my $ok = eval { $adapter->begin_query_budget(timeout_ms=>100, savepoint=>1); 1 };
    is $ok ? 'ok' : $@->code, 'invalid_query_budget', 'refused';
    ok eval { $adapter->begin_query_budget(timeout_ms=>100)->close; 1 }, 'and the handle stays usable';
};
done_testing;
