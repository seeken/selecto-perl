use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use FindBin qw($Bin);
use Selecto;
use Selecto::Write::Capabilities;
use lib 't/lib';
use TestSelecto;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is required' }

{
    package WriteCapabilitySQLite;
    use parent 'Selecto::SQLite';
    sub write_capabilities {
        my ($self) = @_; ++$self->{report_calls};
        die 'private synthetic provider failure' if $self->{report_failure};
        return $self->{report} if exists $self->{report};
        return $self->SUPER::write_capabilities;
    }
    sub execute_write { my ($self,@args)=@_; ++$self->{dispatches}; $self->SUPER::execute_write(@args) }
    sub execute_batch { my ($self,@args)=@_; ++$self->{dispatches}; $self->SUPER::execute_batch(@args) }
    sub execute_graph { my ($self,@args)=@_; ++$self->{dispatches}; $self->SUPER::execute_graph(@args) }
}
my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError=>1,PrintError=>0,AutoCommit=>1});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)');
$db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,parent_id INTEGER,name TEXT)');
$db->do('CREATE TABLE tenant_items(id INTEGER PRIMARY KEY,tenant_id INTEGER,name TEXT)');
$db->do('CREATE TABLE line_items(id INTEGER PRIMARY KEY,quantity INTEGER NOT NULL,reference TEXT NOT NULL)');
$db->do(q{INSERT INTO items VALUES(1,'original')});
$db->do(q{INSERT INTO tenant_items VALUES(1,7,'own'),(2,9,'other')});
$db->do(q{INSERT INTO line_items VALUES(1,2,'AB12')});
my $adapter = WriteCapabilitySQLite->new(dbh => $db);
my $full = $adapter->write_capabilities; # Actual native version discovery, outside refusal counters.
is($full->{protocol_version}, 1, 'actual SQLite adapter reports the versioned protocol');
ok($full->{generated_keys} && $full->{returning} && $full->{write_graph}, 'actual current SQLite reports proven returning graph/key support');
my $child = {
    schema_version=>1,name=>'Children',source=>{source_table=>'children',primary_key=>'id',fields=>[qw(id parent_id name)],
        columns=>{id=>{type=>'integer'},parent_id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
    writes=>{operations=>{insert=>{enabled=>JSON::PP::true}},fields=>{name=>{insertable=>JSON::PP::true},parent_id=>{insertable=>JSON::PP::true}}},
};
my $raw = {
    schema_version=>1,name=>'Items',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id name)],
        columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
    writes=>{operations=>{insert=>{enabled=>JSON::PP::true},update=>{enabled=>JSON::PP::true}},
        fields=>{id=>{insertable=>JSON::PP::true},name=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}},
        relationships=>{children=>{writable=>JSON::PP::true,table=>'children',parent_key=>'id',child_key=>'parent_id',allowed_ops=>['insert'],domain=>$child}}},
};
my $engine = Selecto::Engine->new(domain=>Selecto::Domain->parse($raw,strict=>1),adapter=>$adapter);
sub insert { Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{name=>'safe'},@_) }
sub update { Selecto::Write::Command->new(operation=>'update',relation=>'items',assignments=>{name=>'changed'},predicate=>Selecto::Expression->eq('id',1)) }
sub graph {
    Selecto::Write::Graph->new(nodes=>[
        {id=>'root',command=>insert()},
        {id=>'child',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'children',assignments=>{name=>'actual child'}),
            bindings=>[{field=>'parent_id',from=>'root',key=>'id'}]},
    ]);
}
sub snapshot { [$db->selectall_arrayref('SELECT id,name FROM items ORDER BY id'),$db->selectall_arrayref('SELECT id,parent_id,name FROM children ORDER BY id'),
    $db->selectall_arrayref('SELECT id,tenant_id,name FROM tenant_items ORDER BY id'),
    $db->selectall_arrayref('SELECT id,quantity,reference FROM line_items ORDER BY id')] }
