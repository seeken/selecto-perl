use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Domain::QueryContract;

open my $fh, '<:raw', 't/fixtures/capability_policy.json' or die $!;
my $fixtures = JSON::PP->new->utf8->decode(do {local $/; <$fh>});
close $fh;
my $valid = $fixtures->{D041}{governed_domain};
my $invalid = $fixtures->{D042}{invalid_domain};
sub codes { [sort map { $_->{code} } @{$_[0]{errors}}] }
sub caught { my ($run) = @_; my $ok = eval {$run->(); 1}; return $ok ? undef : $@ }
my $before = dclone($valid);
my $report = Selecto::Domain->validate_capability_policy($valid);
ok($report->{valid}, 'complete original governed declaration validates');
is_deeply($report->{errors}, [], 'original registry and references have no errors');
is_deeply($valid, $before, 'all original authored sections remain unchanged');
my @missing = qw(action_capability_not_found choice_source_capability_not_found
 detail_action_capability_not_found filter_capability_not_found function_capability_not_found
 published_view_capability_not_found query_member_capability_not_found);
is_deeply(codes(Selecto::Domain->validate_capability_policy($invalid)), \@missing,
 'whole original invalid declaration produces all seven independent errors');

my @references = (
 [filters => 'state', 'filter'], [functions => 'normalize_title', 'function'],
 [published_views => 'manager_rollup', 'published_view'], [detail_actions => 'profile', 'detail_action'],
 [choice_sources => 'owner_choices', 'choice_source'], [actions => 'archive', 'action'],
 map { ['query_members', $_, (sort keys %{$valid->{query_members}{$_}})[0], 'query_member'] }
 qw(ctes values subqueries laterals unnests)
);
for my $reference (@references) {
    my @path = @$reference;
    my $family = pop @path;
    my $label = join '.', @path;
    my $copy = dclone($valid);
    my $entry = $copy;
    $entry = $entry->{$_} for @path;
    $entry->{capability} = 'new.actual.capability';
    my $result = Selecto::Domain->validate_capability_policy($copy);
    is_deeply(codes($result), ["${family}_capability_not_found"], "$label checks actual declaration lookup");
    is_deeply($result->{errors}[0]{path}, [@path, 'capability'], "$label error identifies full reference location");
    $copy->{capabilities}{'new.actual.capability'} = {operations => ['select']};
    ok(Selecto::Domain->validate_capability_policy($copy)->{valid}, "$label resolves newly declared capability");
    $entry->{capability} = JSON::PP::true;
    is_deeply(codes(Selecto::Domain->validate_capability_policy($copy)), ["invalid_${family}_capability"],
        "$label rejects boolean reference without laundering it into an identifier");
    delete $entry->{capability};
    ok(Selecto::Domain->validate_capability_policy($copy)->{valid}, "$label permits omitted optional reference");
    $entry->{capability} = undef;
    ok(Selecto::Domain->validate_capability_policy($copy)->{valid}, "$label permits null optional reference");
}
for my $control (
 ['registry list', sub {$_[0]{capabilities}=[]}, 'invalid_section_shape'],
 ['registry null', sub {$_[0]{capabilities}=undef}, 'invalid_section_shape'],
 ['entry list', sub {$_[0]{capabilities}{'work_items.read'}=[]}, 'invalid_section_shape'],
 ['missing operations', sub {delete $_[0]{capabilities}{'work_items.read'}{operations}}, 'capability_missing_operations'],
 ['null operations', sub {$_[0]{capabilities}{'work_items.read'}{operations}=undef}, 'capability_missing_operations'],
 ['empty operations', sub {$_[0]{capabilities}{'work_items.read'}{operations}=[]}, 'capability_empty_operations'],
 ['scalar operations', sub {$_[0]{capabilities}{'work_items.read'}{operations}='select'}, 'invalid_capability_operations'],
 ['numeric operation', sub {$_[0]{capabilities}{'work_items.read'}{operations}=[2]}, 'invalid_capability_operation'],
 ['boolean operation', sub {$_[0]{capabilities}{'work_items.read'}{operations}=[JSON::PP::false]}, 'invalid_capability_operation'],
 ['object operation', sub {$_[0]{capabilities}{'work_items.read'}{operations}=[{}]}, 'invalid_capability_operation'],
 ['malformed reference section', sub {$_[0]{detail_actions}=[]}, 'invalid_section_shape'],
 ['malformed reference entry', sub {$_[0]{actions}{archive}=[]}, 'invalid_section_shape'],
 ['malformed member group', sub {$_[0]{query_members}{values}=[]}, 'invalid_section_shape'],
) {
    my ($label, $edit, $code) = @$control;
    my $copy = dclone($valid); $edit->($copy);
    my $result = Selecto::Domain->validate_capability_policy($copy);
    ok(!$result->{valid} && grep($_ eq $code, @{codes($result)}), "$label has a real diagnostic");
}
my $numeric = JSON::PP->new->decode(q({"capabilities":{"2":{"operations":["2"]}},"actions":{"run":{"capability":2}}}));
is_deeply(codes(Selecto::Domain->validate_capability_policy($numeric)), ['invalid_action_capability'],
 'numeric JSON reference remains numeric even when a matching string registry key exists');
