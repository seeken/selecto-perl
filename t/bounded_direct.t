use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::BoundedQuery;
use lib 't/lib';
use TestSelecto;

sub code {
    my ($run) = @_;
    my $ok = eval { $run->(); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@";
}
sub statement {
    my ($sql, $params, $columns) = @_;
    return Selecto::Statement->new(sql => $sql, params => $params // [], columns => $columns // ['value'],
        adapter_name => 'postgresql');
}

subtest 'scalar column statement' => sub {
    my $adapter = Selecto->adapter(postgresql => (dbh => TestSelecto::DBH->new));
    my $rows = statement(q{SELECT "id", "label" FROM t WHERE a = $1 AND b = $2 AND c = '$1' ORDER BY "id" LIMIT 26},
        [10, 20], ['id', 'label']);
    my $total = statement(q{SELECT COUNT(DISTINCT "id") AS "total" FROM t WHERE a = $1 AND b = $2 AND c = '$2'},
        [10, 20], ['total']);
    my $combined = $adapter->scalar_column_statement($rows, $total, 'selecto_total');
    is $combined->sql, q{SELECT selecto_rows.*, (SELECT COUNT(DISTINCT "id") AS "total" FROM t WHERE a = $3 AND b = $4 AND c = '$2') AS "selecto_total" FROM (SELECT "id", "label" FROM t WHERE a = $1 AND b = $2 AND c = '$1' ORDER BY "id" LIMIT 26) AS selecto_rows},
        'scalar placeholders follow the outer statement, quoted text untouched';
    is_deeply $combined->params, [10, 20, 10, 20], 'outer parameters, then the scalar parameters';
    is_deeply $combined->columns, ['id', 'label', 'selecto_total'], 'the scalar is the last column';
    is code(sub { $adapter->scalar_column_statement($rows, $total, 'label') }), 'invalid_query', 'alias may not shadow a column';
    is code(sub { $adapter->scalar_column_statement($rows, $total, 'Bad Alias') }), 'invalid_query', 'alias must be an identifier';
    is code(sub { $adapter->scalar_column_statement($rows, $rows, 'selecto_total') }), 'invalid_query',
        'the scalar statement must have one column';
    ok !$adapter->bounded_direct_supported, 'test handles cannot run bounded results directly';
};

subtest 'PostgreSQL direct bounded execution' => sub {
    my $database = $ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all => 'disposable PostgreSQL unavailable' unless $database && eval { require DBI; require DBD::Pg; 1 };
    my $dbh = DBI->connect("dbi:Pg:dbname=$database;host=/tmp", undef, undef,
        {RaiseError => 1, PrintError => 0, AutoCommit => 0});
    $dbh->do('CREATE TEMP TABLE direct_rows (id integer primary key, label text)');
    $dbh->do('INSERT INTO direct_rows SELECT n, ' . q{'row ' || n} . ' FROM generate_series(1, 150) n');
    $dbh->do('CREATE TEMP VIEW slow_rows AS SELECT id, label FROM direct_rows WHERE pg_sleep(0.02) IS NOT NULL');
    $dbh->commit;
    my $domain = Selecto::Domain->new(name => 'Direct rows', table => 'direct_rows', primary_key => 'id',
        fields => {id => 'integer', label => 'string'});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
    my $timeout = sub { ($dbh->selectrow_array('SHOW statement_timeout'))[0] };
    my @sql;
    my $page = $engine->query->select('id', 'label')->order_by('id')->limit(26);
    {
        no warnings 'redefine';
        my $prepare = \&DBI::db::prepare;
        my $do = \&DBI::db::do;
        local *DBI::db::prepare = sub { push @sql, $_[1]; goto &$prepare };
        local *DBI::db::do = sub { push @sql, $_[1]; goto &$do };
        my $result = Selecto::BoundedQuery->all($engine, $page, max_rows => 10_000);
        is scalar(@{$result->{rows}}), 26, 'the page comes back whole';
        is_deeply $result->{rows}[0], [1, 'row 1'], 'in order';
    }
    ok !grep({ /\b(?:DECLARE|FETCH)\b/ } @sql), 'no cursor for a one-batch page';
    is scalar(grep { /\ASAVEPOINT \w+; SELECT .*set_config\('statement_timeout'/s } @sql), 1,
        'its savepoint opens with its timeout, in one round trip';
    is scalar(grep { /\AROLLBACK TO SAVEPOINT (\w+); RELEASE SAVEPOINT \1\z/ } @sql), 1,
        'and is rolled back and released in one more';
    is $timeout->(), '0', 'the timeout ends with the page';
    ok eval { $dbh->do('SELECT pg_sleep(0.05)'); 1 }, 'the host transaction runs on under its own timeout';
    my $all = Selecto::BoundedQuery->all($engine, $engine->query->select('id')->order_by('id'), max_rows => 10_000);
    is scalar(@{$all->{rows}}), 150, 'a result larger than one batch still streams';
    is $timeout->(), '0', 'and leaves no timeout behind either, however far it re-armed';
    $dbh->rollback;

    # A page that times out fails alone: its savepoint keeps the host's transaction usable.
    my $slow = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
        domain => Selecto::Domain->new(name => 'Slow rows', table => 'slow_rows', primary_key => 'id',
            fields => {id => 'integer', label => 'string'}));
    my $slow_page = $slow->query->select('id', 'label')->order_by('id')->limit(26);
    isnt code(sub { Selecto::BoundedQuery->all($slow, $slow_page, max_rows => 10_000, timeout_ms => 100) }), 'ok',
        'a page past its budget fails';
    is_deeply [$dbh->selectrow_array('SELECT 1')], [1], 'the host transaction is still usable';
    is $timeout->(), '0', 'with no timeout left behind';
    # A stricter budget never clamps a later, larger one.
    Selecto::BoundedQuery->all($engine, $page, max_rows => 10_000, timeout_ms => 100);
    is code(sub { Selecto::BoundedQuery->all($slow, $slow_page, max_rows => 10_000, timeout_ms => 5000) }), 'ok',
        'a later page gets its own whole budget';
    # A transaction-scoped host timeout is kept, and stays the stricter ceiling.
    $dbh->do(q{SET LOCAL statement_timeout = '7s'});
    Selecto::BoundedQuery->all($engine, $page, max_rows => 10_000);
    is $timeout->(), '7s', 'the host SET LOCAL survives a page';
    $dbh->rollback;

    # A direct page, then a streamed result, in one transaction that commits: every
    # budget is transaction-scoped, so none can restore a transaction-scoped value as
    # the session's and leave it behind on the connection.
    Selecto::BoundedQuery->all($engine, $page, max_rows => 10_000);
    Selecto::BoundedQuery->all($engine, $engine->query->select('id')->order_by('id'), max_rows => 10_000);
    $dbh->commit;
    is $timeout->(), '0', 'no timeout outlives a committed transaction';
    $dbh->do(q{SET statement_timeout = '700ms'});
    $dbh->commit;
    Selecto::BoundedQuery->all($engine, $page, max_rows => 10_000);
    is $timeout->(), '700ms', 'a stricter session timeout is kept';
    $dbh->rollback;
    is $timeout->(), '700ms', 'and is the session setting again afterwards';
    $dbh->do('SET statement_timeout = 0');
    $dbh->commit;
    $dbh->disconnect;
};

done_testing;
