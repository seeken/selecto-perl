use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Selecto::Error;
use Selecto::Limits;
use Selecto::DataRules;
use Selecto::Write::FieldValidators;

my $FV = 'Selecto::Write::FieldValidators';
sub specs { return {value => {validators => $_[0]}} }
sub validates { return $FV->validate_values(specs($_[0]), {value => $_[1]}) }
sub error {
    my ($code, $work, $label) = @_;
    my $ok = eval { $work->(); 1 }; my $caught = $@;
    ok(!$ok && ref($caught) eq 'Selecto::Error', "$label: typed refusal");
    is(ref($caught) eq 'Selecto::Error' ? $caught->code : undef, $code, "$label: code");
    return $caught;
}

subtest 'number translates every comparison and conjunction' => sub {
    my $validators = [['number', [[greater_than => '1.25'], [greater_than_or_equal_to => 2],
        [less_than => '5.5'], [less_than_or_equal_to => 5]]]];
    is_deeply($FV->compile($validators), [{op => 'all', rules => [
        {op => 'number.gt', bound => '1.25'}, {op => 'number.gte', bound => 2},
        {op => 'number.lt', bound => '5.5'}, {op => 'number.lte', bound => 5}]}], 'all four options compiled');
    is_deeply(validates($validators, 3), {value => 3}, 'all comparisons pass');
    error('data_rule_failed', sub { validates($validators, 1) }, 'lower boundary');
    error('data_rule_failed', sub { validates($validators, 6) }, 'upper boundary');
    is_deeply(validates([['number', [[greater_than => 0], [greater_than => 2]]]], 3), {value => 3}, 'duplicate number comparisons all retained');
    error('data_rule_failed', sub { validates([['number', [[greater_than => 0], [greater_than => 2]]]], 1) }, 'duplicate number comparisons not last-wins');
    for my $bad ([], [[unknown => 1]], [[greater_than => 1.5]], [[greater_than => 'not-a-number']], [[greater_than => '1e2']], [[greater_than => 9007199254740992]]) {
        error('unsupported_write_rule', sub { $FV->compile([['number', $bad]]) }, 'bad number declaration');
    }
};
subtest 'length uses Unicode scalars and exact highest duplicate behavior' => sub {
    my $validators = [['length', [[min => 9], [min => 2], [max => 4]]]];
    is_deeply($FV->compile($validators), [{op => 'text.length', unit => 'unicode_scalar', min => 2, max => 4}], 'length duplicate last wins');
    is_deeply(validates($validators, "é😀"), {value => "é😀"}, 'decoded multibyte scalars count as two');
    is_deeply(validates([['length', [[is => 2], [is => 1]]]], 'x'), {value => 'x'}, 'exact duplicate last wins');
    error('data_rule_failed', sub { validates($validators, 'x') }, 'too short');
    for my $bad ([], [[is => 2], [min => 1]], [[min => 4], [max => 2]], [[min => -1]], [[min => '2']], [[min => 1.5]], [[unknown => 2]]) {
        error('unsupported_write_rule', sub { $FV->compile([['length', $bad]]) }, 'bad length declaration');
    }
};
subtest 'native integer and floating bound identity survives scalar spelling' => sub {
    my $integer = JSON::PP->new->decode('1');
    my $float = JSON::PP->new->decode('1.0');
    is_deeply($FV->compile([['number', [[greater_than => $integer]]]]), [{op => 'number.gt', bound => 1}], 'native integer number bound');
    is_deeply($FV->compile([['length', [[min => $integer]]]]), [{op => 'text.length', unit => 'unicode_scalar', min => 1}], 'native integer length bound');
    error('unsupported_write_rule', sub {$FV->compile([['number', [[greater_than => $float]]]])}, 'NOK-only float1.0 is not integer number bound');
    error('unsupported_write_rule', sub {$FV->compile([['length', [[min => $float]]]])}, 'NOK-only float1.0 is not integer length bound');
    my $dual_text = '1'; my $numeric_observation = 0 + $dual_text;
    is($numeric_observation, 1, 'ordinary caller numeric observation');
    error('unsupported_write_rule', sub {$FV->compile([['length', [[min => $dual_text]]]])}, 'dual-flag binary text remains invalid length bound');
    is_deeply($FV->compile([['number', [[greater_than => $dual_text]]]]), [{op => 'number.gt', bound => $dual_text}], 'dual-flag binary text remains a valid number string bound');
    is_deeply($FV->compile([['number', [[greater_than => '1.0']]]]), [{op => 'number.gt', bound => '1.0'}], 'binary decimal bound remains supported');
    my $pattern = '1'; my $pattern_observation = 0 + $pattern;
    is_deeply(validates([['format', {source => $pattern, opts => ''}]], '1'), {value => '1'}, 'observed binary format source remains text');
    my $member = '1'; my $member_observation = 0 + $member;
    error('data_rule_failed', sub { validates([['inclusion', [1]]], $member) }, 'observed binary assignment does not equal numeric member');
    is_deeply(validates([['inclusion', ['1']]], $member), {value => '1'}, 'observed binary assignment equals binary member');
    error('data_rule_failed', sub { validates([['inclusion', [$member]]], 1) }, 'observed binary declared member does not equal numeric assignment');
    is_deeply(validates([['inclusion', [$member]]], '1'), {value => '1'}, 'observed binary declared member equals text assignment');
    is_deeply(validates([['exclusion', [1]]], $member), {value => '1'}, 'observed binary value remains outside numeric exclusion');
    error('data_rule_failed', sub { validates([['exclusion', [$member]]], '1') }, 'observed binary exclusion still excludes equal text');
    is_deeply(validates([['length', [[is => 1]]]], $member), {value => '1'}, 'observed binary length subject remains text');
    is_deeply(validates([['inclusion', [{nested => [$member]}]]], {nested => ['1']}), {value => {nested => ['1']}}, 'nested literal copy preserves binary identity');
};
subtest 'format is a flag-free ascii_v1 full match descriptor' => sub {
    for my $opts ('', []) {
        my $validators = [['format', {source => '[a-z]+[0-9]?', opts => $opts}]];
        is_deeply(validates($validators, 'ada2'), {value => 'ada2'}, 'portable format accepted');
        error('data_rule_failed', sub { validates($validators, 'ADA2') }, 'format rejects changed value');
        error('data_rule_failed', sub { validates($validators, '!ada2!') }, 'format is full match');
    }
    for my $payload ({source => '[a-z]+', opts => 'i'}, {source => '[a-z]+', opts => ['i']},
        {source => 'a', opts => '', extra => 1}, {source => 'a'}, {source => '(?=a)', opts => ''},
        {source => '[', opts => ''}, {source => 'é', opts => ''}, {source => 1, opts => ''}, {source => qr/a/, opts => ''}) {
        error('unsupported_write_rule', sub { $FV->compile([['format', $payload]]) }, 'bad format declaration');
    }
};
subtest 'native comparison booleans retain Boolean identity in every legacy form' => sub {
    my @native = ((1 == 1), (1 == 2));
    my @json = (JSON::PP::true, JSON::PP::false);
    for my $index (0 .. $#native) {
        my $value = $native[$index];
        ok(JSON::PP::is_bool($value), 'actual native comparison scalar is Boolean');
        for my $comparison (qw(greater_than greater_than_or_equal_to less_than less_than_or_equal_to)) {
            error('unsupported_write_rule', sub { $FV->compile([['number', [[$comparison => $value]]]]) }, 'native Boolean number bound');
            error('data_rule_failed', sub { validates([['number', [[$comparison => 0]]]], $value) }, 'native Boolean number subject');
        }
        for my $length (qw(is min max)) {
            error('unsupported_write_rule', sub { $FV->compile([['length', [[$length => $value]]]]) }, 'native Boolean length bound');
        }
        error('data_rule_failed', sub { validates([['length', [[min => 0]]]], $value) }, 'native Boolean length subject');
        error('unsupported_write_rule', sub { $FV->compile([['format', {source => $value, opts => ''}]]) }, 'native Boolean format source');
        error('unsupported_write_rule', sub { $FV->compile([['format', {source => 'x', opts => $value}]]) }, 'native Boolean format opts');
        error('data_rule_failed', sub { validates([['format', {source => '.*', opts => ''}]], $value) }, 'native Boolean format subject');
        my $result = validates([['inclusion', [$json[$index]]]], $value);
        is(JSON::PP->new->canonical->encode($result), $index == 0 ? '{"value":true}' : '{"value":false}', 'native Boolean equals JSON Boolean member');
        my $inverse = validates([['inclusion', [$value]]], $json[$index]);
        is(JSON::PP->new->canonical->encode($inverse), $index == 0 ? '{"value":true}' : '{"value":false}', 'native Boolean declared member equals JSON Boolean subject');
        for my $different (1, 0, '1', '0', '', $json[1 - $index]) {
            error('data_rule_failed', sub { validates([['inclusion', [$different]]], $value) }, 'Boolean differs from numeric/text/opposite member');
            my $outside = validates([['exclusion', [$different]]], $value);
            is(JSON::PP->new->canonical->encode($outside), $index == 0 ? '{"value":true}' : '{"value":false}', 'Boolean remains outside distinct exclusion');
        }
        error('data_rule_failed', sub { validates([['exclusion', [$json[$index]]]], $value) }, 'equal Boolean exclusion');
        my $bundle = $FV->admit(specs([['inclusion', [$value]]]));
        my $tests = $bundle->tests;
        ${$tests->{value}[0]{values}[0]} = $index == 0 ? 0 : 1;
        my $owned = $FV->validate_values($bundle, {value => $value});
        is(JSON::PP->new->canonical->encode($owned), $index == 0 ? '{"value":true}' : '{"value":false}', 'native Boolean inspection clone cannot mutate accepted bundle');
    }
};
subtest 'inclusion and exclusion use portable typed literal equality' => sub {
    my $literal = [undef, JSON::PP::true, 3, '3', {x => [1, 'one']}];
    for my $value (@$literal) {
        is_deeply(validates([['inclusion', $literal]], $value), {value => $value}, 'included typed literal');
        error('data_rule_failed', sub { validates([['exclusion', $literal]], $value) }, 'excluded typed literal');
    }
    is_deeply(validates([['exclusion', [1, 'one']]], 2), {value => 2}, 'nonmember accepted');
    error('data_rule_failed', sub { validates([['inclusion', [3]]], '3') }, 'numeric text remains distinct');
    for my $kind (qw(inclusion exclusion)) {
        error('unsupported_write_rule', sub { $FV->compile([[$kind, []]]) }, 'empty membership');
        error('unsupported_write_rule', sub { $FV->compile([[$kind, {}]]) }, 'membership must be list');
    }
};
subtest 'entire active bundle compiles before any value evaluates' => sub {
    my $specs = {a => {validators => [['number', [[greater_than => 9]]]]}, z => {validators => ['unknown']}};
    error('unsupported_write_rule', sub { $FV->validate_values($specs, {a => 0, z => 1}) }, 'later bad syntax precedes earlier failed value');
    is_deeply($FV->validate_values($specs, {a => 10}), {a => 10}, 'wholly unassigned unknown validator not interpreted');
    my $bundle = $FV->admit($specs, assigned_fields => ['a']);
    is_deeply($FV->validate_values($bundle, {a => 10}), {a => 10}, 'explicit active admission');
    error('unsupported_write_rule', sub { $FV->validate_values($bundle, {a => 10, z => 1}) }, 'newly effective field cannot bypass compilation');
    error('unsupported_write_rule', sub { $FV->admit($specs) }, 'explicit all-field inspection diagnoses unknown');
    error('required_data_rule_pending', sub { $FV->validate_values($specs, {}, nonliteral_fields => ['a']) }, 'active nonliteral pending');
    is_deeply($FV->validate_values({x => {}}, {}, nonliteral_fields => ['x']), {}, 'nonliteral with no validators not consumed');
    is_deeply($FV->validate_values({a => {validators => [['length', [[min => 5]]]]}}, {other => 1}), {other => 1}, 'unassigned invalid stored value does not run');
};
subtest 'plain snapshots and ASTs have independent ownership' => sub {
    my $raw = {value => {validators => [['inclusion', [{x => [1]}, JSON::PP::true]]]}};
    my $bundle = $FV->admit($raw);
    $raw->{value}{validators}[0][1][0]{x}[0] = 99;
    my $tests = $bundle->tests;
    $tests->{value}[0]{values}[0]{x}[0] = 88;
    ${$tests->{value}[0]{values}[1]} = 0;
    is_deeply($FV->validate_values($bundle, {value => {x => [1]}}), {value => {x => [1]}}, 'caller and inspection mutation cannot alter bundle');
    is($bundle->tests->{value}[0]{values}[1] ? 1 : 0, 1, 'Boolean clone is independent');
    my $values = {value => {x => [1]}};
    my $result = $FV->validate_values($bundle, $values);
    $result->{value}{x}[0] = 17;
    is($values->{value}{x}[0], 1, 'result does not mutate input');
    my $forged = bless \(my $identity = undef), 'Selecto::Write::FieldValidators::Bundle';
    error('unsupported_write_rule', sub { $FV->validate_values($forged, {}) }, 'unregistered bundle refused');
};

