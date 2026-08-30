use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::DuckDB ();
use Selecto::MSSQL ();
use Selecto::PostgreSQL ();
use Selecto::SQLite ();

my $dbh = TestSelecto::DBH->new(
    { affected => 1, rows => [[41]] },
    { affected => 1, rows => [[99]] },
);
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $graph = Selecto::Write::Graph->new(nodes => [
    {
        id => 'order',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'orders', assignments => { order_no => 'PO-41' },
        ),
    },
    {
        id => 'line_item',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'line_items', assignments => { sku => 'SKU-1' },
            metadata => { returning => ['id'] },
        ),
        bindings => [{ field => 'order_id', from => 'order', key => 'id' }],
    },
]);

my $result = $adapter->execute_graph($graph);
is($result->root->values->{id}, 41, 'graph exposes root returned values');
is($result->nodes->{line_item}->values->{id}, 99, 'graph exposes child returned values');
is_deeply($dbh->events, ['BEGIN', 'COMMIT'], 'graph executes in one transaction');

my $prepared = $dbh->prepared;
is($prepared->[0]->sql, 'INSERT INTO "orders" ("order_no") VALUES ($1) RETURNING "id"', 'root graph node requests its generated key');
is_deeply($prepared->[1]->params, [41, 'SKU-1'], 'child graph node receives declared parent binding');
is_deeply($graph->nodes->[0]{command}->metadata->{returning}, ['id'],
    'graph normalization derives source RETURNING keys from downstream bindings');

my $unsupported = Selecto::MSSQL->new(dbh => TestSelecto::DBH->new);
eval { $unsupported->execute_graph($graph) };
is($@->code, 'write_capability_missing', 'non-graph adapters fail closed before a transaction begins');

eval {
    Selecto::Write::Graph->new(nodes => [{
        id => 'child',
        command => Selecto::Write::Command->new(operation => 'insert', relation => 'children', assignments => { name => 'x' }),
        bindings => [{ field => 'parent_id', from => 'missing', key => 'id' }],
    }]);
};
isa_ok($@, 'Selecto::Error');
is($@->code, 'invalid_write_graph', 'missing graph binding sources fail during construction');

eval {
    Selecto::Write::Graph->new(nodes => [
        {
            id => 'root',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'roots', assignments => { name => 'root' },
            ),
        },
        {
            id => 'child',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'children', assignments => { name => 'child' },
            ),
            bindings => [{ field => 'root_id', from => 'grandchild', key => 'id' }],
        },
        {
            id => 'grandchild',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'grandchildren', assignments => { name => 'grandchild' },
            ),
            bindings => [{ field => 'child_id', from => 'child', key => 'id' }],
        },
    ]);
};
is($@->code, 'invalid_write_graph', 'forward graph binding sources fail during construction');

{
    package TestSelecto::ModernSQLiteDBH;
    our @ISA = ('TestSelecto::DBH');
    sub selectrow_array { return '3.45.0'; }
}

my $sqlite_dbh = TestSelecto::ModernSQLiteDBH->new(
    { affected => 1, rows => [[501]] },
    { affected => 1, rows => [[502]] },
    { affected => 1, rows => [[503]] },
);
my $sqlite = Selecto::SQLite->new(dbh => $sqlite_dbh);
ok($sqlite->write_capabilities->{write_graph}, 'SQLite 3.35+ advertises native-returning graph execution');
my $deep_graph = Selecto::Write::Graph->new(nodes => [
    {
        id => 'parent',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'parents', assignments => { label => 'parent' },
        ),
    },
    {
        id => 'child',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'children', assignments => { label => 'child' },
        ),
        bindings => [{ field => 'parent_id', from => 'parent', key => 'id' }],
    },
    {
        id => 'grandchild',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'grandchildren', assignments => { label => 'grandchild' },
            metadata => { returning => ['id'] },
        ),
        bindings => [{ field => 'child_id', from => 'child', key => 'id' }],
    },
]);
my $deep_result = $sqlite->execute_graph($deep_graph);
is($deep_result->nodes->{grandchild}->values->{id}, 503,
    'the portable graph executor carries generated keys through three SQLite nodes');
is_deeply(
    $sqlite_dbh->prepared->[2]->params,
    [502, 'grandchild'],
    'the grandchild binds to the immediate child result with positional placeholders',
);
like($sqlite_dbh->prepared->[1]->sql, qr/ RETURNING "id"\z/,
    'an intermediate node automatically returns the key required at the next depth');

eval {
    Selecto::Write::Graph->new(nodes => [
        {
            id => 'root',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'roots', assignments => { name => 'root' },
            ),
        },
        {
            id => 'child',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'children',
                assignments => { parent_id => 999, name => 'child' },
            ),
            bindings => [{ field => 'parent_id', from => 'root', key => 'id' }],
        },
    ]);
};
is($@->code, 'invalid_write_graph', 'bindings cannot silently overwrite authored assignments');

eval {
    Selecto::Write::Graph->new(nodes => [
        {
            id => 'root',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'roots', assignments => { name => 'root' },
            ),
        },
        {
            id => 'child',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'children', assignments => { name => 'child' },
            ),
            bindings => [
                { field => 'parent_id', from => 'root', key => 'id' },
                { field => 'parent_id', from => 'root', key => 'other_id' },
            ],
        },
    ]);
};
is($@->code, 'invalid_write_graph', 'duplicate binding targets fail before order can choose a value');

my $graph_nodes = $deep_graph->nodes;
$graph_nodes->[1]{bindings}[0]{field} = 'mutated';
is($deep_graph->nodes->[1]{bindings}[0]{field}, 'parent_id',
    'graph accessors do not expose mutable binding state');

my $duckdb = Selecto::DuckDB->new(dbh => TestSelecto::DBH->new);
ok($duckdb->write_capabilities->{write_graph}, 'DuckDB advertises shared native-returning graph execution');

done_testing;
