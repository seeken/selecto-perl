use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::FieldValidators ();
BEGIN { eval { require DBI;require DBD::SQLite;1 } or plan skip_all=>'DBD::SQLite is optional' }

{
    package FieldValidatorAdapter;
    use parent 'Selecto::SQLite';
    sub write_capabilities { ++$_[0]{providers};shift->SUPER::write_capabilities(@_) }
    sub execute_query { ++$_[0]{hydrations};shift->SUPER::execute_query(@_) }
    sub rule_project_subject { ++$_[0]{projections};shift->SUPER::rule_project_subject(@_) }
}
sub copy { Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value} }
sub failure {
    my ($work)=@_;my $ok=eval { $work->();1 };return undef if $ok;
    my $error=$@;die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';return $error;
}
sub domain {
    my ($table)=@_;return {name=>'Native field validators',source=>{source_table=>$table,primary_key=>'id',
        fields=>[qw(id name amount code other parent_id)],columns=>{
            map { $_=>{type=>$_ eq 'id'||$_ eq 'amount'||$_ eq 'parent_id'?'integer':'string'} } qw(id name amount code other parent_id)},associations=>{}},schemas=>{},joins=>{},
        writes=>{operations=>{map { $_=>{enabled=>JSON::PP::true,($_ ne 'insert'?(require_filter=>JSON::PP::true):())} } qw(insert update delete)},
            fields=>{map { $_=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true} } qw(id name amount code other parent_id)}}};
}
sub update {
    my ($table,$values)=@_;return Selecto::Write::Command->new(operation=>'update',relation=>$table,
        assignments=>$values,predicate=>Selecto::Expression->eq('id',1));
}
sub input_rule {
    my ($raw,$field,$test,$steps)=@_;
    $raw->{rules}={schema=>'selecto.data_rules.v1',definitions=>{submitted=>{version=>1,test=>$test}},
        normalizers=>{normalize=>{version=>1,steps=>$steps}},bindings=>{
            submitted=>{subject=>{scope=>'input',path=>[$field]},operations=>['insert','update'],
                rule=>{id=>'submitted',version=>1},normalizer=>{id=>'normalize',version=>1}}}};
}
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,amount INTEGER,code TEXT,other TEXT,parent_id INTEGER)');
$db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,name TEXT,amount INTEGER,code TEXT,other TEXT,parent_id INTEGER)');
$db->do(q{INSERT INTO items VALUES(1,'before',3,'ABC','stored',NULL)});
my $adapter=FieldValidatorAdapter->new(dbh=>$db);
my $engine=sub { Selecto::Engine->new(domain=>Selecto::Domain->parse($_[0]),adapter=>$adapter,($_[1]?(limits=>$_[1]):())) };
my (@sql,@authorizer,@hooks);
$db->sqlite_trace(sub { push @sql,$_[0] });
$db->sqlite_set_authorizer(sub { push @authorizer,[@_];0 });
$db->sqlite_update_hook(sub { push @hooks,[@_] });
my $snapshot=sub { $db->selectall_arrayref('SELECT * FROM items ORDER BY id') };
my $zero=sub {
    my ($label,$code,$work)=@_;my $before=$snapshot->();
    @sql=();@authorizer=();@hooks=();@$adapter{qw(providers hydrations projections)}=(0,0,0);
    my $error=failure($work);is($error ? $error->code : 'ok',$code,$label);
    is(scalar @sql,0,"$label: no executed SQL");is(scalar @authorizer,0,"$label: no native prepare");
    is(scalar @hooks,0,"$label: no mutation hooks");is($adapter->{providers},0,"$label: no capability provider");
    is($adapter->{hydrations},0,"$label: no stored hydration");is($adapter->{projections},0,"$label: no native candidate projection");
    is_deeply($snapshot->(),$before,"$label: complete business rows unchanged");
};
my $raw=domain('items');$raw->{writes}{fields}{name}{validators}=['unsupported-validator'];
my $unknown=$engine->($raw);
$zero->('native command node limit retains write admission error precedence','invalid_write',sub {
    $engine->($raw,Selecto::Limits->new(max_expression_nodes=>2))->preview_write(update('items',{name=>'after'}));
});
$zero->('unknown assigned validator refuses raw native update','unsupported_write_rule',sub { $unknown->execute_write(update('items',{name=>'after'})) });
$zero->('preview uses the same validator boundary','unsupported_write_rule',sub { $unknown->preview_write(update('items',{name=>'after'})) });
ok(!failure(sub { $unknown->execute_write(update('items',{other=>'unassigned validator remains inactive'})) }),'unknown unassigned validator permits a partial update');
is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'before','unassigned invalid field was not rewritten');

