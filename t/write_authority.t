use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

sub error_of {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return undef if $ok;
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error : die $error;
}

sub code_of { my $error = error_of(@_); return $error ? $error->code : 'ok'; }

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do('CREATE TABLE work_orders (id integer primary key, site_id integer not null,
    work_order_no text not null, title text not null, state text not null,
    UNIQUE (site_id, work_order_no))');
$dbh->do('CREATE TABLE work_order_steps (id integer primary key, site_id integer,
    work_order_id integer not null, position integer not null, instruction text not null)');
$dbh->do(q{INSERT INTO work_orders VALUES
    (1, 10, 'WO-1', 'Pump seal', 'done'),
    (2, 20, 'WO-1', 'Other site pump', 'done'),
    (3, 10, 'WO-2', 'Belt', 'open')});

sub step_contract {
    my (%options) = @_;
    return {
        schema_version => 1,
        name => 'Steps',
        source => {
            source_table => 'work_order_steps', primary_key => 'id',
            fields => [qw(id site_id work_order_id position instruction)],
            columns => {
                id => {type => 'integer'}, site_id => {type => 'integer'},
                work_order_id => {type => 'integer'}, position => {type => 'integer'},
                instruction => {type => 'string'},
            },
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => {insert => {enabled => 1}},
            fields => {position => {insertable => 1}, instruction => {insertable => 1}},
            ($options{unscoped} ? () : (scope => {tenant => {field => 'site_id'}})),
        },
    };
}

sub work_order_contract {
    my (%options) = @_;
    return {
        schema_version => 1,
        name => 'Work Orders',
        source => {
            source_table => 'work_orders', primary_key => 'id',
            fields => [qw(id site_id work_order_no title state title_code)],
            columns => {
                id => {type => 'integer'}, site_id => {type => 'integer'},
                work_order_no => {type => 'string'}, title => {type => 'string'},
                state => {type => 'string'},
                title_code => {type => 'string',
                    computed => {kind => 'expression', expression => ['upper', ['field', 'title']]}},
            },
            tenant_field => 'site_id',
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => {
                insert => {enabled => 1},
                update => {enabled => 1, bulk => 1},
                delete => {enabled => 1},
                upsert => {enabled => 1, conflict_targets => [[qw(site_id work_order_no)]]},
            },
            fields => {
                work_order_no => {insertable => 1, required => 1},
                title => {insertable => 1, updatable => 1, required => 1},
                state => {insertable => 1, updatable => 1},
            },
            transitions => {state => {done => ['archived']}},
            scope => {tenant => {required => JSON::PP::true, field => 'site_id',
                satisfied_by => ['trusted_context']}},
            relationships => {
                steps => {
                    writable => 1, table => 'work_order_steps',
                    parent_key => 'id', child_key => 'work_order_id',
                    allowed_ops => ['insert'],
                    domain => step_contract(%options),
                },
            },
        },
        actions => {
            open_order => {
                type => 'create', label => 'Open order',
                execution => {kind => 'updato', operation => 'insert',
                    set => {work_order_no => 'WO-NEW', title => 'Opened by action', state => 'open'}},
            },
            sync_order => {
                type => 'create', label => 'Sync order',
                execution => {kind => 'updato', operation => 'upsert',
                    set => {work_order_no => 'WO-2', title => 'Synced by action', state => 'open'}},
            },
            archive => {
                type => 'transition', scope => 'row', capability => 'work_orders.archive',
                transition => {field => 'state', from => 'done', to => 'archived'},
                execution => {kind => 'updato', operation => 'update', set => {state => 'archived'}},
            },
        },
        capabilities => {
            'work_orders.archive' => {operations => ['action', 'update'], action => 'archive'},
        },
    };
}

my $domain = Selecto::Domain->parse(work_order_contract());
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $site10 = $unscoped->with_scope(tenant => 10);

sub title_of { return $dbh->selectrow_array('SELECT title FROM work_orders WHERE id = ?', undef, $_[0]); }

sub update {
    my (%args) = @_;
    return Selecto::Write::Command->new(
        operation => 'update', relation => 'work_orders',
        assignments => $args{assignments} // {title => 'changed'},
        predicate => $args{predicate} // Selecto::Expression->eq('id', $args{id} // 1),
        expected_count => $args{expected_count} // 1,
    );
}

# --- the contract ------------------------------------------------------------

