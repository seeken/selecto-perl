use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use Storable qw(dclone);
use Selecto;
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite;1 };
my$db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE records(id INTEGER PRIMARY KEY, tenant_id INTEGER, title TEXT, state TEXT, priority INTEGER)');
$db->do(q{INSERT INTO records VALUES(1,7,'First','open',2),(2,8,'Other','open',9),(3,7,'Last','done',3)});
$db->do('CREATE TABLE alternate(id INTEGER PRIMARY KEY)');$db->do('INSERT INTO alternate VALUES(900)');
my$adapter=Selecto->adapter(sqlite=>dbh=>$db);
my$base={name=>'Records',source=>{source_table=>'records',primary_key=>'id',fields=>[qw(id tenant_id title state priority)],columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer'},title=>{type=>'string'},state=>{type=>'string'},priority=>{type=>'integer'}},associations=>{}},schemas=>{},joins=>{},default_selected=>['title'],required_selected=>['id'],required_filters=>[['tenant_id',7]],required_order_by=>[['priority','desc']]};
my$engine=Selecto::Engine->new(domain=>Selecto::Domain->parse(dclone($base)),adapter=>$adapter);
my$events=0;$db->sqlite_set_authorizer(sub{$events++;return 0});
sub caught{my($run)=@_;my$ok=eval{$run->();1};return $ok?undef:$@}
sub refusal{my($label,$code,$run)=@_;$events=0;my$error=caught($run);is(ref($error)?$error->code:'none',$code,$label);is($events,0,"$label performs no native SQL");return$error}
refusal('public configured intent refuses ad-hoc join','ad_hoc_join_forbidden',sub{$engine->query->join('audit_log',source=>'alternate')});
refusal('public tuple selection refuses raw SQL','raw_sql_forbidden',sub{$engine->query->select(['raw_sql','current_user'])});
refusal('public expression constructor refuses raw SQL','raw_sql_forbidden',sub{Selecto::Expression->new('raw_sql','current_user')});
for my$route(qw(select filter group order)){
 my$expr=Selecto::Expression->literal('ordinary');$expr->{kind}='raw_sql';$expr->{arguments}=['current_user'];
 my$q=$engine->query->select('title');
 $q=$q->select($expr)if$route eq'select';$q=$q->where($expr)if$route eq'filter';$q=$q->group_by($expr)if$route eq'group';$q=$q->order_by($expr)if$route eq'order';
 refusal("forged raw expression in $route",'raw_sql_forbidden',sub{$engine->all($q)});
}
is_deeply($engine->all($engine->query)->{rows},[[3,'Last'],[1,'First']],'native defaults, required selected/filter/order clauses execute');
is_deeply($engine->all($engine->query->select('title')->replace_orders([[Selecto::Expression->field('priority'),'asc']]))->{rows},[[3,'Last'],[1,'First']],'replacing optional intent cannot erase required native ordering');
my$q=$engine->query->select('title')->where(Selecto::Expression->eq('tenant_id',8));
is_deeply($engine->all($q)->{rows},[],'optional contradictory tenant filter cannot erase required tenant predicate');
my$updated=Selecto::Domain->parse(dclone($base));my$e=Selecto::Engine->new(domain=>$updated,adapter=>$adapter);
$e->domain->{contract}{source}{source_table}='alternate';
my$error=refusal('original D022 contract source tamper','domain_modified_after_configuration',sub{$e->compile($e->query->select('id'))});
is_deeply($error->details->{path},[],'original D022 path is canonical');
$e=Selecto::Engine->new(domain=>Selecto::Domain->parse(dclone($base)),adapter=>$adapter);$e->domain->{table}='alternate';
refusal('actual native target table tamper','domain_modified_after_configuration',sub{$e->all($e->query->select('id'))});
my$udf=Selecto::Expression->new('udf','normalize_title',[Selecto::Expression->field('title')]);
refusal('native UDF execution remains a concrete unsupported boundary','invalid_query',sub{$engine->all($engine->query->select($udf))});
my$full=do{open my$fh,'<:raw','t/fixtures/query_policy.json'or die$!;local$/;JSON::PP->new->utf8->decode(<$fh>)};
refusal('complete rich declaration does not bypass native strict parser','unknown_domain_key',sub{Selecto::Domain->parse($full->{D019}{governed_domain})});
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP storage is memory');
is($db->selectall_arrayref('PRAGMA database_list')->[0][2],'','main database is memory');
$db->disconnect;done_testing;
