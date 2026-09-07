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

done_testing;