is_deeply($domain->write_tenant_scope, {field => 'site_id', satisfied_by => ['trusted_context']},
    'writes.scope.tenant parses into an enforced scope');
my %bad_scope = (
    'unknown key' => {tenant => {field => 'site_id', mode => 'x'}},
    'required false' => {tenant => {field => 'site_id', required => JSON::PP::false}},
    'unknown field' => {tenant => {field => 'tenant_id'}},
    'unknown source' => {tenant => {field => 'site_id', satisfied_by => ['header']}},
);
for my $label (sort keys %bad_scope) {
    my $contract = work_order_contract();
    $contract->{writes}{scope} = $bad_scope{$label};
    is(code_of(sub { Selecto::Domain->parse($contract) }), 'invalid_domain',
        "writes.scope.tenant rejects $label");
}
{
    my $contract = work_order_contract();
    $contract->{writes}{scope} = {tenant => {}};
    is(Selecto::Domain->parse($contract)->write_tenant_scope->{field}, 'site_id',
        'the scope field defaults to source.tenant_field');
}

# --- updates and deletes -------------------------------------------------------

is(code_of(sub { $unscoped->execute_write(update()) }), 'missing_tenant_scope',
    'an update without trusted scope is rejected');
is(code_of(sub { $unscoped->preview_write(update()) }), 'missing_tenant_scope',
    'preview enforces the same scope as execution');
is(title_of(1), 'Pump seal', 'the rejected update did not run');

my $preview = $site10->preview_write(update());
like($preview->{sql}, qr/"site_id" = \?/, 'the trusted tenant is compiled into the WHERE clause');
is_deeply($preview->{params}, ['changed', 1, 10], 'the trusted tenant is a bound parameter');

is(code_of(sub { $site10->execute_write(update(id => 2)) }), 'cardinality_mismatch',
    "another tenant's row is invisible to a scoped update");
is(title_of(2), 'Other site pump', "the other tenant's row is unchanged");

is(code_of(sub { $site10->execute_write(update(
    predicate => Selecto::Expression->all(
        Selecto::Expression->eq('id', 2), Selecto::Expression->eq('site_id', 20),
    ),
)) }), 'tenant_mismatch', 'a caller predicate naming another tenant is rejected');
is(code_of(sub { $site10->execute_write(update(
    predicate => Selecto::Expression->any(
        Selecto::Expression->eq('id', 1), Selecto::Expression->ne('site_id', 10),
    ),
)) }), 'tenant_mismatch', 'the tenant field may only be compared for equality with the trusted tenant');
is(code_of(sub { $site10->execute_write(update(
    predicate => Selecto::Expression->all(
        Selecto::Expression->eq('id', 1), Selecto::Expression->eq('site_id', 10),
    ),
)) }), 'ok', 'a caller may restate the trusted tenant');
is(title_of(1), 'changed', 'the scoped update ran');

is(code_of(sub { $site10->execute_write(update(assignments => {site_id => 20})) }),
    'tenant_mismatch', 'an update cannot move a row to another tenant');
is(code_of(sub { $site10->execute_write(update(predicate => Selecto::Expression->eq('owner', 1))) }),
    'unknown_field', 'predicates resolve fields through the governing domain');
is(code_of(sub { $site10->execute_write(update(predicate => Selecto::Expression->eq('title_code', 'X'))) }),
    'unknown_field', 'computed fields have no storage to filter on');

is(code_of(sub { $site10->execute_write(Selecto::Write::Command->new(
    operation => 'delete', relation => 'work_orders',
    predicate => Selecto::Expression->eq('id', 2),
)) }), 'cardinality_mismatch', "a scoped delete cannot reach another tenant's row");

# --- inserts and upserts -----------------------------------------------------------

sub insert {
    my (%assignments) = @_;
    return Selecto::Write::Command->new(
        operation => 'insert', relation => 'work_orders',
        assignments => {work_order_no => 'WO-9', title => 'New', state => 'open', %assignments},
    );
}

is(code_of(sub { $unscoped->execute_write(insert()) }), 'missing_tenant_scope',
    'an insert without trusted scope is rejected');
is(code_of(sub { $site10->execute_write(insert(site_id => 20)) }), 'tenant_mismatch',
    'an insert naming another tenant is rejected');
$site10->execute_write(insert());
is($dbh->selectrow_array(q{SELECT site_id FROM work_orders WHERE work_order_no = 'WO-9'}), 10,
    'an insert is assigned the trusted tenant');

