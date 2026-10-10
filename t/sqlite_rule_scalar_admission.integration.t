use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use B ();
use Selecto;
BEGIN { eval {require DBI;require DBD::SQLite;1} or plan skip_all=>'DBD::SQLite is optional' }
{
    package ScalarRuleAdapter;
    use parent 'Selecto::SQLite';
    sub write_capabilities {++$_[0]{providers};shift->SUPER::write_capabilities(@_)}
    sub rule_project_subject {++$_[0]{projections};shift->SUPER::rule_project_subject(@_)}
}
sub rules {
    my ($test)=@_;return {schema=>'selecto.data_rules.v1',definitions=>{one=>{version=>1,test=>$test}},
        normalizers=>{},bindings=>{one=>{subject=>{scope=>'input',path=>['name']},operations=>['update'],rule=>{id=>'one',version=>1}}}};
}
sub document {
    my ($test)=@_;return {name=>'Native scalar rules',source=>{source_table=>'items',primary_key=>'id',
        fields=>[qw(id name)],columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
        writes=>{operations=>{update=>{enabled=>JSON::PP::true,require_filter=>JSON::PP::true}},
            fields=>{name=>{updatable=>JSON::PP::true}}},rules=>rules($test)};
}
sub failure {
    my ($work)=@_;my $ok=eval {$work->();1};return undef if $ok;
    die "untyped failure: $@" unless ref($@) eq 'Selecto::Error';return $@->code;
}
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)');
$db->do(q{INSERT INTO items VALUES(1,'before')});
$db->do('CREATE TABLE caller_work(id INTEGER PRIMARY KEY,note TEXT)');
my $adapter=ScalarRuleAdapter->new(dbh=>$db);
my $engine=sub {Selecto::Engine->new(domain=>Selecto::Domain->parse($_[0]),adapter=>$adapter)};
my $command=sub {Selecto::Write::Command->new(operation=>'update',relation=>'items',assignments=>{name=>$_[0]},predicate=>Selecto::Expression->eq('id',1))};
my (@trace,@prepare,@hooks);
$db->sqlite_trace(sub {push @trace,$_[0]});
$db->sqlite_set_authorizer(sub {push @prepare,[@_];0});
$db->sqlite_update_hook(sub {push @hooks,[@_]});
my $snapshot=sub {+{map {$_=>$db->selectall_arrayref("SELECT * FROM $_ ORDER BY id")} qw(items caller_work)}};
my $zero=sub {
    my ($code,$work,$label)=@_;my $before=$snapshot->();
    @trace=();@prepare=();@hooks=();@$adapter{qw(providers projections)}=(0,0);
    is(failure($work),$code,$label);
    is(scalar @trace,0,"$label: zero executed SQL");is(scalar @prepare,0,"$label: zero native prepares");
    is(scalar @hooks,0,"$label: zero business hooks");is($adapter->{providers},0,"$label: zero capability providers");
    is($adapter->{projections},0,"$label: zero candidate projection");
    is_deeply($snapshot->(),$before,"$label: complete rows unchanged");
};
subtest 'canonical Domain admits original rule types before its own cloning' => sub {
    for my $wire ('1.0','1.25') {
        my $value=JSON::PP->new->decode($wire);
        $zero->('invalid_data_rules_contract',sub {$engine->(document({op=>'membership.in',values=>[$value]}))},"native float$wire rule literal");
    }
    my $uv=JSON::PP->new->decode('18446744073709551615');
    my $host=$engine->(document({op=>'membership.in',values=>[$uv]}));
    $zero->('data_rule_failed',sub {$host->execute_write($command->('18446744073709551615'))},'native unsigned rule member differs from submitted text');
    my $legacy=document({op=>'presence.required'});
    $legacy->{writes}{fields}{name}{validators}=[['number',[['greater_than',JSON::PP->new->decode('1.0')]]]];
    my $legacy_host=$engine->($legacy);
    $zero->('unsupported_write_rule',sub {$legacy_host->execute_write($command->('2'))},'legacy floating bound retains delivered identity');
    $legacy=document({op=>'presence.required'});
    $legacy->{writes}{fields}{name}{validators}=[['inclusion',[$uv]]];
    $legacy_host=$engine->($legacy);
    $zero->('data_rule_failed',sub {$legacy_host->execute_write($command->('18446744073709551615'))},'legacy unsigned member differs from submitted text');
};
subtest 'canonical and legacy bracket patterns run through real native writes' => sub {
    my $pattern={op=>'text.pattern',profile=>'ascii_v1',pattern=>'[[]',match=>'full',flags=>[]};
    my $host=$engine->(document($pattern));
    ok(!failure(sub {$host->execute_write($command->('['))}),'canonical bracket pattern permits real update');
    is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'[','canonical permitted value physically stored');
    $zero->('data_rule_failed',sub {$host->preview_write($command->(']'))},'canonical preview rejects other bracket');
    $zero->('data_rule_failed',sub {$host->execute_write($command->('[['))},'canonical full-match rejects extra bracket');
    my $legacy=document({op=>'presence.required'});
    $legacy->{writes}{fields}{name}{validators}=[['format',{source=>'[[]',opts=>''}]];
    my $legacy_host=$engine->($legacy);
    ok(!failure(sub {$legacy_host->execute_write($command->('['))}),'legacy format permits native update');
    is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'[','legacy permitted value physically stored');
    $zero->('data_rule_failed',sub {$legacy_host->execute_write($command->('x'))},'legacy format rejects other text');
    for my $source ('[[:alpha:]]','[a&&b]') {
        $zero->('invalid_text_pattern',sub {$engine->(document({%$pattern,pattern=>$source}))},'canonical unsupported class refuses');
        my $raw=document({op=>'presence.required'});$raw->{writes}{fields}{name}{validators}=[['format',{source=>$source,opts=>''}]];
        my $host=$engine->($raw);
        $zero->('unsupported_write_rule',sub {$host->execute_write($command->('['))},'legacy unsupported class refuses');
    }
};
subtest 'actual composed and DSL policies cannot change native authorization' => sub {
    my $uv=JSON::PP->new->decode('18446744073709551615');
    my $composed=Selecto::Domain->compose(Selecto::Domain->parse(document({op=>'membership.in',values=>[$uv]})),
        {source=>{columns=>{name=>{label=>'Name'}}}});
    my $host=Selecto::Engine->new(domain=>$composed,adapter=>$adapter);
    $zero->('data_rule_failed',sub {$host->execute_write($command->('18446744073709551615'))},'composed unsigned membership cannot grant text');
    my $legacy=document({op=>'presence.required'});
    $legacy->{writes}{fields}{name}{validators}=[['number',[['greater_than',JSON::PP->new->decode('1.0')]]]];
    $composed=Selecto::Domain->compose(Selecto::Domain->parse($legacy),{writes=>{fields=>{name=>{immutable=>JSON::PP::false}}}});
    $host=Selecto::Engine->new(domain=>$composed,adapter=>$adapter);
    $zero->('unsupported_write_rule',sub {$host->preview_write($command->('2'))},'deep-composed legacy floating bound remains unsupported');
    my $overlay=Selecto::Domain::DSL->new->write_field(name=>{updatable=>JSON::PP::true,
        validators=>[['inclusion',[$uv]]]})->build;
    $composed=Selecto::Domain->compose(Selecto::Domain->parse(document({op=>'presence.required'})),$overlay);
    $host=Selecto::Engine->new(domain=>$composed,adapter=>$adapter);
    $zero->('data_rule_failed',sub {$host->execute_write($command->('18446744073709551615'))},'DSL-authored native unsigned member remains numeric');
    $zero->('invalid_data_rules_contract',sub {
        Selecto::Domain->compose(Selecto::Domain->parse(document({op=>'presence.required'})),
            {rules=>rules({op=>'number.gt',bound=>JSON::PP->new->decode('1.0')})});
    },'overlay-added unsupported canonical numeric policy refuses before native activity');
};
sub action_document {
    my $raw=document({op=>'presence.required'});
    $raw->{actions}{set_name}={type=>'action',scope=>'row',inputs=>{name=>{type=>'string',required=>JSON::PP::true}},
        execution=>{kind=>'updato',operation=>'update',set=>{name=>['input','name']}}};
    return $raw;
}
subtest 'genuine native action submission retains scalar identity and positive execution' => sub {
    my $raw=action_document();$raw->{writes}{fields}{name}{validators}=[['number',[['greater_than',0]]]];
    my $host=$engine->($raw);
    for my $wire ('1.0','1.25') {
        my $plan=$host->plan_action({action=>'set_name',target=>1,inputs=>{name=>JSON::PP->new->decode($wire)}});
        $zero->('data_rule_failed',sub {$host->preview_action($plan)},"native planned float $wire preview refuses");
        $zero->('data_rule_failed',sub {$host->execute_action($plan)},"native planned float $wire execution refuses");
        my $plan_flags=B::svref_2object(\$plan->{changes}{name})->FLAGS;
        ok(($plan_flags&B::SVf_NOK()) && !($plan_flags&B::SVf_IOK()),"repeated native planning leaves float $wire assignment unchanged");
        my $native=$host->action_command($plan);
        my $digest=$host->_action_command_digest($native);
        is($host->_action_command_digest($native),$digest,"repeated action command identity is stable for $wire");
        my $native_flags=B::svref_2object(\$native->{assignments}{name})->FLAGS;
        ok(($native_flags&B::SVf_NOK()) && !($native_flags&B::SVf_IOK()),"native identity inspection leaves float $wire assignment unchanged");
        $native->{assignments}{name}=1;
        $zero->('action_plan_mismatch',sub {$host->execute_write($native)},"native accepted float $wire cannot be changed to an integer");
        my $copy=Selecto::Action::Plan->new(%{$plan->to_hash});
        $zero->('data_rule_failed',sub {$host->preview_action($copy)},"native reconstructed float $wire plan refuses");
        my $flags=B::svref_2object(\$copy->{inputs}{name})->FLAGS;
        ok(($flags&B::SVf_NOK()) && !($flags&B::SVf_IOK()),"fallback replanning leaves float $wire input identity unchanged");
    }
    my $plan=$host->plan_action({action=>'set_name',target=>1,inputs=>{name=>2}});
    ok(!failure(sub {$host->execute_action($plan)}),'genuine native integer action still executes');
    is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'2','positive action has actual stored effect');
    my $uv=JSON::PP->new->decode('18446744073709551615');
    $raw=action_document();$raw->{source}{columns}{name}{type}='json';$raw->{actions}{set_name}{inputs}{name}{type}='json';
    $raw->{rules}=rules({op=>'membership.in',values=>[{n=>$uv}]});
    $raw->{rules}{bindings}{one}{subject}={scope=>'action_input',action=>'set_name',path=>['name']};
    $host=$engine->($raw);
    $plan=$host->plan_action({action=>'set_name',target=>1,inputs=>{name=>{n=>$uv}}});
    ok(!failure(sub {$host->execute_action($plan)}),'genuine unsigned JSON ACTION_INPUT reaches real SQLite');
    my $stored=JSON::PP->new->decode($db->selectrow_array('SELECT name FROM items WHERE id=1'));
    is(JSON::PP->new->encode($stored->{n}),'18446744073709551615','actual stored JSON retains numeric literal bytes');
    for my $source (qw(literal default)) {
        $raw=action_document();$raw->{writes}{fields}{name}{validators}=[['number',[['greater_than',0]]]];
        my $float=JSON::PP->new->decode('1.0');
        if ($source eq 'literal') { $raw->{actions}{set_name}{execution}{set}{name}=$float;delete $raw->{actions}{set_name}{inputs} }
        else { $raw->{actions}{set_name}{inputs}{name}{default}=$float;$raw->{actions}{set_name}{inputs}{name}{required}=JSON::PP::false }
        $host=$engine->($raw);$plan=$host->plan_action({action=>'set_name',target=>1});
        $zero->('data_rule_failed',sub {$host->execute_action($plan)},"authored action $source float retains strict native type refusal");
        my $iv=JSON::PP->new->decode('9223372036854775807');
        $raw=action_document();$raw->{writes}{fields}{name}{validators}=[['inclusion',[$iv]]];
        if ($source eq 'literal') { $raw->{actions}{set_name}{execution}{set}{name}=$iv;delete $raw->{actions}{set_name}{inputs} }
        else { $raw->{actions}{set_name}{inputs}{name}={type=>'string',required=>JSON::PP::false,default=>$iv} }
        $host=$engine->($raw);$plan=$host->plan_action({action=>'set_name',target=>1});
        is(failure(sub {$host->execute_action($plan)}),undef,"authored action $source exact signed integer satisfies actual native validator");
        is($db->selectrow_array('SELECT name FROM items WHERE id=1'),'9223372036854775807',
            "authored action $source exact signed integer physically persists without precision loss");
        $raw=action_document();$raw->{source}{columns}{name}{type}='json';
        if ($source eq 'literal') { $raw->{actions}{set_name}{execution}{set}{name}={n=>$uv};delete $raw->{actions}{set_name}{inputs} }
        else { $raw->{actions}{set_name}{inputs}{name}={type=>'json',required=>JSON::PP::false,default=>{n=>$uv}} }
        $host=$engine->($raw);$plan=$host->plan_action({action=>'set_name',target=>1});
        is(failure(sub {$host->execute_action($plan)}),undef,"authored action $source unsigned JSON executes through the actual JSON transport");
        $stored=JSON::PP->new->decode($db->selectrow_array('SELECT name FROM items WHERE id=1'));
        is(JSON::PP->new->encode($stored->{n}),'18446744073709551615',
            "authored action $source unsigned JSON physically retains numeric literal bytes");
    }
};
subtest 'caller transaction and savepoint survive every rule refusal' => sub {
    $db->begin_work;$db->do(q{INSERT INTO caller_work VALUES(7,'caller sentinel')});$db->do('SAVEPOINT caller_proof');
    my $host=$engine->(document({op=>'text.pattern',profile=>'ascii_v1',pattern=>'[[]',match=>'full',flags=>[]}));
    $zero->('data_rule_failed',sub {$host->execute_write($command->('wrong'))},'caller-owned rejection');
    my $uv=JSON::PP->new->decode('18446744073709551615');
    my $numeric=$engine->(document({op=>'membership.in',values=>[$uv]}));
    $zero->('data_rule_failed',sub {$numeric->execute_write($command->('18446744073709551615'))},'caller-owned numeric/text distinction');
    my $legacy=document({op=>'presence.required'});
    $legacy->{writes}{fields}{name}{validators}=[['number',[['greater_than',JSON::PP->new->decode('1.0')]]]];
    my $legacy_host=$engine->($legacy);
    $zero->('unsupported_write_rule',sub {$legacy_host->execute_write($command->('2'))},'caller-owned invalid legacy declaration');
    my $action=action_document();$action->{writes}{fields}{name}{validators}=[['number',[['greater_than',0]]]];
    my $action_host=$engine->($action);
    my $plan=$action_host->plan_action({action=>'set_name',target=>1,inputs=>{name=>JSON::PP->new->decode('1.0')}});
    $zero->('data_rule_failed',sub {$action_host->execute_action($plan)},'caller-owned action preserves original floating subject refusal');
    ok(!failure(sub {$db->do('ROLLBACK TO caller_proof');$db->do('RELEASE caller_proof')}),'original caller savepoint is usable');
    is_deeply($db->selectall_arrayref('SELECT * FROM caller_work'),[[7,'caller sentinel']],'original caller row remains');
    $db->rollback;
};
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP remains in memory');
ok(!scalar(grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}),'all database filenames remain empty');
done_testing;
