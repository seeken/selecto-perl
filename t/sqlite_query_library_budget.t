use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use Selecto;
use Selecto::Limits;
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };
my $db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
$db->do('PRAGMA temp_store=MEMORY');$db->do('CREATE TABLE records(id INTEGER PRIMARY KEY,name TEXT)');$db->do(q{INSERT INTO records VALUES(1,'A'),(2,'B')});
my $adapter=Selecto->adapter(sqlite=>dbh=>$db);
sub domain {
 my($depth,$kind)=@_;my$registry={zero=> $kind eq 'segments' ? {filters=>[['gte','id',['param','minimum']]],parameters=>{minimum=>{type=>'integer',required=>1}}} : {fields=>['id']}};
 my$child='zero';for my$i(1..$depth){my$id='n'.$i;$registry->{$id}={$kind=>[$child,$child]};$child=$id}
 return (Selecto::Domain->new(name=>'Records',table=>'records',fields=>{id=>'integer',name=>'string'},query_library=>{$kind=>$registry}),$child);
}
sub caught {my($run)=@_;my$ok=eval{$run->();1};return $ok?undef:$@}
my $events=0;$db->sqlite_set_authorizer(sub{$events++;0});
my($d,$id)=domain(20,'projections');my$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter);
my$q=$e->apply_projection($e->query,$id);
is_deeply([map{$_->arguments->[0]}@{$q->selections}],['id'],'twenty-level shared projection DAG resolves one actual field');
is(scalar(@{$q->applied_query_library->{projections}}),21,'shared projection retains ordered unique provenance');
is_deeply($e->all($q)->{rows},[[1],[2]],'memoized shared projection executes actual native source');
is_deeply(Selecto::QueryLibrary->projection_fields($d,$id),['id'],'public projection introspection uses bounded memoized resolution');
($d,$id)=domain(20,'segments');$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter);
is_deeply(Selecto::QueryLibrary->parameter_specs($d,segments=>[$id]),{minimum=>{type=>'integer',required=>1}},'public parameter inspection does not exponentially revisit shared segment DAG');
$events=0;my$error=caught(sub{$e->apply_segment($e->query->select('id'),$id,{minimum=>1})});
is($error->code,'invalid_query_library','exponentially emitted shared filters refuse at trusted native ceilings');is($events,0,'expanded filter refusal performs no native preparation or execution');
like($error->message,qr/resource limit/,'refusal exposes resource-bound failure');
($d,$id)=domain(3,'segments');$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter);
$q=$e->apply_segment($e->query->select('id'),$id,{minimum=>2});
is_deeply($e->compile($q)->params,[(2)x8],'small repeated references retain all eight authored filter occurrences');
is_deeply($e->all($q)->{rows},[[2]],'small repeated filters retain actual native predicate semantics');
is_deeply($q->applied_query_library->{segments},[qw(zero n1 n2 n3)],'small repeated filters retain unique stable provenance');
my $tight=Selecto::Limits->new(max_expression_arity=>8);
$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter,limits=>$tight);
$q=$e->apply_segment($e->query->select('id'),$id,{minimum=>1});is_deeply($e->compile($q)->params,[(1)x8],'exact trusted emitted-filter arity is admitted');
my $limits=Selecto::Limits->new(max_expression_arity=>7);$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter,limits=>$limits);$events=0;
$error=caught(sub{$e->apply_segment($e->query->select('id'),$id,{minimum=>1})});is($error->code,'invalid_query_library','one-over emitted filter arity refuses before array growth');is($events,0,'one-over emission performs no native work');
($d,$id)=domain(12,'projections');
# Declaration admission fits this trusted bound; repeated merge/provenance work
# is a distinct stage and must consume it cumulatively before result growth.
$limits=Selecto::Limits->new(max_expression_nodes=>200);$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter,limits=>$limits);$events=0;
$error=caught(sub{$e->apply_projection($e->query,$id)});is($error->code,'invalid_query_library','shared acyclic projection merge work has a cumulative bound');is($events,0,'work refusal performs no native work');
$events=0;$error=caught(sub{Selecto::QueryLibrary->projection_fields($d,$id,$limits)});is($error->code,'invalid_query_library','public projection helper enforces the same cumulative trusted bound');is($events,0,'introspection refusal performs no native work');
($d,$id)=domain(5,'segments');
$error=caught(sub{Selecto::QueryLibrary->parameter_specs($d,segments=>[$id],limits=>Selecto::Limits->new(max_expression_nodes=>5))});is($error->code,'invalid_query_library','parameter-spec helper has a cumulative shared-reference work bound');
my $wide=Selecto::Domain->new(name=>'Records',table=>'records',fields=>{id=>'integer'},query_library=>{segments=>{
 one=>{filters=>[['gte','id',['param','minimum']]],parameters=>{minimum=>{type=>'integer',required=>1,description=>('x'x70000)}}},
 two=>{segments=>['one','one']}}});
