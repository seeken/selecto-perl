use 5.034;
use strict;
use warnings;

use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

sub exception (&) {
    my ($operation) = @_;
    my $ok = eval { $operation->(); 1 };
    return undef if $ok;
    return $@;
}

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do(q{CREATE TABLE items (id integer primary key, tenant_id integer not null, status text, total decimal not null)});
$dbh->do(q{CREATE TABLE item_notes (id integer primary key, item_id integer not null, note text)});
$dbh->do(q{INSERT INTO items VALUES (1, 7, 'active', 10.5)});

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'items',
    fields => { id => 'integer', tenant_id => 'integer', status => 'string', total => 'decimal' },
    tenant_field => 'tenant_id',
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));

# Direct constructor cannot smuggle hostile order directions or pagination values.
for my $direction ('desc; drop table items', 'DESCENDING', '') {
    my $error = exception {
        Selecto::Query->new(orders => [[Selecto::Expression->field('id'), $direction]]);
    };
    isa_ok($error, 'Selecto::Error');
    is($error->code, 'invalid_query', "constructor rejects order direction '$direction'");
}
for my $key (qw(limit_value offset_value)) {
    my $error = exception { Selecto::Query->new($key => '10; drop table items') };
    isa_ok($error, 'Selecto::Error');
    is($error->code, 'invalid_query', "constructor rejects non-numeric $key");
}

# Writes are bound to the domain by default.
my $error = exception { $engine->execute_write(Selecto::Write::Command->new(
    operation => 'update', relation => 'item_notes', assignments => { note => 'x' },
)) };
is($error->code, 'write_relation_mismatch', 'ungoverned cross-table write is rejected');

$error = exception { $engine->execute_write(Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { undeclared => 'x' },
)) };
is($error->code, 'unknown_field', 'write of an undeclared column is rejected');

$error = exception { $engine->execute_batch(Selecto::Write::Batch->new(
    Selecto::Write::Command->new(operation => 'insert', relation => 'other_table', assignments => { id => 1 }),
)) };
is($error->code, 'write_relation_mismatch', 'batch commands are validated too');

my $ok = eval {
    $engine->execute_write(Selecto::Write::Command->new(
        operation => 'update', relation => 'items',
        assignments => { status => 'approved' }, predicate => Selecto::Expression->eq('id', 1),
    ));
    1;
};
ok($ok, 'governed write against declared fields still succeeds');

# Contract-declared writes enforce per-field permissions and enabled operations.
my $contract_domain = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'ContractItems',
    source         => {
        source_table => 'items',
        primary_key  => 'id',
        tenant_field => 'tenant_id',
        fields       => ['id', 'tenant_id', 'status', 'total'],
        columns      => {
            id        => { type => 'integer' },
            tenant_id => { type => 'integer' },
            status    => { type => 'string' },
            total     => { type => 'decimal' },
        },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { update => { enabled => JSON::PP::true } },
        fields     => { status  => { updatable => JSON::PP::true } },
    },
});
is($contract_domain->tenant_field, 'tenant_id', 'canonical parse forwards the tenant field');
my $contract_engine = Selecto::Engine->new(domain => $contract_domain, adapter => $engine->adapter);

$error = exception { $contract_engine->execute_write(Selecto::Write::Command->new(
    operation => 'insert', relation => 'items', assignments => { status => 'x' },
)) };
is($error->code, 'write_operation_not_enabled', 'insert is rejected when not enabled');

$error = exception { $contract_engine->execute_write(Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { total => 1 },
    predicate => Selecto::Expression->eq('id', 1),
)) };
is($error->code, 'write_field_not_writable', 'undeclared writable field is rejected');

# Tenant scope must be a positive conjunct; negations and OR branches fail closed.
my $guarded_scope = sub {
    my ($scope) = @_;
    my $query = $engine->query->where(Selecto::Expression->eq('status', 'active'));
    return $engine->enforce_query_evidence(Selecto::Write::Command->new(
        operation => 'update', relation => 'items',
        assignments => { status => 'approved' },
        scope_predicate => $scope,
    ), Selecto::QueryEnforcement->capture($domain, $query));
};

my $x = 'Selecto::Expression';
$error = exception { $guarded_scope->($x->not($x->eq('tenant_id', 7))) };
is($error->code, 'missing_tenant_scope', 'negated tenant scope fails closed');

