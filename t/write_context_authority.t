use 5.034;
use strict;
use warnings;
use Test::More;
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Write::Context ();
use Selecto::Write::Operation ();

sub error_code {
    my ($work)=@_;return 'ok' if eval{$work->();1};
    my $error=$@;return blessed($error) && ref($error) eq 'Selecto::Error' ? $error->code : "untyped: $error";
}
sub raw_domain {
    my ($table,%options)=@_;
    return {name=>'Context authority',source=>{source_table=>$table,primary_key=>'id',
        fields=>[qw(id tenant_id account_id name)],columns=>{
            id=>{type=>'integer'},tenant_id=>{type=>'string'},account_id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},
        writes=>{operations=>{map{$_=>{enabled=>JSON::PP::true,($_ eq 'update' ? (bulk=>JSON::PP::true) : ())}}qw(insert update delete)},
            fields=>{map{$_=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}}qw(id tenant_id account_id name)},
            scope=>{tenant=>{required=>JSON::PP::true,field=>'tenant_id',satisfied_by=>['trusted_context']}},
            constraints=>{foreign_keys=>{account_id=>{source=>['context','account_id'],required=>JSON::PP::true,
                references=>{relation=>'accounts',field=>'id',%options}}}}}};
}
sub command {
    my ($table,%assignments)=@_;
    return Selecto::Write::Command->new(operation=>'insert',relation=>$table,assignments=>\%assignments);
}

my $C='Selecto::Write::Context';
is_deeply($C->resolve({}, {context=>[['tenant_id','a'],[{'$atom'=>'tenant_id'},'a'],['account_id',42]]}),
    {tenant_id=>'a',tenant_field=>'tenant_id',account_id=>42},'ordered plain and portable atom keys agree without overwriting');
is(error_code(sub{$C->resolve({}, {context=>[['tenant_id','a'],[{'$atom'=>'tenant_id'},'b']]})}),
    'tenant_mismatch','conflicting duplicate keys are refused');
is(error_code(sub{$C->resolve({}, {execution_scope=>{},context=>{tenant=>{tenant_id=>'a',tenant_field=>'account_id'},tenant_field=>'tenant_id'}})}),
    'tenant_mismatch','nested tenant field conflicts are refused');
my $calls=0;
isnt(error_code(sub{$C->resolve({}, {context=>{account_id=>sub{++$calls}}})}),'ok','callbacks refuse before context extraction');
is($calls,0,'context callback did not run');
{
    package ContextTie;
    sub TIEHASH{bless{},shift} sub FIRSTKEY{++$calls} sub NEXTKEY{++$calls} sub FETCH{++$calls} sub SCALAR{++$calls}
}
tie my %tied,'ContextTie';
isnt(error_code(sub{$C->resolve({}, {context=>\%tied})}),'ok','tied context refuses');
is($calls,0,'no tied context hooks ran');
isnt(error_code(sub{$C->applied_scope(\%tied)}),'ok','applied scope admits the complete snapshot before tied root extraction');
is($calls,0,'applied scope tied root hooks did not run');
{
    package ContextTieScalar;
    sub TIESCALAR { bless {},shift } sub FETCH { ++$calls; return {} }
}
my $tied_scope={};tie $tied_scope->{applied_scope},'ContextTieScalar';
isnt(error_code(sub{$C->applied_scope($tied_scope)}),'ok','applied scope refuses tied snapshot slot before FETCH');
is($calls,0,'applied scope tied slot hooks did not run');
is(error_code(sub{$C->applied_scope([])}),'invalid_write_context','applied scope malformed snapshot has typed refusal');
{
    package ContextClassZero;
    use overload '""'=>sub{++$calls;'tenant_id'},bool=>sub{++$calls;0},fallback=>1;
}
my $class_zero=bless {},'ContextClassZero';
isnt(error_code(sub{$C->resolve({}, {context=>[[$class_zero,'a']]})}),'ok','false-valued object key refuses');
is($calls,0,'no overload hooks ran');
my $deep=1;$deep=[$deep] for 1..70;
isnt(error_code(sub{$C->resolve({}, {context=>{nested=>$deep}})}),'ok','deep context refuses bounded admission');

