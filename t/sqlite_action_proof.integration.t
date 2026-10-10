use 5.034;
use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Action;
use Selecto::Action::Plan;
BEGIN { eval {require DBI; require DBD::SQLite; 1} or plan skip_all => 'DBD::SQLite required' }
sub document {
    return {name=>'Accepted action proof',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id reference)],
        columns=>{id=>{type=>'integer'},reference=>{type=>'string'}}},schemas=>{},writes=>{operations=>{insert=>{enabled=>1}},
        fields=>{reference=>{insertable=>1}}},actions=>{create=>{type=>'detail_action',inputs=>{reference=>{type=>'string'}},
        execution=>{kind=>'updato',operation=>'insert',set=>{reference=>['input','reference']}}}},rules=>{schema=>'selecto.data_rules.v1',
        definitions=>{null=>{version=>1,test=>{op=>'value.eq',value=>undef}}},normalizers=>{empty=>{version=>1,steps=>[{op=>'text.empty_to_null'}]}},
        bindings=>{null=>{subject=>{scope=>'action_input',action=>'create',path=>['reference']},rule=>{id=>'null',version=>1},normalizer=>{id=>'empty',version=>1}}}}};
}
sub error { my $work=shift; return eval{$work->();1} ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@" }
sub memory {
    my ($raw,$work)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
    $db->do('PRAGMA temp_store=MEMORY');$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT)');
    my $mutations=0;$db->sqlite_trace(sub{$mutations++ if $_[0]=~/\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+["`\[]?items\b/i});
    my $engine=Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>Selecto::SQLite->new(dbh=>$db));
    $work->($engine,$db,\$mutations);
    is_deeply [grep{length($_->[2])}@{$db->selectall_arrayref('PRAGMA database_list')}],[],'main and temporary databases remain in memory';
    $db->disconnect;
}
sub accepted_plan {$_[0]->plan_action({action=>'create',inputs=>{reference=>''}})}
subtest 'accepted ACTION_INPUT normalization survives preview, grant and execution' => sub {memory(document(),sub {
    my ($e,$db,$n)=@_;my $p=accepted_plan($e);
    ok !defined($p->inputs->{reference}),'empty text normalizes to genuine NULL during planning';
    is error(sub{$e->preview_action($p)}),'ok','preview does not replay empty_to_null on NULL';
    is $$n,0,'preview prepares no target mutation';
    my $grant;is error(sub{$grant=$e->grant_action($p)}),'ok','grant validates exact accepted evidence';
    is error(sub{$e->execute_action($p,grant=>$grant)}),'ok','execute consumes the grant without replay';
    is $$n,1,'exactly one actual target INSERT';
    is_deeply $db->selectall_arrayref('SELECT reference IS NULL FROM items'),[[1]],'actual stored value is NULL';
})};
subtest 'public planner plans retain acceptance for equivalent engine contracts' => sub {memory(document(),sub {
    my ($e,$db)=@_;my $p=Selecto::Action->plan($e->domain,{action=>'create',inputs=>{reference=>''}});
    is error(sub{$e->execute_action($p)}),'ok','public Action planner uses the same private evidence';
    is $db->selectrow_array('SELECT count(*) FROM items'),1,'native row persists';
})};
subtest 'serialized lookalikes cannot claim normalization or erase proof work' => sub {memory(document(),sub {
    my ($e,$db,$n)=@_;my $p=accepted_plan($e);
    my $copy=Selecto::Action::Plan->new(%{$p->to_hash},_action_input_done=>1,_accepted_work=>0);
    is error(sub{$e->preview_action($copy)}),'required_data_rule_pending','caller fields do not restore private acceptance';
    is error(sub{$e->execute_action($copy)}),'required_data_rule_pending','serialized normalized input is not replayed or trusted';
    is $$n,0,'lookalike prepares no target mutation';
})};
subtest 'accepted evidence remains bound to the exact plan and contract' => sub {memory(document(),sub {
    my ($e,$db,$n)=@_;my $p=accepted_plan($e);$p->changes->{reference}='tampered';
    is error(sub{$e->preview_action($p)}),'action_plan_mismatch','changed plan cannot reuse acceptance';
    $p=accepted_plan($e);my $grant;is error(sub{$grant=$e->grant_action($p)}),'ok','original plan remains eligible for a grant';
    $p->changes->{reference}='tampered';
    is error(sub{$e->execute_action($p,grant=>$grant)}),'action_grant_mismatch','grant mismatch keeps its public precedence';
    $p=accepted_plan($e);my $raw=document();$raw->{name}='Different domain';
    my $other=Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>$e->adapter);
    is error(sub{$other->execute_action($p)}),'action_plan_mismatch','different domain cannot reuse acceptance';
    is $$n,0,'changed plans prepare no target mutation';
})};
subtest 'ACTION_INPUT and stored stages share one protected proof budget' => sub {
    my $raw=document();$raw->{rules}={schema=>'selecto.data_rules.v1',definitions=>{text=>{version=>1,test=>{op=>'presence.required'}}},normalizers=>{},bindings=>{}};
    for my $stage(qw(action_input candidate)) {
        $raw->{rules}{normalizers}{$stage}={version=>1,steps=>[map{+{op=>'text.trim',profile=>'ascii_v1'}}1..300]};
        $raw->{rules}{bindings}{$stage}={subject=>{scope=>$stage,path=>['reference'],($stage eq 'action_input'?(action=>'create'):())},
            rule=>{id=>'text',version=>1},normalizer=>{id=>$stage,version=>1},enforcement=>'advisory',condition=>{op=>'presence.absent'}};
    }
    memory($raw,sub {
        my ($e,$db,$n)=@_;my $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});
        $p->{_accepted_work}=0;
        is error(sub{$e->preview_action($p)}),'evaluation_limit','preview carries privately measured planning work';
        is error(sub{$e->execute_action($p)}),'evaluation_limit','execution carries planning work across native stages';
        is $$n,0,'whole-proof refusal precedes target mutation';
        is $db->selectrow_array('SELECT count(*) FROM items'),0,'refused proof persists no row';
        $p=$e->plan_action({action=>'create',inputs=>{reference=>'short'}});
        is error(sub{$e->execute_action($p)}),'ok','a separate small proof resets the counter';
        is $db->selectrow_array('SELECT count(*) FROM items'),1,'small positive control persists';
    });
};
sub budget_document {
    my ($input_steps, $candidate_steps) = @_;
    my $raw = document();
    $raw->{rules} = {schema=>'selecto.data_rules.v1', definitions=>{text=>{version=>1,test=>{op=>'presence.required'}}}, normalizers=>{}, bindings=>{}};
    for my $pair (['action_input',$input_steps], ['candidate',$candidate_steps]) {
        my ($stage,$steps) = @$pair;
        $raw->{rules}{normalizers}{$stage} = {version=>1,steps=>[map {+{op=>'text.trim',profile=>'ascii_v1'}} 1..$steps]};
        $raw->{rules}{bindings}{$stage} = {subject=>{scope=>$stage,path=>['reference'],($stage eq 'action_input'?(action=>'create'):())},
            rule=>{id=>'text',version=>1},normalizer=>{id=>$stage,version=>1},enforcement=>'advisory',condition=>{op=>'presence.absent'}};
    }
    return $raw;
}
subtest 'exact action-command bridge carries accepted work through public preview execute and governance' => sub {
    memory(budget_document(300,300),sub {
        my ($e,$db,$n)=@_; my $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});
        my $command=$e->action_command($p);
        $command->{metadata}{_accepted_work}=0;
        is error(sub{$e->preview_write($command)}),'evaluation_limit','public command preview retains planning work despite caller metadata';
        is error(sub{$e->execute_write($command)}),'evaluation_limit','public command execution retains planning work';
        my $governed=$e->governed_write($command);
        is error(sub{$e->execute_write($governed)}),'evaluation_limit','engine governance copies retain exact private work';
        is $$n,0,'bridge refusal precedes every business statement';
        is $db->selectrow_array('SELECT count(*) FROM items'),0,'bridge resource refusal stores no row';
        $command->{assignments}{reference}='edited';
        is error(sub{$e->execute_write($command)}),'action_plan_mismatch','edited exact command cannot reuse its private receipt';
        my $copy=Selecto::Action::Plan->new(%{$p->to_hash},_accepted_work=>0);
        is error(sub{$e->action_command($copy)}),'required_data_rule_pending','serialized action-input plan cannot create an accepted command';
    });
};
subtest 'once-normalized command bridge has a positive NULL storage control' => sub {memory(document(),sub {
    my ($e,$db,$n)=@_;my $command=$e->action_command(accepted_plan($e));
    is error(sub{$e->preview_write($command)}),'ok','command preview does not replay action-input normalization';
    is $$n,0,'positive command preview remains read only';
    $command=$e->governed_write($command);
    is error(sub{$e->execute_write($command)}),'ok','governed exact command stores accepted NULL once';
    is $$n,1,'one actual native insertion';
    is $db->selectrow_array('SELECT reference IS NULL FROM items'),1,'native stored NULL is preserved';
})};
subtest 'batch and graph command bridges retain planning work before any prefix' => sub {
    memory(budget_document(200,100),sub {
        my ($e,$db,$n)=@_;
        my @commands=map {$e->action_command($e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}}))} 1..2;
        is error(sub{$e->execute_batch(Selecto::Write::Batch->new(@commands))}),'evaluation_limit','independent accepted plans are charged across the full INSERT batch';
        is $$n,0,'batch planning+candidate ceiling precedes first native prefix';
        is $db->selectrow_array('SELECT count(*) FROM items'),0,'failed batch stores no rows';
    });
    memory(budget_document(300,300),sub {
        my ($e,$db,$n)=@_;my $command=$e->action_command($e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}}));
        my $graph=Selecto::Write::Graph->new(nodes=>[{id=>'root',command=>$command}]);
        is error(sub{$e->execute_graph($graph)}),'evaluation_limit','actual graph root retains its action planning work';
        is $$n,0,'graph resource proof precedes target insertion';
    });
};
subtest 'nested private scopes charge prior plans rather than discarding accepted work' => sub {
    memory(budget_document(300,300),sub {
        my ($e,$db,$n)=@_;my $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});
        is error(sub{Selecto::DataRules->_with_proof_budget(sub{$e->execute_action($p,accepted_work=>0)})}),'evaluation_limit','an existing scope imports privately measured prior planning work';
        is $$n,0,'nested prior-plan resource refusal performs no business DML';
        is error(sub{$e->execute_action($e->plan_action({action=>'create',inputs=>{reference=>'short'}}))}),'ok','fresh operation resets after nested refusal';
        is $db->selectrow_array('SELECT count(*) FROM items'),1,'small independent proof persists';
    });
};
subtest 'nested current planning and shared plan bridges charge each accepted event exactly once' => sub {
    memory(budget_document(250,150),sub {
        my ($e,$db,$n)=@_;
        is error(sub{Selecto::DataRules->_with_proof_budget(sub {
            my $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});
            return $e->execute_write($e->action_command($p));
        })}),'ok','planning inside the current scope is not charged a second time';
        is $$n,1,'known current-scope positive performs one insertion';
    });
    memory(budget_document(250,100),sub {
        my ($e,$db,$n)=@_;my $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});
        is error(sub{Selecto::DataRules->_with_proof_budget(sub {
            $e->preview_action($p);
            return $e->execute_write($e->action_command($p));
        })}),'ok','direct action preview and public command bridge share one accepted planning event';
        is $$n,1,'preview plus execute within a bounded shared scope performs one insertion';
    });
};
subtest 'private plan and command records follow object lifetime' => sub {memory(document(),sub {
    my ($e,$db,$n)=@_;my $p=accepted_plan($e);my $weak_plan=$p;Scalar::Util::weaken($weak_plan);
    my $command=$e->action_command($p);undef $p;
    ok !defined($weak_plan),'command receipt does not retain the accepted plan or permit stale address identity';
    my $weak_command=$command;Scalar::Util::weaken($weak_command);undef $command;
    ok !defined($weak_command),'private command records do not keep command keys alive';
    is $$n,0,'lifetime controls do not mutate business rows';
})};
subtest 'trusted work ceilings tighten receipts without changing grant mismatch priority' => sub {
    memory(budget_document(300,100),sub {
        my ($e,$db,$n)=@_;
        my $tight=Selecto::Engine->new(domain=>$e->domain,adapter=>$e->adapter,limits=>Selecto::Limits->new(max_rule_work=>500_000));
        is error(sub{$tight->plan_action({action=>'create',inputs=>{reference=>'a'x4000}})}),'evaluation_limit','trusted planning ceiling is enforced during the original input work';
        my $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});
        my $grant=$e->grant_action($p);$p->changes->{reference}='changed';
        is error(sub{$tight->execute_action($p,grant=>$grant)}),'action_grant_mismatch','invalid grant binding is checked before accepted planning resources';
        $p=$e->plan_action({action=>'create',inputs=>{reference=>'a'x4000}});$grant=$e->grant_action($p);
        is error(sub{$tight->execute_action($p,grant=>$grant)}),'evaluation_limit','valid exact receipt cannot exceed a trusted smaller work ceiling';
        is error(sub{$tight->execute_action($p,grant=>$grant)}),'action_grant_invalid','the failed authorized proof still consumes its one-use grant';
        is $$n,0,'grant and resource refusals perform no business DML';
    });
};
subtest 'accepted command fingerprints bound mutated authority before copying or hashing' => sub {memory(document(),sub {
    my ($e,$db,$n)=@_;my $command=$e->action_command(accepted_plan($e));
    my $cycle={};$cycle->{cycle}=$cycle;$command->{assignments}{reference}=$cycle;
    is error(sub{$e->execute_write($command)}),'invalid_write','cyclic mutated assignment is refused by the tree budget before fingerprinting';
    is $$n,0,'invalid exact command performs no business DML';
})};
done_testing;
