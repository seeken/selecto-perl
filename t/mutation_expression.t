use 5.034;
use strict;
use warnings;

use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::MySQL ();

sub exception (&) {
    my ($operation) = @_;
    my $ok = eval { $operation->(); 1 };
    return undef if $ok;
    return $@;
}

my $mutation = Selecto::Write::Expression->coalesce(
    Selecto::Write::Expression->increment('total', 2.5),
    0,
);
is_deeply($mutation->referenced_fields, ['total'], 'mutation AST reports governed field references');
my $arguments = $mutation->arguments;
$arguments->[0][0] = Selecto::Write::Expression->literal('changed');
is_deeply($mutation->referenced_fields, ['total'], 'returned operands cannot mutate the expression');
$arguments = $mutation->arguments;
$arguments->[0][0]->{arguments}[0]->{arguments}[0] = 'changed_in_place';
is_deeply($mutation->referenced_fields, ['total'],
    'nested expression objects returned by accessors are independent copies');

my $command = Selecto::Write::Command->new(
    operation => 'update',
    relation => 'items',
    assignments => {
        total => $mutation,
        updated_at => Selecto::Write::Expression->current_timestamp,
    },
    predicate => Selecto::Expression->eq('id', 7),
);

my $postgres = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new);
is_deeply(
    $postgres->preview_write($command),
    {
        sql => 'UPDATE "items" SET "total" = COALESCE(("total" + $1), $2), "updated_at" = CURRENT_TIMESTAMP WHERE "id" = $3',
        params => [2.5, 0, 7],
    },
    'PostgreSQL compiles the closed mutation AST and binds only literal operands',
);

my $sqlite = Selecto::SQLite->new(dbh => TestSelecto::DBH->new);
is_deeply(
    $sqlite->preview_write($command),
    {
        sql => 'UPDATE "items" SET "total" = COALESCE(("total" + ?), ?), "updated_at" = CURRENT_TIMESTAMP WHERE "id" = ?',
        params => [2.5, 0, 7],
    },
    'the same mutation AST compiles through a positional-placeholder adapter',
);

my $mysql = Selecto::MySQL->new(dbh => TestSelecto::DBH->new);
is_deeply(
    $mysql->preview_write($command),
    {
        sql => 'UPDATE `items` SET `total` = COALESCE((`total` + ?), ?), `updated_at` = CURRENT_TIMESTAMP WHERE `id` = ?',
        params => [2.5, 0, 7],
    },
    'the mutation AST is independent of identifier and placeholder dialects',
);

my $default = Selecto::Write::Command->new(
    operation => 'update', relation => 'items',
    assignments => { status => Selecto::Write::Expression->default },
    predicate => Selecto::Expression->eq('id', 1),
);
my $error;
is(
    $postgres->preview_write($default)->{sql},
    'UPDATE "items" SET "status" = DEFAULT WHERE "id" = $1',
    'DEFAULT is a typed assignment node rather than raw SQL',
);

$error = exception { $sqlite->preview_write($default) };
is($error->code, 'invalid_write', 'dialects without per-assignment DEFAULT fail closed');

$error = exception {
    $postgres->preview_write(Selecto::Write::Command->new(
        operation => 'insert', relation => 'items',
        assignments => { total => Selecto::Write::Expression->field('total') },
    ));
};
isa_ok($error, 'Selecto::Error');
is($error->code, 'invalid_write', 'insert expressions cannot read a row that does not exist');

$error = exception {
    Selecto::Write::Expression->new('raw_sql', 'total + 1');
};
is($error->code, 'invalid_write', 'unknown mutation nodes fail closed');

$error = exception {
    Selecto::Write::Expression->new('add', Selecto::Write::Expression->literal(1));
};
is($error->code, 'invalid_write', 'malformed mutation nodes fail closed');

$error = exception {
    $postgres->preview_write(Selecto::Write::Command->new(
        operation => 'update', relation => 'items',
        assignments => {
            total => Selecto::Write::Expression->add(
                Selecto::Write::Expression->default,
                1,
            ),
        },
        predicate => Selecto::Expression->eq('id', 1),
    ));
};
is($error->code, 'invalid_write', 'DEFAULT cannot be smuggled into a nested expression');

my $governed_domain = Selecto::Domain->parse({
    schema_version => 1,
    domain_version => '1.0.0',
    domain_fingerprint => 'sha256:mutation-test',
    name => 'Items',
    source => {
        source_table => 'items', primary_key => 'id',
        fields => [qw(id total updated_at)],
        columns => {
            id => { type => 'integer' }, total => { type => 'decimal' },
            updated_at => { type => 'naive_datetime' },
        },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { update => { enabled => 1 } },
        fields => {
            id => { updatable => 0 },
            total => { updatable => 1 },
            updated_at => { updatable => 1 },
        },
        relationships => {},
    },
}, strict => 1);
my $engine = Selecto::Engine->new(
    domain => $governed_domain,
    adapter => Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new({ affected => 1 })),
);
$engine->execute_write($command);
pass('declared mutation target and source fields pass domain governance');

$error = exception {
    $engine->execute_write(Selecto::Write::Command->new(
        operation => 'update', relation => 'items',
        assignments => {
            total => Selecto::Write::Expression->increment('undeclared_total'),
        },
        predicate => Selecto::Expression->eq('id', 7),
    ));
};
is($error->code, 'unknown_field', 'mutation source fields are governed before adapter dispatch');

my $guarded_insert = Selecto::Write::Command->new(
    operation => 'insert', relation => 'items',
    assignments => {
        id => 1,
        tenant_id => Selecto::Write::Expression->literal(7),
        updated_at => Selecto::Write::Expression->current_timestamp,
    },
    predicate => Selecto::Expression->eq('tenant_id', 7),
);
is_deeply(
    $sqlite->preview_write($guarded_insert)->{params},
    [1, 7],
    'literal mutation nodes remain evaluable for insert guards while generated values stay parameter-free',
);

my $graph_dbh = TestSelecto::DBH->new(
    { affected => 1, rows => [[41]] },
    { affected => 1, rows => [[99]] },
);
my $graph_adapter = Selecto::PostgreSQL->new(dbh => $graph_dbh);
my $graph = Selecto::Write::Graph->new(nodes => [
    {
        id => 'parent',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'parents', assignments => { label => 'parent' },
            metadata => { returning => ['id'] },
        ),
    },
    {
        id => 'child',
        command => Selecto::Write::Command->new(
            operation => 'insert', relation => 'children',
            assignments => { created_at => Selecto::Write::Expression->current_timestamp },
            metadata => { returning => ['id'] },
        ),
        bindings => [{ field => 'parent_id', from => 'parent', key => 'id' }],
    },
]);
$graph_adapter->execute_graph($graph);
is(
    $graph_dbh->prepared->[1]->sql,
    'INSERT INTO "children" ("created_at", "parent_id") VALUES (CURRENT_TIMESTAMP, $1) RETURNING "id"',
    'mutation expressions survive parent binding injection in nested graphs',
);
is_deeply($graph_dbh->prepared->[1]->params, [41], 'graph binding remains a bound value');

done_testing;