my $legacy={domain=>{source=>'items',writes=>{scope=>{tenant=>{required=>JSON::PP::true,field=>'account_id',satisfied_by=>['trusted_context']}}}},
    type=>'insert',values=>{name=>'unchanged'},filters=>[['status','open']]};
my $scoped=$C->apply_execution_scope($legacy,{tenant_id=>'tenant-a'});
is_deeply($scoped->{values},$legacy->{values},'execution scope leaves payload unchanged');
is_deeply($scoped->{filters},[['status','open'],['account_id','tenant-a']],'canonical scope targets its actual field');
is_deeply($scoped->{applied_scope}{tenant}{sources},[{source=>'trusted_context',field=>'account_id',value=>'tenant-a',filter=>['account_id','tenant-a']}],
    'actual applied scope is auditable');
is($C->validate_tenant_scope($scoped),1,'applied trusted scope validates');
is_deeply($C->applied_scope($scoped),$scoped->{applied_scope},'public applied scope returns actual admitted metadata');
my $scope_copy=$C->applied_scope($scoped);$scope_copy->{tenant}{field}='other';
is($C->applied_scope($scoped)->{tenant}{field},'account_id','public applied scope copy cannot mutate the snapshot');
is(error_code(sub{$C->validate_tenant_scope($legacy)}),'missing_tenant_scope','unrelated filter does not satisfy required tenant');
my $atom_scope={%$legacy,filters=>[[{'$atom'=>'account_id'},'tenant-a']]};
is_deeply($C->apply_execution_scope($atom_scope,{tenant_id=>'tenant-a'})->{filters},$atom_scope->{filters},
    'scope injection does not invent mixed representation ambiguity beside an authored atom equality');
my $both_scope={%$legacy,filters=>[[{'$atom'=>'account_id'},'tenant-a'],['account_id','tenant-a']]};
is_deeply($C->apply_execution_scope($both_scope,{tenant_id=>'tenant-a'})->{filters},$both_scope->{filters},
    'scope facade retains the actual authored ambiguity for compiler refusal');

