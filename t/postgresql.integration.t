use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;
use Selecto::Certification ();

my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
my $dbh = DBI->connect($dsn, $username, $password, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1,
});
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_items');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_form_grandchildren');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_form_children');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_graph_children');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_graph_parents');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_events');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_employees');
$dbh->do('CREATE TABLE selecto_perl_test_items (id integer primary key, name text not null)');
$dbh->do('ALTER TABLE selecto_perl_test_items ADD COLUMN amount numeric NOT NULL DEFAULT 10');
$dbh->do(q{ALTER TABLE selecto_perl_test_items ADD COLUMN payload jsonb NOT NULL DEFAULT '[]'::jsonb});
$dbh->do(q{INSERT INTO selecto_perl_test_items (id, name, payload) VALUES (1, 'baseline', '[{"sku":"A-1","quantity":2}]')});
$dbh->do('CREATE TABLE selecto_perl_test_events (id integer primary key, item_id integer not null, kind text not null)');
$dbh->do(q{INSERT INTO selecto_perl_test_events VALUES (1, 1, 'status')});
$dbh->do('CREATE TABLE selecto_perl_test_employees (id integer primary key, manager_id integer, name text not null)');
$dbh->do(q{INSERT INTO selecto_perl_test_employees VALUES (1, NULL, 'CEO'), (2, 1, 'Lead'), (3, 2, 'Engineer')});

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'selecto_perl_test_items',
    fields => { id => 'integer', name => 'string', amount => 'decimal', payload => 'jsonb' },
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
my $result = $engine->all($engine->query->select('id', 'name')->order_by('id'));
is_deeply($result, { columns => ['id', 'name'], rows => [[1, 'baseline']] }, 'public query API executes through DBD::Pg');

my $set_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))
        ->union_all($engine->query->select('id')->where(Selecto::Expression->eq('id', 1)))
        ->intersect($engine->query->select('id')->where(Selecto::Expression->eq('id', 999))),
);
is_deeply($set_result->{rows}, [],
    'PostgreSQL executes mixed set operations with portable left-to-right semantics');

my $window_result = $engine->all(
    $engine->query->select(
        'id', Selecto::Expression->row_number(order_by => [['id', 'asc']])->as('position'),
    ),
);
is_deeply($window_result->{rows}, [[1, 1]], 'PostgreSQL executes a governed window function');

my $cte_source = $engine->query->select('id', 'name')
    ->where(Selecto::Expression->eq('id', 1));
my $cte_result = $engine->all(
    $engine->query
        ->with_cte(
            'selected_items', $domain, $cte_source,
            columns => [qw(id name)],
            join => {owner_key => 'id', related_key => 'id', type => 'inner'},
        )
        ->select('id', 'selected_items.name'),
);
is_deeply($cte_result->{rows}, [[1, 'baseline']], 'PostgreSQL executes a governed CTE');

my $employees = Selecto::Domain->new(
    name => 'Employees', table => 'selecto_perl_test_employees',
    fields => {id => 'integer', manager_id => 'integer', name => 'string'},
);
my $employee_engine = Selecto::Engine->new(domain => $employees, adapter => $engine->adapter);
my $employee_anchor = $employee_engine->query->select(qw(id manager_id name))
    ->where(Selecto::Expression->is_null('manager_id'));
my $employee_member = $employee_engine->query->select(qw(id manager_id name));
my $tree_result = $employee_engine->all(
    $employee_engine->query
        ->with_recursive_cte(
            'employee_tree', $employees, $employee_anchor, $employee_member,
            columns => [qw(id manager_id name)],
            join => {owner_key => 'id', related_key => 'id', type => 'inner'},
            recursive_join => {owner_key => 'manager_id', related_key => 'id', type => 'inner'},
        )
        ->select('id', 'employee_tree.name')
        ->order_by('id'),
);
is_deeply(
    $tree_result->{rows},
    [[1, 'CEO'], [2, 'Lead'], [3, 'Engineer']],
    'PostgreSQL executes a three-level recursive CTE',
);

my $rollup_result = $engine->all(
    $engine->query->select(
        'name',
        Selecto::Expression->count->as('item_count'),
        Selecto::Expression->grouping('name')->as('__selecto_rollup_grouping'),
    )->group_by_rollup('name')->order_by('name'),
);
is_deeply(
    $rollup_result->{rows},
    [[undef, 1, 1], ['baseline', 1, 0]],
    'PostgreSQL executes a rollup with an explicit grand-total marker',
);

