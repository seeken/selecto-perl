use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use B ();
use Storable qw(dclone);
use Selecto::DataRules;
use Selecto::Limits;

sub contract {
    my ($test, %binding) = @_;
    return {schema => 'selecto.data_rules.v1', definitions => {rule => {version => 1, test => $test}},
        normalizers => {}, bindings => {rule => {subject => {scope => 'input', path => ['value']},
            rule => {id => 'rule', version => 1}, %binding}}};
}
sub evaluate {
    my ($test, $value, %binding) = @_;
    my $result = eval {Selecto::DataRules->parse(contract($test, %binding))->evaluate(stage => 'input',
        subject => {value => $value})};
    return $result // {state => 'error', code => ref($@) && $@->can('code') ? $@->code : "$@"};
}
my @cases = (
    [{op => 'presence.required'}, undef], [{op => 'presence.non_null'}, 0],
    [{op => 'type.is', type => 'boolean'}, JSON::PP::false],
    [{op => 'text.nonblank'}, ' é '], [{op => 'text.length', exact => 2}, 'é😀'],
    [{op => 'text.pattern', profile => 'ascii_v1', pattern => '(a|ab)+', match => 'full', flags => []}, 'aba'],
    [{op => 'text.prefix', text => 'é'}, 'éx'], [{op => 'text.suffix', text => 'é'}, 'xé'],
    [{op => 'text.contains', text => 'é'}, 'xéx'],
    [{op => 'number.gt', bound => '900719925474099312344'}, '900719925474099312345'],
    [{op => 'number.gte', bound => '0.10'}, '0.1'], [{op => 'number.lt', bound => '0.2'}, '0.1'],
    [{op => 'number.lte', bound => '0.10'}, '0.1'],
    [{op => 'number.range', min => '0.1', max => '0.3', include_min => JSON::PP::false, include_max => JSON::PP::true}, '0.3'],
    [{op => 'number.integer'}, '900719925474099312345.0'],
    [{op => 'number.multiple_of', factor => '0.1'}, '0.3'],
    [{op => 'membership.in', values => [undef, JSON::PP::false, {a => [1, '1']}]}, {a => [1, '1']}],
    [{op => 'membership.not_in', values => [1]}, '1'],
    [{op => 'collection.count', exact => '2'}, [0, undef]],
    [{op => 'collection.sum', path => ['n'], exact => '0.3'}, [{n => '0.1'}, {n => '0.2'}]],
    [{op => 'collection.unique_by', paths => [['a']]}, [{a => 1}, {a => '1'}]],
    [{op => 'value.eq', value => undef}, undef], [{op => 'value.neq', value => 1}, '1'],
    [{op => 'all', rules => [{op => 'number.gt', bound => '0'}, {op => 'number.integer'}]}, 1],
    [{op => 'any', rules => [{op => 'presence.absent'}, {op => 'value.eq', value => 0}]}, 0],
    [{op => 'not', rule => {op => 'presence.absent'}}, undef],
);
for my $case (@cases) { is evaluate(@$case)->{state}, 'passed', "portable $case->[0]{op} passes its exact native case" }
is(Selecto::DataRules->parse(contract({op => 'presence.absent'}))->evaluate(stage => 'input', subject => {})->{state},
    'passed', 'known missing is distinct from null');
is evaluate({op => 'presence.absent'}, undef)->{state}, 'failed', 'explicit null is present';
is evaluate({op => 'number.multiple_of', factor => '0.2'}, '0.3')->{code}, 'not_multiple', 'decimal remainder stays exact';
is evaluate({op => 'collection.sum', path => ['n'], exact => '900719925474099312345.3'},
    [{n => '900719925474099312345.1'}, {n => '0.2'}])->{state}, 'passed', 'sum preserves integers beyond floating precision';
