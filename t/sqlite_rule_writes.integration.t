use 5.034;use strict;use warnings;
use Test::More;use JSON::PP;use Storable qw(dclone);use FindBin qw($Bin);
use Selecto::Domain;use Selecto::Engine;use Selecto::SQLite;use Selecto::Write;use Selecto::Expression;
BEGIN {eval {require DBI;require DBD::SQLite;1} or plan skip_all=>'DBD::SQLite required'}
{package TestRulesAdapter;use parent 'Selecto::SQLite';
sub execute_query {my($self,$s)=@_;$self->{loads}++;my$r=$self->SUPER::execute_query($s);$r->{complete}=0 if$self->{incomplete};return$r}
sub _execute_compiled_write_in_transaction{my$self=shift;$self->{dispatches}++;$self->SUPER::_execute_compiled_write_in_transaction(@_)}}
open my$fh,'<',"$Bin/fixtures/data_rules_write_inputs_v1.json" or die$!;
my$f=JSON::PP->new->decode(do{local$/;<$fh>});
sub memory {
    my($run)=@_;my$db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
    $db->do('CREATE TABLE line_items(id INTEGER PRIMARY KEY,quantity INTEGER NOT NULL,reference TEXT NOT NULL)');
    $db->do('CREATE TABLE rule_write_orders(id INTEGER PRIMARY KEY,reference TEXT NOT NULL)');
    $db->do('CREATE TABLE rule_write_items(id INTEGER PRIMARY KEY,order_id INTEGER NOT NULL,product_id INTEGER NOT NULL,quantity INTEGER NOT NULL)');
    my$a=TestRulesAdapter->new(dbh=>$db);$run->($db,$a);$db->disconnect;
}
sub engine {Selecto::Engine->new(domain=>Selecto::Domain->parse($_[0]),adapter=>$_[1])}
sub seed {
    my($db)=@_;$db->do("INSERT INTO rule_write_orders VALUES(42,'prior')");
    $db->do('INSERT INTO rule_write_items VALUES(?,42,?,?)',undef,@{$_}{qw(id product_id quantity)})for@{$f->{nested_prior}};
}
sub graph {
    my($name)=@_;my$delta=$name=~/delta/;
    my@nodes=({id=>'root',command=>Selecto::Write::Command->new(operation=>$delta?'update':'insert',relation=>'rule_write_orders',assignments=>{reference=>'ORDER-1'},($delta?(predicate=>Selecto::Expression->eq('id',42)):()))});
    my$v=$name eq'nested_delta_incomplete'?$f->{nested_delta_valid}:$f->{$name};my$ops=$delta?$v:{create=>$v};
    for my$pair(['create','insert'],['update','update'],['delete','delete']) {for my$item(@{$ops->{$pair->[0]}//[]}) {
        my%values=%$item;delete$values{id};push@nodes,{id=>'row'.@nodes,bindings=>[{from=>'root',key=>'id',field=>'order_id'}],command=>Selecto::Write::Command->new(operation=>$pair->[1],relation=>'rule_write_items',assignments=>$pair->[1]eq'delete'?{}:\%values,($pair->[1]ne'insert'?(predicate=>Selecto::Expression->eq('id',$item->{id})):()))};
    }}return Selecto::Write::Graph->new(nodes=>\@nodes);
}
subtest 'flat rules normalize before dispatch and action input rules plan only valid selections' => sub {memory(sub {
    my($db,$a)=@_;my$e=engine($f->{flat_domain},$a);
    eval {$e->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'line_items',assignments=>$f->{flat_invalid}))};
    is $@->code,'data_rule_failed','invalid scalar refused';is $a->{dispatches}//0,0,'no invalid write dispatched';
    $e->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'line_items',assignments=>$f->{flat_valid}));
    is $db->selectrow_array('SELECT reference FROM line_items'),'AB12','normalizer persisted';
    my$action=engine($f->{action_domain},$a);eval {$action->plan_action({action=>'choose_products',target=>1,inputs=>$f->{action_invalid}})};
    is $@->code,'data_rule_failed','invalid action input refused before planning';
    is scalar(@{$action->plan_action({action=>'choose_products',target=>1,inputs=>$f->{action_valid}})->inputs->{selected_products}}),3,'valid selection planned';
})};
for my$name(qw(nested_invalid_count nested_invalid_child nested_invalid_unique nested_valid nested_delta_valid nested_delta_invalid_count nested_delta_invalid_unique nested_delta_incomplete)) {
    subtest $name=>sub {memory(sub {
        my($db,$a)=@_;my$delta=$name=~/delta/;seed($db)if$delta;
        my$before=$db->selectall_arrayref('SELECT * FROM rule_write_items ORDER BY id');
        $a->{incomplete}=$name eq'nested_delta_incomplete';my$ok=eval {engine($f->{nested_domain},$a)->execute_graph(graph($name));1};
        if($name eq'nested_valid'||$name eq'nested_delta_valid') {ok $ok,'valid graph executed';is $db->selectrow_array('SELECT count(*) FROM rule_write_items'),3,'complete final set stored'}
        else {is $@->code,$a->{incomplete}?'required_data_rule_pending':'data_rule_failed','closed admission error';is $a->{dispatches}//0,0,'no mutation before candidate admission';is_deeply $db->selectall_arrayref('SELECT * FROM rule_write_items ORDER BY id'),$before,'actual prior rows retained'}
        ok $a->{loads},'delta snapshot loaded through the public query API' if$delta;
    })};
}
sub patch_domain {
    my$d=dclone($f->{nested_domain});
    $d->{actions}{patch}={type=>'detail_action',inputs=>{items=>{type=>'collection',required=>1}},execution=>{kind=>'updato',operation=>'update',set=>{},collection_patches=>{items=>{target=>['relationship','items'],from_input=>'items',strategy=>'ordered',identity=>'id',order_field=>'quantity'}}}};
    return$d;
}
subtest 'collection actions use read anchors, exact generated identities and actual final candidate rules' => sub {memory(sub {
    my($db,$a)=@_;seed($db);
    $db->do("CREATE TRIGGER no_fake_update BEFORE UPDATE ON rule_write_orders BEGIN SELECT RAISE(ABORT,'no fake root update');END");
    $db->do('INSERT INTO rule_write_items VALUES(9007199254740993,99,1,1)');
    my$e=engine(patch_domain(),$a);
    my$p=$e->plan_action({action=>'patch',target=>42,inputs=>{items=>[{op=>'update',id=>11,quantity=>4},{op=>'remove',id=>13},{op=>'add',product_id=>8,quantity=>3,client_id=>'temp'}]}});
    my$preview=$e->preview_action($p)->{statement};like $preview->{statements}[0]{sql},qr/\ASELECT /,'preview selects its read anchor';
    my$r=$e->execute_action($p)->{result};is $r->root->affected_rows,0,'no synthetic root write';
    is "".$r->metadata->{identity_mapping}[0]{identity}{id},'9007199254740994','actual generated client identity remains exact';
    is $db->selectrow_array('SELECT reference FROM rule_write_orders WHERE id=42'),'prior','read anchor did not change stored root';
    is $db->selectrow_array('SELECT quantity FROM rule_write_items WHERE id=11'),4,'child update applied';
    my$invalid=$e->plan_action({action=>'patch',target=>42,inputs=>{items=>[{op=>'remove',id=>12}]}});my$dispatched=$a->{dispatches};
    eval {$e->execute_action($invalid)};is $@->code,'data_rule_failed','actual final count rejects invalid delta';is $a->{dispatches},$dispatched,'no invalid delta dispatched';
    $p->changes({reference=>'forged'});eval {$e->execute_action($p)};is $@->code,'action_plan_mismatch','mutated action plan refused';
})};
subtest 'late child constraints roll back action patches while preserving host work' => sub {memory(sub {
    my($db,$a)=@_;seed($db);my$d=patch_domain();delete$d->{rules};delete$d->{writes}{relationships}{items}{domain}{rules};
    $db->do("CREATE TRIGGER reject_quantity BEFORE INSERT ON rule_write_items WHEN NEW.quantity=99 BEGIN SELECT RAISE(ABORT,'late child');END");
    $db->begin_work;$db->do("UPDATE rule_write_orders SET reference='host' WHERE id=42");
    my$e=engine($d,$a);my$p=$e->plan_action({action=>'patch',target=>42,inputs=>{items=>[{op=>'update',id=>11,quantity=>4},{op=>'add',product_id=>8,quantity=>99}]}});
    eval {$e->execute_action($p)};ok $@,'actual late failure raised';
    is $db->selectrow_array('SELECT quantity FROM rule_write_items WHERE id=11'),1,'earlier patch rolled back';
    is $db->selectrow_array('SELECT reference FROM rule_write_orders WHERE id=42'),'host','host transaction work preserved';ok !$db->{AutoCommit},'host transaction stays open';$db->rollback;
})};
subtest 'partial stored scalar candidates and normalizer write policy are protected' => sub {memory(sub {
    my($db,$a)=@_;my$d=dclone($f->{flat_domain});$_->{operations}=['insert','update']for values%{$d->{rules}{bindings}};
    $d->{writes}{operations}{update}={enabled=>1};$_->{updatable}=1for values%{$d->{writes}{fields}};
    $db->do("INSERT INTO line_items VALUES(1,2,' ab12 ')");my$e=engine($d,$a);
    $e->execute_write(Selecto::Write::Command->new(operation=>'update',relation=>'line_items',assignments=>{quantity=>3},predicate=>Selecto::Expression->eq('id',1)));
    is $db->selectrow_array('SELECT reference FROM line_items'),'AB12','stored candidate normalizer persists its admitted change';
    my$before=$a->{dispatches};$a->{incomplete}=1;eval {$e->execute_write(Selecto::Write::Command->new(operation=>'update',relation=>'line_items',assignments=>{quantity=>4},predicate=>Selecto::Expression->eq('id',1)))};
    is $@->code,'required_data_rule_pending','partial snapshot cannot admit stored candidate';is $a->{dispatches},$before,'partial candidate caused no write';
})};
subtest 'stored row aliases, typed collection equality and unknown expressions fail closed before mutation' => sub {memory(sub {
    my($db,$a)=@_;seed($db);my$e=engine($f->{nested_domain},$a);
    my@nodes=({id=>'root',command=>Selecto::Write::Command->new(operation=>'update',relation=>'rule_write_orders',assignments=>{reference=>'changed'},predicate=>Selecto::Expression->eq('id',42))});
    for my$alias(11,'011') {push@nodes,{id=>'row'.@nodes,command=>Selecto::Write::Command->new(operation=>'update',relation=>'rule_write_items',assignments=>{quantity=>4},predicate=>Selecto::Expression->eq('id',$alias)),bindings=>[{from=>'root',key=>'id',field=>'order_id'}]}}
    eval {$e->execute_graph(Selecto::Write::Graph->new(nodes=>\@nodes))};is $@->code,'invalid_write_graph','physical row cannot be admitted twice through affinity aliases';
    is $a->{dispatches}//0,0,'aliased snapshots never dispatch';
    local$f->{nested_valid}=dclone($f->{nested_valid});$f->{nested_valid}[1]{product_id}='5';
    eval {$e->execute_graph(graph('nested_valid'))};is $@->code,'data_rule_failed','declared integer strings and integers share storage equality';
    is $a->{dispatches}//0,0,'typed duplicate never dispatches';
    my$d=dclone($f->{flat_domain});$d->{rules}{bindings}{positive}{operations}=['update'];delete$d->{rules}{bindings}{reference};$d->{writes}{operations}{update}={enabled=>1};$d->{writes}{fields}{quantity}{updatable}=1;
    $db->do("INSERT INTO line_items VALUES(1,2,'AB12')");
    eval {engine($d,$a)->execute_write(Selecto::Write::Command->new(operation=>'update',relation=>'line_items',assignments=>{quantity=>Selecto::Write::Expression->increment('quantity',1)},predicate=>Selecto::Expression->eq('id',1)))};
    is $@->code,'required_data_rule_pending','unknown database-computed prospective value remains pending';is $a->{dispatches}//0,0,'unknown prospective value causes no mutation';
})};
subtest 'collection snapshots retain child write tenants and required guards and refuse overflow' => sub {memory(sub {
    my($db,$a)=@_;seed($db);$db->do('ALTER TABLE rule_write_orders ADD COLUMN tenant_id INTEGER DEFAULT 7');$db->do('ALTER TABLE rule_write_items ADD COLUMN tenant_id INTEGER DEFAULT 7');$db->do('ALTER TABLE rule_write_items ADD COLUMN active INTEGER DEFAULT 1');
    $db->do('INSERT INTO rule_write_items VALUES(14,42,5,1,8,1)');$db->do('INSERT INTO rule_write_items VALUES(15,42,5,1,7,0)');
    my$d=dclone($f->{nested_domain});my$c=$d->{writes}{relationships}{items}{domain};
    for my$raw($d,$c){push@{$raw->{source}{fields}},'tenant_id';$raw->{source}{columns}{tenant_id}={type=>'integer'};$raw->{writes}{scope}{tenant}={field=>'tenant_id'}}
    push@{$c->{source}{fields}},'active';$c->{source}{columns}{active}={type=>'integer'};$c->{required_filters}=[['eq','active',1]];
    my$e=Selecto::Engine->new(domain=>Selecto::Domain->parse($d),adapter=>$a,scope=>{tenant=>7});
    $e->execute_graph(graph('nested_delta_valid'));
    is $db->selectrow_array('SELECT quantity FROM rule_write_items WHERE id=11'),4,'scoped actual delta admitted';
    is $db->selectrow_array('SELECT count(*) FROM rule_write_items'),5,'hidden and other-tenant rows retained';
    $d->{writes}{relationships}{items}{max_rows}=2;my$before=$a->{dispatches};
    eval {Selecto::Engine->new(domain=>Selecto::Domain->parse($d),adapter=>$a,scope=>{tenant=>7})->execute_graph(graph('nested_delta_valid'))};
    is $@->code,'required_data_rule_pending','candidate overflow cannot imply completeness';is $a->{dispatches},$before,'overflow causes no mutation';
})};
subtest 'implicit sync deletions enforce child rules before the root mutates' => sub {memory(sub {
    my($db,$a)=@_;seed($db);$db->do('UPDATE rule_write_items SET quantity=0 WHERE id=13');my$d=dclone($f->{nested_domain});delete$d->{rules};
    my$edge=$d->{writes}{relationships}{items};$edge->{strategy}='sync';$edge->{delete_missing}=1;$edge->{domain}{rules}{bindings}{positive}{operations}=['delete'];
    my$graph=Selecto::Write::Graph->new(nodes=>[{id=>'root',command=>Selecto::Write::Command->new(operation=>'update',relation=>'rule_write_orders',assignments=>{reference=>'must not change'},predicate=>Selecto::Expression->eq('id',42))}],owned_sets=>[{parent=>'root',relationship=>'items',nodes=>[],delete_missing=>1}]);
    eval {engine($d,$a)->execute_graph($graph)};is $@->code,'data_rule_failed','omitted stored child must pass delete candidate rules';is $a->{dispatches}//0,0,'implicit cleanup validated before root dispatch';is $db->selectrow_array('SELECT reference FROM rule_write_orders'),'prior','root retained';
})};
subtest 'action targets must be owned with a supported relationship strategy' => sub {memory(sub {
    my($db,$a)=@_;seed($db);
    for my$change(['ownership','shared'],['strategy','append_only']) {my$d=patch_domain();$d->{writes}{relationships}{items}{$change->[0]}=$change->[1];my$e=engine($d,$a);my$p=$e->plan_action({action=>'patch',target=>42,inputs=>{items=>[{op=>'update',id=>11,quantity=>4}]}});eval {$e->execute_action($p)};is $@->code,'invalid_action_collection_patch','undeclared collection ownership or strategy refused';}
    is $a->{dispatches}//0,0,'ownership refusals cause no mutation';
})};
subtest 'flat parent updates load complete governed collections for required rules' => sub {memory(sub {
    my($db,$a)=@_;seed($db);my$e=engine($f->{nested_domain},$a);
    my$command=Selecto::Write::Command->new(operation=>'update',relation=>'rule_write_orders',assignments=>{reference=>'flat-parent'},predicate=>Selecto::Expression->eq('id',42));
    $e->execute_write($command);is $db->selectrow_array('SELECT reference FROM rule_write_orders'),'flat-parent','actual complete stored collection admits flat parent write';
    $db->do('DELETE FROM rule_write_items WHERE id=13');my$before=$a->{dispatches};eval {$e->execute_write($command)};is $@->code,'data_rule_failed','flat parent write also enforces complete collection count';is $a->{dispatches},$before,'invalid flat parent does not dispatch';
})};
subtest 'required SQLite rule candidates refuse transforming storage and use actual numeric affinity' => sub {memory(sub {
    my($db,$a)=@_;my$d=dclone($f->{flat_domain});my$command=Selecto::Write::Command->new(operation=>'insert',relation=>'line_items',assignments=>$f->{flat_valid});
    $db->do('CREATE TRIGGER alter_candidate AFTER INSERT ON line_items BEGIN UPDATE line_items SET quantity=0 WHERE id=NEW.id;END');
    eval {engine($d,$a)->execute_write($command)};is $@->code,'required_data_rule_pending','trigger-transformed prospective candidate is unknown';is $a->{dispatches}//0,0,'trigger-bearing target never dispatches';
    $db->do('DROP TRIGGER alter_candidate');$db->do('DROP TABLE line_items');$db->do('CREATE TABLE line_items(id INTEGER PRIMARY KEY,quantity REAL,reference TEXT)');
    eval {engine($d,$a)->execute_write($command)};is $@->code,'required_data_rule_pending','integer rule cannot certify incompatible physical REAL affinity';is $a->{dispatches}//0,0,'incompatible storage never dispatches';
    $db->do('DROP TABLE line_items');$db->do('CREATE TABLE line_items(id INTEGER PRIMARY KEY,quantity NUMERIC,reference TEXT)');$d->{source}{columns}{quantity}{type}='decimal';
    eval {engine($d,$a)->execute_write($command->with_assignments({quantity=>'1e-400',reference=>'AB12'}))};is $@->code,'data_rule_failed','native NUMERIC underflow is zero for required positivity';is $a->{dispatches}//0,0,'underflow cannot pass an exact authored-number rule';
    engine($d,$a)->execute_write($command->with_assignments({quantity=>'0.25',reference=>'AB12'}));is $db->selectrow_array('SELECT quantity FROM line_items'),0.25,'supported NUMERIC candidate persists';
    $db->do('ALTER TABLE line_items ADD COLUMN enabled INTEGER');push@{$d->{source}{fields}},'enabled';$d->{source}{columns}{enabled}={type=>'boolean'};$d->{writes}{fields}{enabled}={insertable=>1};
    $d->{rules}{definitions}{enabled}={version=>1,test=>{op=>'value.eq',value=>JSON::PP::true}};$d->{rules}{bindings}{enabled}={subject=>{scope=>'candidate',path=>['enabled']},operations=>['insert'],rule=>{id=>'enabled',version=>1}};
    engine($d,$a)->execute_write($command->with_assignments({quantity=>2,reference=>'AB12',enabled=>1}));is $db->selectrow_array('SELECT enabled FROM line_items WHERE enabled IS NOT NULL'),1,'stored integer Boolean canonicalizes for rule evaluation';
})};
subtest 'normalizers cannot replace trusted tenant assignments and transaction-stage rules are enforced' => sub {memory(sub {
    my($db,$a)=@_;$db->do("ALTER TABLE line_items ADD COLUMN tenant TEXT DEFAULT 'north'");my$d=dclone($f->{flat_domain});
    push@{$d->{source}{fields}},'tenant';$d->{source}{columns}{tenant}={type=>'string'};$d->{writes}{scope}{tenant}={field=>'tenant'};
    $d->{rules}{definitions}{tenant}={version=>1,test=>{op=>'value.eq',value=>'NORTH'}};
    $d->{rules}{normalizers}{tenant}={version=>1,steps=>[{op=>'text.uppercase',profile=>'ascii_v1'}]};
    $d->{rules}{bindings}{tenant}={subject=>{scope=>'candidate',path=>['tenant']},operations=>['insert'],rule=>{id=>'tenant',version=>1},normalizer=>{id=>'tenant',version=>1}};
    my$e=Selecto::Engine->new(domain=>Selecto::Domain->parse($d),adapter=>$a,scope=>{tenant=>'north'});
    eval {$e->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'line_items',assignments=>$f->{flat_valid}))};is $@->code,'tenant_mismatch','post-normalizer tenant is checked against trusted scope';is $a->{dispatches}//0,0,'normalizer bypass never dispatches';
    $d=dclone($f->{flat_domain});$d->{rules}{bindings}{positive}{subject}{scope}='transaction';
    eval {engine($d,$a)->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'line_items',assignments=>$f->{flat_invalid}))};is $@->code,'data_rule_failed','transaction-stage rule runs at protected boundary';is $a->{dispatches}//0,0,'transaction-stage invalid candidate does not dispatch';
})};
for my $shadow (
    ['table','CREATE TEMP TABLE LINE_ITEMS(id INTEGER PRIMARY KEY,quantity REAL,reference TEXT)'],
    ['view','CREATE TEMP VIEW LINE_ITEMS AS SELECT id,quantity*1.0 AS quantity,reference FROM main.line_items'],
) {
    for my $rules (0,1) {
        subtest "uppercase TEMP $shadow->[0] shadow, rules=$rules" => sub {memory(sub {
            my($db,$a)=@_;$db->do($shadow->[1]);my$d=dclone($f->{flat_domain});delete$d->{rules}unless$rules;
            eval {engine($d,$a)->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'line_items',assignments=>{quantity=>2,reference=>'AB12'},predicate=>Selecto::Expression->gt('quantity',0)))};
            is $@->code,$rules?'required_data_rule_pending':'query_rule_not_evaluable','catalog guard refuses the actual shadow before dispatch';
            is $db->selectrow_array('SELECT count(*) FROM main.line_items'),0,'main table unchanged';
            is $db->selectrow_array('SELECT count(*) FROM temp.LINE_ITEMS'),0,'shadow unchanged';
        })};
    }
}
done_testing;
