use 5.034;
use strict;
use warnings;
use B ();
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Statement ();

# Offline checks of the SQL that formats canonical values: only the outermost
# SELECT list changes, by the selections' declared domain types, and every
# other byte of the statement is kept. The live identity of the values
# themselves is t/canonical_values.integration.t.

{
    # The SQL path needs a DBD::Pg handle (it reads pg_server_version); the
    # offline mock stands in for one here.
    package Local::CanonicalAdapter;
    use parent -norequire, 'Selecto::PostgreSQL';
    our $VERSION_NUM = 170000;
    sub _canonical_server_version { return $VERSION_NUM }
}

my $dbh = TestSelecto::DBH->new;
my $adapter = Local::CanonicalAdapter->new(dbh => $dbh);
my $x = 'Selecto::Expression';

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Events',
    source => {
        source_table => 'events', primary_key => 'id',
        fields => [qw(id label amount ratio day at aware stored active flag_date total_label)],
        columns => {
            id => {type => 'integer'}, label => {type => 'string'}, amount => {type => 'decimal'},
            ratio => {type => 'float'}, day => {type => 'date'}, at => {type => 'naive_datetime'},
            aware => {type => 'utc_datetime'}, stored => {type => 'utc_datetime', storage => 'naive_utc'},
            active => {type => 'boolean'}, flag_date => {type => 'epoch_datetime'},
            total_label => {type => 'decimal', computed => {kind => 'coalesce_fields',
                fields => ['place.amount', 'amount']}},
        },
        associations => {place => {queryable => 'places', owner_key => 'id', related_key => 'id'}},
    },
    schemas => {places => {source_table => 'places', primary_key => 'id', fields => [qw(id amount opened)],
        columns => {id => {type => 'integer'}, amount => {type => 'decimal'}, opened => {type => 'utc_datetime'}},
        associations => {}}},
    joins => {place => {type => 'left'}},
}, strict => 1);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

my $TYPE = sub { "CAST(pg_catalog.pg_typeof(CASE WHEN FALSE THEN ($_[0]) END) AS OID)" };
my $NUMERIC = sub { "CASE WHEN " . $TYPE->($_[0]) . " = 1700 THEN CAST(pg_catalog.trim_scale(CAST(($_[0]) AS NUMERIC)) AS TEXT)"
    . " ELSE CAST(($_[0]) AS TEXT) END" };

sub columns_of { my ($statement) = @_; return [$adapter->_canonical_columns($statement)]; }

subtest 'formatted selections keep their names and every other clause' => sub {
    my $query = $engine->query->select('id', 'amount', $x->field('place.amount'), $x->field('label')->as('l'))
        ->where($x->gt('amount', 5))->order_by('amount', 'desc')->limit(10);
    my $statement = $engine->compile($query);
    my $sql = $statement->sql;
    is($sql, 'SELECT "s0"."id", "s0"."amount", "j_place"."amount" AS "place.amount", "s0"."label" AS "l" '
        . 'FROM "events" AS "s0" LEFT JOIN "places" AS "j_place" ON "s0"."id" = "j_place"."id" '
        . 'WHERE "s0"."amount" > $1 ORDER BY "s0"."amount" DESC LIMIT 10', 'the compiled statement');
    is_deeply(columns_of($statement), [1, 2], 'the decimal columns are formatted');
    my $formatted = $adapter->_canonical_statement($statement);
    isnt($formatted, $statement, 'a new statement');
    is_deeply([$formatted->params, $formatted->columns], [$statement->params, $statement->columns],
        'with the same parameters and columns');
    my $tail = substr($sql, index($sql, ' FROM '));
    is($formatted->sql, 'SELECT "s0"."id", ' . $NUMERIC->('"s0"."amount"') . ' AS "amount", '
        . $NUMERIC->('"j_place"."amount"') . ' AS "place.amount", "s0"."label" AS "l"' . $tail,
        'an unaliased selection keeps its name; ORDER BY sorts the underlying value');
    is($adapter->_canonical_statement($statement)->sql, $formatted->sql, 'the same text again');
};