$error = exception { $guarded_scope->($x->any($x->eq('tenant_id', 7), $x->eq('status', 'active'))) };
is($error->code, 'missing_tenant_scope', 'OR-branched tenant scope fails closed');

$error = exception { $guarded_scope->($x->all($x->ne('status', 'blocked'), $x->eq('tenant_id', 7))) };
ok(!defined($error), 'positive AND-conjunct tenant scope is accepted')
    or diag("unexpected error: " . ($error // ''));

$error = exception { $guarded_scope->($x->in('tenant_id', 7, 8)) };
ok(!defined($error), 'literal in-list over the tenant field is accepted')
    or diag("unexpected error: " . ($error // ''));

# Deletes honor the operations switches: a contract enabling only update
# cannot delete.
my $update_only = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'UpdateOnly',
    source         => {
        source_table => 'items',
        primary_key  => 'id',
        fields       => ['id', 'status'],
        columns      => { id => { type => 'integer' }, status => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { update => { enabled => JSON::PP::true } },
        fields     => { status  => { updatable => JSON::PP::true } },
    },
});
my $update_only_engine = Selecto::Engine->new(domain => $update_only, adapter => $engine->adapter);
$error = exception { $update_only_engine->execute_write(Selecto::Write::Command->new(
    operation => 'delete', relation => 'items', predicate => Selecto::Expression->eq('id', 1),
)) };
is($error->code, 'write_operation_not_enabled', 'delete is rejected when not enabled by the contract');

# Upserts cannot smuggle non-updatable fields through upsert_update_fields,
# and metadata field references must be declared.
my $contract_engine_full = Selecto::Engine->new(domain => Selecto::Domain->parse({
    schema_version => 1,
    name           => 'UpsertItems',
    source         => {
        source_table => 'items',
        primary_key  => 'id',
        tenant_field => 'tenant_id',
        fields       => ['id', 'tenant_id', 'status', 'total'],
        columns      => {
            id        => { type => 'integer' },
            tenant_id => { type => 'integer' },
            status    => { type => 'string' },
            total     => { type => 'decimal' },
        },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => {
            insert => { enabled => JSON::PP::true },
            update => { enabled => JSON::PP::true },
            upsert => { enabled => JSON::PP::true },
        },
        fields     => {
            id     => { insertable => JSON::PP::true },
            status => { insertable => JSON::PP::true, updatable => JSON::PP::false },
            total  => { insertable => JSON::PP::true, updatable => JSON::PP::true },
        },
    },
}), adapter => $engine->adapter);

my $upsert = sub {
    my (%metadata) = @_;
    return $contract_engine_full->execute_write(Selecto::Write::Command->new(
        operation => 'upsert', relation => 'items',
        assignments => { id => 9, status => 'x', total => 1 },
        metadata => { conflict_target => ['id'], %metadata },
    ));
};
$error = exception { $upsert->(upsert_update_fields => ['status']) };
is($error->code, 'write_field_not_writable', 'upsert cannot update a field declared updatable false');
$error = exception { $upsert->(upsert_update_fields => ['undeclared_col']) };
is($error->code, 'unknown_field', 'upsert update fields must be declared');
$error = exception { $upsert->(upsert_update_fields => [], conflict_target => ['nope']) };
is($error->code, 'unknown_field', 'conflict target fields must be declared');
$error = exception { $contract_engine_full->execute_write(Selecto::Write::Command->new(
    operation => 'insert', relation => 'items', assignments => { id => 10 },
    metadata => { returning => ['not_a_field'] },
)) };
is($error->code, 'unknown_field', 'returning fields must be declared');

# Nested form contracts resolve through relationship.domain.source and deeper.
$dbh->do('DELETE FROM item_notes');
$dbh->do(q{CREATE TABLE IF NOT EXISTS item_note_tags (id integer primary key, item_note_id integer not null, tag text)});
$dbh->do('DELETE FROM item_note_tags');
my $form_domain = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'FormItems',
    source         => {
        source_table => 'items',
        primary_key  => 'id',
        fields       => ['id', 'status'],
        columns      => { id => { type => 'integer' }, status => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { insert => { enabled => JSON::PP::true } },
        fields     => { status => { insertable => JSON::PP::true } },
        relationships => {
            notes => {
                writable => JSON::PP::true, ownership => 'owned', cardinality => 'many',
                allowed_ops => ['insert'], parent_key => 'id', child_key => 'item_id',
                domain => {
                    name   => 'Item notes',
                    source => {
                        source_table => 'item_notes', primary_key => 'id',
                        fields       => ['id', 'item_id', 'note'],
                        columns      => {
                            id => { type => 'integer' }, item_id => { type => 'integer' },
                            note => { type => 'string' },
                        },
                    },
                    writes => {
                        fields => { note => { insertable => JSON::PP::true } },
                        relationships => {
                            tags => {
                                writable => JSON::PP::true, ownership => 'owned', cardinality => 'many',
                                allowed_ops => ['insert'], parent_key => 'id', child_key => 'item_note_id',
                                domain => {
                                    name   => 'Item note tags',
                                    source => {
                                        source_table => 'item_note_tags', primary_key => 'id',
                                        fields       => ['id', 'item_note_id', 'tag'],
                                        columns      => {
                                            id           => { type => 'integer' },
                                            item_note_id => { type => 'integer' },
                                            tag          => { type => 'string' },
                                        },
                                    },
                                    writes => {
                                        fields => { tag => { insertable => JSON::PP::true } },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
});
my $form_engine = Selecto::Engine->new(domain => $form_domain, adapter => $engine->adapter);
my $form_graph = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hello' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
]);
my $capability_error = exception { $form_engine->execute_graph($form_graph) };
# SQLite cannot execute write graphs; reaching the capability error proves
# every forms-contract governance check passed.
is($capability_error->code, 'write_capability_missing', 'forms-contract nested graphs pass governance');

# A genuine root -> child -> grandchild graph passes every level of the
# nested contract tree.
my $deep_graph = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
    { id => 'tag', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_note_tags', assignments => { tag => 'keep' },
    ), bindings => [{field => 'item_note_id', from => 'note', key => 'id'}] },
]);
my $deep_error;
{
    local $SIG{__WARN__} = sub { die "warning escaped governance: @_" };
    $deep_error = exception { $form_engine->execute_graph($deep_graph) };
}
is($deep_error->code, 'write_capability_missing', 'root-to-child-to-grandchild graphs pass governance');
like("$deep_error", qr/write_capability_missing|adapter does not support/, 'no uninitialized-value warnings at depth');

# The grandchild cannot skip its parent and bind straight from the root.
my $skipped_grandchild = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
    { id => 'tag', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_note_tags', assignments => { tag => 'keep' },
    ), bindings => [{field => 'item_note_id', from => 'root', key => 'id'}] },
]);
$error = exception { $form_engine->execute_graph($skipped_grandchild) };
is($error->code, 'write_relation_mismatch',
    'grandchildren must bind through their declared parent node');

my $hostile_graph = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { undeclared => 'x' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
]);
$error = exception { $form_engine->execute_graph($hostile_graph) };
is($error->code, 'unknown_field', 'child assignments are checked against the nested contract');

my $bad_binding = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'smuggled_id', from => 'root', key => 'id'}] },
]);
$error = exception { $form_engine->execute_graph($bad_binding) };
is($error->code, 'write_relation_mismatch',
    'bindings must match the declared relationship child_key');

