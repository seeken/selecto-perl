use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;

my $fixtures = do { open my $fh, '<:raw', 't/fixtures/source_relationships.json' or die $!; local $/; JSON::PP->new->utf8->decode(<$fh>) };
my $original = $fixtures->{D043}{governed_domain};
my $before = dclone($original);
sub caught { my ($run) = @_; my $ok = eval { $run->(); 1 }; return $ok ? undef : $@; }
sub codes { my ($domain) = @_; return [sort map { $_->{code} } @{Selecto::Domain->validate_source_relationships($domain)->{errors}}]; }
sub contains { my ($domain, $code) = @_; return scalar grep { $_ eq $code } @{codes($domain)}; }

ok(Selecto::Domain->validate_source_relationships($original)->{valid}, 'complete original governed declaration validates');
is_deeply(Selecto::Domain->project_source_relationships($original), [{id=>'owner',target_domain=>'users',source_field=>'owner_id',target_field=>'id',source_path=>'owners',filters_count=>1,virtual_join_count=>0}], 'canonical original D043 descriptor comes from public API');
is_deeply(codes($fixtures->{D044}{invalid_domain}), [qw(invalid_source_relationship_source_path source_relationship_source_field_not_found)], 'whole original D044 yields both exact diagnostic codes');
my $error = caught(sub { Selecto::Domain->project_source_relationships($fixtures->{D044}{invalid_domain}) });
is(ref($error) ? $error->code : '', 'invalid_source_relationships', 'projection refuses malformed relationships');
is_deeply(Selecto::Domain->project($original,'query_contract')->{source_relationships}, $original->{source_relationships}, 'existing raw query-contract projection remains available');
is_deeply($original, $before, 'public metadata APIs preserve complete original declaration');

my $changed = dclone($original);
$changed->{source_relationships}{owner} = {target_domain=>'teams',source_field=>'title',target_field=>'team_key',source_path=>'teams.members',filters=>[['and',[['eq','teams.active',JSON::PP::true],['not',['in','teams.kind',['a','b']]]]]],virtual_join=>[{working_field=>'owner.name',source_field=>'members.name',required=>JSON::PP::false}]};
my $projection = Selecto::Domain->project_source_relationships($changed);
is_deeply($projection,[{id=>'owner',target_domain=>'teams',source_field=>'title',target_field=>'team_key',source_path=>'teams.members',filters_count=>1,virtual_join_count=>1}], 'every projected value follows changed declarations and nested filters validate');
$projection->[0]{target_domain}='mutated';
is($changed->{source_relationships}{owner}{target_domain},'teams','returned descriptor is independent');
$changed->{source_relationships}{alpha}=dclone($changed->{source_relationships}{owner});
is_deeply([map{$_->{id}}@{Selecto::Domain->project_source_relationships($changed)}],[qw(alpha owner)],'relationship ids sort deterministically');