is evaluate({op => 'value.eq', value => JSON::PP::false}, 0)->{state}, 'failed', 'Boolean is distinct from numeric zero';
is evaluate({op => 'type.is', type => 'integer'}, '1')->{code}, 'invalid_type', 'type predicates do not coerce numeric text';
is evaluate({op => 'type.is', type => 'decimal'}, '0.1')->{code}, 'invalid_type', 'exact decimal subject text remains text for type.is';
is evaluate({op => 'type.is', type => 'decimal'}, 0.1)->{state}, 'passed', 'native numeric subject has decimal kind';
is evaluate({op => 'number.gt', bound => '0'}, 1e-100)->{state}, 'passed', 'native numeric exponent retains bounded exact decimal semantics';
is evaluate({op => 'type.is', type => 'integer'}, 1e20)->{state}, 'passed', 'native integral numeric exponent stays numeric';
is evaluate({op => 'number.gt', bound => 0.1}, 1)->{code}, 'invalid_data_rules_contract', 'binary float operand refused';
for my $wire ('9007199254740992', '9223372036854775807', '-9223372036854775808', '18446744073709551615') {
    my $value = JSON::PP->new->decode($wire);
    ok(B::svref_2object(\$value)->FLAGS & B::SVp_IOK(), 'wide operand is an actual native IV/UV');
    is evaluate({op => 'number.gte', bound => $value}, $value)->{state}, 'passed', 'native exact wide number bound evaluates';
    is evaluate({op => 'text.length', max => $value}, 'x')->{state}, 'passed', 'native exact wide length bound evaluates' unless $wire =~ /^-/;
    is evaluate({op => 'membership.in', values => [$value]}, $value)->{state}, 'passed', 'native exact wide membership literal evaluates';
    is evaluate({op => 'membership.in', values => [{nested => [$value]}]}, {nested => [$value]})->{state}, 'passed', 'recursive native wide membership literal evaluates';
}
my $below = JSON::PP->new->decode('9007199254740992');
my $above = JSON::PP->new->decode('9007199254740993');
is evaluate({op => 'number.gt', bound => $below}, $above)->{state}, 'passed', 'adjacent wide native integers never round together';
for my $wire ('1.0', '1.25') {
    for my $form (qw(number length member nested)) {
        my $value = JSON::PP->new->decode($wire);
        my $flags = B::svref_2object(\$value)->FLAGS;
        ok(($flags & B::SVp_NOK()) && !($flags & B::SVp_IOK()), 'direct RuleTest receives actual NOK-only float');
        my $test = $form eq 'number' ? {op => 'number.gte', bound => $value}
            : $form eq 'length' ? {op => 'text.length', max => $value}
            : {op => 'membership.in', values => [$form eq 'member' ? $value : {nested => [$value]}]};
        my $ok = eval {Selecto::RuleTest->compile($test, Selecto::Limits->new);1};
        is !$ok && ref($@) eq 'Selecto::Error' ? $@->code : undef, 'invalid_data_rules_contract',
            'direct delivered float literal is refused before any generic DataRules clone';
    }
}
for my $value ((1 == 1), (1 == 2), JSON::PP::true, JSON::PP::false) {
    is evaluate({op => 'number.gte', bound => $value}, 2)->{code}, 'invalid_data_rules_contract', 'native/JSON Boolean is not a numeric operand';
    is evaluate({op => 'text.length', max => $value}, 'x')->{code}, 'invalid_data_rules_contract', 'native/JSON Boolean is not a numeric count';
    is evaluate({op => 'number.gte', bound => 0}, $value)->{state}, 'failed', 'native/JSON Boolean is not a numeric runtime subject';
}
my $dual_decimal = '1.0'; my $observation = 0 + $dual_decimal;
is evaluate({op => 'number.gte', bound => $dual_decimal}, 1)->{state}, 'passed', 'observed decimal POK text remains an exact operand';
my $wide_limited = eval { Selecto::DataRules->parse(contract({op => 'number.gte', bound => $above}),
    limits => Selecto::Limits->new(max_rule_numeric_digits => 10));1 };
ok !$wide_limited, 'exact native integers do not bypass trusted numeric digit ceiling';
is evaluate({op => 'number.gt', bound => '0'}, 0, enforcement => 'advisory')->{state}, 'passed', 'ordinary advisory failure stays advisory';

for my $probe (
    ['text.nfc', {profile => 'unicode_nfc_v1'}, "A\x{30a}", 'Å'],
    ['text.line_endings', {}, "A\r\nB\rC", "A\nB\nC"],
    ['text.empty_to_null', {}, '', undef],
    ['text.trim', {profile => 'ascii_v1'}, ' a ', 'a'],
    ['text.uppercase', {profile => 'ascii_v1'}, 'a', 'A'],
    ['text.lowercase', {profile => 'ascii_v1'}, 'A', 'a']) {
    my $raw = contract({op => 'value.eq', value => $probe->[3]},
        normalizer => {id => 'normalize', version => 1}, condition => {op => 'presence.required'});
    $raw->{normalizers}{normalize} = {version => 1, steps => [{op => $probe->[0], %{$probe->[1]}}]};
    my $result = eval {Selecto::DataRules->parse($raw)->evaluate(stage => 'input', subject => {value => $probe->[2]})};
    is $result ? $result->{state} : ref($@) && $@->can('code') ? $@->code : "$@", 'passed', "$probe->[0] runs before condition and rule";
    is_deeply $result->{normalized}, {value => $probe->[3]}, "$probe->[0] has exact normalized output" if $result;
}
my $heavy = {op => 'text.pattern', profile => 'ascii_v1', pattern => '(a|b|c|d|e|f|g|h|i|j)*z', match => 'full', flags => []};
for my $test (
    {op => 'any', rules => [{op => 'presence.required'}, ($heavy) x 20]},
    {op => 'all', rules => [{op => 'presence.absent'}, ($heavy) x 20]},
    {op => 'not', rule => {op => 'any', rules => [($heavy) x 20]}}) {
    is evaluate($test, 'a' x 4096, enforcement => 'advisory')->{code}, 'evaluation_limit', 'logical advisory resource error cannot be negated or short-circuited';
    is evaluate({op => 'presence.required'}, 'a' x 4096, enforcement => 'advisory', condition => $test)->{code}, 'evaluation_limit', 'advisory condition retains resource failure';
}
my $normalizer = contract({op => 'presence.required'}, enforcement => 'advisory',
    normalizer => {id => 'trim', version => 1}, condition => {op => 'presence.absent'});
