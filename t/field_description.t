use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Selecto::API ();
use Selecto::Domain ();

# Column and filter-choice descriptions: plain text for people choosing or
# reading a field, validated with the domain and published by the API for
# public fields only.

sub contract {
    my (%column) = @_;
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {
            source_table => 'orders', primary_key => 'id',
            fields => [qw(id total secret customer_id)],
            columns => {
                id => {type => 'integer'},
                total => {type => 'decimal', label => 'Total', description => "What the customer pays.\nTaxes included.",
                    unit => {kind => 'currency', code => 'USD'}, %column},
                secret => {type => 'string', internal => 1, description => 'Never shown.'},
                customer_id => {type => 'integer'},
            },
            associations => {customer => {queryable => 'customers', field => 'customer', owner_key => 'customer_id',
                related_key => 'id', cardinality => 'one'}},
        },
        schemas => {customers => {source_table => 'customers', primary_key => 'id', fields => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string', description => 'The trading name.'}}}},
        joins => {},
        components => {filter_choices => {total => {label => 'Size', description => 'Order size bands.',
            choices => [{value => '1', label => 'Small'}]}}},
    };
}

# The API needs the domain's identity: its fingerprint, recorded in the contract.
sub identified {
    my ($contract) = @_;
    $contract->{domain_fingerprint} = Selecto::Domain->parse({%$contract}, strict => 1)->fingerprint;
    return Selecto::Domain->parse($contract, strict => 1);
}

my $domain = identified(contract());
is $domain->field_description('total'), "What the customer pays.\nTaxes included.", 'a root column';
is $domain->field_description('customer.name'), 'The trading name.', 'an associated schema\'s column';
is $domain->field_description('id'), undef, 'none without one';
is $domain->components->{filter_choices}{total}{description}, 'Order size bands.', 'a filter choice';

for my $bad ([undef, 'undefined'], ['', 'empty'], ['   ', 'blank'], [[1], 'a reference'],
        ['x' x 1001, 'too long'], ["tab\there", 'a control character']) {
    my ($value, $name) = @$bad;
    ok !eval { Selecto::Domain->parse(contract(description => $value), strict => 1); 1 },
        "a column description that is $name is refused";
    like $@, qr/column total description/, 'naming the column';
}
ok eval { Selecto::Domain->parse(contract(description => 'x' x 1000), strict => 1); 1 }, '1000 characters are allowed';
ok !eval { Selecto::Domain->parse(contract(description => 5), strict => 1); 1 }, 'a number is not a description';
ok !eval { Selecto::Domain->parse(contract(description => "a\rb"), strict => 1); 1 }, 'nor is text with a carriage return';
ok eval { Selecto::Domain->parse(contract(description => "\x{1F600}" x 1000), strict => 1); 1 },
    '1000 characters are counted as code points';
ok !eval { Selecto::Domain->parse(contract(description => "\x{1F600}" x 1001), strict => 1); 1 }, 'and 1001 are too many';
my $bad_choice = contract();
$bad_choice->{components}{filter_choices}{total}{description} = {};
ok !eval { Selecto::Domain->parse($bad_choice, strict => 1); 1 }, 'a filter choice description must be text';

my $fields = Selecto::API->new(domain => $domain)->openapi_document->{'x-selecto'}{fields};
my %by_path = map { $_->{path} => $_ } @$fields;
is_deeply $by_path{total}, {path => 'total', type => 'decimal', label => 'Total',
    description => "What the customer pays.\nTaxes included.", unit => {kind => 'currency', code => 'USD'}},
    'the API publishes a field\'s label, description and unit';
is_deeply $by_path{'customer.name'}, {path => 'customer.name', type => 'string', description => 'The trading name.'},
    'and associated fields';
is_deeply $by_path{id}, {path => 'id', type => 'integer'}, 'a field without them is listed plainly';
ok !$by_path{secret}, 'internal fields are not listed';

my $redacted = contract();
$redacted->{redact_fields} = ['total'];
my $redacted_fields = Selecto::API->new(domain => identified($redacted))
    ->openapi_document->{'x-selecto'}{fields};
ok !(grep { $_->{path} eq 'total' } @$redacted_fields), 'nor redacted ones';

done_testing;