for my $field ('owner_id','owners.name','owner.name','title_key') {
 my$c=dclone($original);$c->{source_relationships}{owner}{source_field}=$field;
 ok(Selecto::Domain->validate_source_relationships($c)->{valid},"field resolution accepts declared $field");
}
my$c=dclone($original);$c->{joins}{ghost}={};$c->{source_relationships}{owner}{source_field}='ghost.name';
ok(contains($c,'source_relationship_source_field_not_found'),'raw join without declared association cannot manufacture a field');
$c=dclone($original);$c->{source}{associations}{owner}{queryable}='missing';$c->{source_relationships}{owner}{source_field}='owner.name';
ok(contains($c,'source_relationship_source_field_not_found'),'missing actual association target cannot resolve joined field');
$c={source=>{columns=>{id=>{type=>'integer'}},associations=>{first=>{queryable=>'a'}}},schemas=>{a=>{columns=>{id=>{type=>'integer'}},associations=>{next=>{queryable=>'b'}}},b=>{columns=>{name=>{type=>'string'}}}},joins=>{first=>{joins=>{next=>{}}}},source_relationships=>{r=>{target_domain=>'other',source_field=>'first.next.name',target_field=>'name'}}};
ok(Selecto::Domain->validate_source_relationships($c)->{valid},'nested aliases preserve the complete declared join path');
$c->{source_relationships}{r}{source_field}='next.name';
ok(Selecto::Domain->validate_source_relationships($c)->{valid},'unique declared nested join retains established local alias');
delete $c->{schemas}{a}{associations}{next};
ok(contains($c,'source_relationship_source_field_not_found'),'undeclared nested association cannot manufacture a local alias');
$c={source=>{columns=>{id=>{type=>'integer'}},associations=>{first=>{queryable=>'a'},other=>{queryable=>'a'}}},schemas=>{a=>{columns=>{id=>{type=>'integer'}},associations=>{next=>{queryable=>'b'}}},b=>{columns=>{name=>{type=>'string'}}},first=>{columns=>{secret=>{type=>'string'}}},next=>{columns=>{secret=>{type=>'string'}}}},joins=>{first=>{joins=>{next=>{}}}},source_relationships=>{r=>{target_domain=>'other',source_field=>'first.secret',target_field=>'name'}}};
ok(contains($c,'source_relationship_source_field_not_found'),'same-name schema cannot supply a missing full join field');
$c->{source_relationships}{r}{source_field}='next.secret';
ok(contains($c,'source_relationship_source_field_not_found'),'same-name schema cannot supply a missing local join field');
$c->{joins}{other}={joins=>{next=>{}}};$c->{source_relationships}{r}{source_field}='next.name';
ok(contains($c,'source_relationship_source_field_not_found'),'ambiguous local join cannot supply a field');
$c->{source_relationships}{r}{source_field}='next.secret';
ok(contains($c,'source_relationship_source_field_not_found'),'ambiguous local join cannot fall through to a coincident schema');
$c->{source_relationships}{r}{source_field}='other.next.name';
ok(Selecto::Domain->validate_source_relationships($c)->{valid},'complete actual path remains valid despite ambiguous shorthand');
$c->{custom_columns}{'next.custom'}={};$c->{source_relationships}{r}{source_field}='next.custom';
ok(contains($c,'source_relationship_source_field_not_found'),'ambiguous local join cannot fall through to a custom field');
$c->{custom_columns}{'first.custom'}={};$c->{source_relationships}{r}{source_field}='first.custom';
ok(contains($c,'source_relationship_source_field_not_found'),'full join namespace cannot fall through to a custom field');
$c->{source}{columns}{'first.custom'}={type=>'string'};
ok(Selecto::Domain->validate_source_relationships($c)->{valid},'actual root field retains priority over same-name join namespace');
$c={source=>{columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{manager=>{queryable=>'source'}}},schemas=>{source=>{columns=>{shadow=>{type=>'string'}}}},joins=>{manager=>{}},source_relationships=>{r=>{target_domain=>'people',source_field=>'manager.name',target_field=>'name'}}};
ok(Selecto::Domain->validate_source_relationships($c)->{valid},'explicit source self-association resolves actual root fields');
$c->{source_relationships}{r}{source_field}='manager.shadow';
ok(contains($c,'source_relationship_source_field_not_found'),'schema named source cannot replace an explicit source self-association');

