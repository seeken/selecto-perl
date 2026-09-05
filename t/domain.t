use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Expression ();
use lib 't/lib';
use TestSelecto;

my $error;
eval {
    Selecto::Domain->parse(JSON::PP->new->encode({
        schema_version => 1,
        name => 'People',
        source => { table => 'people', fields => { id => 'integer' } },
        untrusted_never_intern => JSON::PP::true,
    }), strict => 1);
};
$error = $@;
ok(blessed($error) && $error->isa('Selecto::Error'), 'unknown key produces a stable error');
is($error->code, 'unknown_domain_key', 'unknown key fails closed');
is_deeply($error->details->{keys}, ['untrusted_never_intern'], 'error identifies rejected keys');

my $domain = TestSelecto::orders_domain();
is($domain->resolve('id')->{type}, 'integer', 'resolves a root field');
is($domain->resolve('person.name')->{type}, 'string', 'resolves a joined field');
like($domain->fingerprint, qr/\Asha256:[0-9a-f]{64}\z/, 'domain is fingerprinted');

my $scoped = $domain->with_required_predicate(
    Selecto::Expression->in('person_id', [7, 11]),
);
is($domain->required_predicate, undef, 'scoping a domain does not mutate the shared domain');
isa_ok($scoped->required_predicate, 'Selecto::Expression');
isnt($scoped->fingerprint, $domain->fingerprint,
    'the mandatory visibility predicate participates in the scoped fingerprint');
is_deeply($scoped->contract, $domain->contract,
    'a scoped domain retains its canonical contract metadata');

my $canonical = Selecto::Domain->parse(JSON::PP->new->encode({
    schema_version => 1,
    domain_version => '1.0.0',
    name => 'Orders',
    source => {
        source_table => 'orders',
        primary_key => 'id',
        fields => ['id', 'person_id'],
        columns => { id => { type => 'integer' }, person_id => { type => 'integer' } },
        associations => {
            person => { queryable => 'people', owner_key => 'person_id', related_key => 'id' },
        },
    },
    schemas => {
        people => {
            source_table => 'people', primary_key => 'id', fields => ['id', 'name'],
            columns => { id => { type => 'integer' }, name => { type => 'string' } },
            associations => {},
        },
    },
    joins => { person => { type => 'inner' } },
    writes => { version => 1 },
    components => { query_params => JSON::PP::false },
    domain_dependencies => [{
        provider => 'billing', contract => 'invoice_summary_v1',
        uses => {fields => ['invoice_id']},
    }],
    operations => {approve => {version => '1.0.0'}},
    experiences => {'order-editor' => {operation => 'approve'}},
}), strict => 1);
is($canonical->table, 'orders', 'canonical source table is parsed');
is($canonical->resolve('person.name')->{type}, 'string', 'canonical association fields resolve');
is($canonical->associations->{person}->join_type, 'inner', 'join metadata is applied');

my $deep = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Orders with regions',
    source => {
        source_table => 'orders', primary_key => 'id',
        fields => [qw(id customer_id)],
        columns => {id => {type => 'integer'}, customer_id => {type => 'integer'}},
        associations => {
            customer => {queryable => 'customers', owner_key => 'customer_id', related_key => 'id'},
        },
    },
    schemas => {
        customers => {
            source_table => 'customers', primary_key => 'id',
            fields => [qw(id region_id name)],
            columns => {
                id => {type => 'integer'}, region_id => {type => 'integer'},
                name => {type => 'string'},
            },
            associations => {
                region => {queryable => 'regions', owner_key => 'region_id', related_key => 'id'},
            },
        },
        regions => {
            source_table => 'regions', primary_key => 'id', fields => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}},
            associations => {},
        },
    },
    joins => {customer => {type => 'left'}, 'customer.region' => {type => 'inner'}},
});
is($deep->resolve('customer.region.name')->{type}, 'string',
    'canonical fields resolve through more than one relationship');
is_deeply(
    [map { $_->name } @{$deep->resolve('customer.region.name')->{associations}}],
    [qw(customer region)],
    'deep resolution retains the exact relationship lineage',
);
is($canonical->writes->{version}, 1, 'canonical write metadata remains available to governed consumers');
is($canonical->components->{query_params}, 0, 'canonical component URL-state policy is retained');
is($canonical->domain_dependencies->[0]{contract}, 'invoice_summary_v1',
    'canonical domain dependencies are retained');
is($canonical->operations->{approve}{version}, '1.0.0',
    'canonical operation registries are retained');
is($canonical->experiences->{'order-editor'}{operation}, 'approve',
    'canonical experience registries are retained');

