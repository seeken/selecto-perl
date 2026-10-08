use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Statement ();

# Offline checks of the SQL that formats canonical values: only the outermost
# SELECT list changes, and every other byte of the statement is kept. The live
# identity of the values themselves is t/canonical_values.integration.t.

my $dbh = TestSelecto::DBH->new;
$dbh->{pg_server_version} = 170000;
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $domain = TestSelecto::orders_domain();
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $x = 'Selecto::Expression';

sub formatted {
    my ($statement, @types) = @_;
    my $plan = $adapter->_projection($statement) or return undef;
    return $adapter->_canonical_sql_text($plan, {types => \@types, blocked => {}});
}

sub guard {
    my ($expression, $oid, $format) = @_;
    return "CASE WHEN CAST(pg_catalog.pg_typeof(CASE WHEN FALSE THEN ($expression) END) AS OID) = $oid"
        . " THEN $format ELSE '!' END";
}

subtest 'formatted selections keep their aliases and every other clause' => sub {
    my $query = $engine->query->select('id', 'total', $x->field('person.name'))
        ->where($x->gt('total', 5))->order_by('total', 'desc')->limit(10);
    my $statement = $engine->compile($query);
    my $sql = $statement->sql;
    is($sql, 'SELECT "s0"."id", "s0"."total", "j_person"."name" AS "person.name" FROM "orders" AS "s0" '
        . 'LEFT JOIN "people" AS "j_person" ON "s0"."person_id" = "j_person"."id" '
        . 'WHERE "s0"."total" > $1 ORDER BY "s0"."total" DESC LIMIT 10', 'the compiled statement');
    my $formatted = formatted($statement, 'int4', 'numeric', 'text');
    is_deeply($formatted->{columns}, [1], 'only the numeric column is formatted');
    my $tail = substr($sql, index($sql, ' FROM '));
    is($formatted->{sql}, 'SELECT "s0"."id", '
        . guard('"s0"."total"', 1700, 'CAST(pg_catalog.trim_scale(CAST(CAST(("s0"."total") AS TEXT) AS NUMERIC)) AS TEXT)')
        . ', "j_person"."name" AS "person.name"' . $tail,
        'the ORDER BY still sorts the underlying value, and parameters keep their numbers');
    my $aliased = formatted($statement, 'int4', 'numeric', 'timestamptz');
    like($aliased->{sql}, qr/THEN pg_catalog\.regexp_replace\(pg_catalog\.translate\(CAST\(\("j_person"\."name"\) AS TEXT\), ' ', 'T'\), '\(\[\.\]0\+\)\?\(\[\+\]00\(:00\)\?\|Z\)\$', ''\) ELSE '!' END AS "person\.name" FROM /,
        'an aliased selection keeps its alias after the formatter');
};

subtest 'each canonical type has its formatter' => sub {
    my $statement = $engine->compile($engine->query->select('id', 'total', 'person_id', 'person.name', 'person.id'));
    my $formatted = formatted($statement, 'float4', 'float8', 'timestamp', 'numeric', 'int8');
    like($formatted->{sql}, qr/= 1114 THEN pg_catalog\.translate\(CAST\(\("s0"\."person_id"\) AS TEXT\), ' ', 'T'\) ELSE/, 'timestamp only turns spaces into T');
    is_deeply($formatted->{columns}, [2, 3], 'floats and integers are left to Perl');
    unlike($formatted->{sql}, qr/"s0"\."(?:id|total)"\) END/, 'the float columns are untouched');
    my $old = TestSelecto::DBH->new;
    $old->{pg_server_version} = 120022;
    my $plan = $adapter->_projection($statement);
    my $before_13 = Selecto::PostgreSQL->new(dbh => $old)
        ->_canonical_sql_text($plan, {types => ['numeric', 'text', 'text', 'text', 'text'], blocked => {}});
    ok(!defined($before_13), 'before PostgreSQL 13 a numeric column is left to Perl (no trim_scale)');
    my $blocked = $adapter->_canonical_sql_text($plan, {types => ['numeric', 'timestamptz', 'text', 'text', 'text'], blocked => {1 => 1}});
    is_deeply($blocked->{columns}, [0], 'a column whose type changed is not formatted again');
    ok(!defined($adapter->_canonical_sql_text($plan, {types => ['numeric'], blocked => {}})),
        'learned types for another column count are ignored');
};