for my $control (
 ['section',sub{$_[0]{source_relationships}=[]},'invalid_section_shape'],
 ['entry',sub{$_[0]{source_relationships}{owner}=[]},'invalid_section_shape'],
 ['missing target',sub{delete $_[0]{source_relationships}{owner}{target_field}},'source_relationship_missing_required_keys'],
 ['target object',sub{$_[0]{source_relationships}{owner}{target_domain}={}},'invalid_source_relationship_target_domain'],
 ['numeric target',sub{$_[0]{source_relationships}{owner}{target_domain}=7},'invalid_source_relationship_target_domain'],
 ['source object',sub{$_[0]{source_relationships}{owner}{source_field}={}},'invalid_source_relationship_source_field'],
 ['missing source',sub{$_[0]{source_relationships}{owner}{source_field}='missing'},'source_relationship_source_field_not_found'],
 ['empty path',sub{$_[0]{source_relationships}{owner}{source_path}=''},'invalid_source_relationship_source_path'],
 ['leading dot',sub{$_[0]{source_relationships}{owner}{source_path}='.owners'},'invalid_source_relationship_source_path'],
 ['trailing dot',sub{$_[0]{source_relationships}{owner}{source_path}='owners.'},'invalid_source_relationship_source_path'],
 ['double dot',sub{$_[0]{source_relationships}{owner}{source_path}='owners..active'},'invalid_source_relationship_source_path'],
 ['numeric path',sub{$_[0]{source_relationships}{owner}{source_path}=7},'invalid_source_relationship_source_path'],
 ['virtual list',sub{$_[0]{source_relationships}{owner}{virtual_join}={}},'invalid_source_relationship_virtual_join'],
 ['virtual entry',sub{$_[0]{source_relationships}{owner}{virtual_join}=[[]]},'invalid_source_relationship_virtual_join_entry'],
 ['virtual keys',sub{$_[0]{source_relationships}{owner}{virtual_join}=[{}]},'source_relationship_virtual_join_missing_required_keys'],
 ['virtual working field',sub{$_[0]{source_relationships}{owner}{virtual_join}=[{working_field=>'missing',source_field=>'remote.id'}]},'source_relationship_virtual_join_working_field_not_found'],
 ['virtual working type',sub{$_[0]{source_relationships}{owner}{virtual_join}=[{working_field=>[],source_field=>'remote.id'}]},'invalid_source_relationship_virtual_join_working_field'],
 ['virtual source path',sub{$_[0]{source_relationships}{owner}{virtual_join}=[{working_field=>'id',source_field=>'remote..id'}]},'invalid_source_relationship_virtual_join_source_field'],
 ['virtual required',sub{$_[0]{source_relationships}{owner}{virtual_join}=[{working_field=>'id',source_field=>'remote.id',required=>1}]},'invalid_source_relationship_virtual_join_required'],
 ['filter list',sub{$_[0]{source_relationships}{owner}{filters}={}},'invalid_source_relationship_filters'],
 ['filter expression',sub{$_[0]{source_relationships}{owner}{filters}=[{}]},'invalid_source_relationship_filter_expression'],
 ['filter op',sub{$_[0]{source_relationships}{owner}{filters}=[['unknown','remote.id',1]]},'invalid_source_relationship_filter_operator'],
 ['filter path',sub{$_[0]{source_relationships}{owner}{filters}=[['eq','.bad',1]]},'invalid_source_relationship_filter_path'],
 ['filter operands',sub{$_[0]{source_relationships}{owner}{filters}=[['and',{}]]},'invalid_source_relationship_filter_operands'],
 ['filter arity',sub{$_[0]{source_relationships}{owner}{filters}=[['eq','remote.id']]},'invalid_source_relationship_filter_operands'],
 ['nested filter',sub{$_[0]{source_relationships}{owner}{filters}=[['not',['or',[['eq','remote..id',1]]]]]},'invalid_source_relationship_filter_path'],
) {
 my($label,$edit,$code)=@$control;my$bad=dclone($original);$edit->($bad);
 ok(contains($bad,$code),"$label produces structured $code");
 my$e=caught(sub{Selecto::Domain->project_source_relationships($bad)});
 is(ref($e)?$e->code:'','invalid_source_relationships',"$label cannot project as valid");
}
for my $op (qw(eq neq not_eq gt gte lt lte like case_insensitive_like contains starts_with ends_with between in not_in text_search match_against array_contains array_contained array_overlap array_eq)) {
 my$d=dclone($original);$d->{source_relationships}{owner}{filters}=[[$op,'remote.value',1]];
 ok(Selecto::Domain->validate_source_relationships($d)->{valid},"declared $op static operator is recognized");
}
$c=dclone($original);$c->{source_relationships}{owner}{source_path}=undef;$c->{source_relationships}{owner}{filters}=undef;$c->{source_relationships}{owner}{virtual_join}=undef;
is_deeply(Selecto::Domain->project_source_relationships($c)->[0],{id=>'owner',target_domain=>'users',source_field=>'owner_id',target_field=>'id',source_path=>undef,filters_count=>0,virtual_join_count=>0},'optional null metadata follows portable contract');
is_deeply(Selecto::Domain->project_source_relationships({}),[],'missing registry projects an empty list');
for my$capability ('work_items.read', undef) {
 my$d=dclone($original);$d->{source_relationships}{owner}{capability}=$capability;
 ok(Selecto::Domain->validate_source_relationships($d)->{valid},'declared or optional null relationship capability validates');
}
$c=dclone($original);$c->{source_relationships}{owner}{capability}='missing';
ok(contains($c,'source_relationship_capability_not_found'),'unknown relationship capability fails closed');
is_deeply(Selecto::Domain->validate_source_relationships($c)->{errors}[0]{path},['source_relationships','owner','capability'],'capability error identifies actual relationship path');
$c->{capabilities}{missing}={};
ok(Selecto::Domain->validate_source_relationships($c)->{valid},'declaring referenced capability repairs actual validation');
for my$bad (7,JSON::PP::true,[],{}) {
 $c=dclone($original);$c->{source_relationships}{owner}{capability}=$bad;
 ok(contains($c,'invalid_source_relationship_capability'),'non-string relationship capability fails closed');
}

