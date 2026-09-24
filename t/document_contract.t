use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;

my $artifact = {
    status => 'approved',
    source => {id => 'mongo_work_orders', collection => 'work_orders', tenant_path => ['tenant_id']},
    shape => {fields => {
        id => {path => ['_id'], type => 'string'},
        tenant_id => {path => ['tenant_id'], type => 'string'},
        title => {path => ['title'], type => 'string'},
    }},
    relations => {work_orders => {kind => 'root', access_patterns => {
        by_tenant => {index => 'tenant_id_1__id_1', filter_fields => ['id'], order_fields => ['id']},
    }}},
};

my $release = Selecto::Document::ShapeRelease->new(artifact => $artifact);
my $plan = Selecto::Document::Plan->new(
    release => $release, relation => 'work_orders', tenant => 'tenant-a',
    access_pattern => 'by_tenant', select => [qw(id title)],
    where => {field => 'id', op => 'gte', value => 'wo-1'}, order => [['id', 'asc']], limit => 25,
);
is($plan->tenant, 'tenant-a', 'plan binds trusted tenant scope');
is_deeply($plan->projection_ids, [qw(id title)], 'plan publishes governed projection');
is($plan->access_pattern->{index}, 'tenant_id_1__id_1', 'plan retains declared access pattern');

eval { Selecto::Document::Plan->new(release => $release, relation => 'work_orders', tenant => '', access_pattern => 'by_tenant', select => ['id']) };
is($@->code, 'tenant_required', 'missing trusted tenant fails closed');
eval { Selecto::Document::Plan->new(release => $release, relation => 'work_orders', tenant => 'tenant-a', access_pattern => 'by_tenant', select => ['secret']) };
is($@->code, 'unknown_field', 'undeclared projection fails closed');


$artifact->{source}{collection} = 'changed';
is($release->source->{collection}, 'work_orders', 'release copied input metadata');
my $source = $release->source;
$source->{collection} = 'changed_again';
is($release->source->{collection}, 'work_orders', 'source accessor is a copy');
for my $mutation (
    sub { $release->{artifact} = {} },
    sub { $plan->{tenant} = 'foreign' },
    sub { $plan->{limit} = 2000 },
) { eval { $mutation->() }; ok($@, 'private source/plan state cannot be replaced'); }
my $projection = $plan->projection;
$projection->[0]{path} = ['foreign'];
is_deeply($plan->projection->[0]{path}, ['_id'], 'projection accessor cannot change native paths');
my $integer = Selecto::Document::Integer->new('9223372036854775807');
is($integer->value, '9223372036854775807', 'exact Int64 maximum');
is(Selecto::Document::Integer->new('-9223372036854775808')->value, '-9223372036854775808', 'exact Int64 minimum');
eval { $$integer = '0' }; ok($@, 'integer value cannot be changed');
for my $value ('9223372036854775808', '-9223372036854775809', '1.0', '1e4') {
    eval { Selecto::Document::Integer->new($value) };
    is($@->code, 'invalid_predicate_value', 'invalid integer rejected without coercion');
}
for my $args (
    {select=>['id','id']}, {limit=>1001}, {from=>'foreign'},
    {where=>{field=>'title',op=>'eq',value=>'hidden'}},
    {order=>[['title','asc']]},
) {
    eval { Selecto::Document::Plan->new(release=>$release,tenant=>'tenant-a',relation=>'work_orders',access_pattern=>'by_tenant',select=>['id'],%$args) };
    isa_ok($@, 'Selecto::Error', 'invalid intent rejected by public plan boundary');
}
sub plan_error {
    my (%args) = @_;
    eval { Selecto::Document::Plan->new(release=>$release,tenant=>'tenant-a',relation=>'work_orders',access_pattern=>'by_tenant',select=>['id'],%args) };
    return ref($@) ? $@->code : "no error: $@";
}
for my $op (qw(like in nin ne regex), '') {
    is(plan_error(where=>{field=>'id',op=>$op,value=>'wo-1'}), 'invalid_predicate', "unsupported predicate op '$op' fails as invalid_predicate");
}
is(plan_error(where=>{field=>'id',value=>'wo-1'}), 'invalid_predicate', 'missing predicate op fails as invalid_predicate');
is(plan_error(order=>[['id','sideways']]), 'invalid_order', 'unknown order direction fails as invalid_order');
is(plan_error(order=>[['id']]), 'invalid_order', 'order entry without direction fails as invalid_order');

sub release_error {
    my ($mutate) = @_;
    my $copy = {
        status => 'approved',
        source => {id => 'mongo_work_orders', collection => 'work_orders', tenant_path => ['tenant_id']},
        shape => {fields => {id => {path => ['_id'], type => 'string'}, tenant_id => {path => ['tenant_id'], type => 'string'}}},
        relations => {work_orders => {kind => 'root', access_patterns => {
            by_tenant => {index => 'tenant_id_1__id_1', filter_fields => ['id'], order_fields => ['id']},
        }}},
    };
    $mutate->($copy);
    eval { Selecto::Document::ShapeRelease->new(artifact => $copy) };
    return ref($@) ? $@->code : "no error: $@";
}
is(release_error(sub { $_[0]{shape}{fields}{amount} = {path => ['amount'], type => 'decimal'} }),
    'invalid_shape_release', 'unsupported decimal field type fails closed');
is(release_error(sub { $_[0]{shape}{fields}{amount} = {path => ['amount']} }),
    'invalid_shape_release', 'missing field type fails closed');
is(release_error(sub { $_[0]{shape}{fields}{amount} = {path => ['Bad-Path'], type => 'string'} }),
    'invalid_shape_release', 'invalid field path fails closed');
is(release_error(sub { $_[0]{relations}{work_orders}{access_patterns}{by_tenant}{index} = 'Not An Index' }),
    'invalid_access_pattern', 'invalid access-pattern index fails closed');
is(release_error(sub { delete $_[0]{relations}{work_orders}{access_patterns}{by_tenant}{index} }),
    'invalid_access_pattern', 'missing access-pattern index fails closed');
is(release_error(sub { $_[0]{source}{collection} = 'Bad Collection' }),
    'invalid_shape_release', 'invalid source collection fails closed');
my $forged = bless {}, 'Selecto::Document::Plan';
eval { $forged->validate_scope($release, 'tenant-a') };
is($@->code, 'invalid_document_plan', 'forged native plan rejected');
ok(!exists $INC{'MongoDB.pm'}, 'core remains free of the MongoDB driver');
done_testing;