for my $case (
    ['number','amount',[['number',[['greater_than',0],['greater_than_or_equal_to',2],['less_than',5],['less_than_or_equal_to',4]]]],3,0],
    ['length','name',[['length',[['min',2],['max',3]]]],'éx','x'],
    ['format','code',[['format',{source=>'[A-Z]+',opts=>''}]],'ABC','A1'],
    ['inclusion','name',[['inclusion',['a','b']]],'a','c'],
    ['exclusion','name',[['exclusion',['blocked','denied']]],'allowed','blocked'],
) {
    my ($kind,$field,$validators,$good,$bad)=@$case;my $d=domain('items');$d->{writes}{fields}{$field}{validators}=$validators;
    my $e=$engine->($d);ok(!failure(sub { $e->execute_write(update('items',{$field=>$good})) }),"$kind validator admits actual native assignment");
    is($db->selectrow_array("SELECT $field FROM items WHERE id=1"),$good,"$kind accepted value is physically stored");
    $zero->("$kind rejection",'data_rule_failed',sub { $e->execute_write(update('items',{$field=>$bad})) });
}
my $normalized=domain('items');$normalized->{source}{columns}{name}{text_case}='uppercase';
$normalized->{writes}{fields}{name}{validators}=[['inclusion',['AB']]];
my $normalized_engine=$engine->($normalized);
ok(!failure(sub { $normalized_engine->execute_write(update('items',{name=>Selecto::Write::Expression->literal('ab')})) }),'literal expression is normalized before field validation');
is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'AB','actual normalized literal is stored');
input_rule($normalized,'name',{op=>'text.length',unit=>'unicode_scalar',min=>1},[{op=>'text.trim',profile=>'ascii_v1'}]);
my $input_engine=$engine->($normalized);
ok(!failure(sub { $input_engine->execute_write(update('items',{name=>' ab '})) }),'INPUT trim precedes domain uppercase and validator evaluation');
is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'AB','INPUT/domain normalized assigned value reaches native storage');
$zero->('INPUT-normalized validator failure precedes hydration','data_rule_failed',sub { $input_engine->execute_write(update('items',{name=>' bad '})) });
$zero->('active mutation expression has no forged scalar value','required_data_rule_pending',sub { $normalized_engine->execute_write(update('items',{name=>Selecto::Write::Expression->field('other')})) });
my $number=domain('items');$number->{writes}{fields}{amount}{validators}=[['number',[['greater_than',0]]]];
$zero->('numeric increment requires a real prospective value','required_data_rule_pending',sub { $engine->($number)->execute_write(update('items',{amount=>Selecto::Write::Expression->increment('amount',1)})) });
ok(!failure(sub { $engine->(domain('items'))->execute_write(update('items',{amount=>Selecto::Write::Expression->increment('amount',1)})) }),'unvalidated native mutation expression retains existing behavior');

my $batch=Selecto::Write::Batch->new(update('items',{other=>'prefix must not run'}),update('items',{name=>'after'}));
$zero->('invalid later batch member refuses the entire prefix','unsupported_write_rule',sub { $unknown->execute_batch($batch) });
my $child=domain('children');$child->{writes}{fields}{name}{validators}=['unsupported-validator'];
my $parent=domain('items');$parent->{writes}{relationships}{children}={writable=>1,allowed_ops=>['insert'],table=>'children',parent_key=>'id',child_key=>'parent_id',domain=>$child};
my $parent_engine=$engine->($parent);
my $graph=Selecto::Write::Graph->new(nodes=>[
    {id=>'root',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>10,name=>'prefix'})},
    {id=>'child',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'children',assignments=>{id=>10,name=>'invalid'}),bindings=>[{from=>'root',key=>'id',field=>'parent_id'}]}]);
$zero->('invalid later nested field refuses before root provider and DML','unsupported_write_rule',sub { $parent_engine->execute_graph($graph) });
is($db->selectrow_array('SELECT count(*) FROM children'),0,'invalid nested operation stores no child');