$normalizer->{normalizers}{trim} = {version => 1, steps => [({op => 'text.trim', profile => 'ascii_v1'}) x 250]};
$normalizer->{bindings}{second} = dclone($normalizer->{bindings}{rule});
$normalizer->{bindings}{second}{subject}{path} = ['second'];
is(Selecto::DataRules->parse($normalizer)->evaluate(stage => 'input', subject => {value => 'a' x 4096, second => 'b' x 4096})->{code},
    'evaluation_limit', 'normalizer bindings share one work budget before false conditions');
for my $stage (qw(transaction evidence)) {
    for my $enforcement (qw(required advisory)) {
        my $unavailable = contract({op => 'presence.required'}, enforcement => $enforcement,
            normalizer => {id => 'trim', version => 1}, condition => {op => 'presence.absent'});
        $unavailable->{bindings}{rule}{subject}{scope} = $stage;
        $unavailable->{normalizers}{trim} = {version => 1, steps => [({op => 'text.trim', profile => 'ascii_v1'}) x 700]};
        is(Selecto::DataRules->parse($unavailable)->evaluate(stage => $stage, subject => {value => 'a' x 4000})->{code},
            'evaluation_limit', "$enforcement unavailable $stage cannot conceal resource error");
    }
}
my $early_failure = dclone($normalizer);
$early_failure->{bindings}{aaa} = {subject => {scope => 'input', path => ['missing']}, rule => {id => 'rule', version => 1}};
is(Selecto::DataRules->parse($early_failure)->evaluate(stage => 'input', subject => {value => 'a' x 4096, second => 'b' x 4096})->{code},
    'evaluation_limit', 'early required failure cannot hide remaining shared normalizer resource error');
my $expansion = contract({op => 'presence.required'}, normalizer => {id => 'nfc', version => 1});
$expansion->{normalizers}{nfc} = {version => 1, steps => [{op => 'text.nfc', profile => 'unicode_nfc_v1'}]};
is(Selecto::DataRules->parse($expansion)->evaluate(stage => 'input', subject => {value => "\x{344}" x 2048})->{code},
    'evaluation_limit', 'NFC expansion rechecks the output byte ceiling');
for my $invalid ({op => 'all', rules => []}, {op => 'number.range', min => '2', max => '1'},
    {op => 'number.multiple_of', factor => '0'}, {op => 'value.eq'},
    {op => 'collection.sum', path => [], min => '0'}, {op => 'presence.required', extra => 1},
    {op => 'text.pattern', profile => 'ascii_v1', pattern => 'a', match => 'full'}) {
    ok evaluate($invalid, 1)->{state} eq 'error', 'strict malformed AST refuses compilation';
}
for my $message ({unknown => 'no'}, {key => ''}, {default => []}) {
    my $raw = contract({op => 'presence.required'});
    $raw->{definitions}{rule}{message} = $message;
    ok !eval {Selecto::DataRules->parse($raw); 1}, 'closed message metadata refuses malformed input';
}
for my $request ({stage => 'unknown'}, {stage => 'input', operation => 'unknown'}, {stage => 'action_input'}) {
    eval {Selecto::DataRules->parse(contract({op => 'presence.required'}))->evaluate(%$request, subject => {})};
    is ref($@) && $@->can('code') ? $@->code : "$@", 'invalid_data_rules_request', 'invalid semantic evaluation request refuses';
}
my $authored = contract({op => 'value.eq', value => 'original'}, condition => {op => 'presence.required'});
my $owned = Selecto::DataRules->parse($authored);
$authored->{definitions}{rule}{test}{value} = 'forged';
is $owned->evaluate(stage => 'input', subject => {value => 'original'})->{state}, 'passed', 'compiled definition owns its admitted AST';
$authored = contract({op => 'value.eq', value => 'blocked'}, condition => {op => 'value.eq', value => 'original'});
$owned = Selecto::DataRules->parse($authored);
$authored->{bindings}{rule}{condition}{value} = 'forged';
is $owned->evaluate(stage => 'input', subject => {value => 'original'})->{state}, 'failed', 'caller mutation cannot switch off the compiled condition';
done_testing;
