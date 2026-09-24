use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use DBI ();
use Selecto::DuckDB ();
use Selecto::MSSQL ();
use Selecto::PostgreSQL ();
use Selecto::SQLite ();

sub values_domain {
    my (%overrides) = @_;
    return Selecto::Domain->parse({
        schema_version => 1,
        name => 'Tickets with typed inline statuses',
        source => {
            source_table => 'tickets', primary_key => 'id',
            fields => [qw(id status)],
            columns => {id => {type => 'integer'}, status => {type => 'string'}},
            associations => {
                status_labels => {
                    queryable => 'status_labels', owner_key => 'status', related_key => 'status',
                },
            },
        },
        schemas => {
            status_labels => {
                values => $overrides{values} // [
                    {status => 'open', label => 'Open', sort_order => 2,
                        weight => '1.25', terminal => 0, opened_on => '2026-01-02',
                        payload => '{}'},
                    {status => 'closed', label => 'Closed', sort_order => 10,
                        weight => '0.5', terminal => 1, opened_on => '2026-01-03',
                        payload => '{}'},
                ],
                primary_key => 'status',
                fields => [qw(status label sort_order weight terminal opened_on payload)],
                columns => {
                    status => {type => 'string'},
                    label => {type => 'string'},
                    sort_order => {type => 'integer'},
                    weight => {type => 'decimal'},
                    terminal => {type => 'boolean'},
                    opened_on => {type => 'date'},
                    payload => {type => 'jsonb'},
                },
                associations => {},
            },
        },
        joins => {status_labels => {type => 'left', name => 'Status labels'}},
    }, strict => 1);
}

sub values_cte {
    my ($adapter, $domain) = @_;
    my $engine = Selecto::Engine->new(domain => $domain // values_domain(), adapter => $adapter);
    my $statement = $engine->compile($engine->query->select(
        'id', 'status_labels.label', 'status_labels.sort_order',
    )->order_by('status_labels.sort_order'));
    my ($cte) = $statement->sql =~ /\AWITH \S+ AS \((.*?)\) SELECT /s;
    return ($cte, $statement);
}

my $dbh = TestSelecto::DBH->new;

my ($pg, $pg_statement) = values_cte(Selecto::PostgreSQL->new(dbh => $dbh));
is $pg,
    'SELECT CAST($1 AS TEXT) AS "status", CAST($2 AS TEXT) AS "label", ' .
    'CAST($3 AS BIGINT) AS "sort_order", CAST($4 AS NUMERIC) AS "weight", ' .
    'CAST($5 AS BOOLEAN) AS "terminal", CAST($6 AS DATE) AS "opened_on", $7 AS "payload" ' .
    'UNION ALL SELECT CAST($8 AS TEXT), CAST($9 AS TEXT), CAST($10 AS BIGINT), ' .
    'CAST($11 AS NUMERIC), CAST($12 AS BOOLEAN), CAST($13 AS DATE), $14',
    'PostgreSQL casts every values cell to its declared type and leaves unmapped types untyped';
is_deeply [@{$pg_statement->params}[0 .. 6]],
    ['open', 'Open', 2, '1.25', 0, '2026-01-02', '{}'],
    'typed values cells remain bound parameters';
unlike $pg_statement->sql, qr/'Open'|'1\.25'/, 'typed values are never interpolated';

my ($duckdb) = values_cte(Selecto::DuckDB->new(dbh => $dbh));
like $duckdb,
    qr/\ASELECT CAST\(\$1 AS VARCHAR\) AS "status", CAST\(\$2 AS VARCHAR\) AS "label", CAST\(\$3 AS BIGINT\) AS "sort_order", CAST\(\$4 AS DECIMAL\(38,2\)\) AS "weight", CAST\(\$5 AS BOOLEAN\) AS "terminal", CAST\(\$6 AS DATE\) AS "opened_on", \$7 AS "payload" UNION ALL /,
    'DuckDB casts values cells, sizing decimals to the widest declared scale';

my ($mssql) = values_cte(Selecto::MSSQL->new(dbh => $dbh));
like $mssql,
    qr/\ASELECT \? AS \[status\], \? AS \[label\], CAST\(\? AS BIGINT\) AS \[sort_order\], CAST\(\? AS DECIMAL\(38,2\)\) AS \[weight\], CAST\(\? AS BIT\) AS \[terminal\], CAST\(\? AS DATE\) AS \[opened_on\], \? AS \[payload\] UNION ALL /,
    'SQL Server casts only its allowlisted values types';

SKIP: {
    skip 'DBD::SQLite is not installed', 2 unless eval { require DBD::SQLite; 1 };
    my $sqlite_dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
    });
    $sqlite_dbh->do('CREATE TABLE tickets (id integer primary key, status text)');
    $sqlite_dbh->do(q{INSERT INTO tickets VALUES (1, 'closed'), (2, 'open')});
    my $adapter = Selecto::SQLite->new(dbh => $sqlite_dbh);
    # Text-shaped cells, as decoded from JSON or YAML, bind as SQLite TEXT.
    my $domain = values_domain(values => [
        map { {%$_, sort_order => "$_->{sort_order}"} } @{values_domain()->associations
            ->{status_labels}->values},
    ]);
    my ($sqlite) = values_cte($adapter, $domain);
    like $sqlite,
        qr/\ASELECT \? AS "status", \? AS "label", CAST\(\? AS INTEGER\) AS "sort_order", \? AS "weight"/,
        'SQLite gives integer values columns integer affinity';
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    is_deeply $engine->all($engine->query->select('id', 'status_labels.sort_order')
            ->order_by('status_labels.sort_order'))->{rows},
        [[2, 2], [1, 10]],
        'SQLite returns and orders integer values cells numerically';
}

my $inexact = eval {
    values_cte(Selecto::DuckDB->new(dbh => $dbh), values_domain(values => [
        {status => 'open', label => 'Open', sort_order => 1, weight => '1e3',
            terminal => 0, opened_on => '2026-01-02', payload => '{}'},
    ]));
    1;
};
ok !$inexact, 'inexact decimal values fail closed when a scale must be derived';
is $@->code, 'invalid_domain', 'inexact decimal values report an invalid domain';

done_testing;
