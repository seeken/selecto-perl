use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::DateFormat ();

plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };

my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do('CREATE TABLE selecto_perl_duckdb_items (id integer primary key, name varchar not null, active boolean not null, total decimal(12,2) not null, occurred_on timestamp not null, occurred_at bigint not null)');
$dbh->do(q{INSERT INTO selecto_perl_duckdb_items VALUES (1, 'baseline', true, 10.50, TIMESTAMP '2026-09-11 12:30:45.123456', 1789129845)});
$dbh->do('CREATE TABLE selecto_perl_duckdb_lines (id integer primary key, item_id integer not null, sku varchar not null, occurred_at bigint not null)');
$dbh->do(q{INSERT INTO selecto_perl_duckdb_lines VALUES (10, 1, 'A-10', 1789129845), (20, 1, 'B-20', 1789133445)});

my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
my $domain = Selecto::Domain->new(
    name => 'DuckDBItems', table => 'selecto_perl_duckdb_items',
    fields => {
        id => 'integer', name => 'string', active => 'boolean', total => 'decimal',
        occurred_on => 'naive_datetime',
        occurred_at => 'epoch_datetime',
    },
    associations => {
        lines => {
            table => 'selecto_perl_duckdb_lines',
            fields => {
                id => 'integer', item_id => 'integer', sku => 'string',
                occurred_at => 'epoch_datetime',
            },
            owner_key => 'id', related_key => 'item_id',
            target_primary_key => 'id', cardinality => 'many', join_type => 'left',
        },
    },
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $query = $engine->query->select(qw(id name active total))
    ->where(Selecto::Expression->eq(name => q{baseline' OR 1=1 --}));

like($engine->compile($query)->sql, qr/"s0"\."name" = \?/, 'DuckDB uses prepared positional parameters');
is_deeply($engine->all($query)->{rows}, [], 'bound injection-shaped input remains data');
is($adapter->normalize_type('timestamp'), 'naive_datetime', 'DuckDB types normalize portably');
ok($adapter->supports('transactions'), 'DuckDB declares transaction support');
ok($adapter->supports('rollup'), 'DuckDB declares native rollup support');

my $api_handler = Selecto::API::EngineHandler->new(default_limit => 100);
my $subtable = $api_handler->query($engine, {
    select => [
        'id', [
            'lines.sku',
            {field => 'lines.occurred_at', alias => 'line_day', format => 'day'},
        ],
    ],
});
is_deeply($subtable->{columns}, [qw(id lines)],
    'DuckDB API builds an explicitly requested to-many subtable');
is_deeply($subtable->{rows}, [[1, [
    ['A-10', '2026-09-11'],
    ['B-20', '2026-09-11'],
]]], 'DuckDB API applies array row format to nested aliases and formats');
is_deeply($subtable->{subtables}, {
    lines => {columns => ['lines.sku', 'line_day']},
}, 'DuckDB API publishes ordered columns for array-form subtables');

my $flattened = $api_handler->query($engine, {
    select => ['id', 'lines.sku'],
});
is_deeply($flattened->{columns}, ['id', 'lines.sku'],
    'DuckDB API keeps ordinary relationship fields flat');
is_deeply($flattened->{rows}, [[1, 'A-10'], [1, 'B-20']],
    'DuckDB API flat selections deliberately permit root-row multiplication');

my @date_formats = map { $_->{id} } @{Selecto::DateFormat->choices};
my $formatted = $engine->query->select(map {
    Selecto::Expression->datetime_format(
        'occurred_on', $_,
    )->as('occurred_' . $_)
} @date_formats);
is_deeply(
    $engine->all($formatted)->{rows},
    [[
        '2026-09-11T12:30:45', '2026-09-11T12:30:45.123Z',
        1789129845, 1789129845123,
        '2026-09-11', '12:30:45', '2026-09-11 12',
        '2026-W37', '2026-W37', '2026-W37-5', '2026-09', '2026-Q3',
        '2026', '09', '11', 'Friday', '5', '254', '12', '+00:00',
    ]],
    'DuckDB executes every governed date format used by API and Explorer clients',
);
is_deeply(
    $engine->all($engine->query->select(
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'month',
        )->as('occurred_month'),
    ))->{rows},
    [['2026-09']],
    'DuckDB formats governed epoch datetime fields',
);
is_deeply(
    $engine->all($engine->query->select(
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'day_hour',
        )->as('occurred_hour'),
    )->use_timezone('America/New_York'))->{rows},
    [['2026-09-11 08']],
    'DuckDB applies explicit IANA timezones before formatting epoch fields',
);
is_deeply(
    $engine->all($engine->query->select(
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'iso8601',
        )->as('occurred_at'),
    ))->{rows},
    [['2026-09-11T12:30:45Z']],
    'DuckDB renders epoch instants as RFC 3339 UTC by default',
);
is_deeply(
    $engine->all($engine->query->select(
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'iso8601',
        )->as('occurred_at'),
    )->use_timezone('America/New_York'))->{rows},
    [['2026-09-11T08:30:45-04:00']],
    'DuckDB renders localized epoch instants with their numeric UTC offset',
);
is_deeply(
    $engine->all($engine->query->select(
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'iso8601',
        )->as('occurred_at'),
    )->use_timezone('Asia/Kolkata'))->{rows},
    [['2026-09-11T18:00:45+05:30']],
    'DuckDB preserves minute precision in non-whole-hour timezone offsets',
);
is_deeply(
    $engine->all($engine->query->select(
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'rfc3339_millis',
        )->as('rfc3339_millis'),
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'epoch_seconds',
        )->as('epoch_seconds'),
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'epoch_milliseconds',
        )->as('epoch_milliseconds'),
        Selecto::Expression->datetime_format(
            Selecto::Expression->epoch_datetime('occurred_at'), 'timezone_offset',
        )->as('timezone_offset'),
    )->use_timezone('America/New_York'))->{rows},
    [['2026-09-11T08:30:45.000-04:00', 1789129845, 1789129845000, '-04:00']],
    'DuckDB executes the common instant interchange formats in a requested timezone',
);
$dbh->do('CREATE TABLE selecto_perl_duckdb_timezone_probe (occurred_utc TIMESTAMPTZ NOT NULL, occurred_date DATE NOT NULL)');
$dbh->do(q{INSERT INTO selecto_perl_duckdb_timezone_probe VALUES (TIMESTAMPTZ '2026-09-11 12:30:45+00', DATE '2026-09-11')});
my $timezone_engine = Selecto::Engine->new(
    domain => Selecto::Domain->new(
        name => 'DuckDBTimezoneProbe', table => 'selecto_perl_duckdb_timezone_probe',
        fields => {occurred_utc => 'utc_datetime', occurred_date => 'date'},
    ),
    adapter => $adapter,
);
is_deeply(
    $timezone_engine->all($timezone_engine->query->select(
        Selecto::Expression->datetime_format('occurred_utc', 'day_hour')
            ->as('occurred_hour'),
    )->use_timezone('America/New_York'))->{rows},
    [['2026-09-11 08']],
    'DuckDB applies explicit IANA timezones to UTC datetime fields',
);
is_deeply(
    $timezone_engine->all($timezone_engine->query->select(
        Selecto::Expression->datetime_format('occurred_date', 'iso8601')
            ->as('occurred_date'),
    ))->{rows},
    [['2026-09-11']],
    'DuckDB renders proper DATE fields as ISO calendar dates',
);

