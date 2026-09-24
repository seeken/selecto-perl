use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';

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
is_deeply(
    $engine->all($engine->query->select('id')
        ->where(Selecto::Expression->starts_with('name', 'base')))->{rows},
    [[1]], 'PostgreSQL executes a bound prefix predicate',
);
is_deeply(
    $engine->all($engine->query->select('id')
        ->where(Selecto::Expression->starts_with('name', 'base%')))->{rows},
    [], 'PostgreSQL treats a prefix wildcard as literal text',
);
is_deeply(
    $engine->all($engine->query->select('id')
        ->where(Selecto::Expression->starts_with('name', 'base_')))->{rows},
    [], 'PostgreSQL treats a single-character wildcard as literal text',
);

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
my $renamed_lateral_result = $engine->all(
    $engine->query
        ->lateral_join(
            'events', $events_domain, $event_query,
            columns => [qw(item_id event_kind)],
            correlations => {item_id => 'id'},
            type => 'inner',
        )
        ->select('id', 'events.event_kind'),
);
is_deeply($renamed_lateral_result->{rows}, [[1, 'status']],
    'PostgreSQL executes declared lateral output column renames');

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
my $typed_values_domain = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Events with typed inline kinds',
    source => {
        source_table => 'selecto_perl_test_events', primary_key => 'id',
        fields => [qw(id kind)],
        columns => {id => {type => 'integer'}, kind => {type => 'string'}},
        associations => {
            kind_labels => {queryable => 'kind_labels', owner_key => 'kind', related_key => 'kind'},
        },
    },
    schemas => {
        kind_labels => {
            values => [
                {kind => 'status', sort_order => 10, weight => '1.50', opened_on => '2026-01-02'},
                {kind => 'note', sort_order => 2, weight => '0.25', opened_on => '2026-01-03'},
            ],
            primary_key => 'kind', fields => [qw(kind sort_order weight opened_on)],
            columns => {
                kind => {type => 'string'}, sort_order => {type => 'integer'},
                weight => {type => 'decimal'}, opened_on => {type => 'date'},
            },
            associations => {},
        },
    },
    joins => {kind_labels => {type => 'left', name => 'Kind labels'}},
}, strict => 1);
my $typed_values_engine = Selecto::Engine->new(
    domain => $typed_values_domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
);
$dbh->do(q{INSERT INTO selecto_perl_test_events VALUES (2, 1, 'note')});
my $typed_values = $typed_values_engine->all($typed_values_engine->query->select(
    'id', 'kind_labels.sort_order', 'kind_labels.weight', 'kind_labels.opened_on',
)->order_by('kind_labels.sort_order'));
is_deeply($typed_values->{rows}, [[2, 2, '0.25', '2026-01-03'], [1, 10, '1.5', '2026-01-02']],
    'PostgreSQL values cells decode as their declared types and order numerically');
unlike(JSON::PP->new->canonical->encode($typed_values->{rows}), qr/"(?:2|10)"/,
    'integer values cells are returned as numbers, not strings');
my $filtered_values = $typed_values_engine->all($typed_values_engine->query
    ->select('id')->where(Selecto::Expression->gt(
        Selecto::Expression->field('kind_labels.sort_order'), Selecto::Expression->literal(9),
    )));
is_deeply($filtered_values->{rows}, [[1]],
    'PostgreSQL compares integer values cells numerically');

# Governed value expressions execute on PostgreSQL with typed results.
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_value_assets');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_value_sites');
$dbh->do('CREATE TABLE selecto_perl_test_value_sites (id integer primary key, name text not null)');
$dbh->do(q{INSERT INTO selecto_perl_test_value_sites VALUES (1, 'North')});
$dbh->do(q{CREATE TABLE selecto_perl_test_value_assets (
    id integer primary key, site_id integer, location_text text, status text not null,
    rate_cents integer not null, metadata jsonb not null default '{}'::jsonb)});
$dbh->do(q{INSERT INTO selecto_perl_test_value_assets VALUES
    (1, 1, 'Bay 4', 'available', 1850, '{"manufacturer":"Bridgeport"}'),
    (2, NULL, 'Annex closet', 'maintenance', 900, '{}'),
    (3, NULL, NULL, 'missing', 12000, '{"manufacturer":"Epson"}')});
