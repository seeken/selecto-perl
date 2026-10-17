use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::Operation;
use Selecto::Write::PortableCommand;
use Selecto::Write::NestedGraph;
use Selecto::Write::Multi;
BEGIN {eval {require DBI;require DBD::SQLite;1} or plan skip_all=>'DBD::SQLite required'}

sub copy {Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value}}
sub error {
    my ($run)=@_; my $ok=eval {$run->();1};return undef if $ok;
    my $error=$@;ok ref($error) eq 'Selecto::Error','public failure is typed';return $error;
}
sub domain {
    my ($table,$fields)=@_;
    return {name=>$table,source=>{source_table=>$table,primary_key=>'id',fields=>$fields,
        columns=>{map {$_=>{type=>($_ eq 'name' || $_ eq 'tenant_id')?'string':'integer'}} @$fields},associations=>{}},schemas=>{},joins=>{},
        writes=>{operations=>{map {$_=>{enabled=>JSON::PP::true,($_ ne 'insert'?(require_filter=>JSON::PP::true):())}} qw(insert update delete)},
            fields=>{name=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true},tenant_id=>{insertable=>JSON::PP::true,immutable=>JSON::PP::true}},
            scope=>{tenant=>{required=>JSON::PP::true,field=>'tenant_id',satisfied_by=>['trusted_context']}}}};
}
sub root {
    my $child=domain('children',[qw(id tenant_id parent_id name)]);
    my $parent=domain('parents',[qw(id tenant_id name)]);
    $parent->{writes}{relationships}{children}={writable=>JSON::PP::true,cardinality=>'many',ownership=>'owned',
        allowed_ops=>[qw(insert update delete)],domain=>$child,child_key=>'parent_id',identity_fields=>['id'],strategy=>'sync',delete_missing=>JSON::PP::true};
    return $parent;
}
sub engine {Selecto::Engine->new(domain=>Selecto::Domain->parse($_[0]),adapter=>$_[1],write_context=>{tenant_id=>'A'})}
sub execute {
    my ($raw,$adapter,$op)=@_;
    my $compiled=$op->compile(context=>{tenant_id=>'A'});
    return engine($raw,$adapter)->execute_graph($compiled->{command});
}
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
$db->do('PRAGMA temp_store=MEMORY');$db->do('PRAGMA foreign_keys=ON');
$db->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,name TEXT UNIQUE)');
$db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,parent_id INTEGER NOT NULL REFERENCES parents(id),name TEXT UNIQUE)');
$db->do('CREATE TABLE grandchildren(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,child_id INTEGER NOT NULL REFERENCES children(id),name TEXT UNIQUE)');
$db->do('CREATE TABLE others(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,name TEXT UNIQUE)');
my $adapter=Selecto->adapter(sqlite=>(dbh=>$db));my $raw=root();
my $created=execute($raw,$adapter,Selecto::Write::Operation->new($raw)->insert({name=>'parent',children=>[{name=>'first'},{name=>'second'}]}));
isa_ok $created,'Selecto::Write::Graph::Result','native graph executes';
is_deeply $db->selectall_arrayref('SELECT tenant_id,parent_id,name FROM children ORDER BY id'),[['A',1,'first'],['A',1,'second']], 'actual generated parent FK and tenant materialize for every child';
is $db->selectrow_array('SELECT count(*) FROM parents'),1,'one parent inserted';
my $updated=execute($raw,$adapter,Selecto::Write::Operation->new($raw)->update({name=>'updated',children=>[{id=>1,name=>'retained'}]})->filter(['id',1]));
isa_ok $updated,'Selecto::Write::Graph::Result','native owned update executes';
is_deeply $db->selectall_arrayref('SELECT id,tenant_id,parent_id,name FROM children ORDER BY id'),[[1,'A',1,'retained']], 'full-set sync retains identified child and deletes omitted owned row';
$db->do(q{INSERT INTO parents VALUES(2,'B','other')});$db->do(q{INSERT INTO children VALUES(20,'B',2,'foreign')});
my $before=$db->selectall_arrayref('SELECT * FROM parents ORDER BY id');
my $children_before=$db->selectall_arrayref('SELECT * FROM children ORDER BY id');
my $mutations=0;$db->sqlite_trace(sub {$mutations++ if $_[0]=~/\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+["`\[]?(?:parents|children|grandchildren|others)\b/i});
for my $case (
    ['authored generated key',{name=>'bad-fk',children=>[{name=>'bad',parent_id=>2}]}],
    ['duplicate stable identity',{name=>'bad-ids',children=>[{id=>1,name=>'a'},{id=>1,name=>'b'}]}],
    ['invalid child field',{name=>'bad-field',children=>[{unknown=>'bad'}]}],
) {
    my $start=$mutations;my $error=error(sub {execute($raw,$adapter,Selecto::Write::Operation->new($raw)->update($case->[1])->filter(['id',1]))});
    ok $error,"$case->[0] refuses";is $mutations,$start,"$case->[0] refuses before root DML";
}
my $cross=error(sub {execute($raw,$adapter,Selecto::Write::Operation->new($raw)->update({name=>'cross',children=>[{id=>20,name=>'stolen'}]})->filter(['id',1]))});
ok $cross,'identity in another tenant/parent refuses';
is_deeply $db->selectall_arrayref('SELECT * FROM parents ORDER BY id'),$before,'failed child governance rolls back parent';
is_deeply $db->selectall_arrayref('SELECT * FROM children ORDER BY id'),$children_before,'failed child governance preserves all memberships';
my $rolled=error(sub {execute($raw,$adapter,Selecto::Write::Operation->new($raw)->insert({name=>'rolled-parent',children=>[{name=>'retained'}]}))});
ok $rolled,'native unique violation fails graph';
is $db->selectrow_array(q{SELECT count(*) FROM parents WHERE name='rolled-parent'}),0,'native child failure rolls back actual generated parent';

subtest 'portable modes, identity and validation precede SQL' => sub {
    my $delta=copy($raw);$delta->{writes}{relationships}{children}{write}={modes=>['delta'],create=>JSON::PP::true,update=>JSON::PP::true,delete=>JSON::PP::true,max_mutations=>3};
    delete @{$delta->{writes}{relationships}{children}}{qw(strategy delete_missing)};
    my $compiled=Selecto::Write::Operation->new($delta)->update({name=>'delta',children=>{create=>[{name=>'third'}],update=>[{id=>1,name=>'changed'}]}})->filter(['id',1])->compile(context=>{tenant_id=>'A'});
    is_deeply [map {$_->{command}->operation} @{$compiled->{command}->nodes}],[qw(update insert update)],'delta emits actual ordered create/update commands';
    is_deeply $compiled->{command}->owned_sets,[],'delta does not delete missing children';
    engine($delta,$adapter)->execute_graph($compiled->{command});
    is_deeply $db->selectall_arrayref(q{SELECT name FROM children WHERE tenant_id='A' ORDER BY id}),[['changed'],['third']],'declared delta really mutates only requested children';
    my $shared=copy($raw);$shared->{writes}{relationships}{children}{ownership}='shared_reference';
    ok error(sub {Selecto::Write::Operation->new($shared)->insert({name=>'bad-shared',children=>[{name=>'child'}]})->compile(context=>{tenant_id=>'A'})}),'shared reference cannot use composition create';
    my $limited=copy($raw);$limited->{writes}{relationships}{children}{max_items}=1;
    ok error(sub {Selecto::Write::Operation->new($limited)->insert({name=>'too-many',children=>[{name=>'a'},{name=>'b'}]})->compile(context=>{tenant_id=>'A'})}),'declared cardinality limit refuses';
    my $client=copy($raw);$client->{writes}{relationships}{children}{client_identity}='cid';
    ok error(sub {Selecto::Write::Operation->new($client)->insert({name=>'unstable',children=>[{name=>'a'}]})->compile(context=>{tenant_id=>'A'})}),'declared client identity required for creates';
    my $stable=Selecto::Write::Operation->new($client)->insert({name=>'stable',children=>[{cid=>'one',name=>'a'}]})->compile(context=>{tenant_id=>'A'});
    is $stable->{command}->nodes->[1]{command}->metadata->{nested_graph}{client_identity},'one','stable identity is actual metadata';
    ok !exists($stable->{command}->nodes->[1]{command}->assignments->{cid}),'client identity is not a storage assignment';
};
subtest 'deep native topology and ordered root input' => sub {
    my $deep=copy($raw);my $child=$deep->{writes}{relationships}{children}{domain};
    delete $child->{name};
    $child->{writes}{relationships}{grandchildren}={cardinality=>'many',ownership=>'owned',writable=>JSON::PP::true,
        allowed_ops=>['insert'],child_key=>'child_id',identity_fields=>['id'],domain=>domain('grandchildren',[qw(id tenant_id child_id name)])};
    my $op=Selecto::Write::Operation->new($deep)->insert([['name','deep-root'],['children',[{name=>'deep-child',grandchildren=>[{name=>'deep-grand'}]}]]]);
    my $compiled=$op->compile(context=>{tenant_id=>'A'});
    is scalar @{$compiled->{command}->nodes},3,'ordered root lowers real three-generation topology';
    engine($deep,$adapter)->execute_graph($compiled->{command});
    is_deeply $db->selectall_arrayref(q{SELECT p.name,c.name,g.name,g.tenant_id FROM grandchildren g JOIN children c ON c.id=g.child_id JOIN parents p ON p.id=c.parent_id}),
        [['deep-root','deep-child','deep-grand','A']],'actual generated child and grandchild keys retain complete ownership and tenant';
    my $start=$mutations;
    ok error(sub {Selecto::Write::Operation->new($deep)->insert([['name','bad-root'],['children',[]],[{'$atom'=>'children'},[]]])->compile(context=>{tenant_id=>'A'})}),'root pair collision refuses';
    is $mutations,$start,'root pair ambiguity has no native business SQL';
};
subtest 'generated keys obey public returning policy' => sub {
    for my $policy ('none','list') {
        my $restricted=copy($raw);
        $restricted->{writes}{operations}{insert}{returning}=$policy eq 'none'?'none':['name'];
        $restricted->{writes}{relationships}{children}{domain}{writes}{operations}{insert}{returning}='none';
        my $op=Selecto::Write::Operation->new($restricted)->insert({name=>"return-$policy",children=>[{name=>"return-child-$policy"}]});
        $op=$op->returning(['name']) if $policy eq 'list';
        my $graph=$op->compile(context=>{tenant_id=>'A'})->{command};
        $graph->{metadata}{root_returning}='all';
        my $result=engine($restricted,$adapter)->execute_graph($graph);
        is_deeply $result->root->values,$policy eq 'none'?{}:{name=>"return-list"},"$policy root exposes only governed public intent";
        my ($child_id)=grep {$_ ne 'root'} keys %{$result->nodes};
        is_deeply $result->nodes->{$child_id}->values,{},"$policy child internal identity is not public data";
        is_deeply $db->selectrow_arrayref('SELECT p.id,c.parent_id FROM parents p JOIN children c ON c.parent_id=p.id WHERE p.name=?',undef,"return-$policy"),
            [($db->selectrow_array('SELECT id FROM parents WHERE name=?',undef,"return-$policy")) x 2],"$policy generated binding actually materializes";
        my $start=$mutations;
        my $bad=error(sub {Selecto::Write::Operation->new($restricted)->insert({name=>"bad-return-$policy",children=>[{name=>'bad'}]})->returning(['id'])->compile(context=>{tenant_id=>'A'})});
        is $bad->code,'returning_policy_violation',"$policy unrelated public key request still refuses";
        is $mutations,$start,"$policy refusal has no native business effects";
        # Re-authoring an internal graph command as an ordinary public request
        # still undergoes policy; generated-key storage is not a grant.
        my $forged=Selecto::Write::Graph->new(nodes=>$graph->nodes,metadata=>{root_returning=>'none'});
        $start=$mutations;my $native_bad=error(sub {engine($restricted,$adapter)->execute_graph($forged)});
        is $native_bad->code,'returning_policy_violation',"$policy native explicit internal-key request refuses";
        is $mutations,$start,"$policy native refusal occurs before DML";
    }
    my $deep=copy($raw);$deep->{writes}{operations}{insert}{returning}='none';
    my $child=$deep->{writes}{relationships}{children}{domain};$child->{writes}{operations}{insert}{returning}='none';
    my $grand=domain('grandchildren',[qw(id tenant_id child_id name)]);$grand->{writes}{operations}{insert}{returning}='none';
    $child->{writes}{relationships}{grandchildren}={cardinality=>'many',ownership=>'owned',writable=>JSON::PP::true,
        allowed_ops=>['insert'],child_key=>'child_id',identity_fields=>['id'],domain=>$grand};
    my $result=execute($deep,$adapter,Selecto::Write::Operation->new($deep)->insert({name=>'return-deep',children=>[{name=>'return-deep-child',grandchildren=>[{name=>'return-deep-grand'}]}]}));
    is_deeply [map {$result->nodes->{$_}->values} sort keys %{$result->nodes}],[{},{},{}],'three-generation internal keys never escape none policy';
    is $db->selectrow_array(q{SELECT count(*) FROM grandchildren g JOIN children c ON c.id=g.child_id JOIN parents p ON p.id=c.parent_id WHERE p.name='return-deep'}),1,
        'deep none-policy graph really binds both generated ancestors';
};
subtest 'real cross-domain atomic Multi' => sub {
    my $other=domain('others',[qw(id tenant_id name)]);delete $other->{name};my $host=engine($raw,$adapter);
    my $multi=Selecto::Write::Multi->new->insert('parent',$raw,{name=>'multi-parent'})->insert('other',$other,{name=>'multi-other'});
    my $result=$multi->run($host);
    is_deeply [sort keys %$result],[qw(other parent)],'complete operation/result map';
    isa_ok $result->{other},'Selecto::Write::Result';
    is_deeply $db->selectall_arrayref(q{SELECT tenant_id,name FROM others}),[['A','multi-other']],'second domain really executes with trusted host tenant';
    my $bad=Selecto::Write::Multi->new->insert('prefix',$raw,{name=>'must-not-dispatch'})->insert('invalid',$other,{bogus=>'bad'});
    my $start=$mutations;ok error(sub {$bad->run($host)}),'last operation compilation fails';is $mutations,$start,'all operations compile before first DML';
    my $duplicate=Selecto::Write::Multi->new->insert('same',$raw,{name=>'one'})->insert('same',$other,{name=>'two'});
    $start=$mutations;ok error(sub {$duplicate->run($host)}),'duplicate operation names fail';is $mutations,$start,'duplicate names fail before native DML';
    my $rollback=Selecto::Write::Multi->new->insert('prefix',$raw,{name=>'rollback-multi'})->insert('duplicate',$other,{name=>'multi-other'});
    ok error(sub {$rollback->run($host)}),'actual native final-member violation fails Multi';
    is $db->selectrow_array(q{SELECT count(*) FROM parents WHERE name='rollback-multi'}),0,'one atomic batch rolls back earlier domain';
    my $conflict=Selecto::Write::Multi->new(operations=>[
        ['a',Selecto::Write::Operation->new($raw)->insert({name=>'conflict-a'})->with_tenant({tenant_id=>'A'})],
        ['b',Selecto::Write::Operation->new($other)->insert({name=>'conflict-b'})->with_tenant({tenant_id=>'B'})]]);
    $start=$mutations;my $error=error(sub {$conflict->run($host)});is $error->code,'tenant_mismatch','compiler context conflicts are typed';is $mutations,$start,'context conflict has no SQL effects';
};
is $db->selectrow_array('PRAGMA temp_store'),2,'SQLite TEMP stays memory';
is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}],[],'all actual schemas are in memory';
$db->disconnect;
done_testing;
