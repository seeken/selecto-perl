use 5.034;
use strict;
use warnings;
use lib 't/lib';
use Test::More;
use TestSelecto;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Write ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

# Graph children that update, delete, or upsert must stay under the parent row
# the graph bound them to. The parent binding is a WHERE condition for update
# and delete, never an assignment, and an upsert conflict must include it.

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $e = $@;
    return blessed($e) && $e->isa('Selecto::Error') ? $e->code : "died: $e";
}

sub step_domain {
    return {
        schema_version => 1, name => 'Steps',
        source => {
            source_table => 'work_order_steps', primary_key => 'id',
            fields => [qw(id work_order_id position instruction)],
            columns => {
                id => {type => 'integer'}, work_order_id => {type => 'integer'},
                position => {type => 'integer'}, instruction => {type => 'string'},
            },
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => {map { ($_ => {enabled => 1}) } qw(insert update upsert delete)},
            fields => {
                work_order_id => {insertable => 1},
                position      => {insertable => 1, updatable => 1},
                instruction   => {insertable => 1, updatable => 1},
            },
        },
    };
}

sub work_order_domain {
    my (%o) = @_;
    return Selecto::Domain->parse({
        schema_version => 1, name => 'Work Orders',
        source => {
            source_table => 'work_orders', primary_key => 'id',
            fields => [qw(id site_id title)],
            columns => {id => {type => 'integer'}, site_id => {type => 'integer'}, title => {type => 'string'}},
            tenant_field => 'site_id', associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => {update => {enabled => 1}},
            fields => {title => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
            relationships => {
                steps => {
                    writable => 1, table => 'work_order_steps', parent_key => 'id', child_key => 'work_order_id',
                    allowed_ops => [qw(insert update upsert delete)],
                    ($o{bare_child} ? () : (domain => step_domain())),
                },
            },
        },
    });
}

sub engine {
    my (%o) = @_;
    my $dbh = TestSelecto::DBH->new(@{$o{specs} // [
        {affected => 1, rows => [[1]]}, {affected => 1, rows => [[200]]}, {affected => 1},
    ]});
    my $engine = Selecto::Engine->new(
        domain => work_order_domain(%o), adapter => Selecto::PostgreSQL->new(dbh => $dbh),
        scope => {tenant => 10}, %{$o{engine} // {}},
    );
    return ($dbh, $engine);
}

sub graph_with_child {
    my ($child, %binding) = @_;
    return Selecto::Write::Graph->new(nodes => [
        {id => 'order', command => Selecto::Write::Command->new(
            operation => 'update', relation => 'work_orders',
            assignments => {title => 'touched'}, predicate => Selecto::Expression->eq('id', 1),
        )},
        {id => 'step', command => $child,
         bindings => [{field => 'work_order_id', from => 'order', key => 'id', %binding}]},
    ]);
}

subtest 'update child is confined to its bound parent and does not move' => sub {
    my ($dbh, $engine) = engine();
    my $child = Selecto::Write::Command->new(
        operation => 'update', relation => 'work_order_steps',
        assignments => {instruction => 'changed'}, predicate => Selecto::Expression->eq('id', 200),
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($child)) }), 'ok', 'graph executes');
    my $step = $dbh->prepared->[1];
    is($step->sql,
        'UPDATE "work_order_steps" SET "instruction" = $1 WHERE ("id" = $2) AND ("work_order_id" = $3)',
        'parent key is a WHERE condition, not a SET');
    is_deeply($step->params, ['changed', 200, 1], 'parent value is bound');
};

subtest 'update child addressing a row under another parent fails and rolls back' => sub {
    my ($dbh, $engine) = engine(specs => [{affected => 1, rows => [[1]]}, {affected => 0}]);
    my $child = Selecto::Write::Command->new(
        operation => 'update', relation => 'work_order_steps',
        assignments => {instruction => 'pwned'}, predicate => Selecto::Expression->eq('id', 999),
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($child)) }), 'cardinality_mismatch',
        'foreign child row is not matched');
    ok($dbh->rolled_back, 'graph transaction is rolled back') if $dbh->can('rolled_back');
};

