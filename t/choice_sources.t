use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Domain::Choices;
use Selecto::Domain::StaticFilters;

sub read_json { open my$f,'<:raw',$_[0] or die$!;local$/;JSON::PP->new->utf8->decode(<$f>) }
sub caught {my($run)=@_;my$ok=eval{$run->();1};$ok?undef:$@}
sub code {ref($_[0])&&UNIVERSAL::isa($_[0],'Selecto::Error')?$_[0]->code:'none'}
my$f=read_json('t/fixtures/choice_sources.json');
my$expected=read_json('t/fixtures/choice_sources_expected.json');
my$before=dclone($f);my$d=$f->{D045}{governed_domain};my$api='Selecto::Domain::Choices';
sub has_code {my($domain,$wanted)=@_;scalar grep{$_->{code}eq$wanted}@{Selecto::Domain->validate_choice_sources($domain)->{errors}}}

ok(Selecto::Domain->validate_choice_sources($d)->{valid},'whole original governed domain validates');
my$b=$api->binding($d,$f->{D045}{field});
my$r=$api->request($d,$f->{D045}{field},$f->{D045}{value},{tenant=>$f->{D045}{tenant},context=>$f->{D045}{context}});
is_deeply({binding_kind=>$b->{binding_kind},map{$_=>$r->{$_}}qw(choice_source field source_relationship tenant constraint_policy constraint_filters)},$expected->{D045},'unchanged D045 whole-fixture public binding and request');
$r=$api->options_request($f->{D046}{governed_domain},$f->{D046}{field},{map{$_=>$f->{D046}{$_}}qw(tenant context search limit offset)});
is_deeply({map({$_=>$r->{$_}}qw(choice_source search limit offset tenant)),request_order_by=>$r->{order_by},declared_order_by=>$r->{choice_source_config}{order_by}},$expected->{D046},'unchanged D046 options request');
my@decisions;
for my$a(@{$f->{D047}{attempts}}){
 my$resolver;
 if($a->{decision}){my$status=$a->{decision}{status};$resolver=sub{$api->$status($a->{decision}{reason})}}
 my$result=$api->validate_choice($f->{D047}{governed_domain},$f->{D047}{field},$a->{value},{},$resolver);
 push@decisions,{status=>$result->status,reason=>$result->reason_code};
}
is_deeply(\@decisions,$expected->{D047},'unchanged D047 resolver-required and explicit provider outcomes');
is_deeply($f,$before,'all three complete original fixtures remain unchanged');

my$c=dclone($d);delete$c->{source}{columns}{owner_id}{reference};
is($api->binding($c,'owner_id')->{binding_kind},'choice_source','compact binding remains supported');
$c->{source}{columns}{owner_id}{reference}={choice_source=>'state_choices',caption_field=>'owner.name'};
is($api->binding($c,'owner_id')->{choice_source},'state_choices','rich reference takes precedence over compact binding');
$c->{columns}{owner_id}={choice_source=>'state_choices',reference=>{choice_source=>'owner_choices'},label=>'Projected owner'};
$b=$api->binding($c,'owner_id');
is($b->{column}{label},'Projected owner','projection presentation merges into actual source column');
is($b->{choice_source},'owner_choices','projected rich reference takes precedence after shallow merge');
$b->{column}{label}='changed';is($c->{columns}{owner_id}{label},'Projected owner','binding metadata is independent');
$c->{columns}{only_projection}={reference=>{choice_source=>'state_choices'}};
is($api->binding($c,'only_projection')->{choice_source},'state_choices','explicit projection-only binding remains supported');
is(code(caught(sub{$api->binding($d,'missing')})),'field_not_found','missing field refuses');
is(code(caught(sub{$api->binding($d,'title')})),'field_choice_source_not_bound','unbound field refuses');
is(code(caught(sub{$api->binding($d,7)})),'invalid_choice_field','numeric field is not a string identity');
is($api->binding({schema_version=>1,authored_domain=>$d,domain=>$d},'owner_id')->{choice_source},'owner_choices','normalized portable wrapper validates and resolves actual domain');

