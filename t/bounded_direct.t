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
    my $domain = Selecto::Domain->new(name => 'Direct rows', table => 'direct_rows', primary_key => 'id',
        fields => {id => 'integer', label => 'string'});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
    my $timeout = sub { ($dbh->selectrow_array('SHOW statement_timeout'))[0] };
    my @sql;
    my $page = $engine->query->select('id', 'label')->order_by('id')->limit(26);
    {
        no warnings 'redefine';
        my $do = \&DBI::db::prepare;
        local *DBI::db::prepare = sub { push @sql, $_[1]; goto &$do };
        my $result = Selecto::BoundedQuery->all($engine, $page, max_rows => 10_000);
        is scalar(@{$result->{rows}}), 26, 'the page comes back whole';
        is_deeply $result->{rows}[0], [1, 'row 1'], 'in order';
    }
    ok !grep({ /\b(?:DECLARE|FETCH|SAVEPOINT)\b/ } @sql), 'no cursor or savepoint for a one-batch page';
    is $timeout->(), '5s', 'the timeout lasts for the rest of the transaction';
    $dbh->rollback;
    is $timeout->(), '0', 'and ends with it';
    my $all = Selecto::BoundedQuery->all($engine, $engine->query->select('id')->order_by('id'), max_rows => 10_000);
    is scalar(@{$all->{rows}}), 150, 'a result larger than one batch still streams';
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