my $upsert = Selecto::Write::Command->new(
    operation => 'upsert', relation => 'work_orders',
    assignments => {work_order_no => 'WO-1', title => 'Upserted', state => 'done'},
    metadata => {conflict_target => ['work_order_no'], upsert_update_fields => ['title']},
);
is(code_of(sub { $site10->execute_write($upsert) }), 'tenant_scope_conflict_target',
    'a scoped upsert must resolve conflicts within the tenant');

# --- batches -------------------------------------------------------------------------

is(code_of(sub { $site10->execute_batch(Selecto::Write::Batch->new(
    update(assignments => {title => 'batched'}),
    insert(site_id => 20),
)) }), 'tenant_mismatch', 'one out-of-scope batch command rejects the batch');
is(title_of(1), 'changed', 'no batch command ran');

# --- graphs ----------------------------------------------------------------------------

sub graph {
    return Selecto::Write::Graph->new(nodes => [
        {id => 'order', command => insert(work_order_no => 'WO-G')},
        {
            id => 'step',
            command => Selecto::Write::Command->new(
                operation => 'insert', relation => 'work_order_steps',
                assignments => {position => 1, instruction => 'Isolate', @_},
            ),
            bindings => [{field => 'work_order_id', from => 'order', key => 'id'}],
        },
    ]);
}

is(code_of(sub { $site10->execute_graph(graph(site_id => 20)) }), 'tenant_mismatch',
    'a nested node naming another tenant is rejected');
SKIP: {
    skip 'SQLite graphs need RETURNING (3.35+)', 1 unless $adapter->write_capabilities->{write_graph};
    $site10->execute_graph(graph());
    is_deeply(
        $dbh->selectall_arrayref(q{SELECT s.site_id, o.site_id FROM work_order_steps s
            JOIN work_orders o ON o.id = s.work_order_id WHERE o.work_order_no = 'WO-G'}),
        [[10, 10]],
        'every graph node is assigned the trusted tenant',
    );
}
is(code_of(sub { $unscoped->execute_graph(graph()) }), 'missing_tenant_scope',
    'a graph without trusted scope is rejected');
my $leaky = Selecto::Engine->new(
    domain => Selecto::Domain->parse(work_order_contract(unscoped => 1)),
    adapter => $adapter, scope => {tenant => 10},
);
is(code_of(sub { $leaky->execute_graph(graph()) }), 'missing_tenant_scope',
    'a nested domain that stores the tenant field must declare its scope');

# --- engine scope --------------------------------------------------------------------

is(code_of(sub { $site10->with_scope(tenant => 20) }), 'tenant_mismatch',
    'a scoped engine cannot be re-scoped to another tenant');
is(code_of(sub { Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => []}) }),
    'invalid_tenant_scope', 'trusted tenant values are scalars');

# --- actions ---------------------------------------------------------------------------

my @requests;
my $resolver = sub { my ($request) = @_; push @requests, $request; return 'enabled' };
my $plan = $site10->plan_action({action => 'archive', target => 1});
my $command = $site10->action_command($plan);
is_deeply($command->assignments, {state => 'archived'}, 'the plan changes become assignments');
is($command->expected_count, 1, 'the planned cardinality becomes the expected count');

is(code_of(sub { $site10->preview_action($plan) }), 'missing_capability_resolver',
    'a declared capability requires a host resolver');
my $action_preview = $site10->preview_action($plan, resolver => $resolver);
is($action_preview->{decision}{status}, 'enabled', 'preview carries the capability decision');
like($action_preview->{statement}{sql}, qr/"state" = \?.*"site_id" = \?/s,
    'the preview statement carries the transition guard and tenant scope');
is($dbh->selectrow_array('SELECT state FROM work_orders WHERE id = 1'), 'done', 'preview writes nothing');

my $executed = $site10->execute_action($plan, resolver => $resolver);
is($executed->{result}->affected_rows, 1, 'execute applies the planned write');
is($dbh->selectrow_array('SELECT state FROM work_orders WHERE id = 1'), 'archived', 'the transition ran');
is_deeply([map { $_->{phase} } @requests], ['preview', 'execute'], 'each phase is authorized');
is_deeply(
    {%{$requests[0]}, phase => 'x'}, {%{$requests[1]}, phase => 'x'},
    'preview and execute ask for the same capability decision',
);

is(code_of(sub { $site10->execute_action($plan, resolver => $resolver) }), 'cardinality_mismatch',
    'the transition source state is enforced at execution');
