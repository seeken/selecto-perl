use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
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

eval { Selecto::Action->plan($domain, { action => 'archive', target => 7, inputs => { state => 'open' } }) };
$error = $@;
is($error->code, 'unknown_action_input', 'undeclared action inputs fail closed');

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

my $variant_contract = $domain->contract;
$variant_contract->{source}{fields} = [qw(
    id state documents_complete checked_in_at medical_form_received follow_up_note priority
)];
$variant_contract->{source}{columns} = {
    id => { type => 'integer' }, state => { type => 'string' },
    documents_complete => { type => 'boolean' }, checked_in_at => { type => 'utc_datetime' },
    medical_form_received => { type => 'boolean' }, follow_up_note => { type => 'string' },
    priority => { type => 'integer' },
};
$variant_contract->{writes}{fields} = {
    map { $_ => { updatable => JSON::PP::true } }
        qw(state checked_in_at medical_form_received follow_up_note priority)
};
$variant_contract->{actions}{check_in_camper} = {
    type => 'transition', scope => 'row',
    transition => { field => 'state', from => 'done', to => 'archived' },
    inputs => {
        checked_in_at => { type => 'utc_datetime', required => JSON::PP::false, default => ['system', 'now'] },
        documents_complete => { type => 'boolean', required => JSON::PP::true, discriminator => JSON::PP::true },
        follow_up_note => { type => 'string', required => JSON::PP::false },
    },
    variants => [
        {
            id => 'standard_check_in', when => { documents_complete => JSON::PP::true },
            execution => {
                kind => 'updato', operation => 'update',
                set => { state => 'archived', checked_in_at => ['input', 'checked_in_at'] },
            },
        },
        {
            id => 'missing_documents', when => { documents_complete => JSON::PP::false },
            inputs => {
                missing_documents => { type => 'collection', min_items => 1 },
                follow_up_note => { type => 'string', required => JSON::PP::true },
            },
            execution => {
                kind => 'updato', operation => 'update',
                set => {
                    state => 'archived', medical_form_received => JSON::PP::false,
                    follow_up_note => ['input', 'follow_up_note'],
                },
                collection_patches => {
                    missing_documents => {
                        from_input => 'missing_documents',
                        target => ['relationship', 'registration_missing_documents'],
                        strategy => 'patch', identity => 'id', order_field => 'position',
                    },
                },
            },
        },
    ],
};
$variant_contract->{actions}{archive_by_case} = {
    type => 'transition', scope => 'row',
    transition => { field => 'state', from => 'done', to => 'archived' },
    inputs => {
        reason => { type => 'string', required => JSON::PP::true },
        urgent => { type => 'boolean', required => JSON::PP::true },
    },
    execution => {
        kind => 'updato', operation => 'update',
        cases => [
            { id => 'urgent', when => { urgent => JSON::PP::true }, set => { state => 'archived', priority => 99 } },
            { id => 'ordinary', when => { urgent => JSON::PP::false }, set => { state => 'archived' } },
        ],
    },
};
my $variant_domain = Selecto::Domain->parse($variant_contract, strict => 1);

my $standard = Selecto::Action->plan($variant_domain, {
    action => 'check_in_camper', target => 42, inputs => { documents_complete => 'true' },
});
is($standard->variant, 'standard_check_in', 'normalized boolean selects the standard variant');
is_deeply(
    $standard->inputs,
    { checked_in_at => ['system', 'now'], documents_complete => JSON::PP::true },
    'planner materializes defaults and normalized inputs',
);
is_deeply(
    $standard->changes,
    { checked_in_at => ['system', 'now'], state => 'archived' },
    'input references resolve inside variant changes',
);

my $missing = Selecto::Action->plan($variant_domain, {
    action => 'check_in_camper', target => 42,
    inputs => {
        documents_complete => JSON::PP::false,
        follow_up_note => 'Guardian will bring the waiver.',
        missing_documents => [
            { op => 'add', client_id => 'tmp-waiver', position => 1, document_type => 'waiver' },
            { op => 'reorder', id => 17, position => 2 },
        ],
    },
});
is($missing->variant, 'missing_documents', 'false discriminator selects the collection variant');
is_deeply(
    $missing->collection_patches->{missing_documents},
    {
        target => ['relationship', 'registration_missing_documents'], strategy => 'patch',
        identity => 'id', order_field => 'position',
        entries => [
            { op => 'add', client_id => 'tmp-waiver', position => 1, document_type => 'waiver' },
            { op => 'reorder', id => 17, position => 2 },
        ],
    },
    'selected variant binds collection patch metadata to normalized entries',
);

my $urgent = Selecto::Action->plan($variant_domain, {
    action => 'archive_by_case', target => 7, inputs => { reason => 'certification', urgent => 'true' },
});
my $ordinary = Selecto::Action->plan($variant_domain, {
    action => 'archive_by_case', target => 7, inputs => { reason => 'certification', urgent => 'false' },
});
is($urgent->execution_case, 'urgent', 'urgent execution case is explicit in the public plan');
is_deeply($urgent->changes, { state => 'archived', priority => 99 }, 'urgent case adds governed priority');
is_deeply($ordinary->changes, { state => 'archived' }, 'ordinary case keeps its narrower governed assignment');

eval {
    Selecto::Action->plan($variant_domain, {
        action => 'check_in_camper', target => 42, inputs => { documents_complete => 'not-a-boolean' },
    });
};
$error = $@;
is($error->code, 'invalid_action_input', 'invalid discriminators fail closed before variant selection');

done_testing;
