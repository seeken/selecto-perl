use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
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
}), strict => 1);
is($canonical->table, 'orders', 'canonical source table is parsed');
is($canonical->resolve('person.name')->{type}, 'string', 'canonical association fields resolve');
is($canonical->associations->{person}->join_type, 'inner', 'join metadata is applied');
is($canonical->writes->{version}, 1, 'canonical write metadata remains available to governed consumers');
is($canonical->components->{query_params}, 0, 'canonical component URL-state policy is retained');
is $canonical->associations->{person}->cardinality, 'one',
    'a join to the target primary key is inferred as to-one';

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

eval { $canonical->resolve('person.secret') };
$error = $@;
is($error->code, 'unknown_field', 'fields outside the contract are rejected');

done_testing;
