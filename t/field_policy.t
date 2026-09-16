use 5.034;
use strict;
use warnings;

use Test::More;
use JSON::PP ();
use Selecto::Domain ();
use Selecto::FieldPolicy ();

my $domain = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Orders',
    source => {
        source_table => 'orders', primary_key => 'id',
        fields => [qw(id status amount secret customer_id)],
        columns => {
            id => {type => 'integer', label => 'Order ID'},
            status => {type => 'string', label => 'Status'},
            amount => {type => 'decimal', label => 'Amount'},
            secret => {type => 'string', internal => 1},
            customer_id => {type => 'integer'},
        },
        associations => {
            customer => {queryable => 'customers', owner_key => 'customer_id', related_key => 'id'},
        },
    },
    schemas => {
        customers => {
            source_table => 'customers', primary_key => 'id',
            fields => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string', label => 'Customer'}},
            associations => {},
        },
    },
    joins => {customer => {type => 'left'}},
    writes => {
        operations => {insert => {enabled => 1}, update => {enabled => 1}},
        fields => {
            status => {insertable => 1, updatable => 1, required => 1},
            amount => {insertable => 1, updatable => 1},
        },
    },
}, strict => 1);

my %decisions = (
    'orders.view_amount' => {status => 'enabled'},
    'orders.edit_amount' => {status => 'disabled', reason => 'Accounting is locked', reason_code => 'locked'},
    'orders.view_secret' => {status => 'enabled'},
);
my $policy = Selecto::FieldPolicy->new(
    domain => $domain,
    authorize => sub { return $decisions{$_[0]{capability}} // {status => 'enabled'} },
);

my $resolved = $policy->resolve(
    operation => 'update',
    snapshot => {id => 12, status => 'A', amount => 99.5, secret => 'nope'},
    profile => [
        {field => 'id'},
        {field => 'status'},
        {field => 'amount', view_capability => 'orders.view_amount', edit_capability => 'orders.edit_amount'},
        {field => 'secret', view_capability => 'orders.view_secret'},
        {field => 'customer.name'},
    ],
);

is_deeply [map { $_->{state} } @$resolved],
    [qw(read-only editable read-only hidden read-only)],
    'visibility and editability are resolved independently';
is $resolved->[0]{label}, 'Order ID', 'column label is reused';
is $resolved->[1]{control}, 'text', 'control is inferred from the field type';
is $resolved->[2]{reason_code}, 'locked', 'edit denial explains read-only state';
is $resolved->[3]{reason_code}, 'field_not_public', 'internal fields remain hidden';

my $insert = $policy->resolve(
    operation => 'insert', profile => [{field => 'status'}], snapshot => {},
);
ok $insert->[0]{required}, 'write-contract requiredness applies to inserts';

my $action = $policy->resolve(
    operation => 'update',
    profile => [{field => 'status', action => 'transition_status'}],
    snapshot => {status => 'A'},
);
is $action->[0]{state}, 'action-backed', 'workflow-owned values are not direct assignments';
is_deeply $policy->accepted_fields(
    operation => 'update', profile => [{field => 'status'}, {field => 'id'}],
), ['status'], 'accepted fields contains only effective editable assignments';

is $policy->resolve(
    operation => 'update', snapshot => {},
    profile => [{field => 'amount', eligible => JSON::PP::false}],
)->[0]{state}, 'read-only', 'JSON boolean profile values are accepted';

eval {
    $policy->resolve(operation => 'update', profile => [{field => 'missing'}]);
};
isa_ok $@, 'Selecto::Error';
is $@->code, 'invalid_field_policy', 'unknown profile fields fail closed';

done_testing;