# A grandchild cannot bind directly from the root, skipping its parent edge.
my $skipped_edge = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
    { id => 'deep', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'sneaky' },
    ), bindings => [{field => 'status', from => 'note', key => 'id'}] },
]);
$error = exception { $form_engine->execute_graph($skipped_edge) };
is($error->code, 'write_relation_mismatch', 'edges must be declared on the referenced parent node');

# Binding the generated parent id into a non-key field is rejected.
my $wrong_field = Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'note', from => 'root', key => 'id'}] },
]);
$error = exception { $form_engine->execute_graph($wrong_field) };
is($error->code, 'write_relation_mismatch', 'the parent key must land in the declared child_key field');

# Deletes validate returning metadata too.
$error = exception { $engine->execute_write(Selecto::Write::Command->new(
    operation => 'delete', relation => 'items', predicate => Selecto::Expression->eq('id', 1),
    metadata => { returning => ['secret'] },
)) };
is($error->code, 'unknown_field', 'delete returning fields must be declared');

# Malformed metadata produces typed errors, not raw Perl failures.
$error = exception { $engine->execute_write(Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { status => 'x' },
    predicate => Selecto::Expression->eq('id', 1),
    metadata => { returning => 'status' },
)) };
is($error->code, 'invalid_write', 'non-array returning fails with a typed error');
$error = exception { $upsert->(upsert_update_fields => 'status') };
is($error->code, 'invalid_write', 'non-array upsert update fields fail with a typed error');
$error = exception { $upsert->(upsert_update_fields => ['total'], conflict_target => 'id') };
is($error->code, 'invalid_write', 'non-array conflict target fails with a typed error');