my ($prepares,$updates) = (0,0);
$db->sqlite_set_authorizer(sub { ++$prepares; 0 });
$db->sqlite_update_hook(sub { ++$updates });
sub refusal {
    my ($label,$report,$work,$code) = @_;
    $db->sqlite_set_authorizer(undef); my $before=snapshot();
    $adapter->{report}=$report; $adapter->{dispatches}=0; ($prepares,$updates)=(0,0);
    $db->sqlite_set_authorizer(sub { ++$prepares; 0 });
    my $ok=eval{$work->();1};my $error=$@;
    ok(!$ok && Scalar::Util::blessed($error) && UNIVERSAL::isa($error,'Selecto::Error'), "$label returns a native typed error");
    is(Scalar::Util::blessed($error)?$error->code:'untyped',$code,"$label retains its protocol/semantic diagnostic");
    is($adapter->{dispatches},0,"$label never calls the adapter execution method");
    is($prepares,0,"$label performs zero native SQL admission/business prepares");
    is($updates,0,"$label performs zero native update hooks");
    ok($db->sqlite_get_autocommit,"$label preserves autocommit");
    $db->sqlite_set_authorizer(undef); is_deeply(snapshot(),$before,"$label preserves all actual business rows");
}
my $missing={%$full};delete $missing->{protocol_version};
my $fresh_adapter=WriteCapabilitySQLite->new(dbh=>$db);
my $fresh_engine=Selecto::Engine->new(domain=>$engine->domain,adapter=>$fresh_adapter);
my $wrong=insert(relation=>'children');
my @invalid_plan=(
    ['preview',sub{$fresh_engine->preview_write($wrong)}],
    ['command',sub{$fresh_engine->execute_write($wrong)}],
    ['batch',sub{$fresh_engine->execute_batch(Selecto::Write::Batch->new(insert(),$wrong))}],
    ['graph',sub{$fresh_engine->execute_graph(Selecto::Write::Graph->new(nodes=>[
        {id=>'prefix',command=>insert()},{id=>'wrong',command=>$wrong}]))}],
);
for my $pair (@invalid_plan) {
    refusal("complete $pair->[0] governance precedes discovery",$full,$pair->[1],'write_relation_mismatch');
    is($fresh_adapter->{report_calls}//0,0,"invalid $pair->[0] never invokes even a fresh capability provider");
}
open my $fixture_file,'<',"$Bin/fixtures/data_rules_write_inputs_v1.json" or die $!;
my $rules_fixture=JSON::PP->new->decode(do{local $/;<$fixture_file>});close $fixture_file;
my $rules_raw=dclone($rules_fixture->{flat_domain});
$_->{operations}=['insert','update'] for values %{$rules_raw->{rules}{bindings}};
$rules_raw->{writes}{operations}{update}={enabled=>JSON::PP::true};
$_->{updatable}=JSON::PP::true for values %{$rules_raw->{writes}{fields}};
my $rules_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($rules_raw),adapter=>$adapter);
refusal('missing capability precedes protected stored-candidate reads',{%$full,update=>0},sub{
    $rules_engine->execute_write(Selecto::Write::Command->new(operation=>'update',relation=>'line_items',
        assignments=>{quantity=>3},predicate=>Selecto::Expression->eq('id',1)))
},'write_capability_missing');
refusal('missing protocol preview',$missing,sub{$engine->preview_write(insert())},'invalid_write_capabilities');
refusal('missing protocol direct execution',$missing,sub{$engine->execute_write(insert())},'invalid_write_capabilities');
refusal('wrong protocol batch',{%$full,protocol_version=>99},sub{$engine->execute_batch(Selecto::Write::Batch->new(insert(),update()))},'write_protocol_mismatch');
refusal('wrong protocol graph',{%$full,protocol_version=>99},sub{$engine->execute_graph(graph())},'write_protocol_mismatch');
refusal('missing insert semantics',{%$full,insert=>0},sub{$engine->execute_write(insert())},'write_capability_missing');
refusal('missing returning semantics',{%$full,returning=>0},sub{$engine->execute_write(insert(metadata=>{returning=>['id']}))},'write_capability_missing');
refusal('wrong returning operation',{%$full,returning=>{update=>1}},sub{$engine->execute_write(insert(metadata=>{returning=>['id']}))},'write_capability_missing');
refusal('missing atomic batch',{%$full,atomic_batch=>0},sub{$engine->execute_batch(Selecto::Write::Batch->new(insert(),update()))},'write_capability_missing');
refusal('missing transactions',{%$full,transactions=>0},sub{$engine->execute_batch(Selecto::Write::Batch->new(insert(),update()))},'write_capability_missing');
refusal('missing graph support',{%$full,write_graph=>0},sub{$engine->execute_graph(graph())},'write_capability_missing');
refusal('missing generated keys',{%$full,generated_keys=>0},sub{$engine->execute_graph(graph())},'write_capability_missing');
refusal('missing graph source returning',{%$full,returning=>0},sub{$engine->execute_graph(graph())},'write_capability_missing');
refusal('missing native mapping',$full,sub{$engine->execute_write(insert(metadata=>{native_constraints=>[{name=>'declared',code=>'conflict'}]}))},'write_capability_missing');
refusal('trusted unsafe SQL entry still requires protocol',$missing,sub{$adapter->execute_write_unsafe(insert())},'invalid_write_capabilities');
$adapter->{report_failure}=1;
refusal('provider callback failure',$full,sub{$engine->execute_write(insert())},'invalid_write_capabilities');
delete $adapter->{report_failure};delete $adapter->{report};