$c=dclone($d);$c->{schemas}{owners}{columns}{name}{choice_source}='owner_choices';
is($api->binding($c,'owners.name')->{choice_source},'owner_choices','direct schema-qualified binding');
is($api->binding($c,'owner.name')->{choice_source},'owner_choices','actual declared join alias binding');
is_deeply($api->binding($c,'owner.name')->{path},['schemas','owners','columns','name'],'alias binding path names actual authored column origin');
$c->{schemas}{owner}=dclone($c->{schemas}{owners});$c->{schemas}{owner}{columns}{name}{choice_source}='state_choices';
is($api->binding($c,'owner.name')->{choice_source},'owner_choices','actual association target outranks same-name unjoined schema');
$c->{schemas}{owner}{columns}{fake}={choice_source=>'state_choices',type=>'string'};push@{$c->{schemas}{owner}{fields}},'fake';
$c->{columns}{'owner.fake'}={choice_source=>'state_choices'};
is(code(caught(sub{$api->binding($c,'owner.fake')})),'field_not_found','recognized actual join namespace cannot fall through to schema or projection');
my$caption_collision=dclone($c);$caption_collision->{source}{columns}{owner_id}{reference}{caption_field}='owner.fake';
ok(has_code($caption_collision,'field_reference_caption_field_not_found'),'caption field lookup shares actual alias namespace authority');
$c->{schemas}{owners}{associations}{next}={queryable=>'owners',owner_key=>'id',related_key=>'id'};
$c->{joins}{owner}{joins}{next}={type=>'left'};
is($api->binding($c,'owner.next.name')->{choice_source},'owner_choices','complete nested alias resolves actual target');
is($api->binding($c,'next.name')->{choice_source},'owner_choices','unique established local nested alias resolves actual target');
$c->{source}{associations}{other}={queryable=>'owners',owner_key=>'owner_id',related_key=>'id'};
$c->{joins}{other}={type=>'left',joins=>{next=>{type=>'left'}}};
$c->{schemas}{next}=dclone($c->{schemas}{owner});$c->{columns}{'next.name'}={choice_source=>'state_choices'};
is(code(caught(sub{$api->binding($c,'next.name')})),'field_not_found','ambiguous nested shorthand cannot take a coincident schema or projection binding');
is($api->binding($c,'other.next.name')->{choice_source},'owner_choices','full path remains available when local alias is ambiguous');
$c->{source}{associations}{next}={queryable=>'owner',owner_key=>'owner_id',related_key=>'id'};$c->{joins}{next}={type=>'left'};
is($api->binding($c,'next.name')->{choice_source},'state_choices','explicit top-level join wins over nested local alias');
delete$c->{schemas}{owners}{associations}{next};
is(code(caught(sub{$api->binding($c,'owner.next.name')})),'field_not_found','raw nested join without actual association cannot manufacture a field');
$c=dclone($d);$c->{source}{associations}{manager}={queryable=>'source',owner_key=>'id',related_key=>'id'};$c->{joins}{manager}={type=>'left'};
$c->{schemas}{source}=dclone($c->{schemas}{owners});$c->{schemas}{source}{columns}{name}{choice_source}='state_choices';
is($api->binding($c,'manager.owner_id')->{choice_source},'owner_choices','explicit source self-association uses actual root columns');
is_deeply($api->binding($c,'manager.owner_id')->{path},['source','columns','owner_id'],'self-association binding path names actual root column origin');
is(code(caught(sub{$api->binding($c,'manager.name')})),'field_not_found','schema named source cannot replace self-association target');