$numeric->{actions}{run}{capability} = '2';
ok(Selecto::Domain->validate_capability_policy($numeric)->{valid}, 'authored numeric-looking strings remain valid strings');
my $field = dclone($valid); $field->{source}{columns}{private_metric}{capability} = 'external.field.policy';
ok(Selecto::Domain->validate_capability_policy($field)->{valid}, 'bounded validator does not invent field authorization policy');
my ($projected) = grep {$_->{id} eq 'private_metric'} @{Selecto::Domain->project($field, 'query_contract')->{fields}};
is($projected->{capability}, 'external.field.policy', 'existing public field projection preserves authored policy metadata');
my $fresh_flag = Selecto::Domain->validate_capability_policy($valid);
${$fresh_flag->{valid}} = 0;
ok(Selecto::Domain->validate_capability_policy($valid)->{valid}, 'returned boolean flags are isolated');

my $calls = 0;
{package CapabilityEvil; use overload '""'=>sub{$calls++;'evil'}, 'bool'=>sub{$calls++;1}, fallback=>1;
 sub STORABLE_freeze {$calls++;die 'hook'} sub TO_JSON {$calls++;die 'hook'} sub isa {$calls++;1}}
for my $bad (sub {$calls++}, bless({}, 'CapabilityEvil'), bless({}, '0')) {
    my $copy = dclone($valid); $copy->{unrelated_extension} = $bad;
    my $error = caught(sub {Selecto::Domain->validate_capability_policy($copy)});
    is(ref($error) ? $error->code : 'none', 'invalid_query_contract', 'whole declaration refuses executable/object metadata before copy');
}
{package CapabilityTied; sub TIEHASH {bless {},shift} sub FIRSTKEY {$calls++;die 'tie'} sub FETCH {$calls++;die 'tie'}}
tie my %tied, 'CapabilityTied';
my $tied_error = caught(sub {Selecto::Domain->validate_capability_policy(\%tied)});
is(ref($tied_error) ? $tied_error->code : 'none', 'invalid_query_contract', 'tied root is refused before enumeration');
is($calls, 0, 'no callback, resolver, serializer, overload or tied hook executes');
for my $control (qw(cycle depth breadth bytes alias)) {
    my $copy = dclone($valid);
    if ($control eq 'cycle') {$copy->{extension}=$copy}
    elsif ($control eq 'depth') {my $n={};$copy->{extension}=$n;for(1..70){$n->{next}={};$n=$n->{next}}}
    elsif ($control eq 'breadth') {$copy->{extension}=[(1)x10001]}
    elsif ($control eq 'bytes') {$copy->{extension}='x'x131073}
    else {my $n=['leaf'];for(1..14){$n=[$n,$n]}$copy->{extension}=$n}
    my $error = caught(sub {Selecto::Domain->validate_capability_policy($copy)});
    is(ref($error) ? $error->code : 'none', 'invalid_query_contract', "$control is bounded before semantic processing");
}
my $long_id = 'x'x4096;
my $amplified = {capabilities => {$long_id => {operations => [(undef)x40]}}};
is_deeply(Selecto::Domain::QueryContract->copy_declaration($amplified), $amplified, 'compact diagnostic amplification input fits admission');
my $error = caught(sub {Selecto::Domain->validate_capability_policy($amplified)});
is(ref($error) ? $error->code : 'none', 'invalid_capability_policy', 'generated diagnostic bytes are bounded before accumulating repeated long paths');
done_testing;
