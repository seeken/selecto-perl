use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;

my $domain = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Work Items',
    source => {
        source_table => 'work_items', primary_key => 'id',
        fields => [qw(id state)],
        columns => { id => { type => 'integer' }, state => { type => 'string' } },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => { update => { enabled => 1, require_filter => 1, bulk => 1 } },
        fields => { state => { updatable => 1 } },
        transitions => { state => { done => ['archived'] } },
    },
    actions => {
        archive => {
            type => 'transition', scope => 'row', capability => 'work_items.archive',
            transition => { field => 'state', from => 'done', to => 'archived' },
            execution => { kind => 'updato', operation => 'update', set => { state => 'archived' } },
        },
        bulk_archive => {
            type => 'bulk_action', scope => 'bulk', capability => 'work_items.bulk_archive',
            execution => { kind => 'updato', operation => 'update', set => { state => 'archived' } },
        },
    },
    capabilities => {
        'work_items.archive' => { operations => ['action', 'update'], action => 'archive' },
        'work_items.bulk_archive' => { operations => ['action', 'update'], action => 'bulk_archive' },
    },
}, strict => 1);

my $plan = Selecto::Action->plan($domain, { action => 'archive', target => 7 });
isa_ok($plan, 'Selecto::Action::Plan');
is($plan->operation, 'update', 'action is confined to its declared operation');
is_deeply($plan->changes, { state => 'archived' }, 'action changes remain declared');
is_deeply($plan->filters, [['id', 7], ['state', 'done']], 'row target and transition precondition are explicit');
is_deeply($plan->expected_cardinality, ['exactly', 1], 'row action has exact cardinality');

my $request = Selecto::Action->capability_request($plan, 'preview');
is($request->{phase}, 'preview', 'capability request is phase-bound');
is($request->{capability}, 'work_items.archive', 'declared capability reaches policy request');

my $decision = Selecto::Action->authorize($plan, 'execute', resolver => sub { return 'enabled' });
is_deeply($decision, { status => 'enabled', capability => 'work_items.archive' }, 'enabled policy permits the phase');

my $error;
eval { Selecto::Action->authorize($plan, 'execute') };
$error = $@;
ok(blessed($error) && $error->isa('Selecto::Error'), 'missing resolver fails with a stable error');
is($error->code, 'missing_capability_resolver', 'missing resolver fails closed');
is($error->details->{status}, 'hidden', 'missing policy hides the action');

eval { Selecto::Action->authorize($plan, 'preview', resolver => sub { return 'disabled' }) };
$error = $@;
is($error->code, 'action_capability_denied', 'disabled policy fails closed');

eval { Selecto::Action->plan($domain, { action => 'archive' }) };
$error = $@;
is($error->code, 'action_scope_mismatch', 'row action requires a concrete target');

my $bulk = Selecto::Action->plan(
    $domain,
    { action => 'bulk_archive', target => { ids => ['2', '3'] } },
);
is_deeply($bulk->target, { ids => [2, 3] }, 'bulk target ids normalize at the public plan boundary');
is_deeply($bulk->filters, [['id', 'in', [2, 3]]], 'bulk filter uses the same normalized ids');
is_deeply($bulk->expected_cardinality, ['exactly', 2], 'bulk plan preserves exact selection cardinality');

eval {
    Selecto::Action->plan(
        $domain,
        { action => 'bulk_archive', target => { ids => [2, 2] } },
    );
};
$error = $@;
is($error->code, 'invalid_action_target', 'duplicate bulk targets fail closed');

done_testing;