my$attrs={actor=>{id=>8},tenant=>9,record=>{id=>11},context=>{tenant_id=>9},metadata=>{trace=>'t'},filters=>[['eq','users.region','west']],constraint_policy=>{domain_of_interest=>'best_effort',choice_source=>'fail_closed',unknown=>'fail_closed'}};
$r=$api->request($d,'owner_id',99,$attrs);
is_deeply([@{$r}{qw(value actor tenant record context metadata)}],[99,@{$attrs}{qw(actor tenant record context metadata)}],'request preserves all host input metadata');
is_deeply($r->{constraint_filters}{domain_of_interest},$attrs->{filters},'host filters occupy their own declared constraint bundle');
is_deeply($r->{constraint_filters}{choice_source},$d->{choice_sources}{owner_choices}{filters},'choice filters preserve context placeholders as inert metadata');
is_deeply($r->{constraint_filters}{source_relationship},$d->{source_relationships}{owner}{filters},'relationship filters preserve actual declarations');
is_deeply($r->{constraint_policy},{domain_of_interest=>'best_effort',choice_source=>'fail_closed'},'trusted request policy overrides supported declared modes and drops unknown keys');
$r->{context}{tenant_id}=22;$r->{choice_source_config}{filters}=[];
is($attrs->{context}{tenant_id},9,'request does not mutate host attributes');
is(scalar@{$d->{choice_sources}{owner_choices}{filters}},1,'request config does not mutate declarations');
$r=$api->choice_source_options_request($d,'owner_choices',{search=>'Bo',limit=>3,offset=>2,cursor=>{after=>7},order_by=>[['users.name','desc']]});
is_deeply([@{$r}{qw(field search limit offset cursor order_by)}],[undef,'Bo',3,2,{after=>7},[['users.name','desc']]],'direct choice source supports paging cursor and request ordering');
$r=$api->options_request($d,'owner_id');
is_deeply([@{$r}{qw(search limit offset order_by)}],[undef,undef,0,[]],'optional options defaults');
is($api->options_request($d,'owner_id',{order_by=>[{custom=>'provider ordering'}]})->{order_by}[0]{custom},'provider ordering','request ordering follows highest list-only contract');
for my$bad ([search=>7],[limit=>0],[limit=>-1],[limit=>'2'],[limit=>2.5],[limit=>JSON::PP::true],[offset=>-1],[offset=>'2'],[offset=>1.2],[order_by=>{}],[context=>[]],[metadata=>[]],[record=>[]],[filters=>{}]){
 my($key,$value)=@$bad;is(code(caught(sub{$api->options_request($d,'owner_id',{$key=>$value})})),'invalid_choice_request',"invalid options $key type/range refuses");
}
is(code(caught(sub{$api->options_request($d,'owner_id',{by=>'remote'})})),'invalid_options_request_target','unsupported target mode refuses');
is(code(caught(sub{$api->choice_source_options_request($d,'absent')})),'choice_source_not_found','undeclared direct choice source refuses');