my $events_domain = Selecto::Domain->new(
    name => 'Events', table => 'selecto_perl_test_events',
    fields => {id => 'integer', item_id => 'integer', kind => 'string'},
);
my $event_query = Selecto::Query->new->select('item_id', 'kind')
    ->where(Selecto::Expression->eq('kind', 'status'));
my $lateral_result = $engine->all(
    $engine->query
        ->lateral_join(
            'events', $events_domain, $event_query,
            columns => [qw(item_id kind)], correlations => {item_id => 'id'},
        )
        ->select('id', 'events.kind'),
);
is_deeply($lateral_result->{rows}, [[1, 'status']],
    'PostgreSQL executes a correlated lateral subquery');

my $json_result = $engine->all(
    $engine->query
        ->json_rowset('payload', 'payload_items', {sku => 'string', quantity => 'integer'})
        ->select('id', 'payload_items.sku', 'payload_items.quantity'),
);
is_deeply($json_result->{rows}, [[1, 'A-1', 2]],
    'PostgreSQL executes a typed JSON rowset');

my $search_result = $engine->all(
    $engine->query->select('id')->where(
        Selecto::Expression->text_search(['name'], 'baseline', configuration => 'english'),
    ),
);
is_deeply($search_result->{rows}, [[1]], 'PostgreSQL executes governed full-text search');

my $stream = $engine->stream($engine->query->select('id', 'name')->order_by('id'), fetch_size => 1);
is_deeply($stream->next, [1, 'baseline'], 'PostgreSQL streams one decoded row at a time');
is($stream->next, undef, 'PostgreSQL streaming closes at exhaustion');

my $mutation = $engine->execute_write(Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_test_items',
    assignments => {amount => Selecto::Write::Expression->increment('amount', 1.25)},
    predicate => Selecto::Expression->eq('id', 1),
));
is($mutation->affected_rows, 1, 'PostgreSQL executes an adapter-independent mutation expression');
is($dbh->selectrow_array('SELECT amount FROM selecto_perl_test_items WHERE id = 1'), 11.25,
    'PostgreSQL applies the mutation expression atomically');

my $first = Selecto::Write::Command->new(
    operation => 'insert', relation => 'selecto_perl_test_items', assignments => { id => 2, name => 'must-roll-back' },
);
my $second = Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_test_items', assignments => { name => 'never' },
    predicate => Selecto::Expression->eq('id', 999),
);
eval { $engine->execute_batch(Selecto::Write::Batch->new($first, $second)) };
is($@->code, 'cardinality_mismatch', 'live batch reports portable cardinality error');
is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_test_items'), 1, 'failed live batch rolls back atomically');

$dbh->do('CREATE TABLE selecto_perl_test_graph_parents (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, label text NOT NULL)');
$dbh->do('CREATE TABLE selecto_perl_test_graph_children (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, parent_id integer NOT NULL REFERENCES selecto_perl_test_graph_parents(id), label text NOT NULL)');
my $graph_domain = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'GraphParents',
    source         => {
        source_table => 'selecto_perl_test_graph_parents',
        primary_key  => 'id',
        fields       => ['id', 'label'],
        columns      => { id => { type => 'integer' }, label => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { insert => { enabled => JSON::PP::true } },
        fields     => { label  => { insertable => JSON::PP::true } },
        relationships => {
            children => {
                writable    => JSON::PP::true,
                cardinality => 'many',
                allowed_ops => ['insert'],
                ownership   => 'owned',
                foreign_key => 'parent_id',
                table       => 'selecto_perl_test_graph_children',
            },
        },
    },
});
my $graph_engine = Selecto::Engine->new(domain => $graph_domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
my $ungoverned_child = Selecto::Write::Graph->new(nodes => [
    { id => 'parent', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_graph_parents', assignments => { label => 'nope' },
    ) },
    { id => 'child', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_undeclared', assignments => { label => 'child' },
    ), bindings => [{field => 'parent_id', from => 'parent', key => 'id'}] },
]);
eval { $graph_engine->execute_graph($ungoverned_child); 1 };
is($@->code, 'write_relation_mismatch', 'graph child relations must be declared writable relationships');
my $graph = Selecto::Write::Graph->new(nodes => [
    { id => 'parent', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_graph_parents', assignments => {label => 'parent'}, metadata => {returning => ['id']},
    ) },
    { id => 'child', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_graph_children', assignments => {label => 'child'},
    ), bindings => [{field => 'parent_id', from => 'parent', key => 'id'}] },
]);
my $graph_result = $graph_engine->execute_graph($graph);
is($graph_result->root->values->{id}, 1, 'live graph returns the generated root id');
is($dbh->selectrow_array('SELECT parent_id FROM selecto_perl_test_graph_children WHERE label = ?', undef, 'child'), 1,
    'live graph binds generated parent id into the child insert');

