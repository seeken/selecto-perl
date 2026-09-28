use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Action;

my $action = {
    inputs => {
        complete => {type => 'boolean', required => 1, default => JSON::PP::false},
        note => {type => 'string', required => 1},
    },
    variants => [
        {id => 'ready', when => {complete => JSON::PP::true},
            inputs => {note => {type => 'string', required => 0}}},
        {id => 'follow_up', when => {complete => JSON::PP::false},
            inputs => {reason => {type => 'string', required => 1}}},
    ],
};
my $copy = dclone($action);
my $form = Selecto::Action->input_form($action, {});
is $form->{variant}, 'follow_up', 'false default selects a variant without other required fields';
ok $form->{inputs}{reason}{required}, 'selected variant includes its required inputs';
$form = Selecto::Action->input_form($action, {complete => 'true'});
is $form->{variant}, 'ready', 'form selector uses the planner boolean normalization';
ok !$form->{inputs}{note}{required}, 'variant can override a base field requirement';
ok !exists($form->{inputs}{reason}), 'inactive input is absent';
is_deeply $action, $copy, 'form discovery does not mutate the contract';

sub error_code {
    my ($spec, $values) = @_;
    eval { Selecto::Action->input_form($spec, $values); 1 };
    return ref($@) ? $@->code : "$@";
}
is error_code($action, {complete => 'maybe'}), 'invalid_action_input', 'bad selector rejected';
my $ambiguous = dclone($action);
$ambiguous->{variants}[1]{when} = {complete => JSON::PP::true};
is error_code($ambiguous, {complete => 1}), 'ambiguous_action_variant', 'ambiguous selection rejected';
is error_code($ambiguous, {complete => 0}), 'action_variant_not_found', 'no match rejected';
my $bad = dclone($action);
$bad->{variants}[0]{inputs}{complete} = {type => 'string'};
is error_code($bad, {complete => 1}), 'invalid_action_variant', 'selector override rejected';
$bad = dclone($action);
$bad->{variants}[0]{when} = {undeclared => 1};
is error_code($bad, {}), 'invalid_action_variant', 'undeclared selector rejected';
$bad = dclone($action);
$bad->{variants}[0]{id} = 'follow_up';
is error_code($bad, {}), 'invalid_action_variant', 'duplicate variant ids rejected';

my $plain = Selecto::Action->input_form({inputs => [{id => 'value', type => 'string', required => 1}]}, {});
is_deeply $plain->{inputs}, {value => {type => 'string', required => 1}}, 'nonvariant partial forms supported';
done_testing;