# Present-but-malformed write contract sections fail closed.
for my $malformed (
    { operations => [], fields => { status => { updatable => JSON::PP::true } } },
    { operations => { update => { enabled => JSON::PP::true } }, fields => [] },
) {
    my $broken = Selecto::Domain->parse({
        schema_version => 1,
        name           => 'Broken',
        source         => {
            source_table => 'items',
            primary_key  => 'id',
            fields       => ['id', 'status'],
            columns      => { id => { type => 'integer' }, status => { type => 'string' } },
            associations => {},
        },
        schemas => {}, joins => {},
        writes => $malformed,
    });
    my $broken_engine = Selecto::Engine->new(domain => $broken, adapter => $engine->adapter);
    $error = exception { $broken_engine->execute_write(Selecto::Write::Command->new(
        operation => 'update', relation => 'items', assignments => { status => 'x' },
        predicate => Selecto::Expression->eq('id', 1),
    )) };
    is($error->code, 'invalid_domain', 'malformed write sections are rejected as invalid domains');
}

# Malformed allowed_ops fails closed as an invalid domain.
my $bad_ops_domain = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'BadOps',
    source         => {
        source_table => 'items', primary_key => 'id',
        fields => ['id', 'status'],
        columns => { id => { type => 'integer' }, status => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { insert => { enabled => JSON::PP::true } },
        fields     => { status  => { insertable => JSON::PP::true } },
        relationships => {
            notes => {
                writable => JSON::PP::true, ownership => 'owned',
                allowed_ops => 'insert', parent_key => 'id', child_key => 'item_id',
                domain => $form_domain->writes->{relationships}{notes}{domain},
            },
        },
    },
});
my $bad_ops_engine = Selecto::Engine->new(domain => $bad_ops_domain, adapter => $engine->adapter);
$error = exception { $bad_ops_engine->execute_graph(Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
])) };
is($error->code, 'invalid_domain', 'scalar allowed_ops is rejected as an invalid domain');

# Duplicate declarations of one physical edge with different nested
# permissions are rejected instead of being chosen by relationship name.
my $duplicate_edge_domain = Selecto::Domain->parse({
    schema_version => 1,
    name           => 'DuplicateEdge',
    source         => {
        source_table => 'items', primary_key => 'id',
        fields => ['id', 'status'],
        columns => { id => { type => 'integer' }, status => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { insert => { enabled => JSON::PP::true } },
        fields     => { status  => { insertable => JSON::PP::true } },
        relationships => {
            a_notes => {
                writable => JSON::PP::true, ownership => 'owned',
                allowed_ops => ['insert'], parent_key => 'id', child_key => 'item_id',
                domain => $form_domain->writes->{relationships}{notes}{domain},
            },
            b_notes => {
                writable => JSON::PP::true, ownership => 'owned',
                allowed_ops => ['insert'], parent_key => 'id', child_key => 'item_id',
                domain => {
                    name   => 'Restrictive notes',
                    source => {
                        source_table => 'item_notes', primary_key => 'id',
                        fields       => ['id', 'item_id', 'note'],
                        columns      => {
                            id => { type => 'integer' }, item_id => { type => 'integer' },
                            note => { type => 'string' },
                        },
                    },
                    writes => { fields => {} },
                },
            },
        },
    },
});
my $duplicate_engine = Selecto::Engine->new(domain => $duplicate_edge_domain, adapter => $engine->adapter);
$error = exception { $duplicate_engine->execute_graph(Selecto::Write::Graph->new(nodes => [
    { id => 'root', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => { status => 'open' },
        metadata => { returning => ['id'] },
    ) },
    { id => 'note', command => Selecto::Write::Command->new(
        operation => 'insert', relation => 'item_notes', assignments => { note => 'hi' },
    ), bindings => [{field => 'item_id', from => 'root', key => 'id'}] },
])) };
is($error->code, 'invalid_domain', 'conflicting duplicate physical edges fail closed regardless of naming');

done_testing;
