use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;

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
            metadata => { returning => ['id'] },
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

my $unsupported = Selecto::DuckDB->new(dbh => TestSelecto::DBH->new);
eval { $unsupported->execute_graph($graph) };
is($@->code, 'write_capability_missing', 'non-graph adapters fail closed before a transaction begins');

eval {
    Selecto::Write::Graph->new(nodes => [{
        id => 'child',
        command => Selecto::Write::Command->new(operation => 'insert', relation => 'children', assignments => { name => 'x' }),
        bindings => [{ field => 'parent_id', from => 'missing', key => 'id' }],
    }]);
};
ok(!$@, 'graph validates binding shape before execution');

done_testing;
