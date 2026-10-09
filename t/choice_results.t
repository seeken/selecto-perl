use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain::Choices;
use Selecto::Domain::Choices::Result;
use Selecto::Domain::Choices::OptionsResult;
sub read_json {open my$f,'<:raw',$_[0]or die$!;local$/;JSON::PP->new->utf8->decode(<$f>)}
sub caught {my($run)=@_;my$ok=eval{$run->();1};$ok?undef:$@}
sub code {ref($_[0])&&UNIVERSAL::isa($_[0],'Selecto::Error')?$_[0]->code:'none'}
my$d=read_json('t/fixtures/choice_sources.json')->{D045}{governed_domain};
my$before=dclone($d);my$api='Selecto::Domain::Choices';
my$model='Selecto::Domain::Choices::Result';my$options_model='Selecto::Domain::Choices::OptionsResult';
my$r=$api->validate_choice($d,'owner_id',42);
is_deeply([ $r->status,$r->reason_code,$r->outcome ],[qw(unknown resolver_required error)],'missing provider is unknown');
is($r->request->{value},42,'unknown result retains actual request');
ok(!$api->valid_choice($d,'owner_id',42),'unknown membership is false');
for my$pair([valid=>'choice_valid'],[invalid=>'choice_invalid'],[unknown=>'resolver_required']){
 my($status,$reason)=@$pair;my$x=$api->$status();
 is_deeply([$x->status,$x->reason_code],[$status,$reason],"native $status default");
 ok($model->is_native($x,$model),"$status is a native membership result");
 ok(!$model->is_native($x,$options_model),"$status is not an options result");
}
my$attrs={metadata=>{nested=>['initial']},request=>{field=>'host supplied'},user_message=>'host message'};
$r=$api->valid('accepted',$attrs);
$attrs->{metadata}{nested}[0]='changed';
is($r->as_hash->{metadata}{nested}[0],'initial','constructor owns independent metadata');
my$serialized=$r->as_hash;$serialized->{status}='invalid';$serialized->{metadata}{nested}[0]='changed';
is($r->status,'valid','serialized output cannot rewrite status');
is($r->as_hash->{metadata}{nested}[0],'initial','serialized output cannot rewrite nested metadata');
my$request=$r->request;$request->{field}='changed';is($r->request->{field},'host supplied','request getter owns independent copy');
$$r=999;is($r->status,'valid','public scalar marker cannot alter private decision');
ok(!$model->can('_state'),'no callable mutable state accessor');
$r=$api->validate_choice($d,'owner_id',42,{},sub{my($request)=@_;$request->{value}=99;$request->{context}{changed}=1;return$api->valid('host accepted')});
is($r->request->{value},42,'provider mutation of its copy does not rewrite canonical request');
ok(!exists$r->request->{context}{changed},'provider receives independent nested request');
is($r->reason_code,'host accepted','native host reason preserved');
ok($api->valid_choice($d,'owner_id',42,{},sub{$api->valid}),'native valid membership is true');
ok(!$api->valid_choice($d,'owner_id',42,{},sub{$api->invalid}),'native invalid membership is false');
ok(!$api->valid_choice($d,'owner_id',42,{},sub{$api->unknown}),'native unknown membership is false');
$r=$api->validate_choice($d,'owner_id',42,{},sub{$api->valid('host',{request=>{explicit=>'host request'}})});
is_deeply($r->request,{explicit=>'host request'},'explicit native host request follows highest ensure-result-request behavior');
for my$tag(qw(ok error)){
 $r=$api->validate_choice($d,'owner_id',42,{},sub{[$tag,$api->valid]});
 is($r->outcome,$tag,"native tagged $tag transport is preserved");
 is($api->valid_choice($d,'owner_id',42,{},sub{[$tag,$api->valid]})?1:0,$tag eq'ok'?1:0,"$tag-tagged valid membership preserves Boolean transport semantics");
}
my$exception=caught(sub{$api->validate_choice($d,'owner_id',42,{},sub{die"host failure\n"})});
is($exception,"host failure\n",'trusted provider exceptions propagate');
for my$bad(1,'resolver',{},[]){
 $r=$api->validate_choice($d,'owner_id',42,{},$bad);
 is($r->reason_code,'invalid_resolver','non-CODE provider cannot supply membership');
}
my$marker=0;my$forged=bless\$marker,$model;
my$reblessed=$api->unknown;bless$reblessed,$options_model;
my$calls=0;
{package ResultEvil;use overload '""'=>sub{$calls++;'evil'},bool=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub TO_JSON{$calls++;die'hook'}sub as_hash{$calls++;die'hook'}}
{package ResultTie;sub TIEARRAY{bless{},shift}sub TIEHASH{bless{},shift}sub TIESCALAR{bless{},shift}sub FETCH{$calls++;die'hook'}sub FETCHSIZE{$calls++;die'hook'}sub FIRSTKEY{$calls++;die'hook'}}
tie my@tied_array,'ResultTie';tie my%tied_hash,'ResultTie';
my@tied_element=('ok',$api->valid);tie$tied_element[0],'ResultTie';
for my$bad(undef,{status=>'valid'},$forged,bless({},'ResultEvil'),bless({},'0'),\@tied_array,\%tied_hash,\@tied_element,['ok',{status=>'valid'}],['bad',$api->valid],$api->options_resolved([])){
 $r=$api->validate_choice($d,'owner_id',42,{},sub{$bad});
 is_deeply([$r->status,$r->reason_code],[qw(unknown invalid_resolver_result)],'forged/serialized/malformed/wrong-model provider result refuses');
}
ok(!$model->is_native($reblessed,$options_model),'reblessing a genuine result cannot change its sealed original model');
$r=$api->list_options($d,'owner_id',{},sub{$reblessed});
is($r->reason_code,'invalid_resolver_result','reblessed membership result cannot impersonate native options result');
is(code(caught(sub{$reblessed->as_hash})),'invalid_choice_result','reblessed private state accessor refuses');
is(code(caught(sub{$forged->status})),'invalid_choice_result','forged private state accessor refuses');
is($calls,0,'provider-return admission executes no overload, tied or object hooks');
for my$bad({status=>'resolved'},{status=>7},{status=>JSON::PP::true},{status=>'valid',metadata=>[]},{status=>'valid',request=>[]},{status=>'valid',reason_code=>7},{status=>'valid',user_message=>{}},{status=>'valid',outcome=>'maybe'}){
 is(code(caught(sub{$model->new($bad)})),'invalid_choice_result','native membership constructors validate all typed result fields');
}
for my$bad(sub{$calls++},bless({},'ResultEvil'),bless({},'0')){
 is(code(caught(sub{$api->valid('reason',{unrelated=>$bad})})),'invalid_query_contract','whole result input rejects executable or unknown object metadata');
}
is(code(caught(sub{$api->valid('reason',\%tied_hash)})),'invalid_query_contract','tied result metadata refuses before hooks');
is($calls,0,'result constructors execute no input hooks');
my$cycle={};$cycle->{cycle}=$cycle;
is(code(caught(sub{$api->valid('reason',$cycle)})),'invalid_query_contract','cyclic native result metadata refuses');
is(code(caught(sub{$api->valid('reason',{metadata=>{oversize=>'x'x131073}})})),'invalid_query_contract','oversized native result metadata refuses');