my $rollup = $engine->query->select(
    'name',
    Selecto::Expression->count->as('item_count'),
    Selecto::Expression->grouping('name')->as('__selecto_rollup_grouping'),
)->group_by_rollup('name')->order_by('name', 'asc');
is_deeply(
    $engine->all($rollup)->{rows},
    [[undef, 1, 1], ['baseline', 1, 0]],
    'DuckDB executes rollups with the grouping marker used by Explorer',
);

my $upsert = Selecto::Write::Command->new(
    operation => 'upsert', relation => 'selecto_perl_duckdb_items',
    assignments => {
        id => 1, name => 'updated', active => 0, total => '2.50',
        occurred_on => '2026-09-11 12:30:45', occurred_at => 1789129845,
    },
    metadata => {
        conflict_target => ['id'],
        upsert_update_fields => [qw(name active total occurred_on occurred_at)],
    },
);
is($engine->execute_write($upsert)->affected_rows, 1, 'DuckDB reports native upsert rows');

my $insert = Selecto::Write::Command->new(
    operation => 'insert', relation => 'selecto_perl_duckdb_items',
    assignments => {
        id => 2, name => 'must-roll-back', active => 1, total => '1.00',
        occurred_on => '2026-09-11 12:30:45', occurred_at => 1789129845,
    },
);
my $missing = Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_duckdb_items',
    assignments => { name => 'never' },
    predicate => Selecto::Expression->eq(id => 999),
);
eval { $engine->execute_batch(Selecto::Write::Batch->new($insert, $missing)); 1 };
is($@->code, 'cardinality_mismatch', 'DuckDB reports portable batch cardinality errors');
is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_duckdb_items'), 1, 'DuckDB rolls back the batch atomically');

$dbh->disconnect;
done_testing;
