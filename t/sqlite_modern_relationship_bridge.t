use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::Operation ();
plan skip_all=>'DBD::SQLite is optional' unless eval{require DBI;require DBD::SQLite;1};

sub copy {Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value}}
sub code {
    my ($work)=@_;return 'ok' if eval{$work->();1};
    return ref($@) eq 'Selecto::Error' ? $@->code : "untyped: $@";
}
sub domain {
    my ($table,$fields)=@_;
    return {name=>$table,source=>{source_table=>$table,primary_key=>'id',fields=>$fields,
        columns=>{map{$_=>{type=>$_ eq 'name'||$_ eq 'tenant_id'?'string':'integer'}}@$fields},associations=>{}},schemas=>{},
        writes=>{operations=>{map{$_=>{enabled=>JSON::PP::true}}qw(insert update delete)},
            fields=>{map{$_=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}}grep{$_ ne 'parent_id'}@$fields},
            scope=>{tenant=>{required=>JSON::PP::true,field=>'tenant_id',satisfied_by=>['trusted_context']}}}};
}
sub composition {
    my ($mode)=@_;my $parent=domain('parents',[qw(id tenant_id name)]);
    my $child=domain('children',[qw(id tenant_id parent_id name)]);delete $child->{name};
    $parent->{writes}{relationships}{children}={cardinality=>'many',ownership=>'composition',domain=>$child,
        child_key=>'parent_id',identity_fields=>['id'],write=>{modes=>[$mode],
            create=>JSON::PP::true,update=>JSON::PP::true,delete=>JSON::PP::true,
            ($mode eq 'full_set' ? (omission=>'delete_missing') : ())}};
    return $parent;
}
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
$db->do('PRAGMA temp_store=MEMORY');$db->do('PRAGMA foreign_keys=OFF');
$db->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,name TEXT)');
$db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,parent_id INTEGER NOT NULL,name TEXT)');
$db->do('CREATE TABLE targets(id INTEGER PRIMARY KEY,name TEXT)');
$db->do('CREATE TABLE memberships(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,parent_id INTEGER NOT NULL,target_id INTEGER)');
$db->do("INSERT INTO targets VALUES(42,'protected target')");
my $adapter=Selecto->adapter(sqlite=>dbh=>$db);
sub engine {Selecto::Engine->new(domain=>Selecto::Domain->parse($_[0]),adapter=>$adapter,write_context=>{tenant_id=>'A'})}
sub compile {$_[0]->compile(context=>{tenant_id=>'A'})}
sub run {my($raw,$operation)=@_;engine($raw)->execute_graph(compile($operation)->{command})}
my (@sql,@auth,@hooks);
$db->sqlite_trace(sub{push@sql,$_[0]});$db->sqlite_set_authorizer(sub{push@auth,[@_];0});$db->sqlite_update_hook(sub{push@hooks,[@_]});
my $zero=sub {
    my($label,$expected,$work)=@_;@sql=();@auth=();@hooks=();
    is(code($work),$expected,$label);is(scalar@sql,0,"$label: no SQL execution");
    is(scalar@auth,0,"$label: no native prepare authority calls");is(scalar@hooks,0,"$label: no physical update hooks");
};
my $delta=composition('delta');
is(code(sub{run($delta,Selecto::Write::Operation->new($delta)->insert({name=>'parent',children=>{create=>[{name=>'first'},{name=>'second'}]}}))}),
    'ok','modern-only composition delta creates real parent and children');
is_deeply($db->selectall_arrayref('SELECT id,tenant_id,parent_id,name FROM children ORDER BY id'),
    [[1,'A',1,'first'],[2,'A',1,'second']],'actual generated bindings and host tenant are stored');
my $string_grant=copy($delta);$string_grant->{writes}{relationships}{children}{write}{create}='1';
my $new_child=compile(Selecto::Write::Operation->new($delta)->update({name=>'bad string grant',children=>{create=>[{name=>'blocked'}]}})->filter(['id',1]))->{command};
$zero->('authored string is not a native Boolean grant','invalid_domain',sub{engine($string_grant)->execute_graph($new_child)});
is(code(sub{run($delta,Selecto::Write::Operation->new($delta)->update({name=>'delta',children=>{
    create=>[{name=>'third'}],update=>[{id=>1,name=>'changed'}],delete=>[{id=>2}]}})->filter(['id',1]))}),
    'ok','modern-only delta executes declared create, update and delete');
is_deeply($db->selectall_arrayref('SELECT id,parent_id,name FROM children ORDER BY id'),[[1,1,'changed'],[3,1,'third']],
    'delta actual rows match requested mutations');
$db->do("INSERT INTO parents VALUES(2,'B','other parent')");$db->do("INSERT INTO children VALUES(20,'B',2,'other child')");
my $full=composition('full_set');
is(code(sub{run($full,Selecto::Write::Operation->new($full)->update({name=>'full',children=>[{id=>1,name=>'kept'}]})->filter(['id',1]))}),
    'ok','modern-only full_set omission derives actual owned cleanup');
is_deeply($db->selectall_arrayref('SELECT id,tenant_id,parent_id,name FROM children ORDER BY id'),[[1,'A',1,'kept'],[20,'B',2,'other child']],
    'full-set cleanup removes only omitted rows of the actual returned parent');