subtest 'each declared type has its formatter' => sub {
    my $statement = $engine->compile($engine->query->select(qw(id label amount ratio day at aware stored active
        flag_date total_label place.opened)));
    is_deeply(columns_of($statement), [2, 4, 5, 6, 7, 11],
        'decimal, date, naive_datetime and utc_datetime; not integers, strings, floats, booleans, epochs or computed');
    my $sql = $adapter->_canonical_statement($statement)->sql;
    my $day = 'CAST(("s0"."day") AS DATE)';
    like($sql, qr/\Q, CASE WHEN @{[$TYPE->('"s0"."day"')]} = 1082 THEN CASE WHEN pg_catalog.isfinite($day) THEN pg_catalog.to_char(CAST($day AS TIMESTAMP), 'YYYY-MM-DD') || CASE WHEN $day < '0001-01-01' THEN ' BC' ELSE '' END ELSE CAST($day AS TEXT) END ELSE CAST(("s0"."day") AS TEXT) END AS "day", \E/,
        'date, by its PostgreSQL type; any other type is its text');
    my $at = 'CAST(("s0"."at") AS TIMESTAMP)';
    my $local = qq{pg_catalog.rtrim(pg_catalog.rtrim(pg_catalog.to_char($at, 'YYYY-MM-DD"T"HH24:MI:SS.US'), '0'), '.')};
    like($sql, qr/\Q, CASE @{[$TYPE->('"s0"."at"')]} WHEN 1114 THEN CASE WHEN pg_catalog.isfinite($at) THEN $local || CASE WHEN $at < '0001-01-01' THEN 'TBC' ELSE '' END ELSE CAST($at AS TEXT) END WHEN 1184 THEN \E/,
        'a datetime: timestamp');
    $at = 'CAST(("s0"."at") AS TIMESTAMPTZ)';
    ($local = $local) =~ s/AS TIMESTAMP\)/AS TIMESTAMPTZ)/;
    my $seconds = "CAST(pg_catalog.date_part('timezone', $at) AS INTEGER) % 60";
    like($sql, qr/\Q WHEN 1184 THEN CASE WHEN pg_catalog.isfinite($at) THEN $local || COALESCE(NULLIF(CASE WHEN $at >= '1972-01-08 00:00:00+00' THEN pg_catalog.to_char($at, 'OF') ELSE pg_catalog.to_char($at, 'OF') || CASE WHEN $seconds = 0 THEN '' ELSE pg_catalog.to_char(pg_catalog.abs($seconds), '":"FM00') END || CASE WHEN $at < '0001-01-02 00:00:00+00' AND pg_catalog.to_char($at, 'BC') = 'BC' THEN 'TBC' ELSE '' END END, '+00'), '') ELSE CAST($at AS TEXT) END ELSE CAST(("s0"."at") AS TEXT) END AS "at", \E/,
        'and timestamptz: the session offset unless +00, with its seconds before 1972 and TBC');
    like($sql, qr/\Q AS "aware", CASE @{[$TYPE->('"s0"."stored"')]} WHEN 1114 THEN \E/, 'every datetime has both');
    like($sql, qr/"s0"\."active", "s0"\."flag_date", COALESCE\(/, 'the others are untouched');
    unlike($sql, qr/~|regexp|'!'/, 'no regular expressions or sentinels');

    my $zoned = $engine->compile($engine->query->select('id', 'aware', 'day')->use_timezone('Asia/Tokyo'));
    my $zoned_sql = $adapter->_canonical_statement($zoned)->sql;
    like($zoned_sql, qr/\QWHEN 1114 THEN CASE WHEN pg_catalog.isfinite(CAST((("s0"."aware" AT TIME ZONE \E\$1\Q)) AS TIMESTAMP))\E/,
        'a utc_datetime localized by a query timezone is formatted as its (naive) type');
    is_deeply($zoned->params, ['Asia/Tokyo'], 'the zone stays one parameter');
};

subtest 'a CTE prefix and grouping keep their text' => sub {
    my $query = $engine->query->select('day', $x->sum('amount')->as('total'))
        ->group_by('day')->order_by($x->sum('amount'), 'desc')->order_by('day');
    my $statement = $engine->compile($query);
    my $sql = $statement->sql;
    is_deeply(columns_of($statement), [0], 'an aggregate is decoded in Perl');
    my $formatted = $adapter->_canonical_statement($statement)->sql;
    my $tail = substr($sql, index($sql, ', SUM('));
    is(substr($formatted, -length $tail), $tail, 'GROUP BY and ORDER BY keep the expressions');
    like($tail, qr/GROUP BY "s0"\."day" ORDER BY SUM\("s0"\."amount"\) DESC, "s0"\."day" ASC/,
        'never output names or positions');

    my $people = TestSelecto::people_domain();
    my $with = $engine->query->with_cte('top_people', $people,
        Selecto::Engine->new(domain => $people, adapter => $adapter)->query->select('id', 'score'),
        join => {owner_key => 'id', related_key => 'id'})
        ->select('id', 'amount', 'top_people.score');
    my $cte = $engine->compile($with);
    like($cte->sql, qr/\AWITH /, 'the statement has a CTE prefix');
    is_deeply(columns_of($cte), [1], 'a query-source field has no declared type here');
    my $prefix = substr($cte->sql, 0, index($cte->sql, 'SELECT "s0"."id"'));
    my $cte_formatted = $adapter->_canonical_statement($cte)->sql;
    is(substr($cte_formatted, 0, length $prefix), $prefix, 'the CTE text is unchanged');
    like($cte_formatted, qr/\Q"s0"."id", @{[$NUMERIC->('"s0"."amount"')]} AS "amount", "top_people"."score"\E/,
        'the outer selection is formatted');
};

