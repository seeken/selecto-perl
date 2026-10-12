use 5.034;use strict;use warnings;
use Test::More;use Scalar::Util qw(blessed);use JSON::PP ();
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
use Selecto::Action ();use Selecto::Action::Plan ();use Selecto::Write::Operation ();use Selecto::Write::PortableCommand ();
use Selecto::Verification::WriteModel ();
sub caught {my($fn)=@_;my$e;{local$@;my$ok=eval{$fn->();1};$e=$@ unless$ok;}return$e;}
my$d=Selecto::Verification::WriteModel::work_items();
require Selecto::Domain;
my$projected=Selecto::Domain->project($d,'write');
is_deeply($projected->{rules},{},'actual public write projection has empty absent-rules registry');
my$projected_plan=Selecto::Action->plan($projected,{action=>'archive',target=>{id=>7}});
ok(Selecto::Action->validate_provenance($projected_plan),'public projected contract plans through real accepted registry');
my$projected_handle=Selecto::Action->planned_operation($projected,{action=>'archive',target=>7});
isa_ok($projected_handle,'Selecto::Write::PlannedOperation');
my$bad_projected=Selecto::Domain->project($d,'write');$bad_projected->{rules}={schema=>'unsupported'};
my$rules_error=caught(sub{Selecto::Action->plan($bad_projected,{action=>'archive',target=>7})});
is($rules_error->code,'invalid_data_rules_contract','nonempty malformed projected rules retain strict parser refusal');
my$opaque=Selecto::Action->planned_operation($d,{action=>'archive',target=>7});
isa_ok($opaque,'Selecto::Write::PlannedOperation');
my$calls=0;
my$e=caught(sub{Selecto::Write::PortableCommand->compile($opaque,choice_membership_resolver=>sub{++$calls;die'not reached'})});
is($e->details->{code},'opaque_planned_operation','genuine planned operation cannot enter authored portable compiler');
is($calls,0,'opaque refusal precedes all compiler callbacks');
my$forged=bless\(my$x=0),'Selecto::Write::PlannedOperation';
$e=caught(sub{Selecto::Write::PortableCommand->compile($forged)});
is($e->details->{code},'opaque_planned_operation','forged opaque handle grants no compiler authority');
$e=caught(sub{Selecto::Write::PlannedOperation->_from_plan(Selecto::Action->plan($d,{action=>'archive',target=>7}))});
is($e->code,'invalid_planned_operation','internal opaque issuance is restricted to actual public planning path');
my$fake=Selecto::Action::Plan->new(action=>'archive',operation=>'update',capability=>'work_items.archive');
$e=caught(sub{Selecto::Action->authorize_and_issue($fake,'execute',resolver=>sub{++$calls;'enabled'})});
is($e->details->{code},'invalid_planned_operation','unregistered plan refuses at genuine accepted-plan registry');
is($calls,0,'unregistered plan cannot call resolver');
my$p=Selecto::Action->plan($d,{action=>'archive',target=>{id=>7}});
ok(Selecto::Action->validate_provenance($p),'actual accepted plan validates');
$p->target({id=>99});
$e=caught(sub{Selecto::Action->authorize_and_issue($p,'execute',resolver=>sub{++$calls;'enabled'})});
is($e->details->{code},'action_policy_mismatch','mutated exact accepted plan refuses against original native planning digest');
is($calls,0,'changed plan cannot call resolver');
{
 package CallbackObject;
 our$hooks=0;
 sub STORABLE_freeze{++$hooks;return('callback')}
 package main;
 my$bad=Selecto::Action->plan($d,{action=>'archive',target=>7});$bad->changes({state=>bless({},'CallbackObject')});
 $e=caught(sub{Selecto::Action->validate_provenance($bad)});
 isa_ok($e,'Selecto::Error');is($CallbackObject::hooks,0,'malformed accepted content is admitted before native digest cloning');
 $e=caught(sub{Selecto::Action->planned_operation({bad=>bless({},'CallbackObject')},{action=>'archive',target=>7})});
 isa_ok($e,'Selecto::Error');is($CallbackObject::hooks,0,'planned-operation metadata refuses callbacks before actual planner clone');
}
{
 package ProvenanceTieHash;
 our$hooks=0;
 sub TIEHASH {bless{},shift}sub FIRSTKEY{++$hooks;undef}sub NEXTKEY{++$hooks;undef}sub FETCH{++$hooks;undef}sub SCALAR{++$hooks;0}
 package ProvenanceTieArray;
 our$hooks=0;
 sub TIEARRAY{bless{},shift}sub FETCHSIZE{++$hooks;0}sub FETCH{++$hooks;undef}
 package ProvenanceTieScalar;
 our$hooks=0;
 sub TIESCALAR{bless{},shift}sub FETCH{++$hooks;'unsafe'}
 package main;
 my$p=Selecto::Action->plan($d,{action=>'archive',target=>7});tie my%h,'ProvenanceTieHash';$p->target(\%h);
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($ProvenanceTieHash::hooks,0,'nested tied plan HASH refuses before iteration or fetch');
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});tie my@a,'ProvenanceTieArray';$p->filters(\@a);
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($ProvenanceTieArray::hooks,0,'nested tied plan ARRAY refuses before size or fetch');
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});tie $p->{changes}{state},'ProvenanceTieScalar';
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($ProvenanceTieScalar::hooks,0,'nested tied plan scalar slot refuses before FETCH');
 my$class0_hooks=0;{no strict 'refs';no warnings 'redefine';*{'0::STORABLE_freeze'}=sub{++$class0_hooks;return('callback')};}
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});$p->changes({state=>bless({},'0')});
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($e->code,'invalid_planned_operation','false class name is a native reference and refuses');is($class0_hooks,0,'class0 native reference refuses before serialization hooks');
 my$inside=bless({},'0');my$wrapped=bless\$inside,'JSON::PP::Boolean';
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});$p->changes({state=>$wrapped});
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');
 is($class0_hooks,0,'reference-valued Boolean wrapper refuses before serialization hooks');
 # A reference-valued wrapper has native reftype REF and is refused by the
 # outer SCALAR check; this does not claim the inner scalar guard is reached.
 my$shared=[('x')x1000];
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});$p->changes({state=>[($shared)x11]});
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($e->code,'invalid_planned_operation','repeated aliases consume occurrence budget before digest');
 my$cycle=[];push@$cycle,$cycle;
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});$p->changes({state=>$cycle});
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($e->code,'invalid_planned_operation','cyclic native plan mutation refuses before digest');
 $p=Selecto::Action->plan($d,{action=>'archive',target=>7});$p->changes({state=>['x'x131_073]});
 $e=caught(sub{Selecto::Action->validate_provenance($p)});isa_ok($e,'Selecto::Error');is($e->code,'invalid_planned_operation','native provenance data is byte bounded before digest');
}