for my$control(
 ['registry shape',sub{$_[0]{choice_sources}=[]},'invalid_section_shape'],
 ['entry shape',sub{$_[0]{choice_sources}{owner_choices}=[]},'invalid_section_shape'],
 ['required presence',sub{delete $_[0]{choice_sources}{owner_choices}{domain}},'choice_source_missing_required_keys'],
 ['domain type',sub{$_[0]{choice_sources}{owner_choices}{domain}=7},'invalid_choice_source_domain'],
 ['value field type',sub{$_[0]{choice_sources}{owner_choices}{value_field}=[]},'invalid_choice_source_value_field'],
 ['label field type',sub{$_[0]{choice_sources}{owner_choices}{label_field}=JSON::PP::true},'invalid_choice_source_label_field'],
 ['source path',sub{$_[0]{choice_sources}{owner_choices}{source_path}='bad..path'},'invalid_choice_source_source_path'],
 ['value path',sub{$_[0]{choice_sources}{owner_choices}{value_source}='.bad'},'invalid_choice_source_value_source'],
 ['caption path',sub{$_[0]{choice_sources}{owner_choices}{caption_source}='bad.'},'invalid_choice_source_caption_source'],
 ['description path',sub{$_[0]{choice_sources}{owner_choices}{description_source}=7},'invalid_choice_source_description_source'],
 ['filters shape',sub{$_[0]{choice_sources}{owner_choices}{filters}={}},'invalid_choice_source_filters'],
 ['filter expression',sub{$_[0]{choice_sources}{owner_choices}{filters}=[{}]},'invalid_choice_source_filter_expression'],
 ['filter operator',sub{$_[0]{choice_sources}{owner_choices}{filters}=[['unknown','id',1]]},'invalid_choice_source_filter_operator'],
 ['filter operands',sub{$_[0]{choice_sources}{owner_choices}{filters}=[['and',{}]]},'invalid_choice_source_filter_operands'],
 ['filter nested path',sub{$_[0]{choice_sources}{owner_choices}{filters}=[['not',['or',[['eq','bad..id',1]]]]]},'invalid_choice_source_filter_path'],
 ['order list',sub{$_[0]{choice_sources}{owner_choices}{order_by}={}},'invalid_choice_source_order_by'],
 ['order entry',sub{$_[0]{choice_sources}{owner_choices}{order_by}=[['bad..id','asc']]},'invalid_choice_source_order_by_entry'],
 ['order direction',sub{$_[0]{choice_sources}{owner_choices}{order_by}=[['id','sideways']]},'invalid_choice_source_order_by_direction'],
 ['presentation',sub{$_[0]{choice_sources}{owner_choices}{presentation}=[]},'invalid_choice_source_presentation'],
 ['control',sub{$_[0]{choice_sources}{owner_choices}{presentation}{control}='dropdown'},'invalid_choice_source_presentation_control'],
 ['mode',sub{$_[0]{choice_sources}{owner_choices}{presentation}{mode}='remote'},'invalid_choice_source_presentation_mode'],
 ['cardinality',sub{$_[0]{choice_sources}{owner_choices}{presentation}{cardinality}='zero'},'invalid_choice_source_presentation_cardinality'],
 ['constraint policy',sub{$_[0]{choice_sources}{owner_choices}{constraint_policy}=[]},'invalid_choice_source_constraint_policy'],
 ['policy key',sub{$_[0]{choice_sources}{owner_choices}{constraint_policy}{other}='fail_closed'},'invalid_choice_source_constraint_policy_key'],
 ['policy mode',sub{$_[0]{choice_sources}{owner_choices}{constraint_policy}{choice_source}='permit'},'invalid_choice_source_constraint_policy_mode'],
 ['relationship type',sub{$_[0]{choice_sources}{owner_choices}{source_relationship}=7},'invalid_choice_source_relationship'],
 ['relationship missing',sub{$_[0]{choice_sources}{owner_choices}{source_relationship}='absent'},'choice_source_relationship_not_found'],
 ['capability type',sub{$_[0]{choice_sources}{owner_choices}{capability}=[]},'invalid_choice_source_capability'],
 ['capability missing',sub{$_[0]{choice_sources}{owner_choices}{capability}='absent'},'choice_source_capability_not_found'],
 ['compact reference type',sub{$_[0]{source}{columns}{owner_id}{choice_source}=7},'invalid_field_choice_source'],
 ['compact reference missing',sub{$_[0]{source}{columns}{owner_id}{choice_source}='absent'},'field_choice_source_not_found'],
 ['rich reference shape',sub{$_[0]{source}{columns}{owner_id}{reference}=[]},'invalid_field_reference'],
 ['rich reference type',sub{$_[0]{source}{columns}{owner_id}{reference}{choice_source}=JSON::PP::true},'invalid_field_reference_choice_source'],
 ['rich reference missing',sub{$_[0]{source}{columns}{owner_id}{reference}{choice_source}='absent'},'field_reference_choice_source_not_found'],
 ['reference value source',sub{$_[0]{source}{columns}{owner_id}{reference}{value_source}=[]},'invalid_field_reference_value_source'],
 ['reference caption source',sub{$_[0]{source}{columns}{owner_id}{reference}{caption_source}=7},'invalid_field_reference_caption_source'],
 ['reference caption field type',sub{$_[0]{source}{columns}{owner_id}{reference}{caption_field}=JSON::PP::false},'invalid_field_reference_caption_field'],
 ['reference caption field missing',sub{$_[0]{source}{columns}{owner_id}{reference}{caption_field}='absent'},'field_reference_caption_field_not_found'],
 ['complete schema invalid',sub{$_[0]{source}{readonly}=1},'invalid_readonly'],
 ['complete relationship invalid',sub{$_[0]{source_relationships}{owner}{source_path}='bad..path'},'invalid_source_relationship_source_path'],
){my($name,$edit,$wanted)=@$control;my$x=dclone($d);$edit->($x);ok(has_code($x,$wanted),"$name yields $wanted");is(code(caught(sub{$api->binding($x,'owner_id')})),'invalid_domain_contract',"$name cannot produce a binding");}
for my$op(qw(eq neq not_eq gt gte lt lte like case_insensitive_like contains starts_with ends_with between in not_in text_search match_against array_contains array_contained array_overlap array_eq)){
 $c=dclone($d);$c->{choice_sources}{owner_choices}{filters}=[[$op,'users.id',1],[$op,'users.id',1,2]];
 ok(Selecto::Domain->validate_choice_sources($c)->{valid},"portable $op three/four-item provider metadata");
}
$c=dclone($d);$c->{choice_sources}{owner_choices}{filters}=[['and',[]],['or',[]],['not',['eq','users.id',['context','id']]]];
ok(Selecto::Domain->validate_choice_sources($c)->{valid},'empty logical lists and inert context placeholders follow highest contract');
$c=dclone($d);@{$c->{choice_sources}{owner_choices}}{qw(domain value_field label_field)}=(undef,undef,undef);
ok(Selecto::Domain->validate_choice_sources($c)->{valid},'required presence retains explicit null semantics of highest metadata contract');
$c=dclone($d);$c->{source}{columns}{owner_id}{reference}{caption_source}='remote..inert';
ok(Selecto::Domain->validate_choice_sources($c)->{valid},'reference source hints are string identities rather than choice path grammar');
my$long='x'x4096;
$c=dclone($d);$c->{choice_sources}{$long}={domain=>'remote',value_field=>'id',label_field=>'name',filters=>[map{['eq','remote.id',$_]}1..100]};
ok(Selecto::Domain->validate_choice_sources($c)->{valid},'valid many filters do not repeatedly copy a long owner identifier');
$c->{choice_sources}{$long}{filters}=[map{['eq','bad..path',$_]}1..100];
is(code(caught(sub{Selecto::Domain->validate_choice_sources($c)})),'invalid_choice_sources','repeated invalid paths cannot amplify long identifiers in diagnostics');