my $wide_engine=Selecto::Engine->new(domain=>$wide,adapter=>$adapter);$events=0;
$error=caught(sub{$wide_engine->apply_segment($wide_engine->query->select('id'),'two',{minimum=>1})});is($error->code,'invalid_query_library','cumulative copied parameter metadata bytes refuse before repeated dclone/encode growth');is($events,0,'parameter-copy resource refusal performs no native work');
$error=caught(sub{Selecto::QueryLibrary->parameter_specs($wide,segments=>['two'])});is($error->code,'invalid_query_library','returned parameter-spec clone consumes the same cumulative metadata budget');
my $calls=0;
{package LibraryHook;use overload '""'=>sub{$calls++;'hook'},'bool'=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub STORABLE_freeze{$calls++;die 'hook'} }
my $hook=bless {},'LibraryHook';
for my $bad ($hook,sub{$calls++}) {
 my $mutated=Selecto::Domain->new(name=>'Records',table=>'records',fields=>{id=>'integer'});
 $mutated->{query_library}={segments=>{unsafe=>{parameters=>{p=>$bad}}}};$events=0;
 $error=caught(sub{Selecto::QueryLibrary->parameter_specs($mutated,segments=>['unsafe'])});is($error->code,'invalid_query_library','direct public parameter inspection admits metadata before clone/encode hooks');is($events,0,'malformed direct metadata performs no native work');
}
my $malformed={name=>'Records',source=>{table=>'records',fields=>{id=>'integer'}},query_library=>{segments=>{unsafe=>{extra=>$hook}}}};
$error=caught(sub{Selecto::Domain->parse($malformed)});is($error->code,'invalid_query_library','domain parsing refuses hooked library metadata before canonical cloning');
my $cycle={};$cycle->{self}=$cycle;
$error=caught(sub{Selecto::ConfiguredDomain->admit_library($cycle)});is($error->code,'invalid_query_library','plain library admission refuses cycles');
my $false_class=bless {},'0';$error=caught(sub{Selecto::ConfiguredDomain->admit_library($false_class)});is($error->code,'invalid_query_library','false-valued package name remains a blessed reference');
($d,$id)=domain(0,'segments');$e=Selecto::Engine->new(domain=>$d,adapter=>$adapter);$events=0;
$error=caught(sub{$e->apply_segment($e->query->select('id'),$id,{minimum=>$hook})});is($error->code,'invalid_query_library','hooked parameter value refuses before boolean/cast callbacks');is($events,0,'hooked parameter performs no native work');
$error=caught(sub{$e->apply_segment($e->query,$false_class)});is($error->code,'invalid_query_library','false-class selected ID is rejected as a reference');
is($calls,0,'direct library admission invokes no callbacks, overloads, custom isa or serialization hooks');
$db->sqlite_set_authorizer(undef);is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP is memory');is($db->selectall_arrayref('PRAGMA database_list')->[0][2],'','main database is memory');$db->disconnect;
done_testing;
