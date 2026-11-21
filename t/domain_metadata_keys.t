use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Domain;

# Top-level domain_data, events, json_schemas and relation source_kind,
# readonly: the parser admits them with the semantics the domain schema
# conformance fixture (selecto.domain_schema_conformance.v1) gives them.

my $json = JSON::PP->new->canonical;
sub base {
    return {schema_version => 1, name => 'Metadata',
        source => {source_table => 'items', primary_key => 'id', fields => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}};
}
sub other { return {source_table => 'items', primary_key => 'id', fields => [qw(id name)],
    columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}} }
sub refusal {
    my ($raw, $strict) = @_;
    my $ok = eval { Selecto::Domain->parse($raw, strict => $strict); 1 };
    return undef if $ok;
    return blessed($@) && $@->can('code') ? $@ : die $@;
}
my $event = {schema_version => 1, additional_fields => JSON::PP::false,
    data => {id => {type => 'integer', required => JSON::PP::true}, state => {type => 'enum', values => [qw(open closed)]},
        tags => {type => 'list', item => 'string'}, note => 'string'}};

my %accepted = (
    empty_domain_data => sub { $_[0]{domain_data} = {} },
    opaque_domain_data => sub { $_[0]{domain_data} = 'host metadata' },
    domain_data_payload => sub { $_[0]{domain_data} = {display => {title => 'Items'}} },
    empty_json_schemas => sub { $_[0]{json_schemas} = {} },
    json_schemas_payload => sub { $_[0]{json_schemas} = {payload => {type => 'object'}} },
    empty_events => sub { $_[0]{events} = {} },
    event_contract => sub { $_[0]{events} = {changed => $event} },
    (map { my $kind = $_; ("source_$kind" => sub { @{$_[0]{source}}{qw(source_kind readonly)} = ($kind, JSON::PP::true) }) }
        qw(table view materialized_view)),
    schema_view => sub { $_[0]{schemas}{other} = {%{other()}, source_kind => 'view', readonly => JSON::PP::false} },
);
for my $id (sort keys %accepted) {
    for my $strict (1, 0) {
        my $raw = base();
        $accepted{$id}->($raw);
        my $error = refusal($raw, $strict);
        ok(!$error, "$id loads (strict $strict)") or diag($error->message);
    }
}

my %refused = (
    invalid_events_shape => [sub { $_[0]{events} = 'invalid' }, 'invalid_section_shape'],
    invalid_event_version => [sub { $_[0]{events} = {changed => {%$event, schema_version => 0}} }, 'invalid_event_schema_version'],
    string_event_version => [sub { $_[0]{events} = {changed => {%$event, schema_version => '1'}} }, 'invalid_event_schema_version'],
    invalid_event_data => [sub { $_[0]{events} = {changed => {%$event, data => []}} }, 'invalid_event_data_contract'],
    invalid_event_additional_fields => [sub { $_[0]{events} = {changed => {%$event, additional_fields => 'no'}} }, 'invalid_event_additional_fields'],
    invalid_event_type => [sub { $_[0]{events} = {changed => {%$event, data => {x => {type => 'date'}}}} }, 'unsupported_event_field_type'],
    invalid_event_enum => [sub { $_[0]{events} = {changed => {%$event, data => {x => {type => 'enum'}}}} }, 'invalid_event_enum'],
    invalid_event_list_item => [sub { $_[0]{events} = {changed => {%$event, data => {x => {type => 'list', item => 'date'}}}} }, 'unsupported_event_field_type'],
    invalid_event_non_list_item => [sub { $_[0]{events} = {changed => {%$event, data => {x => {type => 'string', item => 'string'}}}} }, 'event_item_on_non_list'],
    invalid_event_boolean => [sub { $_[0]{events} = {changed => {%$event, data => {x => {type => 'string', required => 1}}}} }, 'invalid_event_field_option'],
    source_invalid_source_kind => [sub { $_[0]{source}{source_kind} = 'alien' }, 'invalid_source_kind'],
    source_null_source_kind => [sub { $_[0]{source}{source_kind} = undef }, 'invalid_source_kind'],
    source_invalid_readonly => [sub { $_[0]{source}{readonly} = 'yes' }, 'invalid_readonly'],
    source_numeric_readonly => [sub { $_[0]{source}{readonly} = 1 }, 'invalid_readonly'],
    source_null_readonly => [sub { $_[0]{source}{readonly} = undef }, 'invalid_readonly'],
    schema_invalid_source_kind => [sub { $_[0]{schemas}{other} = {%{other()}, source_kind => 'alien'} }, 'invalid_source_kind'],
    schema_null_source_kind => [sub { $_[0]{schemas}{other} = {%{other()}, source_kind => undef} }, 'invalid_source_kind'],
    schema_invalid_readonly => [sub { $_[0]{schemas}{other} = {%{other()}, readonly => 'yes'} }, 'invalid_readonly'],
    schema_null_readonly => [sub { $_[0]{schemas}{other} = {%{other()}, readonly => undef} }, 'invalid_readonly'],
);
for my $id (sort keys %refused) {
    my ($change, $reason) = @{$refused{$id}};
    # Values are checked whether or not the parse is strict.
    for my $strict (1, 0) {
        my $raw = base();
        $change->($raw);
        my $error = refusal($raw, $strict);
        ok($error, "$id refuses (strict $strict)") or next;
        is($error->code, 'invalid_domain', "$id is invalid_domain");
        is($error->details->{reason}, $reason, "$id reason is $reason");
    }
}

subtest 'contract keeps the metadata and the admission tables list it' => sub {
    my $raw = base();
    @{$raw->{source}}{qw(source_kind readonly)} = ('view', JSON::PP::true);
    $raw->{domain_data} = {display => {title => 'Items'}};
    $raw->{json_schemas} = {payload => {type => 'object'}};
    $raw->{events} = {changed => $event};
    my $contract = Selecto::Domain->parse($raw, strict => 1)->as_contract;
    is($json->encode([@{$contract}{qw(domain_data json_schemas events)}]),
        $json->encode([@{$raw}{qw(domain_data json_schemas events)}]), 'top-level metadata survives');
    is($contract->{source}{source_kind}, 'view', 'source_kind survives');
    ok(JSON::PP::is_bool($contract->{source}{readonly}) && $contract->{source}{readonly}, 'readonly stays a JSON boolean');
    my $keys = Selecto::Domain->contract_keys;
    ok(!grep({ my $k = $_; !grep { $_ eq $k } @{$keys->{top_level}} } qw(domain_data events json_schemas)), 'top-level table');
    ok(!grep({ my $k = $_; !grep { $_ eq $k } @{$keys->{relation}} } qw(source_kind readonly)), 'relation table');
    my $simple = {name => 'Simple', source => {table => 'items', fields => {id => 'integer'}, source_kind => 'view'}};
    is(refusal($simple, 1)->code, 'unknown_domain_key', 'a simple source does not take relation metadata');
};

done_testing;
