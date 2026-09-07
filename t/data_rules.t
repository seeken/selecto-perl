use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::DataRules ();
use Selecto::Domain ();

my $fixtures = $ENV{SELECTO_DATA_RULE_FIXTURES} // '../selecto-protocol/spec/fixtures/rules';
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