# Pure native governance is usable with a compile-only adapter; it does not
# infer dispatch semantics or require an adapter protocol during compilation.
$adapter->{report}=$missing;$adapter->{report_calls}=0;
my $governed=$engine->governed_write(insert());
isa_ok($governed,'Selecto::Write::Command','adapter-neutral governance still produces a native command');
is($adapter->{report_calls},0,'pure governance does not discover runtime capabilities');
delete $adapter->{report};
$adapter->{dispatches}=0;($prepares,$updates)=(0,0);
$db->sqlite_set_authorizer(sub {++$prepares;0});
my $result=$engine->execute_write(insert(assignments=>{id=>2,name=>'native'},metadata=>{returning=>['id']}));
is($result->values->{id},2,'supported real SQLite insert returns the actual native id');
is($adapter->{dispatches},1,'positive direct execution reaches exactly one adapter dispatch');
ok($prepares>0 && $updates>0,'positive direct execution really prepares and mutates native SQLite');
my $batch=$engine->execute_batch(Selecto::Write::Batch->new(insert(assignments=>{id=>3,name=>'batch'}),update()));
is(scalar(@$batch),2,'supported actual batch produces both native results');
my $graph_result=$engine->execute_graph(graph());
ok(defined($graph_result->root->values->{id}),'supported generated graph materializes the actual parent key');
$db->sqlite_set_authorizer(undef);
is_deeply($db->selectall_arrayref('SELECT id,name FROM items ORDER BY id'),[[1,'changed'],[2,'native'],[3,'batch'],[4,'safe']], 'actual direct/batch/graph effects are retained');
is_deeply($db->selectall_arrayref('SELECT parent_id,name FROM children'),[[4,'actual child']], 'actual generated binding stores the returned parent ownership key');
my $independent=Selecto::Write::Graph->new(nodes=>[
    {id=>'first',command=>insert(assignments=>{id=>5,name=>'first root row'})},
    {id=>'second',command=>insert(assignments=>{id=>6,name=>'second root row'})},
]);
is_deeply([map{$_->{bindings}}@{$independent->nodes}],[[],[]],'native constructor preserves both independent graph rows');
my ($prepared,$contexts)=$engine->_prepared_graph($independent);
is(Scalar::Util::refaddr($contexts->{second}{domain}),Scalar::Util::refaddr($engine->domain),
    'independent graph row retains the actual root domain context');
$engine->execute_graph($independent);
is_deeply($db->selectall_arrayref('SELECT id,name FROM items WHERE id IN (5,6) ORDER BY id'),
    [[5,'first root row'],[6,'second root row']], 'actual governed graph stores both independent root rows');
refusal('independent graph cannot infer another relation',$full,sub{$engine->execute_graph(
    Selecto::Write::Graph->new(nodes=>[
        {id=>'prefix',command=>insert(assignments=>{id=>7,name=>'never written'})},
        {id=>'other',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'children',assignments=>{name=>'unbound'})},
    ]))},'write_relation_mismatch');
delete $adapter->{report};
my $tenant_raw={schema_version=>1,name=>'Tenant items',source=>{source_table=>'tenant_items',primary_key=>'id',
    tenant_field=>'tenant_id',fields=>[qw(id tenant_id name)],columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},
    schemas=>{},joins=>{},writes=>{operations=>{insert=>{enabled=>JSON::PP::true}},
        fields=>{id=>{insertable=>JSON::PP::true},name=>{insertable=>JSON::PP::true}},
        scope=>{tenant=>{field=>'tenant_id',satisfied_by=>['trusted_context']}}}};
my $tenant_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($tenant_raw,strict=>1),adapter=>$adapter,scope=>{tenant=>7});
$tenant_engine->execute_graph(Selecto::Write::Graph->new(nodes=>[
    {id=>'first',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'tenant_items',assignments=>{id=>3,name=>'first scoped'})},
    {id=>'second',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'tenant_items',assignments=>{id=>4,name=>'second scoped'})},
]));
is_deeply($db->selectall_arrayref('SELECT id,tenant_id,name FROM tenant_items ORDER BY id'),
    [[1,7,'own'],[2,9,'other'],[3,7,'first scoped'],[4,7,'second scoped']],
    'both independent graph rows use actual trusted tenant governance');
refusal('independent child preserves trusted tenant',$full,sub{$tenant_engine->execute_graph(
    Selecto::Write::Graph->new(nodes=>[
        {id=>'prefix',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'tenant_items',assignments=>{id=>5,name=>'never written'})},
        {id=>'other',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'tenant_items',assignments=>{id=>6,name=>'wrong tenant',tenant_id=>9})},
    ]))},'tenant_mismatch');
delete $adapter->{report};
ok($db->sqlite_get_autocommit,'successful native writes restore autocommit');
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP remains in memory');
ok(!grep(length($_->[2]),@{$db->selectall_arrayref('PRAGMA database_list')}),'all native SQLite schemas remain in memory');
$db->sqlite_update_hook(undef);$db->disconnect;
done_testing;