for my $invalid_consumer_section (
    {domain_dependencies => [{provider => '', contract => 'invoice'}]},
    {domain_dependencies => [{provider => 'billing', contract => 'invoice', surface => 'old'}]},
    {operations => {'' => {}}},
    {experiences => {'order-editor' => 'form'}},
) {
    my $invalid = $canonical->contract;
    @{$invalid}{keys %$invalid_consumer_section} = values %$invalid_consumer_section;
    eval { Selecto::Domain->parse($invalid, strict => 1) };
    ok(blessed($@) && $@->isa('Selecto::Error'),
        'malformed canonical consumer contract metadata fails closed');
}
is $canonical->associations->{person}->cardinality, 'one',
    'a join to the target primary key is inferred as to-one';

my $computed_contract = $canonical->contract;
push @{$computed_contract->{source}{fields}}, 'has_person';
$computed_contract->{source}{columns}{has_person} = {
    type => 'boolean',
    computed => {kind => 'association_exists', association => 'person'},
};
my $computed = Selecto::Domain->parse($computed_contract, strict => 1);
is_deeply($computed->field_metadata('has_person')->{computed}, {
    kind => 'association_exists', association => 'person',
}, 'canonical domains retain governed association-exists computed fields');

my $predicate_contract = $computed->contract;
push @{$predicate_contract->{source}{fields}}, 'is_ready';
$predicate_contract->{source}{columns}{is_ready} = {
    type => 'boolean',
    internal => 1,
    computed => {
        kind => 'predicate',
        expression => ['and', [
            ['gt', 'id', 0],
            ['eq', 'has_person', 1],
        ]],
    },
};
my $predicate_computed = Selecto::Domain->parse($predicate_contract, strict => 1);
is_deeply($predicate_computed->field_metadata('is_ready')->{computed}, {
    kind => 'predicate',
    expression => ['and', [
        ['gt', 'id', 0],
        ['eq', 'has_person', 1],
    ]],
}, 'canonical domains retain governed predicate computed fields');
ok !$predicate_computed->field_is_public('is_ready'),
    'SQL-computed eligibility fields may remain internal to consumers';

my $eligible_action_contract = $predicate_computed->contract;
$eligible_action_contract->{actions}{dispatch}{selection}{eligibility_field} = 'is_ready';
my $eligible_action = Selecto::Domain->parse($eligible_action_contract, strict => 1);
is(
    $eligible_action->actions->{dispatch}{selection}{eligibility_field},
    'is_ready',
    'actions retain a governed boolean root eligibility field',
);