subtest 'statements without a top-level projection decode in Perl' => sub {
    my $rollup = $engine->compile($engine->query->select('day', $x->sum('amount')->as('total'))
        ->group_by_rollup('day')->order_by('day'));
    is($adapter->_canonical_statement($rollup), $rollup, 'a rollup ordered by output position');
    my $plain_rollup = $engine->compile($engine->query->select('day', $x->sum('amount')->as('total'))
        ->group_by_rollup('day'));
    is_deeply(columns_of($plain_rollup), [0], 'an unordered rollup is formatted');
    my $union = $engine->compile($engine->query->select('id', 'amount')
        ->union($engine->query->select('id', 'amount'))->order_by('amount'));
    is($adapter->_canonical_statement($union), $union, 'a set operation');
    my $statement = $engine->compile($engine->query->select('id', 'amount'));
    my $copy = Selecto::Statement->new(sql => $statement->sql, params => $statement->params,
        columns => $statement->columns, adapter_name => 'postgresql');
    is($adapter->_canonical_statement($copy), $copy, 'a statement the adapter did not compile');
    my $sum = $adapter->projection_sum_statement($statement, 'amount');
    is($adapter->_canonical_statement($sum), $sum, 'a projection sum');
    my $only_integers = $engine->compile($engine->query->select('id', 'label'));
    is($adapter->_canonical_statement($only_integers), $only_integers, 'nothing to format');
    $statement->{sql} .= ' ';
    is($adapter->_canonical_statement($statement), $statement, 'a statement whose SQL changed after compile');
    my $plain = Selecto::PostgreSQL->new(dbh => $dbh);
    my $compiled = Selecto::Engine->new(domain => $domain, adapter => $plain)->compile(
        $engine->query->select('id', 'amount'));
    is($plain->_canonical_statement($compiled), $compiled, 'a handle that is not DBD::Pg');
    my $off = Local::CanonicalAdapter->new(dbh => $dbh, canonical_sql => 0);
    $compiled = Selecto::Engine->new(domain => $domain, adapter => $off)->compile($engine->query->select('id', 'amount'));
    is($off->_canonical_statement($compiled), $compiled, 'canonical_sql => 0');
};

subtest 'numeric needs PostgreSQL 13' => sub {
    my $statement = $engine->compile($engine->query->select('amount', 'day'));
    local $Local::CanonicalAdapter::VERSION_NUM = 120022;
    is_deeply(columns_of($statement), [1], 'before 13 numeric is decoded in Perl');
    unlike($adapter->_canonical_statement($statement)->sql, qr/trim_scale/, 'no trim_scale');
    my $numeric_only = $engine->compile($engine->query->select('amount'));
    is($adapter->_canonical_statement($numeric_only), $numeric_only, 'nothing else to format');
    local $Local::CanonicalAdapter::VERSION_NUM = 130000;
    like($adapter->_canonical_statement($numeric_only)->sql, qr/trim_scale/, 'from 13 it is formatted');
};

subtest 'the bounded-result guard selects the formatted columns' => sub {
    my $statement = $engine->compile($engine->query->select('id', 'amount', 'day')->order_by('amount'));
    my $guarded = $adapter->bounded_result_statement($statement, max_cell_bytes => 100, max_rows => 10);
    my $formatted = $adapter->_canonical_statement($guarded)->sql;
    my $inner = $adapter->_canonical_statement($statement)->sql;
    like($formatted, qr/\A\QWITH selecto_bounded AS MATERIALIZED (SELECT * FROM ($inner) AS selecto_source LIMIT 10)\E/,
        'the wrapped statement is the formatted one');
    like($formatted, qr/\Q) SELECT CASE WHEN octet_length(CAST(selecto_bounded."id" AS TEXT)) > 100\E/,
        'and the guard is unchanged, so it measures the canonical text');
    is($adapter->bounded_result_statement($statement, max_cell_bytes => 100, max_rows => 10)->sql, $guarded->sql,
        'the guard without canonical values is as before');
};

subtest 'integers the driver made as numbers are kept' => sub {
    my $FLAGS = B::SVf_IOK() | B::SVf_NOK() | B::SVf_POK() | B::SVf_ROK();
    my $shape = sub { my ($v) = @_; defined($v) ? sprintf('%s/%x', $v, B::svref_2object(\$v)->FLAGS & $FLAGS) : 'undef' };
    my $dual = '7'; { no warnings; my $n = $dual + 0; }
    # DBD::Pg makes integer columns IVs or (on 32-bit perls, for int8)
    # strings; other handles may hand over anything.
    my @driver = (5, -3, 0, 9_000_000_000, '12', '-4', '007', ' 8', '1.5', 'x', $dual, undef);
    my @other = (@driver, 2.0, -0.0, 1e20);
    for my $driver (0, 1) {
        my @values = $driver ? @driver : @other;
        my $expected = [map { $shape->(Selecto::PostgreSQL->new(dbh => $dbh)->_decode($_, 'int4')) } @values];
        my $decoder = $driver ? $adapter : Selecto::PostgreSQL->new(dbh => $dbh);
        my $rows = [map { [$_] } @values];
        $decoder->_decode_rows($rows, ['int8']);
        is_deeply([map { $shape->($_->[0]) } @$rows], $expected,
            ($driver ? 'a DBD::Pg handle' : 'another handle') . ': the values, flags included, int() gives');
    }
};

done_testing;