my $value_domain = Selecto::Domain->parse({
    name => 'Value assets',
    source => {
        source_table => 'selecto_perl_test_value_assets', primary_key => 'id',
        fields => [qw(id site_id location_text status rate_cents metadata
            effective_location attention_state rate_dollars manufacturer)],
        columns => {
            id => {type => 'integer'}, site_id => {type => 'integer'},
            location_text => {type => 'string'}, status => {type => 'string'},
            rate_cents => {type => 'integer'}, metadata => {type => 'jsonb'},
            effective_location => {type => 'string', computed => {kind => 'expression', expression =>
                ['coalesce', ['field', 'site.name'], ['field', 'location_text'], ['literal', 'Location unknown']]}},
            attention_state => {type => 'string', computed => {kind => 'expression', expression =>
                ['case', [['in', 'status', ['maintenance', 'missing']], ['literal', 'Needs attention']],
                    ['else', ['literal', 'Ready']]]}},
            rate_dollars => {type => 'decimal', computed => {kind => 'expression', expression =>
                ['divide', ['field', 'rate_cents'], ['literal', 100]]}},
            manufacturer => {type => 'string', computed => {kind => 'expression', expression =>
                ['json_text', 'metadata', ['manufacturer']]}},
        },
        associations => {site => {queryable => 'site', owner_key => 'site_id', related_key => 'id'}},
    },
    schemas => {site => {
        source_table => 'selecto_perl_test_value_sites', primary_key => 'id', fields => [qw(id name)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {},
    }},
    joins => {site => {type => 'left'}},
});
my $value_engine = Selecto::Engine->new(
    domain => $value_domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
);
my $value_rows = $value_engine->all($value_engine->query
    ->select(qw(id effective_location attention_state rate_dollars manufacturer))->order_by('id'));
is_deeply($value_rows, {
    columns => [qw(id effective_location attention_state rate_dollars manufacturer)],
    rows => [
        [1, 'North', 'Ready', '18.5', 'Bridgeport'],
        [2, 'Annex closet', 'Needs attention', '9', undef],
        [3, 'Location unknown', 'Needs attention', '120', 'Epson'],
    ],
}, 'PostgreSQL executes coalesce, case, decimal division, and JSON text value expressions');
is_deeply($value_engine->all($value_engine->query
    ->select('attention_state', Selecto::Expression->count->as('assets'))
    ->group_by('attention_state')->order_by('attention_state'))->{rows},
    [['Needs attention', 2], ['Ready', 1]],
    'PostgreSQL groups and orders by a computed value field');
is_deeply($value_engine->all($value_engine->query->select('id')
    ->where(Selecto::Expression->gte('rate_dollars', '100'))->order_by('id'))->{rows},
    [[3]], 'PostgreSQL filters numerically by a computed decimal');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_value_assets');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_value_sites');

# Tenant-scoped graph: the engine's trusted tenant reaches every node.
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_scope_steps');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_scope_orders');
$dbh->do('CREATE TABLE selecto_perl_test_scope_orders (id serial primary key, site_id integer not null, title text not null)');
$dbh->do('CREATE TABLE selecto_perl_test_scope_steps (id serial primary key, site_id integer not null,
    order_id integer not null references selecto_perl_test_scope_orders(id), instruction text not null)');
my $scoped_contract = sub {
    my ($table, $fields, $writable, %extra) = @_;
    return {
        schema_version => 1, name => $table,
        source => {source_table => $table, primary_key => 'id', fields => $fields,
            columns => {map { ($_ => {type => /id\z/ ? 'integer' : 'string'}) } @$fields},
            associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}},
            fields => {map { ($_ => {insertable => 1}) } @$writable},
            scope => {tenant => {field => 'site_id'}}, %extra},
    };
};
my $scoped_orders = Selecto::Domain->parse($scoped_contract->(
    'selecto_perl_test_scope_orders', [qw(id site_id title)], ['title'],
    relationships => {steps => {writable => 1, table => 'selecto_perl_test_scope_steps',
        parent_key => 'id', child_key => 'order_id', allowed_ops => ['insert'],
        domain => $scoped_contract->('selecto_perl_test_scope_steps',
            [qw(id site_id order_id instruction)], ['instruction'])}},
));
my $scoped_engine = Selecto::Engine->new(domain => $scoped_orders,
    adapter => Selecto->adapter(postgresql => (dbh => $dbh)), scope => {tenant => 7});
my $scoped_result = $scoped_engine->execute_graph(Selecto::Write::Graph->new(nodes => [
    {id => 'order', command => Selecto::Write::Command->new(operation => 'insert',
        relation => 'selecto_perl_test_scope_orders', assignments => {title => 'Pump'},
        metadata => {returning => ['site_id']})},
    {id => 'step', command => Selecto::Write::Command->new(operation => 'insert',
        relation => 'selecto_perl_test_scope_steps', assignments => {instruction => 'Isolate'},
        metadata => {returning => ['site_id']}),
        bindings => [{field => 'order_id', from => 'order', key => 'id'}]},
]));
is_deeply([map { $scoped_result->nodes->{$_}->values->{site_id} } qw(order step)], [7, 7],
    'PostgreSQL graph nodes are assigned the trusted tenant');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_scope_steps');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_scope_orders');

$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_form_grandchildren');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_form_children');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_graph_children');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_graph_parents');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_events');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_employees');
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_items');
$dbh->disconnect;
done_testing;