my $non_boolean_eligibility_contract = $predicate_computed->contract;
$non_boolean_eligibility_contract->{actions}{dispatch}{selection}{eligibility_field} = 'id';
eval { Selecto::Domain->parse($non_boolean_eligibility_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'action eligibility fields must name boolean root fields');

my $cyclic_predicate_contract = $predicate_computed->contract;
$cyclic_predicate_contract->{source}{columns}{has_person}{computed} = {
    kind => 'predicate', expression => ['eq', 'is_ready', 1],
};
eval { Selecto::Domain->parse($cyclic_predicate_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'computed predicate dependency cycles fail closed');

my $bad_computed_contract = $computed->contract;
$bad_computed_contract->{source}{columns}{has_person}{computed}{association} = 'passwords';
eval { Selecto::Domain->parse($bad_computed_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'computed fields cannot reference associations outside the domain');

$bad_computed_contract = $computed->contract;
$bad_computed_contract->{source}{columns}{has_person}{computed}{kind} = 'raw_sql';
eval { Selecto::Domain->parse($bad_computed_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'arbitrary computed field kinds fail closed');

my $many_contract = $canonical->contract;
$many_contract->{schemas}{people}{fields} = [qw(id name order_id)];
$many_contract->{schemas}{people}{columns}{order_id} = {type => 'integer'};
$many_contract->{source}{associations}{person}{related_key} = 'order_id';
my $many = Selecto::Domain->parse($many_contract, strict => 1);
is $many->associations->{person}->cardinality, 'many',
    'a join through a non-primary target key is inferred as to-many';
is $many->associations->{person}->target_primary_key, 'id',
    'a to-many association retains its target ordering key';

my $through_contract = $canonical->contract;
$through_contract->{source}{associations}{person} = {
    queryable => 'people',
    owner_key => 'id',
    related_key => 'id',
    cardinality => 'many',
    through => {
        table => 'order_people',
        owner_key => 'order_id',
        related_key => 'person_id',
    },
};
my $through = Selecto::Domain->parse($through_contract, strict => 1);
is_deeply(
    $through->associations->{person}->through,
    {table => 'order_people', owner_key => 'order_id', related_key => 'person_id'},
    'canonical associations retain an explicit keyless bridge contract',
);
isnt($through->fingerprint, $canonical->fingerprint,
    'through metadata participates in the domain fingerprint');

my $qualified_through_contract = $through->contract;
$qualified_through_contract->{source}{associations}{person}{where} = {userstatus => 'A'};
$qualified_through_contract->{schemas}{people}{fields} = [qw(id name userstatus)];
$qualified_through_contract->{schemas}{people}{columns}{userstatus} = {type => 'string'};
$qualified_through_contract->{source}{associations}{person}{through}{where} = {type => 'E'};
$qualified_through_contract->{source}{associations}{person}{through}{target_key_cast} = 'string';
my $qualified_through = Selecto::Domain->parse($qualified_through_contract, strict => 1);
is_deeply($qualified_through->associations->{person}->where, {userstatus => 'A'},
    'canonical associations retain target constant predicates');
is_deeply($qualified_through->associations->{person}->through->{where}, {type => 'E'},
    'canonical through associations retain bridge constant predicates');
is($qualified_through->associations->{person}->through->{target_key_cast}, 'string',
    'canonical through associations retain an explicit target-key cast');

my $bad_where_contract = $qualified_through->contract;
$bad_where_contract->{source}{associations}{person}{where} = {password => 'secret'};
eval { Selecto::Domain->parse($bad_where_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'association predicates cannot reference fields outside the governed schema');

my $bad_cast_contract = $qualified_through->contract;
$bad_cast_contract->{source}{associations}{person}{through}{target_key_cast} = 'integer';
eval { Selecto::Domain->parse($bad_cast_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'unsupported through target casts fail closed');

my $bad_through_contract = $through->contract;
$bad_through_contract->{source}{associations}{person}{through}{source_scope_key} =
    'person_id';
eval { Selecto::Domain->parse($bad_through_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'partial through scope metadata fails closed');

my $scoped_direct = Selecto::Domain->new(
    name => 'Scoped parents',
    table => 'parents',
    fields => {id => 'integer', tenant_id => 'integer'},
    associations => {
        children => {
            table => 'children',
            fields => {id => 'integer', parent_id => 'integer', tenant_id => 'integer'},
            owner_key => 'id', related_key => 'parent_id', cardinality => 'many',
            source_scope_key => 'tenant_id', target_scope_key => 'tenant_id',
        },
    },
);
is($scoped_direct->associations->{children}->source_scope_key, 'tenant_id',
    'direct association retains its source scope key');
is($scoped_direct->associations->{children}->target_scope_key, 'tenant_id',
    'direct association retains its target scope key');
eval {
    Selecto::Domain->new(
        name => 'Bad scoped parents', table => 'parents',
        fields => {id => 'integer', tenant_id => 'integer'},
        associations => {
            children => {
                table => 'children', fields => {id => 'integer', parent_id => 'integer'},
                owner_key => 'id', related_key => 'parent_id', cardinality => 'many',
                source_scope_key => 'tenant_id',
            },
        },
    );
};
$error = $@;
is($error->code, 'invalid_domain',
    'partial direct association scope metadata fails closed');

my $star_contract = $canonical->contract;
$star_contract->{joins}{person} = {
    type => 'star_dimension',
    name => 'Person',
    display_field => 'name',
    dimension_key => 'person_id',
};
my $star = Selecto::Domain->parse($star_contract, strict => 1);
my $person_dimension = $star->associations->{person};
is $person_dimension->join_mode, 'star_dimension',
    'canonical star-dimension intent is retained';
is $person_dimension->join_type, 'left',
    'a star dimension compiles through a fact-preserving left join';
is $person_dimension->display_field, 'name',
    'a star dimension exposes its descriptive field';
is $person_dimension->dimension_key, 'person_id',
    'a star dimension exposes its fact-table key';
is $person_dimension->display_name, 'Person',
    'a star dimension retains its presentation name';

my $bad_star_contract = $canonical->contract;
$bad_star_contract->{joins}{person} = {
    type => 'star_dimension', display_field => 'missing', dimension_key => 'person_id',
};
eval { Selecto::Domain->parse($bad_star_contract, strict => 1) };
$error = $@;
is $error->code, 'invalid_domain',
    'a star dimension cannot expose a display field outside its schema';

my $bad_components = eval {
    Selecto::Domain->new(
        name => 'Bad components', table => 'bad_components', fields => { id => 'integer' },
        components => { query_params => 'sometimes' },
    );
    1;
};
ok(!$bad_components, 'component URL-state policy requires a boolean');
is($@->code, 'invalid_domain', 'invalid component policy fails through the domain boundary');

my $action_contract = $canonical->contract;
$action_contract->{detail_actions} = {
    open_order => {
        name => 'Open order',
        description => 'Open this order in maintenance.',
        type => 'external_link',
        required_fields => [qw(id person.name)],
        payload => {
            url_template => '/orders/maint?id={{id}}&person={{person.name}}',
            target => '_blank',
        },
    },
};
my $action_domain = Selecto::Domain->parse($action_contract, strict => 1);
is_deeply(
    $action_domain->detail_actions->{open_order},
    $action_contract->{detail_actions}{open_order},
    'canonical detail actions retain their validated external-link contract',
);

my $modal_action_contract = dclone($action_contract);
$modal_action_contract->{detail_actions}{open_order} = {
    name => 'Order maintenance',
    description => 'Review this order without leaving the result set.',
    type => 'iframe_modal',
    required_fields => [qw(id person.name)],
    payload => {
        url_template => '/orders/maint?id={{id}}&person={{person.name}}',
        title => 'Order {{id}}',
        size => 'fullscreen',
        referrer_policy => 'same-origin',
        navigation_enabled => 1,
        allow => 'clipboard-write',
    },
};
my $modal_action_domain = Selecto::Domain->parse($modal_action_contract, strict => 1);
is_deeply(
    $modal_action_domain->detail_actions->{open_order},
    $modal_action_contract->{detail_actions}{open_order},
    'canonical detail actions retain their validated iframe-modal contract',
);

my $default_modal_contract = dclone($modal_action_contract);
delete @{$default_modal_contract->{detail_actions}{open_order}{payload}}{
    qw(title size referrer_policy navigation_enabled allow)
};
my $default_modal = Selecto::Domain->parse($default_modal_contract, strict => 1)
    ->detail_actions->{open_order}{payload};
is_deeply(
    $default_modal,
    {
        url_template => '/orders/maint?id={{id}}&person={{person.name}}',
        title => 'Order maintenance',
        size => 'xl',
        referrer_policy => 'strict-origin-when-cross-origin',
        navigation_enabled => 1,
    },
    'iframe-modal presentation and navigation defaults are portable',
);

my $bad_action_contract = dclone($action_contract);
$bad_action_contract->{detail_actions}{open_order}{payload}{url_template} =
    'javascript:alert({{id}})';
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'executable detail-action URLs fail closed');

$bad_action_contract = dclone($action_contract);
$bad_action_contract->{detail_actions}{open_order}{required_fields} = ['person.name'];
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'every detail-action URL placeholder must be a declared required field');

$bad_action_contract = dclone($action_contract);
$bad_action_contract->{detail_actions}{open_order}{required_fields} = [qw(id person.secret)];
$bad_action_contract->{detail_actions}{open_order}{payload}{url_template} =
    '/orders/maint?id={{id}}&secret={{person.secret}}';
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'detail actions cannot require fields outside the governed domain');

$bad_action_contract = $many->contract;
$bad_action_contract->{detail_actions} = {
    open_order => {
        name => 'Open order', type => 'external_link',
        required_fields => [qw(id person.name)],
        payload => {url_template => '/orders/maint?id={{id}}&person={{person.name}}'},
    },
};
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'detail-action fields cannot introduce a to-many row multiplication');

$bad_action_contract = dclone($action_contract);
$bad_action_contract->{detail_actions}{open_order}{type} = 'modal';
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'unsupported detail-action types fail closed');

$bad_action_contract = dclone($modal_action_contract);
$bad_action_contract->{detail_actions}{open_order}{payload}{title} = 'Order {{person.secret}}';
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain',
    'iframe-modal title placeholders must be governed required fields');

$bad_action_contract = dclone($modal_action_contract);
$bad_action_contract->{detail_actions}{open_order}{payload}{referrer_policy} = 'send-everything';
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'unknown iframe referrer policies fail closed');

$bad_action_contract = dclone($modal_action_contract);
$bad_action_contract->{detail_actions}{open_order}{payload}{target} = '_blank';
eval { Selecto::Domain->parse($bad_action_contract, strict => 1) };
$error = $@;
is($error->code, 'invalid_domain', 'external-link settings cannot leak into iframe actions');

eval { $canonical->resolve('person.secret') };
$error = $@;
is($error->code, 'unknown_field', 'fields outside the contract are rejected');

done_testing;
