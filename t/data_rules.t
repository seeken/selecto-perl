use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use FindBin qw($Bin);
use Selecto::DataRules ();
use Selecto::Domain ();

my $fixtures = $ENV{SELECTO_DATA_RULE_FIXTURES} // "$Bin/fixtures/data_rules";
my $json = JSON::PP->new;
open my $contract_file, '<', "$fixtures/baseline.contract.json" or die $!;
my $contract = $json->decode(do { local $/; <$contract_file> });
open my $cases_file, '<', "$fixtures/baseline.cases.json" or die $!;
my $cases = $json->decode(do { local $/; <$cases_file> });
open my $invalid_file, '<', "$fixtures/invalid.cases.json" or die $!;
my $invalid = $json->decode(do { local $/; <$invalid_file> });

for my $probe (@{$cases->{cases}}) {
    my $result = Selecto::DataRules->parse($contract)->evaluate(
        stage => $probe->{stage}, operation => $probe->{operation}, action => $probe->{action},
        authoritative_stage => $probe->{authoritative_stage}, subject => $probe->{subject},
    );
    is $result->{state}, $probe->{expected}{state}, "$probe->{id} has the expected state";
    is $result->{code}, $probe->{expected}{code}, "$probe->{id} has the expected code" if exists $probe->{expected}{code};
    is_deeply $result->{normalized}, $probe->{expected}{normalized}, "$probe->{id} has normalized output" if exists $probe->{expected}{normalized};
}

my $non_ascii = Selecto::DataRules->parse($contract)->evaluate(
    stage => 'candidate', operation => 'update', subject => {reference => '  éfoo  '},
);
is $non_ascii->{state}, 'failed', 'non-ASCII uppercase fails the portable normalizer';
is $non_ascii->{code}, 'normalization_error', 'non-ASCII uppercase keeps the Perl error code';
is_deeply $non_ascii->{normalized}, {reference => '  éfoo  '}, 'failed normalization preserves the submitted value';

my $alternate = dclone($contract);
$alternate->{definitions}{reference_pattern}{test}{pattern} = 'VIN|VINC';
my $alternate_result = Selecto::DataRules->parse($alternate)->evaluate(
    stage => 'candidate', operation => 'update', subject => {reference => 'VINC'},
);
is $alternate_result->{state}, 'passed', 'full pattern can match a later alternation branch';

my $all_operations = dclone($contract);
$all_operations->{bindings}{positive_quantity}{operations} = [];
my $all_operations_result = Selecto::DataRules->parse($all_operations)->evaluate(
    stage => 'candidate', operation => 'update', subject => {quantity => -1},
);
is $all_operations_result->{code}, 'numeric_bound', 'empty operations applies to every operation';

my $invalid_item = Selecto::DataRules->parse($contract)->evaluate(
    stage => 'candidate', operation => 'delete', subject => {items => [{}]},
);
is $invalid_item->{code}, 'invalid_collection_item', 'missing unique-by item path has its own code';

my $same_object = Selecto::DataRules->parse($contract)->evaluate(
    stage => 'candidate', operation => 'delete',
    subject => {items => [
        {product_id => {a => 1, b => 2}, variant => 'x'},
        {product_id => {b => 2, a => 1}, variant => 'x'},
    ]},
);
is $same_object->{code}, 'duplicate_collection_value', 'unique-by compares nested objects independent of key order';

my $large_versions = dclone($contract);
$large_versions->{definitions}{positive}{version} = '900719925474099312345';
$large_versions->{bindings}{positive_quantity}{rule}{version} = '900719925474099312345';
my $large_version_result = Selecto::DataRules->parse($large_versions)->evaluate(
    stage => 'candidate', operation => 'insert', subject => {quantity => 1},
);
is $large_version_result->{state}, 'passed', 'numeric-string rule versions remain exact through references';

my @strict_probes = (
    ['scientific_bound', {definitions => {positive => {test => {bound => '1e3'}}}}, 'invalid_data_rules_contract'],
    ['conflicting_count', {definitions => {exactly_three => {test => {min => 1}}}}, 'invalid_data_rules_contract'],
    ['unknown_normalizer_profile', {normalizers => {reference => {steps => [{op => 'text.trim', profile => 'unicode_v1'}]}}}, 'invalid_data_rules_contract'],
    ['duplicate_operations', {bindings => {positive_quantity => {operations => ['insert', 'insert']}}}, 'invalid_data_rules_contract'],
    ['binding_condition', {bindings => {positive_quantity => {condition => {op => 'value.eq', value => 1}}}}, 'unsupported_rule_operator'],
    ['missing_normalizer', {bindings => {reference_shape => {normalizer => {id => 'missing', version => 1}}}}, 'unresolved_rule_reference'],
    ['unknown_test_option', {definitions => {positive => {test => {remote_url => 'invalid'}}}}, 'unknown_rule_option'],
);
for my $probe (@strict_probes) {
    eval { Selecto::DataRules->parse(_merge(dclone($contract), $probe->[1])) };
    my $error = $@;
    ok blessed($error) && $error->isa('Selecto::Error'), "$probe->[0] is rejected during parsing";
    is $error->code, $probe->[2], "$probe->[0] keeps the Perl error code";
}

for my $probe (@{$invalid->{cases}}) {
    my $patched = _merge(dclone($contract), $probe->{patch});
    eval { Selecto::DataRules->parse($patched) };
    my $error = $@;
    ok blessed($error) && $error->isa('Selecto::Error'), "$probe->{id} rejects a malformed contract";
    is $error->code, $probe->{expected_code}, "$probe->{id} returns the protocol error code";
}

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Orders',
    source => {source_table => 'orders', primary_key => 'id', fields => [qw(id quantity)], columns => {id => {type => 'integer'}, quantity => {type => 'integer'}}, associations => {}},
    schemas => {}, joins => {}, rules => {schema => 'selecto.data_rules.v1', definitions => {positive => {version => 1, test => {op => 'number.gt', bound => '0'}}}, normalizers => {}, bindings => {quantity => {subject => {scope => 'candidate', path => ['quantity']}, operations => ['insert'], rule => {id => 'positive', version => 1}}}},
}, strict => 1);
is $domain->rules->evaluate(stage => 'candidate', operation => 'insert', subject => {quantity => 1})->{state}, 'passed', 'domain import exposes compiled portable rules';

sub _merge { my ($target, $patch) = @_; for my $key (keys %$patch) { if (ref($patch->{$key}) eq 'HASH' && ref($target->{$key}) eq 'HASH') { _merge($target->{$key}, $patch->{$key}); } else { $target->{$key} = $patch->{$key}; } } return $target; }

done_testing;
