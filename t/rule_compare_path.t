use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::DataRules;
use Selecto::Limits;

sub rules {
    my ($comparison, %options) = @_;
    my $test = delete($options{test}) // {op => 'value.compare_path', comparison => $comparison, path => ['start']};
    return {schema => 'selecto.data_rules.v1', definitions => {compare => {version => 1, test => $test}},
        normalizers => {}, bindings => {compare => {subject => {scope => 'candidate', path => ['finish']},
            operations => ['upsert'], rule => {id => 'compare', version => 1}, %options}}};
}
sub outcome {
    my ($raw, $subject, %options) = @_;
    return Selecto::DataRules->parse($raw, %options)->evaluate(stage => 'candidate', operation => 'upsert', subject => $subject);
}
for my $case (
    ['gt', 6, 5, 'passed'], ['gte', 5, 5, 'passed'], ['lt', 4, 5, 'passed'], ['lte', 5, 5, 'passed'],
    ['gt', 5, 5, 'failed'], ['eq', 5, 5, 'passed'], ['neq', 4, 5, 'passed'],
    ['eq', '5', 5, 'failed'], ['neq', JSON::PP::true, 1, 'passed'],
    ['eq', undef, undef, 'passed'], ['gt', '9007199254740993.1', '9007199254740993.0', 'passed'],
    ['eq', {x => [1, undef]}, {x => [1, undef]}, 'passed']) {
    my ($op, $finish, $start, $expected) = @$case;
    is(outcome(rules($op), {finish => $finish, start => $start})->{state}, $expected, "$op compares actual root values");
}
is(outcome(rules('gte'), {finish => 5})->{code}, 'missing_related_value', 'absent root value has precise diagnostic');
is(outcome(rules('gte'), {finish => 5, start => undef})->{code}, 'invalid_related_value_type', 'null ordered operand is not numeric');
for my $value (JSON::PP::true, 1.0, 1.25, '1e0', '01') {
    is(outcome(rules('gt'), {finish => $value, start => 0})->{code}, 'invalid_related_value_type', 'ordered comparison rejects nonexact numeric type/grammar');
}
my $native_fraction = unpack('F', pack('F', 1.25));
is(outcome(rules('gt', test => {op => 'type.is', type => 'decimal'}),
    {finish => $native_fraction})->{state}, 'passed', 'generic decimal type test retains native numeric identity');
is(outcome(rules('gt', test => {op => 'type.is', type => 'text'}),
    {finish => $native_fraction})->{state}, 'failed', 'native numeric subject does not become text');
my $nested = rules('gte', test => {op => 'all', rules => [{op => 'presence.non_null'},
    {op => 'not', rule => {op => 'value.compare_path', comparison => 'lt', path => ['bounds', 'minimum']}}]});
is(outcome($nested, {finish => 6, bounds => {minimum => 5}})->{state}, 'passed', 'logical children retain root context and nested path');
my $parsed = Selecto::DataRules->parse($nested);
is_deeply($parsed->consumed_paths('candidate', 'upsert'), [['finish'], ['bounds', 'minimum']], 'root dependency is not prefixed by binding path');
my $condition = rules('gt', condition => {op => 'value.compare_path', comparison => 'eq', path => ['finish']});
is(outcome($condition, {finish => 6, start => 5})->{state}, 'passed', 'condition compares against canonical root subject');
my $normalized = rules('eq');
$normalized->{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
$normalized->{bindings}{compare}{normalizer} = {id => 'trim', version => 1};
is(outcome($normalized, {finish => ' x ', start => 'x'})->{state}, 'passed', 'comparison uses root after current binding normalization');
my $limits = Selecto::Limits->new(max_rule_numeric_digits => 10);
for my $test (
    {op => 'value.compare_path', comparison => 'gt', path => ['start']},
    {op => 'any', rules => [{op => 'presence.required'}, {op => 'value.compare_path', comparison => 'gt', path => ['start']}]},
    {op => 'not', rule => {op => 'value.compare_path', comparison => 'gt', path => ['start']}}) {
    my $raw = rules('gt', test => $test, enforcement => 'advisory', condition => {op => 'presence.absent'});
    is(outcome($raw, {finish => 1, start => '9' x 20}, limits => $limits)->{code}, 'evaluation_limit',
        'related numeric preflight precedes advisory/false/logical branches');
}
for my $bad ({op => 'value.compare_path', comparison => 'wat', path => ['start']},
    {op => 'value.compare_path', comparison => 'gt', path => []},
    {op => 'value.compare_path', comparison => 'gt', path => [{}]},
    {op => 'value.compare_path', comparison => 'gt', path => ['start'], sql => 'escape'}) {
    ok(!eval {Selecto::DataRules->parse(rules('gt', test => $bad));1}, 'malformed comparison declaration refuses');
}
done_testing;