my $empty=compile(Selecto::Write::Operation->new($full)->update({name=>'empty',children=>[]})->filter(['id',1]))->{command};
my $no_delete=copy($full);$no_delete->{writes}{relationships}{children}{write}{delete}=JSON::PP::false;
my $denied=engine($no_delete);
$zero->('compiled graph cannot invent an omitted delete grant','write_operation_not_enabled',sub{$denied->execute_graph($empty)});
is(code(sub{engine($full)->execute_graph($empty)}),'ok','modern-only empty full_set performs actual cleanup');
is_deeply($db->selectall_arrayref('SELECT id,tenant_id,parent_id,name FROM children ORDER BY id'),[[20,'B',2,'other child']],
    'empty full_set retains other tenant and parent rows');
is(code(sub{run($full,Selecto::Write::Operation->new($full)->insert({name=>'full insert',children=>[{name=>'new full'}]}))}),
    'ok','full_set root insertion does not require update-only omission cleanup');
my $incomplete=compile(Selecto::Write::Operation->new($full)->update({name=>'incomplete',children=>[{id=>21,name=>'kept'}]})->filter(['id',3]))->{command};
my $without_set=Selecto::Write::Graph->new(nodes=>$incomplete->nodes,metadata=>{mode=>'full_set',delete_missing=>1});
$zero->('informational mode cannot replace actual full-set cleanup','invalid_write_graph',sub{engine($full)->execute_graph($without_set)});
my $append=composition('append_only');
my $forged=Selecto::Write::Graph->new(nodes=>[
    {id=>'root',command=>Selecto::Write::Command->new(operation=>'update',relation=>'parents',assignments=>{name=>'fake'},predicate=>Selecto::Expression->eq('id',3))},
    {id=>'child',command=>Selecto::Write::Command->new(operation=>'update',relation=>'children',assignments=>{name=>'fake'},predicate=>Selecto::Expression->eq('id',21),
        metadata=>{nested_graph=>{mutation_mode=>'delta',semantic_operation=>'update'}}),bindings=>[{field=>'parent_id',from=>'root',key=>'id'}]}]);
$zero->('forged delta metadata cannot grant update under append_only','write_operation_not_enabled',sub{engine($append)->execute_graph($forged)});

my $link=domain('parents',[qw(id tenant_id name)]);my $membership=domain('memberships',[qw(id tenant_id parent_id target_id)]);
$membership->{writes}{constraints}{foreign_keys}{target_id}={source=>'input',references=>{relation=>'targets',field=>'id',tenant_field=>JSON::PP::false}};
$link->{writes}{relationships}{memberships}={cardinality=>'many',ownership=>'join_association',domain=>$membership,
    child_key=>'parent_id',identity_fields=>['id'],write=>{modes=>['link_delta'],link=>JSON::PP::true,unlink=>JSON::PP::true}};
is(code(sub{run($link,Selecto::Write::Operation->new($link)->update({name=>'linked',memberships=>{link=>[{id=>101,target_id=>42}]}})->filter(['id',1]))}),
    'ok','modern-only link grant inserts an actual membership row');
is_deeply($db->selectall_arrayref('SELECT * FROM memberships'),[[101,'A',1,42]],'membership relation has exact generated ownership');
is_deeply($db->selectall_arrayref('SELECT * FROM targets'),[[42,'protected target']],'link does not mutate shared target');
my $unlink=compile(Selecto::Write::Operation->new($link)->update({name=>'unlinked',memberships=>{unlink=>[{id=>101}]}})->filter(['id',1]))->{command};
my $no_unlink=copy($link);$no_unlink->{writes}{relationships}{memberships}{write}{unlink}=JSON::PP::false;
$zero->('compiled unlink cannot invent a host unlink grant','write_operation_not_enabled',sub{engine($no_unlink)->execute_graph($unlink)});
is(code(sub{engine($link)->execute_graph($unlink)}),'ok','modern-only unlink removes actual membership');
is_deeply($db->selectall_arrayref('SELECT * FROM memberships'),[],'unlink removes only the membership row');
is_deeply($db->selectall_arrayref('SELECT * FROM targets'),[[42,'protected target']],'unlink preserves shared target');
my $before=$db->selectall_arrayref('SELECT * FROM parents ORDER BY id');
isnt(code(sub{run($link,Selecto::Write::Operation->new($link)->update({name=>'missing target',memberships=>{link=>[{id=>102,target_id=>999}]}})->filter(['id',1]))}),
    'ok','link requires an actual target even with physical foreign keys disabled');
is_deeply($db->selectall_arrayref('SELECT * FROM parents ORDER BY id'),$before,'missing target rolls back real root prefix');
is_deeply($db->selectall_arrayref('SELECT * FROM memberships'),[],'missing target stores no orphan membership');
$zero->('shared link policy cannot create a new parent implicitly','write_operation_not_enabled',sub{
    run($link,Selecto::Write::Operation->new($link)->insert({name=>'bad shared parent',memberships=>{link=>[{id=>103,target_id=>42}]}}))});
my $mismatch=copy($delta);$mismatch->{writes}{relationships}{children}{table}='targets';
my $wrong_table=Selecto::Write::Graph->new(nodes=>[
    {id=>'root',command=>Selecto::Write::Command->new(operation=>'update',relation=>'parents',assignments=>{name=>'bad'},predicate=>Selecto::Expression->eq('id',1))},
    {id=>'child',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'targets',assignments=>{id=>99,name=>'bad'}),bindings=>[{field=>'parent_id',from=>'root',key=>'id'}]}]);
$zero->('relationship table cannot retarget its child domain','write_relation_mismatch',sub{engine($mismatch)->execute_graph($wrong_table)});
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP stays in memory');
is_deeply([grep{length($_->[2])}@{$db->selectall_arrayref('PRAGMA database_list')}],[],'main and all schemas are memory only');
$db->sqlite_trace(undef);$db->sqlite_set_authorizer(undef);$db->sqlite_update_hook(undef);$db->disconnect;
done_testing;