my $other = $site10->plan_action({action => 'archive', target => 2});
is(code_of(sub { $site10->execute_action($other, resolver => $resolver) }), 'cardinality_mismatch',
    "an action cannot reach another tenant's row");
is(code_of(sub { $unscoped->execute_action($other, resolver => $resolver) }), 'missing_tenant_scope',
    'actions on a tenant-scoped domain require trusted scope');
is(code_of(sub { $site10->execute_action($other, resolver => sub { 'disabled' }) }),
    'action_capability_denied', 'a denied capability stops execution before any write');

# --- write policy ----------------------------------------------------------------------

{
    my $legacy = Selecto::Domain->new(
        name => 'Legacy', table => 'work_orders',
        fields => {id => 'integer', title => 'string', site_id => 'integer'},
    );
    my $strict = Selecto::Engine->new(domain => $legacy, adapter => $adapter);
    is($strict->write_policy, 'strict', 'engines are strict by default');
    is(code_of(sub { $strict->preview_write(update(assignments => {title => 'x'})) }), 'write_policy_missing',
        'a domain without a write policy is denied');
    my $permissive = Selecto::Engine->new(domain => $legacy, adapter => $adapter, write_policy => 'permissive');
    is(code_of(sub { $permissive->preview_write(update(assignments => {title => 'x'})) }), 'ok',
        'permissive must be chosen explicitly');
    is(code_of(sub { Selecto::Engine->new(domain => $legacy, adapter => $adapter, write_policy => 'lax') }),
        'invalid_write_policy', 'only strict and permissive exist');

    my $no_fields = work_order_contract();
    delete $no_fields->{writes}{fields};
    my $partial = Selecto::Engine->new(domain => Selecto::Domain->parse($no_fields), adapter => $adapter,
        scope => {tenant => 10});
    is(code_of(sub { $partial->preview_write(update(assignments => {title => 'x'})) }), 'write_policy_missing',
        'strict engines also require writes.fields for anything but deletes');
    is(code_of(sub { $partial->preview_write(Selecto::Write::Command->new(
        operation => 'delete', relation => 'work_orders', predicate => Selecto::Expression->eq('id', 3),
    )) }), 'ok', 'a declared delete needs no field grants');
}

# --- the adapter boundary ---------------------------------------------------------------

my $raw = update(id => 3, assignments => {title => 'bypass'});
is(code_of(sub { $adapter->execute_write($raw) }), 'ungoverned_write',
    'an adapter refuses a raw command');
is(code_of(sub { $adapter->execute_write($raw, bless(\(my $x = 1), 'Selecto::Write::Authorization')) }),
    'ungoverned_write', 'a forged authorization authorizes nothing');
is(code_of(sub { Selecto::Write::Authorization->_issue($raw) }), 'ungoverned_write',
    'only the engine issues authorizations');
is(code_of(sub { $adapter->execute_batch(Selecto::Write::Batch->new($raw)) }), 'ungoverned_write',
    'an adapter refuses a raw batch');
is(code_of(sub { $adapter->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'r', command => $raw}])) }),
    'ungoverned_write', 'an adapter refuses a raw graph');
is(title_of(3), 'Belt', 'no bypass attempt wrote anything');

# --- insert and upsert actions --------------------------------------------------------

my $open = $site10->plan_action({action => 'open_order'});
is($open->scope, 'create', 'an insert action plans a create');
my $opened = $site10->execute_action($open);
is($opened->{result}->affected_rows, 1, 'an insert action writes one row');
is($dbh->selectrow_array(q{SELECT site_id FROM work_orders WHERE work_order_no = 'WO-NEW'}), 10,
    'an insert action is assigned the trusted tenant');
is(code_of(sub { $site10->plan_action({action => 'open_order', target => 1}) }), 'action_scope_mismatch',
    'insert actions take no target');
is(code_of(sub { $unscoped->execute_action($open) }), 'missing_tenant_scope',
    'insert actions on a scoped domain require trusted scope');

my $sync_command = $site10->action_command($site10->plan_action({action => 'sync_order'}));
is_deeply($sync_command->metadata->{conflict_target}, [qw(site_id work_order_no)],
    'an upsert action resolves conflicts on the declared target');
is_deeply($sync_command->metadata->{upsert_update_fields}, [qw(state title)],
    'an upsert action updates only updatable changes, never conflict keys');