my$calls=0;
{package RelationshipEvil;use overload '""'=>sub{$calls++;'evil'},'bool'=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub STORABLE_freeze{$calls++;die'callback'}sub TO_JSON{$calls++;die'callback'}}
{package RelationshipTied;sub TIEHASH{bless{},shift}sub FIRSTKEY{$calls++;die'tied hook'}sub FETCH{$calls++;die'tied hook'}}
{package RelationshipScalar;sub TIESCALAR{bless{},shift}sub FETCH{$calls++;die'tied scalar'}}
for my$bad(sub{$calls++},bless({},'RelationshipEvil'),bless({},'0')) {
 my$d=dclone($original);$d->{unrelated_extension}=$bad;
 for my$method(qw(validate_source_relationships project_source_relationships)) {
  my$e=caught(sub{Selecto::Domain->$method($d)});
  is(ref($e)?$e->code:'','invalid_query_contract',"$method refuses executable/object metadata anywhere in complete input");
 }
}
tie my%tied,'RelationshipTied';
for my$method(qw(validate_source_relationships project_source_relationships)) {
 my$e=caught(sub{Selecto::Domain->$method(\%tied)});
 is(ref($e)?$e->code:'','invalid_query_contract',"$method refuses tied root before inspection");
}
$c=dclone($original);tie $c->{source_relationships}{owner}{source_path},'RelationshipScalar';
$error=caught(sub{Selecto::Domain->validate_source_relationships($c)});
is(ref($error)?$error->code:'','invalid_query_contract','tied nested scalar refuses before FETCH');
is($calls,0,'callbacks, overloads, getter/clone hooks and tied FETCH never execute');
for my$kind(qw(cycle depth breadth bytes alias)) {
 my$d=dclone($original);
 if($kind eq'cycle'){$d->{extension}=$d}
 elsif($kind eq'depth'){my$n={};$d->{extension}=$n;for(1..70){$n->{next}={};$n=$n->{next}}}
 elsif($kind eq'breadth'){$d->{extension}=[(1)x10001]}
 elsif($kind eq'bytes'){$d->{extension}='x'x131073}
 else{my$n=['leaf'];for(1..14){$n=[$n,$n]}$d->{extension}=$n}
 $error=caught(sub{Selecto::Domain->validate_source_relationships($d)});
 is(ref($error)?$error->code:'','invalid_query_contract',"$kind exceeds bounded complete-input admission");
}
my$long='x'x4096;
$c={source_relationships=>{$long=>{target_domain=>'target',source_field=>'missing',target_field=>'id',virtual_join=>[map{{working_field=>'missing',source_field=>'bad..path'}}1..100]}}};
$error=caught(sub{Selecto::Domain->validate_source_relationships($c)});
is(ref($error)?$error->code:'','invalid_source_relationships','repeated diagnostic paths are charged before output amplification');
$c={schemas=>{$long=>{columns=>{map{("f$_"=>{type=>'integer'})}1..40}}}};
$error=caught(sub{Selecto::Domain->validate_source_relationships($c)});
is(ref($error)?$error->code:'','invalid_source_relationships','generated schema prefixes are charged before concatenation amplification');
my$r=Selecto::Domain->validate_source_relationships($original);${$r->{valid}}=0;
ok(Selecto::Domain->validate_source_relationships($original)->{valid},'returned valid Boolean has independent storage');
is_deeply($original,$before,'all controls preserve complete original domain');
done_testing;