my$calls=0;
{package ChoiceEvil;use overload '""'=>sub{$calls++;'evil'},bool=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub TO_JSON{$calls++;die'callback'}sub STORABLE_freeze{$calls++;die'callback'}}
{package ChoiceTie;sub TIEHASH{bless{},shift}sub TIESCALAR{bless{},shift}sub FETCH{$calls++;die'callback'}sub FIRSTKEY{$calls++;die'callback'}}
for my$bad(sub{$calls++},bless({},'ChoiceEvil'),bless({},'0')){
 $c=dclone($d);$c->{unrelated_extension}=$bad;
 is(code(caught(sub{$api->binding($c,'owner_id')})),'invalid_query_contract','complete declaration rejects callbacks and objects before interpretation');
 is(code(caught(sub{$api->request($d,'owner_id',1,{extension=>$bad})})),'invalid_query_contract','complete host metadata rejects executable values');
}
tie my%tied,'ChoiceTie';
is(code(caught(sub{$api->binding(\%tied,'owner_id')})),'invalid_query_contract','tied root refuses without FETCH');
$c=dclone($d);tie$c->{choice_sources}{owner_choices}{domain},'ChoiceTie';
is(code(caught(sub{Selecto::Domain->validate_choice_sources($c)})),'invalid_query_contract','tied nested identity refuses without FETCH');
is($calls,0,'no callback, overload or tied hook ran during metadata admission');
for my$kind(qw(cycle depth breadth bytes repeated_aliases)){
 $c=dclone($d);
 if($kind eq'cycle'){$c->{extension}=$c}
 elsif($kind eq'depth'){my$n={};$c->{extension}=$n;for(1..70){$n->{child}={};$n=$n->{child}}}
 elsif($kind eq'breadth'){$c->{extension}=[(1)x10001]}
 elsif($kind eq'bytes'){$c->{extension}='x'x131073}
 else{my$n=['leaf'];$n=[$n,$n]for 1..14;$c->{extension}=$n}
 is(code(caught(sub{$api->binding($c,'owner_id')})),'invalid_query_contract',"$kind has bounded complete-input admission");
}
my$report=Selecto::Domain->validate_choice_sources($d);${$report->{valid}}=0;
ok(Selecto::Domain->validate_choice_sources($d)->{valid},'returned valid flag has independent Boolean storage');
is_deeply($f,$before,'all controls preserve complete original fixtures');
done_testing;