subtest 'graph INPUT runs once and validators precede collection candidates' => sub {
    my $c=domain('children');$c->{writes}{fields}{name}{validators}=[['inclusion',['CHILD']]];
    input_rule($c,'name',{op=>'text.pattern',profile=>'ascii_v1',pattern=>'[A-Z]+',match=>'full',flags=>[]},[{op=>'text.uppercase',profile=>'ascii_v1'}]);
    my $p=domain('items');$p->{writes}{fields}{name}{validators}=[['inclusion',['ROOT']]];
    input_rule($p,'name',{op=>'text.pattern',profile=>'ascii_v1',pattern=>'[A-Z]+',match=>'full',flags=>[]},[{op=>'text.uppercase',profile=>'ascii_v1'}]);
    for my $d ($p,$c) {
        # The first input binding accepts only raw lowercase. A second input
        # pass after uppercase would fail this actual declaration.
        $d->{rules}{bindings}{z_normalize}=delete $d->{rules}{bindings}{submitted};
        $d->{rules}{definitions}{raw}={version=>1,test=>{op=>'text.pattern',profile=>'ascii_v1',pattern=>'[a-z]+',match=>'full',flags=>[]}};
        $d->{rules}{bindings}{a_raw}={subject=>{scope=>'input',path=>['name']},operations=>['insert'],rule=>{id=>'raw',version=>1}};
    }
    $p->{writes}{relationships}{children}={writable=>1,allowed_ops=>['insert'],table=>'children',parent_key=>'id',child_key=>'parent_id',domain=>$c};
    $p->{rules}{definitions}{one}={version=>1,test=>{op=>'collection.count',exact=>1}};
    $p->{rules}{bindings}{one}={subject=>{scope=>'candidate',path=>['children']},operations=>['insert'],rule=>{id=>'one',version=>1}};
    my $g=Selecto::Write::Graph->new(nodes=>[
        {id=>'root',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>20,name=>'root'})},
        {id=>'child',command=>Selecto::Write::Command->new(operation=>'insert',relation=>'children',assignments=>{id=>20,name=>'child'}),bindings=>[{from=>'root',key=>'id',field=>'parent_id'}]}]);
    ok(!failure(sub { $engine->($p)->execute_graph($g) }),'actual graph collection admission accepts INPUT-prepared assignments');
    is_deeply($db->selectrow_arrayref('SELECT p.name,c.name,c.parent_id FROM items p JOIN children c ON c.parent_id=p.id WHERE p.id=20'),['ROOT','CHILD',20],'actual uppercase values and parent binding persist');
};

my $action_raw=domain('items');$action_raw->{writes}{fields}{name}{validators}=['unsupported-validator'];
$action_raw->{actions}{rename}={type=>'detail_action',capability=>'items.rename',execution=>{kind=>'updato',operation=>'update',set=>{name=>'renamed'}}};
$action_raw->{capabilities}{'items.rename'}={operations=>['action','update'],action=>'rename'};
my $action_engine=$engine->($action_raw);my $plan=$action_engine->plan_action({action=>'rename',target=>1});my $resolvers=0;
$zero->('action syntax refuses before capability resolver','unsupported_write_rule',sub { $action_engine->execute_action($plan,resolver=>sub { ++$resolvers;'enabled' }) });
is($resolvers,0,'unknown assigned action validator cannot invoke trusted resolver');
my $good_action=copy($action_raw);$good_action->{writes}{fields}{name}{validators}=[['inclusion',['renamed']]];
my $good_action_engine=$engine->($good_action);my $good_plan=$good_action_engine->plan_action({action=>'rename',target=>1});
ok(!failure(sub { $good_action_engine->execute_action($good_plan,resolver=>sub {'enabled'}) }),'genuine planned action executes supported field validator');
is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'renamed','planned action physically stores validated value');

my $budget_raw=domain('items');$budget_raw->{writes}{fields}{name}{validators}=[['inclusion',['budget']]];
my $budget_limits=Selecto::Limits->new(max_rule_work=>10_000);
my $budget_engine=$engine->($budget_raw,$budget_limits);
ok(!failure(sub { $budget_engine->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>40,name=>'budget'})) }),
    'one native validated operation fits the trusted rule-work ceiling');
my $budget_graph=Selecto::Write::Graph->new(nodes=>[map {
    {id=>"bounded_$_",command=>Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>40+$_,name=>'budget'})}
} 1..20]);
$zero->('native graph nodes share one cumulative validator/rule budget','evaluation_limit',sub { $budget_engine->execute_graph($budget_graph) });

is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP remains memory');
is_deeply([grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}],[],'all SQLite schemas are in memory');
$db->sqlite_trace(undef);$db->sqlite_set_authorizer(undef);$db->sqlite_update_hook(undef);$db->disconnect;
done_testing;