subtest 'a CTE prefix and grouping keep their text' => sub {
    my $query = $engine->query->select('person_id', $x->sum('total')->as('total'))
        ->group_by('person_id')->order_by($x->sum('total'), 'desc');
    my $statement = $engine->compile($query);
    my $sql = $statement->sql;
    my $formatted = formatted($statement, 'int4', 'numeric');
    my ($head, $tail) = ($sql =~ /\A(SELECT "s0"\."person_id", )(?:SUM\("s0"\."total"\) AS "total")( FROM .*)\z/);
    ok(defined($tail), 'the compiled statement') or diag $sql;
    is($formatted->{sql}, $head . guard('SUM("s0"."total")', 1700, 'CAST(pg_catalog.trim_scale(CAST(CAST((SUM("s0"."total")) AS TEXT) AS NUMERIC)) AS TEXT)')
        . ' AS "total"' . $tail, 'GROUP BY and ORDER BY keep the aggregate itself');
    like($tail, qr/ORDER BY SUM\("s0"\."total"\) DESC/, 'ordered by the expression, never by name or position');

    my $people = TestSelecto::people_domain();
    my $with = $engine->query->with_cte('top_people', $people,
        Selecto::Engine->new(domain => $people, adapter => $adapter)->query->select('id', 'score'),
        join => {owner_key => 'person_id', related_key => 'id'})
        ->select('id', 'top_people.score');
    my $cte = $engine->compile($with);
    like($cte->sql, qr/\AWITH /, 'the statement has a CTE prefix');
    my $cte_formatted = formatted($cte, 'int4', 'numeric');
    my $prefix = substr($cte->sql, 0, index($cte->sql, 'SELECT "s0"."id"'));
    is(substr($cte_formatted->{sql}, 0, length $prefix), $prefix, 'the CTE text is unchanged');
    like($cte_formatted->{sql}, qr/THEN CAST\(pg_catalog\.trim_scale\(CAST\(CAST\(\("top_people"\."score"\) AS TEXT\) AS NUMERIC\)\) AS TEXT\) ELSE '!' END AS "top_people\.score" FROM /,
        'the outer selection is formatted');
};

subtest 'statements without a top-level projection decode in Perl' => sub {
    my $rollup = $engine->compile($engine->query->select('person_id', $x->sum('total')->as('total'))
        ->group_by_rollup('person_id')->order_by('person_id'));
    ok(!$adapter->_projection($rollup), 'a rollup ordered by output position');
    my $plain_rollup = $engine->compile($engine->query->select('person_id', $x->sum('total')->as('total'))
        ->group_by_rollup('person_id'));
    ok($adapter->_projection($plain_rollup), 'an unordered rollup is formatted');
    my $union = $engine->compile($engine->query->select('id', 'total')
        ->union($engine->query->select('id', 'total'))->order_by('total'));
    ok(!$adapter->_projection($union), 'a set operation');
    my $statement = $engine->compile($engine->query->select('id', 'total'));
    my $copy = Selecto::Statement->new(sql => $statement->sql, params => $statement->params,
        columns => $statement->columns, adapter_name => 'postgresql');
    ok(!$adapter->_projection($copy), 'a statement the adapter did not compile');
    $statement->{sql} .= ' ';
    ok(!$adapter->_projection($statement), 'a statement whose SQL changed after compile');
    ok(!$adapter->_canonical_plan($engine->compile($engine->query->select('id'))),
        'a handle that is not DBD::Pg');
};

done_testing;