our $HOOKS = 0;
{
    package Local::TiedHash;
    sub TIEHASH { bless {}, shift } sub FIRSTKEY { ++$main::HOOKS; return }
    sub FETCH { ++$main::HOOKS; return } sub EXISTS { ++$main::HOOKS; return 1 }
    package Local::TiedArray;
    sub TIEARRAY { bless {}, shift } sub FETCHSIZE { ++$main::HOOKS; return 1 }
    sub FETCH { ++$main::HOOKS; return 'bad' }
    package Local::TiedScalar;
    sub TIESCALAR { bless {}, shift } sub FETCH { ++$main::HOOKS; return 'bad' }
    package Local::Executable;
    use overload '""' => sub { ++$main::HOOKS; 'bad' }, bool => sub { ++$main::HOOKS; 1 }, fallback => 1;
    sub STORABLE_freeze { ++$main::HOOKS; return }
}
subtest 'callback-free recursive admission including inactive policy and slots' => sub {
    tie my %hash, 'Local::TiedHash'; tie my @array, 'Local::TiedArray';
    my %slot = (value => undef); tie $slot{value}, 'Local::TiedScalar';
    my @slot = (undef); tie $slot[0], 'Local::TiedScalar';
    my $class0 = bless {}, '0';
    my $object = bless {}, 'Local::Executable';
    my $cyclic = {}; $cyclic->{next} = $cyclic;
    for my $bad (\%hash, \@array, \%slot, \@slot, $object, $class0, sub { ++$HOOKS }, $cyclic, qr/x/) {
        $HOOKS = 0;
        error('unsupported_write_rule', sub { $FV->prepare_contract({writes => {fields => {inactive => {validators => [$bad]}}}}) }, 'nested bad plain shape');
        is($HOOKS, 0, 'no callback/overload/tied fetch');
    }
    $HOOKS = 0;
    error('unsupported_write_rule', sub { $FV->admit({value => {}}, fields => \@array) }, 'tied selection');
    is($HOOKS, 0, 'selection no tied hooks');
    $HOOKS = 0;
    error('unsupported_write_rule', sub { $FV->validate_values({value => {}}, {value => $object}) }, 'assignment object');
    is($HOOKS, 0, 'assignment no object hooks');
    tie my $root, 'Local::TiedScalar';
    my @root_probes = (
        sub { $FV->admit($root) }, sub { $FV->compile($root) }, sub { $FV->prepare_contract($root) },
        sub { $FV->admit_domain($root) }, sub { $FV->validate_values($root, {}) },
        sub { $FV->validate_values({}, $root) }, sub { $FV->evaluate({}, $root) },
    );
    for my $probe (@root_probes) {
        $HOOKS = 0;
        error('unsupported_write_rule', $probe, 'direct tied root scalar');
        is($HOOKS, 0, 'root scalar no FETCH before admission');
    }
    my $domain = {writes => {fields => {a => {validators => ['unknown']}}}};
    is_deeply($FV->admit_domain($domain), $domain, 'plain admission does not interpret inactive semantic syntax');
};
subtest 'one cumulative work budget covers bundles, scopes, and canonical rules' => sub {
    my $small = Selecto::Limits->new(max_rule_work => 80);
    my $once = sub { $FV->validate_values(specs([]), {value => 'x'}, limits => $small) };
    $once->(); $once->(); pass('separate public calls start fresh');
    error('evaluation_limit', sub { $FV->with_budget(sub { $once->() for 1 .. 5 }, limits => $small) }, 'bundles share scope');
    error('evaluation_limit', sub { $FV->with_budget(sub {
        $FV->with_budget($once, limits => Selecto::Limits->new) for 1 .. 5;
    }, limits => $small) }, 'nested scopes cannot reset or widen');
    $once->(); pass('failed scope restores next independent request');
    my $rules = Selecto::DataRules->parse({schema => 'selecto.data_rules.v1', definitions => {
        text => {version => 1, test => {op => 'text.length', min => 1}}}, normalizers => {}, bindings => {
        text => {subject => {scope => 'input', path => ['value']}, rule => {id => 'text', version => 1}}}});
    my $limits = Selecto::Limits->new(max_rule_work => 1000);
    $FV->with_budget(sub {
        my ($work) = Selecto::DataRules->_rule_work_context($limits);
        my $before = $$work;
        $FV->validate_values(specs([['length', [[min => 1]]]]), {value => 'x'}, limits => $limits);
        cmp_ok($$work, '>', $before, 'validator charges actual protected counter');
        my $after = $$work;
        my $result = $rules->evaluate(stage => 'input', subject => {value => 'x'}, limits => $limits);
        is($result->{state}, 'passed', 'canonical rule still evaluates');
        cmp_ok($$work, '>', $after, 'canonical rule charges same counter');
    }, limits => $limits);
    error('evaluation_limit', sub { $FV->prepare_contract({a => 'x' x 20}, limits => Selecto::Limits->new(max_state_bytes => 10)) }, 'admission bytes');
    error('evaluation_limit', sub { $FV->prepare_contract({a => [1,2,3]}, limits => Selecto::Limits->new(max_expression_nodes => 3)) }, 'admission occurrences');
    error('unsupported_write_rule', sub { $FV->compile([['number', [[greater_than => '1' x 30]]]], limits => Selecto::Limits->new(max_rule_numeric_digits => 10)) }, 'numeric declaration exceeds admitted numeric grammar');
};

done_testing;
