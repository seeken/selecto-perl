use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;

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
    $dbh->disconnect;
};
done_testing;