# Forms-style nested contracts resolve through relationship.domain.source.
$dbh->do('CREATE TABLE selecto_perl_test_form_children (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, parent_id integer NOT NULL REFERENCES selecto_perl_test_graph_parents(id), note text NOT NULL)');
$dbh->do('CREATE TABLE selecto_perl_test_form_grandchildren (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, form_child_id integer NOT NULL REFERENCES selecto_perl_test_form_children(id), tag text NOT NULL)');
my $grandchild_domain = {
    name   => 'Form grandchildren',
    source => {
        source_table => 'selecto_perl_test_form_grandchildren', primary_key => 'id',
        fields => ['id', 'form_child_id', 'tag'],
        columns => {
            id            => { type => 'integer' },
            form_child_id => { type => 'integer' },
            tag           => { type => 'string' },
        },
    },
    writes => { fields => { tag => { insertable => JSON::PP::true } } },
};
my $form_domain = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'FormParents',
    source         => {
        source_table => 'selecto_perl_test_graph_parents',
        primary_key  => 'id',
        fields       => ['id', 'label'],
        columns      => { id => { type => 'integer' }, label => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { insert => { enabled => JSON::PP::true } },
        fields     => { label  => { insertable => JSON::PP::true } },
        relationships => {
            children => {
                writable => JSON::PP::true, cardinality => 'many', ownership => 'owned',
                allowed_ops => ['insert'], parent_key => 'id', child_key => 'parent_id',
                domain => {
                    name   => 'Form children',
                    source => {
                        source_table => 'selecto_perl_test_form_children', primary_key => 'id',
                        fields => ['id', 'parent_id', 'note'],
                        columns => {
                            id => { type => 'integer' }, parent_id => { type => 'integer' },
                            note => { type => 'string' },
                        },
                    },
                    writes => {
                        fields => { note => { insertable => JSON::PP::true } },
                        relationships => {
                            tags => {
                                writable => JSON::PP::true, cardinality => 'many', ownership => 'owned',
                                allowed_ops => ['insert'], parent_key => 'id', child_key => 'form_child_id',
                                domain => $grandchild_domain,
                            },
                        },
                    },
                },
            },
        },
    },
});
my $form_engine = Selecto::Engine->new(domain => $form_domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
my $form_graph = Selecto::Write::Graph->new(nodes => [
    { id => 'parent', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_graph_parents',
        assignments => { label => 'form-parent' }, metadata => { returning => ['id'] },
    ) },
    { id => 'child', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_form_children',
        assignments => { note => 'nested' },
    ), bindings => [{field => 'parent_id', from => 'parent', key => 'id'}] },
    { id => 'grandchild', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_form_grandchildren',
        assignments => { tag => 'deep' },
    ), bindings => [{field => 'form_child_id', from => 'child', key => 'id'}] },
]);
my $form_result = $form_engine->execute_graph($form_graph);
is($form_result->root->values->{id}, 2, 'forms-contract graph executes through the nested domains');
is($dbh->selectrow_array('SELECT parent_id FROM selecto_perl_test_form_children WHERE note = ?', undef, 'nested'), 2,
    'forms-contract graph binds the generated parent id');
is($dbh->selectrow_array('SELECT form_child_id FROM selecto_perl_test_form_grandchildren WHERE tag = ?', undef, 'deep'),
    $form_result->nodes->{child}->values->{id},
    'grandchild binds its generated child id through the declared edge');

my $skipped = Selecto::Write::Graph->new(nodes => [
    { id => 'parent', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_graph_parents',
        assignments => { label => 'skipped-parent' }, metadata => { returning => ['id'] },
    ) },
    { id => 'child', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_form_children',
        assignments => { note => 'nested' },
    ), bindings => [{field => 'parent_id', from => 'parent', key => 'id'}] },
    { id => 'grandchild', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_perl_test_form_grandchildren',
        assignments => { tag => 'sneaky' },
    ), bindings => [{field => 'form_child_id', from => 'parent', key => 'id'}] },
]);
eval { $form_engine->execute_graph($skipped); 1 };
is($@->code, 'write_relation_mismatch', 'a grandchild bound directly from the root is rejected');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_form_grandchildren');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_form_children');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_graph_children');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_graph_parents');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_events');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_employees');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_items');
$dbh->disconnect;
done_testing;
