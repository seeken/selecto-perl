use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::Operation;
plan skip_all => 'DBD::SQLite is not installed' unless eval {require DBI;require DBD::SQLite;1};

sub domain {
    return {name => 'items', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id tenant_id account_id name quantity)],
        columns => {map {$_=>{type=>$_ eq 'name'||$_ eq 'tenant_id'?'string':'integer'}} qw(id tenant_id account_id name quantity)},
        associations => {}}, schemas => {}, writes => {
        operations => {map {$_ => {enabled=>JSON::PP::true,returning=>'all',
            ($_ eq 'upsert'?(conflict_targets=>[[qw(tenant_id name)]]):())}} qw(insert update upsert delete)},
        fields => {tenant_id=>{insertable=>JSON::PP::true,immutable=>JSON::PP::true},
            account_id=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true},
            name=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true,required_on=>['insert']},
            quantity=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}},
        scope=>{tenant=>{field=>'tenant_id',required=>JSON::PP::true,satisfied_by=>['trusted_context']}},
        constraints=>{foreign_keys=>{account_id=>{source=>['context','account_id'],required=>JSON::PP::true,
            references=>{relation=>'accounts',field=>'id'}}}}}};
}
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('PRAGMA foreign_keys=OFF');
$db->do('CREATE TABLE accounts(id INTEGER PRIMARY KEY)');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,tenant_id TEXT,account_id INTEGER,name TEXT,quantity INTEGER,UNIQUE(tenant_id,name))');
$db->do('INSERT INTO accounts VALUES(42)');
my $raw=domain();my$adapter=Selecto->adapter(sqlite=>(dbh=>$db));
sub engine {my($account)=@_;Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>$adapter,write_context=>{tenant_id=>'tenant-a',account_id=>$account})}
sub op {Selecto::Write::Operation->new($raw)->with_tenant({tenant_id=>'tenant-a'})}
sub compile {my($operation,$account)=@_;$operation->compile(context=>{account_id=>$account//42})}
my $engine=engine(42);
my $insert=compile(op()->insert({name=>'one',quantity=>1}));
my $created=$engine->execute_write($insert->{command});
isa_ok $created,'Selecto::Write::Result','actual native insert executes compiled intent';
is_deeply $db->selectall_arrayref('SELECT tenant_id,account_id,name,quantity FROM items'),
    [['tenant-a',42,'one',1]],'native storage contains actual trusted fills';
is $created->values->{account_id},42,'actual returning includes the context foreign key';
my $upsert=compile(op()->upsert({name=>'one',quantity=>2}));
is $engine->execute_write($upsert->{command})->affected_rows,1,'actual tenant-scoped conflict branch executes';
is_deeply $db->selectall_arrayref('SELECT tenant_id,account_id,name,quantity FROM items'),
    [['tenant-a',42,'one',2]],'upsert updates only admitted update fields';
$db->do(q{INSERT INTO items VALUES(2,'tenant-b',42,'other',5)});
my $before=$db->selectall_arrayref('SELECT * FROM items ORDER BY id');
eval {$engine->execute_write(compile(op()->update({quantity=>99})->filter(['id',2]))->{command})};
isa_ok $@,'Selecto::Error','other tenant target cannot be updated';
is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'),$before,'tenant refusal preserves all rows';

my $missing=compile(op()->insert({name=>'missing',quantity=>3}),99);
eval {engine(99)->execute_write($missing->{command})};
isa_ok $@,'Selecto::Error','missing actual context parent refuses with native foreign keys disabled';
is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'),$before,'existence guard alone prevents orphan storage';
$db->do('INSERT INTO accounts VALUES(99)');
is engine(99)->execute_write($missing->{command})->affected_rows,1,'same compiled intent succeeds once the actual parent exists';
is $db->selectrow_array(q{SELECT account_id FROM items WHERE name='missing'}),99,'guarded insert persists exact referenced value';
my $raw_command=Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{name=>'raw',account_id=>7});
my $before_raw=$db->selectall_arrayref('SELECT * FROM items ORDER BY id');
eval {$engine->execute_write($raw_command)};
isa_ok $@,'Selecto::Error','raw native command cannot override trusted context source';
is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'),$before_raw,'context mismatch has no effect';

my $update=compile(op()->update({quantity=>8})->filter(['id',1]));
is $engine->execute_write($update->{command})->values->{quantity},8,'native update returns actual persisted prospective value';
my $delete=compile(op()->delete->filter(['id',1]));
is $engine->execute_write($delete->{command})->affected_rows,1,'native delete executes compiled scope';
is_deeply $db->selectall_arrayref('SELECT tenant_id,name FROM items ORDER BY id'),
    [['tenant-b','other'],['tenant-a','missing']],'other tenant and unrelated owned row remain exact';
is $db->selectrow_array('PRAGMA foreign_keys'),0,'test proves actual guards without database FK constraints';
is $db->selectrow_array('PRAGMA temp_store'),2,'temporary storage is memory';
ok !grep(length($_->[2]),@{$db->selectall_arrayref('PRAGMA database_list')}),'all databases are in memory';
# Use an independently configured host domain to prove the portable command
# itself carries its captured/required guard, beyond native domain enforcement.
my $guarded_raw=domain();$guarded_raw->{required_filters}=[['gte','quantity',5]];
my $guarded_op=Selecto::Write::Operation->new($guarded_raw)->with_tenant({tenant_id=>'tenant-a'});
my $bad_candidate=$guarded_op->insert({name=>'guarded-low',quantity=>4})->compile(context=>{account_id=>42},storage_backend=>'sqlite');
my $guard_before=$db->selectall_arrayref('SELECT * FROM items ORDER BY id');
eval {$engine->execute_write($bad_candidate->{command})};
isa_ok $@,'Selecto::Error','native typed insert enforces portable required guard on a host without that guard';
is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'),$guard_before,'typed candidate refusal preserves the whole database';
my $good_candidate=$guarded_op->insert({name=>'guarded-ok',quantity=>5})->compile(context=>{account_id=>42},storage_backend=>'sqlite');
is $engine->execute_write($good_candidate->{command})->affected_rows,1,'same actual required guard admits an eligible stored candidate';
my $captured_query=$engine->query->where(Selecto::Expression->gte('quantity',5));
my $captured=op()->update({name=>'captured'})->filter(['name','missing'])->enforce_query($captured_query);
my $captured_command=compile($captured)->{command};
$captured_query->{predicate}=Selecto::Expression->eq('quantity',3);
my $capture_before=$db->selectall_arrayref('SELECT * FROM items ORDER BY id');
eval {$engine->execute_write($captured_command)};
isa_ok $@,'Selecto::Error','captured query guard survives later mutation of the original query';
is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'),$capture_before,'captured guard refusal preserves exact rows';
my $eligible=op()->update({quantity=>6})->filter(['name','guarded-ok'])->enforce_query($engine,$engine->query->where(Selecto::Expression->gte('quantity',5)));
is $engine->execute_write(compile($eligible)->{command})->values->{quantity},6,'captured query permits a matching native update';
my $capture_snapshot=$eligible->snapshot;$capture_snapshot->{query_enforcement}{filters}=[['quantity',999]];
is $engine->execute_write(compile($eligible)->{command})->affected_rows,1,'snapshot edits cannot modify private captured evidence';
my $captured_insert=op()->insert({name=>'captured-low',quantity=>1})->enforce_query($engine->query->where(Selecto::Expression->gte('quantity',5)));
my $capture_insert_before=$db->selectall_arrayref('SELECT * FROM items ORDER BY id');
eval {$engine->execute_write(compile($captured_insert)->{command})};
isa_ok $@,'Selecto::Error','captured SQLite backend defers insert guard to actual typed storage admission';
is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'),$capture_insert_before,'captured insert refusal leaves no candidate row';
my $other_raw=domain();$other_raw->{name}='other';$other_raw->{source}{source_table}='other_items';
my $other_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($other_raw),adapter=>$adapter);
eval {compile(op()->update({name=>'bad-source'})->filter(['id',1])->enforce_query($other_engine->query->where(Selecto::Expression->eq('id',1))))};
isa_ok $@,'Selecto::Error','captured query from another source refuses';
is $@->code,'query_source_mismatch','source refusal has precise code';
eval {op()->insert({name=>'empty'})->enforce_query($engine->query)};
is $@->code,'query_enforcement_requires_filter','empty query cannot produce enforcement evidence';
eval {op()->insert({name=>'forged'})->enforce_query(bless({},'Selecto::Query'))};
is $@->code,'invalid_query_enforcement','unbound forged query cannot assert a configured source';
{
    package QueryEnforcementTrap;
    our $calls=0;
    sub TIEHASH {bless {},shift}
    sub FIRSTKEY {$calls++;die 'tie hook must not run'}
    sub FETCH {$calls++;die 'tie hook must not run'}
}
my $tied_query=$engine->query->where(Selecto::Expression->eq('id',1));
tie my %trap,'QueryEnforcementTrap';$tied_query->{unused}=\%trap;
eval {op()->update({name=>'trap'})->filter(['id',1])->enforce_query($tied_query)};
is $@->code,'invalid_query_enforcement','unused tied native query metadata refuses before accessors';
is $QueryEnforcementTrap::calls,0,'capturing invokes no tied callbacks';
$db->do(q{INSERT INTO items(tenant_id,account_id,name,quantity) VALUES('tenant-a',42,'not_null',10),('tenant-a',42,'ordinary-string',10)});
my $literal_capture=op()->update({quantity=>11})->enforce_query($engine->query->where(Selecto::Expression->eq('name','not_null')));
is $engine->execute_write(compile($literal_capture)->{command})->affected_rows,1,'captured literal not_null equality targets exactly its matching row';
is_deeply $db->selectall_arrayref(q{SELECT name,quantity FROM items WHERE name IN ('not_null','ordinary-string') ORDER BY name}),
    [['not_null',11],['ordinary-string',10]],'literal operator spelling never broadens native captured write scope';
$db->do('CREATE TABLE peculiar(id INTEGER PRIMARY KEY,is_null TEXT,name TEXT)');
$db->do(q{INSERT INTO peculiar VALUES(1,'one',NULL),(2,'two','ordinary')});
my $peculiar={name=>'peculiar',source=>{source_table=>'peculiar',primary_key=>'id',fields=>[qw(id is_null name)],
    columns=>{id=>{type=>'integer'},is_null=>{type=>'string'},name=>{type=>'string'}},associations=>{}},schemas=>{},
    writes=>{operations=>{update=>{enabled=>JSON::PP::true,returning=>'all'}},fields=>{name=>{updatable=>JSON::PP::true}}}};
my $peculiar_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($peculiar),adapter=>$adapter);
my $null_capture=Selecto::Write::Operation->new($peculiar)->update({name=>'selected'})
    ->enforce_query($peculiar_engine->query->where(Selecto::Expression->is_null('name')));