$site10->execute_action($site10->plan_action({action => 'sync_order'}));
is($dbh->selectrow_array(q{SELECT title FROM work_orders WHERE site_id = 10 AND work_order_no = 'WO-2'}),
    'Synced by action', 'the upsert updated the conflicting row within the tenant');
is($dbh->selectrow_array(q{SELECT title FROM work_orders WHERE site_id = 20}), 'Other site pump',
    "another tenant's row with the same number is untouched");

# --- single-use action grants ----------------------------------------------------------

$dbh->do(q{INSERT INTO work_orders VALUES (9, 10, 'WO-G', 'Granted', 'done')});
my $alice = {actor => {id => 'alice'}};
my $grant_plan = $site10->plan_action({action => 'archive', target => 9});
my $grant = $site10->grant_action($grant_plan, phase => 'execute', resolver => $resolver, context => $alice);
like($grant->id, qr/\A[0-9a-f]{32}\z/, 'a grant has an opaque id for audit correlation');

my $fresh = sub { $site10->grant_action($grant_plan, phase => 'execute', resolver => $resolver, context => $alice) };
my %mismatch = (
    actor => sub { $site10->execute_action($grant_plan, grant => $_[0], context => {actor => {id => 'bob'}}) },
    plan => sub { $site10->execute_action($site10->plan_action({action => 'archive', target => 1}),
        grant => $_[0], context => $alice) },
    tenant => sub { $unscoped->with_scope(tenant => 20)->execute_action($grant_plan, grant => $_[0], context => $alice) },
    phase => sub { $site10->preview_action($grant_plan, grant => $_[0], context => $alice) },
);
for my $binding (sort keys %mismatch) {
    my $probe = $fresh->();
    is(code_of(sub { $mismatch{$binding}->($probe) }), 'action_grant_mismatch', "a grant is bound to its $binding");
    is(code_of(sub { $site10->execute_action($grant_plan, grant => $probe, context => $alice) }),
        'action_grant_invalid', "a grant presented for another $binding is revoked");
}

my $granted = $site10->execute_action($grant_plan, grant => $grant, context => $alice);
is($granted->{result}->affected_rows, 1, 'a matching grant executes the plan');
is($granted->{decision}{grant}, $grant->id, 'the decision names the grant it consumed');
is(code_of(sub { $site10->execute_action($grant_plan, grant => $grant, context => $alice) }),
    'action_grant_invalid', 'a grant is used once');

my $short = $site10->grant_action($grant_plan, phase => 'preview', resolver => $resolver,
    context => $alice, expires_in => 0.01);
select(undef, undef, undef, 0.05);
is(code_of(sub { $site10->preview_action($grant_plan, grant => $short, context => $alice) }),
    'action_grant_invalid', 'an expired grant authorizes nothing');
is(code_of(sub { $site10->execute_action($grant_plan, grant => bless(\(my $y = 1), 'Selecto::Action::Grant'),
    context => $alice) }), 'action_grant_invalid', 'a forged grant authorizes nothing');
is(code_of(sub { $site10->grant_action($grant_plan, resolver => sub { 'disabled' }, context => $alice) }),
    'action_capability_denied', 'a denied capability issues no grant');

# --- write_command ---------------------------------------------------------------------

my $built = $site10->write_command(operation => 'update', assignments => {title => 'built'}, filter => ['eq', 'id', 3]);
is($built->relation, 'work_orders', 'write_command binds the domain table');
ok(!defined($built->scope_predicate), 'write_command returns the caller command; execution applies scope');
is(code_of(sub { $site10->write_command(operation => 'update', assignments => {owner => 1}, filter => ['eq', 'id', 3]) }),
    'unknown_field', 'write_command reports contract errors early');
is(code_of(sub { $unscoped->write_command(operation => 'update', assignments => {title => 'x'}, filter => ['eq', 'id', 3]) }),
    'missing_tenant_scope', 'write_command applies the same scope checks');
$site10->execute_write($built);
is(title_of(3), 'built', 'the built command executes through the engine');

# --- fingerprints -----------------------------------------------------------------------

my $scoped_predicate = Selecto::Expression->eq('site_id', 10);
my $without_actions = work_order_contract();
delete @{$without_actions}{qw(actions capabilities)};
isnt(
    $domain->with_required_predicate($scoped_predicate)->fingerprint,
    Selecto::Domain->parse($without_actions)->with_required_predicate($scoped_predicate)->fingerprint,
    'derived domains keep actions and capabilities in their fingerprint',
);

done_testing;