subtest 'native issued grant retains actual context and single use'=>sub{
 eval{require DBI;require DBD::SQLite;1}or plan skip_all=>'DBD::SQLite is not installed';
 require Selecto;require Selecto::Domain;require Selecto::Engine;
 my$dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
 $dbh->do('PRAGMA temp_store=MEMORY');is($dbh->selectrow_array('PRAGMA temp_store'),2,'TEMP is memory');
 ok(!grep(defined($_->[2])&&length($_->[2]),@{$dbh->selectall_arrayref('PRAGMA database_list')}),'all database files empty');
 $dbh->do('CREATE TABLE work_items(id INTEGER PRIMARY KEY, tenant_id TEXT NOT NULL, state TEXT NOT NULL)');
 $dbh->do(q{INSERT INTO work_items VALUES(7,'tenant-a','done'),(8,'tenant-b','done')});
 my$raw={name=>'Native planned grant',source=>{source_table=>'work_items',primary_key=>'id',fields=>[qw(id tenant_id state)],columns=>{id=>{type=>'integer'},tenant_id=>{type=>'string'},state=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
  writes=>{operations=>{update=>{enabled=>1,require_filter=>1}},fields=>{state=>{updatable=>1}},scope=>{tenant=>{required=>1,field=>'tenant_id',satisfied_by=>['trusted_context']}},transitions=>{state=>{done=>['archived']}}},
  actions=>{archive=>{type=>'transition',scope=>'row',capability=>'work_items.archive',transition=>{field=>'state',from=>'done',to=>'archived'},execution=>{kind=>'updato',operation=>'update',set=>{state=>'archived'}}}},capabilities=>{'work_items.archive'=>{operations=>['action','update'],action=>'archive'}}};
 my$domain=Selecto::Domain->parse($raw);my$engine=Selecto::Engine->new(domain=>$domain,adapter=>Selecto->adapter(sqlite=>dbh=>$dbh),scope=>{tenant=>'tenant-a'});
 # A selected document specification is authoritative even when ordinary set
 # assignments are also present. Refuse both malformed and well-shaped plain
 # specifications before planning can reach a host resolver or native SQL.
 for my$document ('malformed nonempty document',
     {shape_release=>{id=>'approved-shape',status=>'approved',source=>{tenant_path=>['tenant_id'],version_path=>['version']}},
      relation=>'root',mutations=>[{op=>'set',path=>['body'],value=>['input','body']}],
      expected_version_from=>'version',idempotency_key_from=>'request_id'}) {
  my$document_raw=Selecto::Domain::QueryContract->copy_declaration($raw);
  $document_raw->{actions}{archive}{execution}{document}=$document;
  my$before=$dbh->selectall_arrayref('SELECT id,tenant_id,state FROM work_items ORDER BY id');
  my($prepared,$updated,$resolved)=(0,0,0);
  $dbh->sqlite_set_authorizer(sub{++$prepared;return 0});
  $dbh->sqlite_update_hook(sub{++$updated});
  my$error=caught(sub{
   my$document_handle=Selecto::Action->planned_operation($document_raw,{action=>'archive',target=>7});
   $document_handle->execute($engine,resolver=>sub{++$resolved;'enabled'});
  });
  $dbh->sqlite_set_authorizer(undef);$dbh->sqlite_update_hook(undef);
  is($error->code,'unsupported_document_action','selected document specification refuses instead of dropping document authority');
  is($resolved,0,'unsupported document action refuses before capability resolver');
  is($prepared,0,'unsupported document action refuses before native prepare');
  is($updated,0,'unsupported document action invokes no native update hooks');
  is_deeply($dbh->selectall_arrayref('SELECT id,tenant_id,state FROM work_items ORDER BY id'),$before,
      'unsupported document action preserves complete physical rows');
 }
 my$plan=$engine->plan_action({action=>'archive',target=>7});my$handle=Selecto::Action->planned_operation($engine->domain,{action=>'archive',target=>7});my$context={actor=>{id=>'actor-a'}};my$called=0;
 my$grant=$handle->authorize($engine,'execute',context=>$context,resolver=>sub{++$called;'enabled'});
 isa_ok($grant,'Selecto::Action::Grant');is($called,1,'genuine engine issues grant through actual resolver once');
 $handle->execute($engine,grant=>$grant,context=>$context);
 is_deeply($dbh->selectall_arrayref('SELECT id,tenant_id,state FROM work_items ORDER BY id'),[[7,'tenant-a','archived'],[8,'tenant-b','done']],'issued native grant changes only governed tenant target');
 $e=caught(sub{$handle->execute($engine,grant=>$grant,context=>$context)});
 is($e->code,'action_grant_invalid','actual engine consumes grant once');
 $dbh->do(q{UPDATE work_items SET state='done' WHERE id=7});
 $grant=$handle->authorize($engine,'execute',context=>$context,resolver=>sub{'enabled'});
 $e=caught(sub{$handle->execute($engine,grant=>$grant,context=>{actor=>{id=>'actor-b'}})});
 is($e->code,'action_grant_mismatch','issued grant remains bound to real actor context');
 is_deeply($dbh->selectall_arrayref('SELECT id,tenant_id,state FROM work_items ORDER BY id'),[[7,'tenant-a','done'],[8,'tenant-b','done']],'context refusal leaves all actual rows unchanged');
 $e=caught(sub{$handle->authorize($engine,'execute',engine=>$engine,resolver=>sub{++$called;'enabled'})});
 is($e->code,'invalid_argument','opaque authorization cannot override its positional engine');
 my$preview=$handle->preview($engine,context=>$context,resolver=>sub{'enabled'});
 ok(ref($preview),'opaque handle previews through actual native engine');
 is_deeply($dbh->selectall_arrayref('SELECT id,tenant_id,state FROM work_items ORDER BY id'),[[7,'tenant-a','done'],[8,'tenant-b','done']],'native opaque preview leaves actual rows unchanged');
 my$forged_handle=bless\(my$fake_token=0),'Selecto::Write::PlannedOperation';
 $e=caught(sub{$forged_handle->execute($engine,resolver=>sub{++$called;'enabled'})});
 is($e->code,'invalid_planned_operation','forged handle cannot execute through real engine');
 my$changed_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>Selecto->adapter(sqlite=>dbh=>$dbh),scope=>{tenant=>'tenant-a'});
 $changed_engine->domain->{name}='changed';
 $e=caught(sub{$handle->execute($changed_engine,resolver=>sub{++$called;'enabled'})});
 is($e->code,'domain_modified_after_configuration','opaque execution refuses mutated configured engine');
 is_deeply($dbh->selectall_arrayref('SELECT id,tenant_id,state FROM work_items ORDER BY id'),[[7,'tenant-a','done'],[8,'tenant-b','done']],'forged handle and changed engine preserve complete business rows');
 $dbh->disconnect;
};
done_testing;