is $peculiar_engine->execute_write($null_capture->compile->{command})->affected_rows,1,'captured null operator retains identity when a root field has the same name';
is_deeply $db->selectall_arrayref('SELECT id,is_null,name FROM peculiar ORDER BY id'),
    [[1,'one','selected'],[2,'two','ordinary']],'operator/field collision preserves exact unrelated rows';
my $scoped_read=$engine->require_tenant_filter('name','not_null');
my $scoped_capture=op()->update({quantity=>12})->enforce_query($scoped_read->query->where(Selecto::Expression->gt('id',0)));
is $engine->execute_write(compile($scoped_capture)->{command})->affected_rows,1,'captured query preserves additional configured read filters against an independent write host';
is_deeply $db->selectall_arrayref(q{SELECT name,quantity FROM items WHERE name IN ('not_null','ordinary-string') ORDER BY name}),
    [['not_null',12],['ordinary-string',10]],'configured read scope and literal identity survive native write compilation';
$db->do(q{ATTACH DATABASE ':memory:' AS auxiliary});
$db->do('CREATE TABLE auxiliary.items(id INTEGER PRIMARY KEY,name TEXT)');
$db->do(q{INSERT INTO auxiliary.items VALUES(1,'attached')});
my $prefix_read=$engine->with_tenant({prefix=>'auxiliary'});
my $prefix_query=$prefix_read->query->where(Selecto::Expression->gt('id',0));
my $capture_prepares=0;$db->sqlite_set_authorizer(sub {$capture_prepares++;return 0});
eval {op()->update({quantity=>100})->enforce_query($prefix_query)};
is $@->code,'query_source_mismatch','prefix-routed query cannot become authority for an unqualified main-table write';
is $capture_prepares,0,'prefix source refusal occurs before native prepare';
$db->sqlite_set_authorizer(undef);
is_deeply $db->selectall_arrayref('SELECT * FROM auxiliary.items'),[[1,'attached']],'attached source remains exact';
is_deeply $db->selectall_arrayref(q{SELECT name,quantity FROM main.items WHERE name IN ('not_null','ordinary-string') ORDER BY name}),
    [['not_null',12],['ordinary-string',10]],'main source remains exact after captured prefix refusal';