$r=$api->list_options($d,'owner_id');
is_deeply([$r->status,$r->reason_code,$r->options],[qw(unknown resolver_required),[]],'options without provider are unknown and empty');
my$rows=[{value=>42,label=>'Ada'}];
$r=$api->list_options($d,'owner_choices',{by=>'choice_source',search=>'Ada',limit=>1},sub{my($request)=@_;is($request->{search},'Ada','options provider receives actual request');$api->options_resolved($rows,{total_count=>3,next_cursor=>{after=>42},metadata=>{host=>'test'}})});
is_deeply([$r->status,$r->outcome,$r->options,$r->total_count,$r->next_cursor],[qw(resolved ok),[{value=>42,label=>'Ada'}],3,{after=>42}],'native options result preserves full provider output');
$rows->[0]{label}='changed';my$out=$r->options;$out->[0]{label}='changed';my$cursor=$r->next_cursor;$cursor->{after}=99;
is_deeply([$r->options,$r->next_cursor],[[{value=>42,label=>'Ada'}],{after=>42}],'options constructor and getters own independent nested data');
is($r->request->{choice_source},'owner_choices','resolved options attach actual request');
for my$pair([options_unknown=>'unknown'],[options_error=>'error']){
 my($method,$status)=@$pair;my$x=$api->$method('host reason',{metadata=>{source=>'provider'}});
 is_deeply([$x->status,$x->reason_code,$x->options],[$status,'host reason',[]],"native $status options result");
}
for my$bad({status=>'valid'},{status=>'resolved',options=>{}},{status=>'resolved',total_count=>-1},{status=>'resolved',total_count=>'2'},{status=>'resolved',total_count=>1.2},{status=>'resolved',total_count=>JSON::PP::true}){
 is(code(caught(sub{$options_model->new($bad)})),'invalid_choice_result','options constructors validate status/list/typed count');
}
for my$tag(qw(ok error)){
 $r=$api->list_options($d,'owner_id',{},sub{[$tag,$api->options_resolved([])]});
 is($r->outcome,$tag,"options preserve $tag tagged transport");
}
$r=$api->list_options($d,'owner_id',{},sub{$api->valid});
is($r->reason_code,'invalid_resolver_result','membership decision cannot serve as options result');
is_deeply($d,$before,'all result controls preserve complete original domain');
done_testing;