subtest 'native trusted authority and atomic references' => sub {
    eval{require DBI;require DBD::SQLite;1} or plan skip_all=>'DBD::SQLite is optional';
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $dbh->do('PRAGMA temp_store=MEMORY');$dbh->do('PRAGMA foreign_keys=OFF');
    is($dbh->selectrow_array('PRAGMA temp_store'),2,'TEMP is memory');
    is_deeply([map{$_->[2]}@{$dbh->selectall_arrayref('PRAGMA database_list')}],[''],'main is memory');
    $dbh->do('CREATE TABLE accounts(id INTEGER PRIMARY KEY,tenant_id TEXT,name TEXT)');
    $dbh->do("INSERT INTO accounts VALUES(42,'tenant-a','ours'),(43,'tenant-b','theirs')");
    for my $table(qw(items other_items)){$dbh->do("CREATE TABLE $table(id INTEGER PRIMARY KEY,tenant_id TEXT NOT NULL,account_id INTEGER,name TEXT)")}
    my $adapter=Selecto->adapter(sqlite=>dbh=>$dbh);
    my $new_engine=sub{my($table,$context,%refs)=@_;Selecto::Engine->new(domain=>Selecto::Domain->parse(raw_domain($table,%refs)),adapter=>$adapter,write_context=>$context)};
    my $engine=$new_engine->('items',{tenant_id=>'tenant-a',account_id=>42});
    my (@sql,@auth,@updates);
    $dbh->sqlite_trace(sub{push @sql,$_[0]});
    $dbh->sqlite_set_authorizer(sub{push @auth,[@_];0});
    $dbh->sqlite_update_hook(sub{push @updates,[@_]});
    my $zero=sub{
        my($label,$expected,$work)=@_;@sql=();@auth=();@updates=();
        is(error_code($work),$expected,$label);is(scalar(@sql),0,"$label: zero executed SQL");
        is(scalar(@auth),0,"$label: zero native prepare authority calls");is(scalar(@updates),0,"$label: zero update hooks");
    };
    $zero->('caller mismatching context FK','foreign_key_source_mismatch',sub{$engine->execute_write(command('items',id=>1,name=>'bad',account_id=>43))});
    $zero->('context-owned mutation expression','foreign_key_source_mismatch',sub{$engine->execute_write(command('items',id=>1,name=>'bad',account_id=>Selecto::Write::Expression->field('id')))});
    my $missing=$new_engine->('items',{tenant_id=>'tenant-a'});
    $zero->('missing required host context','missing_foreign_key_context',sub{$missing->execute_write(command('items',id=>1,name=>'bad'))});
    my $spoof=command('items',id=>1,name=>'bad',account_id=>43)->with_metadata({context=>{account_id=>43}});
    $zero->('command metadata cannot grant context','foreign_key_source_mismatch',sub{$engine->execute_write($spoof)});
    my $getter=$engine->write_context;$getter->{account_id}=43;
    is($engine->write_context->{account_id},42,'public context getter is independent');
    @sql=();@auth=();@updates=();
    is(error_code(sub{$engine->execute_write(command('items',id=>1,name=>'injected'))}),'ok','host context materializes missing required FK');
    is(scalar(@updates),1,'positive native write has one physical update hook');
    ok(grep(/EXISTS.*accounts/s,@sql),'actual business SQL checks parent existence');
    is_deeply($dbh->selectall_arrayref('SELECT * FROM items'),[[1,'tenant-a',42,'injected']],'actual stored tenant and context FK');
    is(error_code(sub{$engine->execute_write(command('items',id=>2,name=>'literal',account_id=>Selecto::Write::Expression->literal(42)))}),'ok','matching native literal unwraps once');
    my $no_parent=$new_engine->('items',{tenant_id=>'tenant-a',account_id=>999});
    @updates=();
    is(error_code(sub{$no_parent->execute_write(command('items',id=>3,name=>'missing'))}),'cardinality_mismatch','missing context parent refuses inside native SQL with SQLite FKs disabled');
    is(scalar(@updates),0,'missing parent has no physical prefix');
    my $explicit=$new_engine->('items',{tenant_id=>'tenant-a',account_id=>43},tenant_field=>'tenant_id');
    @updates=();
    is(error_code(sub{$explicit->execute_write(command('items',id=>3,name=>'cross-tenant'))}),'cardinality_mismatch','authored referenced tenant metadata is enforced');
    is(scalar(@updates),0,'cross-tenant parent has zero physical writes');
    my $input_raw=raw_domain('items',tenant_field=>JSON::PP::false);
    $input_raw->{writes}{constraints}{foreign_keys}{account_id}{source}='input';
    my $input_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($input_raw),adapter=>$adapter,write_context=>{tenant_id=>'tenant-a'});
    my $input_op=Selecto::Write::Operation->new($input_raw)->with_tenant({tenant_id=>'tenant-a'});
    my $compiled_missing=$input_op->insert({id=>4,name=>'missing shared input',account_id=>999})->compile;
    @updates=();
    is(error_code(sub{$input_engine->execute_write($compiled_missing->{command})}),'cardinality_mismatch','portable shared/input EXISTS survives native governance with database FKs disabled');
    is(scalar(@updates),0,'portable shared/input parent refusal has no physical writes');
    is(error_code(sub{$input_engine->execute_write($input_op->insert({id=>4,name=>'present shared input',account_id=>42})->compile->{command})}),
        'ok','portable shared/input native guard admits actual parent');
    my $undeclared_raw=raw_domain('items');$undeclared_raw->{writes}{constraints}{foreign_keys}{account_id}{source}='input';
    my $undeclared=Selecto::Engine->new(domain=>Selecto::Domain->parse($undeclared_raw),adapter=>$adapter,write_context=>{tenant_id=>'tenant-a'});
    $zero->('input reference cannot bypass absent tenant metadata','invalid_domain',sub{$undeclared->execute_write(command('items',id=>5,name=>'bad',account_id=>42)->with_metadata({portable_foreign_key_guards=>1}))});
    my $tight=$engine->with_write_context({required_filters=>[['name','eq','allowed']]});
    @updates=();
    is(error_code(sub{$tight->execute_write(command('items',id=>3,name=>'denied'))}),'query_rule_violation','trusted required filter checks inserted candidate');
    is(scalar(@updates),0,'required-filter refusal writes nothing');
    is(error_code(sub{$tight->execute_write(command('items',id=>3,name=>'allowed'))}),'ok','trusted required filter admits matching candidate');
    my $mutated=$new_engine->('items',{tenant_id=>'tenant-a',account_id=>42});$mutated->{write_context}{account_id}=43;
    $zero->('mutated configured context','domain_modified_after_configuration',sub{$mutated->execute_write(command('items',id=>4,name=>'bad'))});
    $zero->('conflicting immutable context','tenant_mismatch',sub{$engine->with_write_context({tenant_id=>'tenant-b'})});
    my $other=$new_engine->('other_items',{tenant_id=>'tenant-a',account_id=>42});
    my $batch=Selecto::Write::Batch->new(command('items',id=>10,name=>'batch'),command('other_items',id=>10,name=>'batch'));
    $zero->('default batch cannot retarget domain','write_relation_mismatch',sub{$engine->execute_batch($batch)});
    $zero->('configured batch needs exact engine count','invalid_write',sub{$engine->execute_batch($batch,engines=>[$engine])});
    my $different=$new_engine->('other_items',{tenant_id=>'tenant-b',account_id=>43});
    $zero->('configured batch contexts must agree','tenant_mismatch',sub{$engine->execute_batch($batch,engines=>[$engine,$different])});
    my $adapter2=Selecto->adapter(sqlite=>dbh=>$dbh);
    my $other_adapter=Selecto::Engine->new(domain=>Selecto::Domain->parse(raw_domain('other_items')),adapter=>$adapter2,write_context=>$engine->write_context);
    $zero->('configured batch adapter identity must agree','invalid_write',sub{$engine->execute_batch($batch,engines=>[$engine,$other_adapter])});
    my $forged=bless{%$other},'Selecto::Engine';
    $zero->('copied public engine state is not authority','invalid_write',sub{$engine->execute_batch($batch,engines=>[$engine,$forged])});
    is(error_code(sub{$engine->execute_batch($batch,engines=>[$engine,$other])}),'ok','explicit configured domains dispatch one atomic native batch');
    is_deeply($dbh->selectall_arrayref('SELECT * FROM other_items'),[[10,'tenant-a',42,'batch']],'second configured domain stores real row');
    my $atomic=Selecto::Write::Batch->new(command('items',id=>20,name=>'prefix'),command('other_items',id=>10,name=>'duplicate'));
    isnt(error_code(sub{$engine->execute_batch($atomic,engines=>[$engine,$other])}),'ok','later native constraint failure is refused');
    is($dbh->selectrow_array('SELECT count(*) FROM items WHERE id=20'),0,'cross-domain later failure rolls back the first domain');
    $dbh->do('CREATE TABLE children(id INTEGER PRIMARY KEY,tenant_id TEXT,account_id INTEGER,name TEXT,parent_id INTEGER)');
    my $child=raw_domain('children');delete $child->{name};
    push @{$child->{source}{fields}},'parent_id';$child->{source}{columns}{parent_id}={type=>'integer'};
    $child->{writes}{fields}{parent_id}={insertable=>1};
    my $parent_raw=raw_domain('items');
    $parent_raw->{writes}{relationships}{children}={writable=>1,table=>'children',parent_key=>'id',child_key=>'parent_id',allowed_ops=>['insert'],domain=>$child};
    my $parent_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($parent_raw),adapter=>$adapter,write_context=>$engine->write_context);
    my $graph=sub{my($account)=@_;Selecto::Write::Graph->new(nodes=>[
        {id=>'root',command=>command('items',id=>30,name=>'graph')},
        {id=>'child',command=>command('children',id=>30,name=>'child',defined($account)?(account_id=>$account):()),
            bindings=>[{field=>'parent_id',from=>'root',key=>'id'}]}],metadata=>{label=>'context-native'})};
    $zero->('nested context mismatch refuses before root prefix','foreign_key_source_mismatch',sub{$parent_engine->execute_graph($graph->(43))});
    is(error_code(sub{$parent_engine->execute_graph($graph->())}),'ok','nested actual domain inherits independently trusted context');
    is_deeply($dbh->selectall_arrayref('SELECT * FROM children'),[[30,'tenant-a',42,'child',30]],'native child receives exact context, tenant and actual parent binding');
    ok(!exists($child->{name}),'native optional-name bridge leaves authored child domain unchanged');
    for my $returning ([],['name']) {
        my $protected=raw_domain('items');
        my $protected_child=Selecto::Domain::QueryContract->copy_declaration($child);
        $protected->{writes}{operations}{insert}{returning}=@$returning ? ['name'] : 'none';
        $protected_child->{writes}{operations}{insert}{returning}='none';
        for my $spec ([$protected,'name','protected'],[$protected_child,'account_id',42]) {
            my ($raw,$field,$value)=@$spec;
            $raw->{rules}={schema=>'selecto.data_rules.v1',normalizers=>{},
                definitions=>{actual=>{version=>1,test=>{op=>'value.eq',value=>$value}}},
                bindings=>{actual=>{subject=>{scope=>'candidate',path=>[$field]},operations=>['insert'],rule=>{id=>'actual',version=>1}}}};
        }
        $protected->{writes}{relationships}{children}={writable=>1,table=>'children',parent_key=>'id',child_key=>'parent_id',allowed_ops=>['insert'],domain=>$protected_child};
        $protected->{rules}{definitions}{one_child}={version=>1,test=>{op=>'collection.count',exact=>1}};
        $protected->{rules}{bindings}{one_child}={subject=>{scope=>'candidate',path=>['children']},operations=>['insert'],rule=>{id=>'one_child',version=>1}};
        my $protected_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($protected),adapter=>$adapter,write_context=>$engine->write_context);
        my $id=@$returning ? 32 : 31;
        my $protected_graph=Selecto::Write::Graph->new(nodes=>[
            {id=>'root',command=>command('items',id=>$id,name=>'protected')->with_metadata({returning=>$returning})},
            {id=>'child',command=>command('children',id=>$id,name=>'protected child')->with_metadata({returning=>[]}),
                bindings=>[{field=>'parent_id',from=>'root',key=>'id'}]}]);
        my $result;
        is(error_code(sub{$result=$protected_engine->execute_graph($protected_graph)}),'ok','protected graph governs public returning before actual internal key materialization');
        is_deeply($result->root->values,@$returning ? {name=>'protected'} : {},'protected public root result omits internal parent key');
        is_deeply($result->nodes->{child}->values,{},'protected public child none returning stays empty');
        is_deeply($dbh->selectrow_arrayref('SELECT tenant_id,account_id,name,parent_id FROM children WHERE id=?',undef,$id),
            ['tenant-a',42,'protected child',$id],'protected native child retains actual context FK and generated binding');
        my $extra=Selecto::Write::Graph->new(nodes=>[{id=>'root',command=>command('items',id=>$id+100,name=>'protected')->with_metadata({returning=>['id']})}]);
        $zero->('public id returning cannot use the internal binding exception','returning_policy_violation',sub{$protected_engine->execute_graph($extra)});
    }
    my $wide=raw_domain('items');my %wide_values;
    for my $i (1..100) {
        my $field="fk_$i";push @{$wide->{source}{fields}},$field;
        $wide->{source}{columns}{$field}={type=>'integer'};
        $wide->{writes}{fields}{$field}={insertable=>JSON::PP::true};
        $wide->{writes}{constraints}{foreign_keys}{$field}={source=>'input',references=>{relation=>'accounts',field=>'id',tenant_field=>JSON::PP::false}};
        $wide_values{$field}=42;
    }
    for my $i (1..300) {$wide->{schemas}{"schema_$i"}={source_table=>"schema_$i",primary_key=>'id',fields=>['id'],columns=>{id=>{type=>'integer'}},associations=>{}}}
    my $wide_engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($wide),adapter=>$adapter,write_context=>$engine->write_context);
    $zero->('cumulative FK metadata work is bounded','invalid_domain',sub{$wide_engine->execute_write(command('items',id=>90,name=>'wide',%wide_values))});
    $dbh->sqlite_trace(undef);$dbh->sqlite_set_authorizer(undef);$dbh->sqlite_update_hook(undef);$dbh->disconnect;
};
done_testing;