ok !grep(length($_->[2]),@{$db->selectall_arrayref('PRAGMA database_list')}),'attached control also uses only memory schemas';
my $projected=Selecto::Domain->project($raw,'write');
my $projected_operation=Selecto::Write::Operation->new($projected)->with_tenant({tenant_id=>'tenant-a'})
    ->update({quantity=>13})->filter(['name','not_null'])
    ->enforce_query($engine->query->where(Selecto::Expression->eq('name','not_null')));
is $engine->execute_write(compile($projected_operation)->{command})->affected_rows,1,'public projected write domain preserves captured query source identity without native read re-import';
is $db->selectrow_array(q{SELECT quantity FROM items WHERE name='not_null'}),13,'projected captured write has actual guarded storage effect';
my $versioned_raw=domain();$versioned_raw->{domain_fingerprint}='published-v1';
my $versioned_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($versioned_raw),adapter=>$adapter);
my $wrong_version=Selecto::Domain->project($versioned_raw,'write');$wrong_version->{domain_fingerprint}='published-v2';
eval {compile(Selecto::Write::Operation->new($wrong_version)->with_tenant({tenant_id=>'tenant-a'})
    ->update({quantity=>14})->filter(['name','not_null'])
    ->enforce_query($versioned_engine->query->where(Selecto::Expression->eq('name','not_null'))))};
is $@->code,'query_source_mismatch','contradictory published fingerprints still refuse at the pure boundary';
is $db->selectrow_array(q{SELECT quantity FROM items WHERE name='not_null'}),13,'published identity refusal performs no mutation';
$db->disconnect;
done_testing;