subtest 'delete child is confined to its bound parent' => sub {
    my ($dbh, $engine) = engine();
    my $child = Selecto::Write::Command->new(
        operation => 'delete', relation => 'work_order_steps', predicate => Selecto::Expression->eq('id', 201),
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($child)) }), 'ok', 'graph executes');
    is($dbh->prepared->[1]->sql,
        'DELETE FROM "work_order_steps" WHERE ("id" = $1) AND ("work_order_id" = $2)',
        'delete carries the parent key');
    is_deeply($dbh->prepared->[1]->params, [201, 1], 'parent value is bound');
};

subtest 'explicit scope_field still produces a single parent condition' => sub {
    my ($dbh, $engine) = engine();
    my $child = Selecto::Write::Command->new(
        operation => 'delete', relation => 'work_order_steps', predicate => Selecto::Expression->eq('id', 201),
    );
    $engine->execute_graph(graph_with_child($child, scope_field => 'work_order_id'));
    is($dbh->prepared->[1]->sql,
        'DELETE FROM "work_order_steps" WHERE ("id" = $1) AND ("work_order_id" = $2)',
        'opt-in scope_field is not duplicated');
};

subtest 'update child cannot reassign its parent key' => sub {
    my ($dbh, $engine) = engine();
    my $child = Selecto::Write::Command->new(
        operation => 'update', relation => 'work_order_steps',
        assignments => {work_order_id => 77}, predicate => Selecto::Expression->eq('id', 200),
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($child)) }), 'invalid_write_graph',
        'explicit parent-key assignment is refused when the graph is built');
};

subtest 'upsert child conflict target must include the parent key' => sub {
    my ($dbh, $engine) = engine();
    my $outside = Selecto::Write::Command->new(
        operation => 'upsert', relation => 'work_order_steps',
        assignments => {position => 1, instruction => 'x'},
        metadata => {conflict_target => ['position'], upsert_update_fields => ['instruction']},
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($outside)) }), 'invalid_write_graph',
        'conflict target without the parent key is refused');

    ($dbh, $engine) = engine();
    my $inside = Selecto::Write::Command->new(
        operation => 'upsert', relation => 'work_order_steps',
        assignments => {position => 1, instruction => 'x'},
        metadata => {conflict_target => ['work_order_id', 'position'], upsert_update_fields => ['instruction']},
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($inside)) }), 'ok',
        'conflict target including the parent key is accepted');
    like($dbh->prepared->[1]->sql, qr/ON CONFLICT \("work_order_id", "position"\)/, 'conflict is parent-scoped');
};

subtest 'insert child still receives the parent key by assignment' => sub {
    my ($dbh, $engine) = engine();
    my $child = Selecto::Write::Command->new(
        operation => 'insert', relation => 'work_order_steps',
        assignments => {position => 1, instruction => 'new'},
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($child)) }), 'ok', 'graph executes');
    like($dbh->prepared->[1]->sql, qr/INSERT INTO "work_order_steps" \(.*"work_order_id".*\)/, 'parent key is inserted');
};

subtest 'strict engine refuses relationships without a nested domain' => sub {
    my ($dbh, $engine) = engine(bare_child => 1);
    my $child = Selecto::Write::Command->new(
        operation => 'delete', relation => 'work_order_steps',
        predicate => Selecto::Expression->eq('not_a_declared_column', 1),
        metadata => {returning => ['any_column_at_all']},
    );
    is(code_of(sub { $engine->execute_graph(graph_with_child($child)) }), 'write_policy_missing',
        'undeclared child domain is refused before any SQL');
    is(scalar @{$dbh->prepared}, 0, 'no statement ran');
};

done_testing;
