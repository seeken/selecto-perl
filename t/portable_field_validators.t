use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Selecto::Write::Operation;
use Selecto::Write::PortableCommand;
use Selecto::Write::NestedGraph;
use Selecto::Write::Multi;
use Selecto::Domain::Choices;
use Selecto::Domain::QueryContract;

sub copy {Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value}}
sub domain {
    my ($table)=@_;$table //='items';
    return {name=>$table,source=>{source_table=>$table,primary_key=>'id',fields=>[qw(id name quantity tenant_id account_id unused)],
        columns=>{map {$_=>{type=>$_ eq 'quantity'||$_ eq 'account_id'||$_ eq 'id'?'integer':'string'}} qw(id name quantity tenant_id account_id unused)},associations=>{}},schemas=>{},
        writes=>{operations=>{map {$_=>{enabled=>JSON::PP::true,($_ eq 'update'?(require_filter=>JSON::PP::true):())}} qw(insert update)},
            fields=>{map {$_=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}} qw(name quantity tenant_id account_id unused)}}};
}
sub compile {
    my ($raw,$values,%options)=@_;
    return Selecto::Write::Operation->new($raw)->update($values)->filter(['id',1])->compile(%options);
}
sub caught {my($work)=@_;my($ok,$error);{local$@;$ok=eval{$work->();1};$error=$@ unless $ok}return $error}
sub refuses {
    my ($code,$work,$label)=@_;my $error=caught($work);
    ok ref($error) eq 'Selecto::Error',$label;
    is ref($error) eq 'Selecto::Error'?$error->code:'untyped',$code,'refusal preserves typed category';
    return $error;
}
sub validator_domain {my($field,$validator)=@_;my$d=domain();$d->{writes}{fields}{$field}{validators}=[$validator];return$d}

for my $case (
    ['number','quantity',['number',[[greater_than=>0],[greater_than_or_equal_to=>2],[less_than=>10],[less_than_or_equal_to=>8]]],2,9],
    ['length','name',['length',[[min=>2],[max=>3]]],"é😀",'x'],
    ['format','name',['format',{source=>'[A-Z]+',opts=>''}],'ABC','AbC'],
    ['inclusion','name',['inclusion',['open','done']],'open','closed'],
    ['exclusion','name',['exclusion',['blocked','hidden']],'visible','blocked'],
) {
    my ($label,$field,$validator,$positive,$negative)=@$case;my $raw=validator_domain($field,$validator);
    is_deeply compile($raw,{$field=>$positive})->{command}->assignments->{$field},$positive,"$label admits genuine positive assignment";
    refuses('data_rule_failed',sub {compile($raw,{$field=>$negative})},"$label rejects genuine failing assignment");
}
my $exact=validator_domain('name',['length',[[is=>1]]]);
is compile($exact,{name=>'😀'})->{command}->assignments->{name},'😀','exact Unicode scalar length treats one supplementary scalar as one';
refuses('data_rule_failed',sub {compile($exact,{name=>'😀x'})},'exact Unicode scalar length refuses two scalars');
my $fraction=validator_domain('quantity',['number',[[greater_than=>'0.1'],[less_than=>'0.3']]]);
is compile($fraction,{quantity=>'0.2'})->{command}->assignments->{quantity},'0.2','number validator evaluates exact decimal text without native float rounding';
refuses('data_rule_failed',sub {compile($fraction,{quantity=>'0.3'})},'exact decimal boundary remains exclusive');

subtest 'normalized effective assignments and trusted fills' => sub {
    my $raw=validator_domain('name',['format',{source=>'[A-Z]+',opts=>[]}]);
    $raw->{source}{columns}{name}{text_case}='uppercase';
    is compile($raw,{name=>'mixed'})->{command}->assignments->{name},'MIXED','field text normalization precedes validation';
    my $trimmed=validator_domain('name',['inclusion',['accepted']]);
    $trimmed->{rules}={schema=>'selecto.data_rules.v1',definitions=>{ok=>{version=>1,test=>{op=>'text.nonblank'}}},
        normalizers=>{trim=>{version=>1,steps=>[{op=>'text.trim',profile=>'ascii_whitespace_v1'}]}},
        bindings=>{name=>{subject=>{scope=>'input',path=>['name']},normalizer=>{id=>'trim',version=>1},rule=>{id=>'ok',version=>1}}}};
    is compile($trimmed,{name=>'  accepted  '})->{command}->assignments->{name},'accepted','INPUT normalization precedes legacy validation';
    my $raw_only=copy($trimmed);$raw_only->{writes}{fields}{name}{validators}=[['inclusion',['  accepted  ']]];
    refuses('data_rule_failed',sub {compile($raw_only,{name=>'  accepted  '})},'raw-valid normalized-invalid value cannot bypass validation');
    my $trusted=domain();$trusted->{writes}{scope}{tenant}={required=>JSON::PP::true,field=>'tenant_id',satisfied_by=>['trusted_context']};
    $trusted->{writes}{fields}{tenant_id}{validators}=[['inclusion',['tenant-a']]];
    $trusted->{writes}{fields}{account_id}{validators}=[['number',[[greater_than=>0]]]];
    $trusted->{writes}{constraints}{foreign_keys}{account_id}={source=>['context','account_id'],required=>JSON::PP::true,references=>{relation=>'accounts',field=>'id'}};
    my $op=Selecto::Write::Operation->new($trusted)->insert({name=>'filled'});
    my $good=$op->compile(context=>{tenant_id=>'tenant-a',account_id=>7});
    is_deeply {map {$_=>$good->{command}->assignments->{$_}} qw(tenant_id account_id)},{tenant_id=>'tenant-a',account_id=>7},'validators see real trusted tenant and foreign-key fills';
    refuses('data_rule_failed',sub {$op->compile(context=>{tenant_id=>'tenant-b',account_id=>7})},'trusted tenant fill is validated as an effective assignment');
    refuses('data_rule_failed',sub {$op->compile(context=>{tenant_id=>'tenant-a',account_id=>0})},'trusted FK fill is validated before choice or SQL');
};

subtest 'assigned-only semantics and complete active syntax' => sub {
    my $raw=domain();$raw->{writes}{fields}{unused}{validators}=['unknown-but-unassigned'];
    isa_ok compile($raw,{name=>'ordinary'})->{command},'Selecto::Write::Command','highest semantics leave wholly unassigned unknown validator uninterpreted';
    refuses('unsupported_write_rule',sub {compile($raw,{unused=>'now-assigned'})},'assigned unknown validator fails closed');
    my $multiple=domain();$multiple->{writes}{fields}{name}{validators}=[['inclusion',['allowed']],'later-unknown'];
    refuses('unsupported_write_rule',sub {compile($multiple,{name=>'failing-first-value'})},'whole active syntax compiles before first test evaluation');
    my $delete=domain();$delete->{writes}{operations}{delete}={enabled=>JSON::PP::true,require_filter=>JSON::PP::true};
    $delete->{writes}{fields}{name}{validators}=['unknown-but-no-delete-assignment'];
    isa_ok(Selecto::Write::Operation->new($delete)->delete->filter(['id',1])->compile->{command},'Selecto::Write::Command','delete has no submitted field validation');
};
sub choice_domain {
    my ($table)=@_;my $raw=domain($table);$raw->{source}{columns}{name}{choice_source}='names';
    $raw->{choice_sources}={names=>{domain=>'names',value_field=>'id',label_field=>'name'}};return$raw;
}
subtest 'callbacks run exactly once after the complete pure bundle' => sub {
    my $calls=0;my $resolver=sub {my($request)=@_;$calls++;is $request->{value},'ACCEPTED','resolver receives the normalized validated value';
        $request->{record}{name}='mutated-provider-copy';return Selecto::Domain::Choices->valid('allowed')};
    my $raw=choice_domain();$raw->{source}{columns}{name}{text_case}='uppercase';$raw->{writes}{fields}{name}{validators}=[['inclusion',['ACCEPTED']]];
    my $result=compile($raw,{name=>'accepted'},choice_membership_resolver=>$resolver);
    is $calls,1,'one actual membership decision after success';
    is $result->{command}->assignments->{name},'ACCEPTED','callback request mutation cannot change accepted command';
    refuses('data_rule_failed',sub {compile($raw,{name=>'bad'},choice_membership_resolver=>$resolver)},'invalid normalized value refuses before membership');
    is $calls,1,'failing field invokes zero additional callbacks';
    my $unknown=copy($raw);$unknown->{writes}{fields}{quantity}{validators}=['later-unknown'];
    refuses('unsupported_write_rule',sub {compile($unknown,{name=>'accepted',quantity=>1},choice_membership_resolver=>$resolver)},'later assigned field syntax refuses before first callback');
    is $calls,1,'later unknown syntax invokes no resolver';
    my $failure=caught(sub {compile($raw,{name=>'accepted'},choice_membership_resolver=>sub {die "trusted resolver stops\n"})});
    like "$failure",qr/trusted resolver stops/,'trusted callback throw stops the entire compilation';
    my $again=compile($raw,{name=>'accepted'},choice_membership_resolver=>$resolver);
    is $calls,2,'failed scope does not retain or replay its ephemeral queue';
    isa_ok $again->{command},'Selecto::Write::Command';
};

sub nested_domain {
    my $root=choice_domain('parents');my $child=domain('children');
    push @{$child->{source}{fields}},'parent_id';$child->{source}{columns}{parent_id}={type=>'integer'};
    $root->{writes}{relationships}{children}={writable=>JSON::PP::true,cardinality=>'many',ownership=>'owned',allowed_ops=>['insert'],domain=>$child,child_key=>'parent_id',identity_fields=>['id']};
    return$root;
}
subtest 'later nested and batch validators precede root callbacks' => sub {
    my $calls=0;my $resolver=sub {$calls++;return Selecto::Domain::Choices->valid('allowed')};
    my $nested=nested_domain();$nested->{writes}{relationships}{children}{domain}{writes}{fields}{name}{validators}=['unknown-child-validator'];
    my $operation=Selecto::Write::Operation->new($nested)->insert({name=>'root',children=>[{name=>'child'}]});
    refuses('unsupported_write_rule',sub {$operation->compile(choice_membership_resolver=>$resolver)},'later child active validator refuses before root callback');
    is $calls,0,'later child syntax causes no root resolver calls';
    refuses('unsupported_write_rule',sub {Selecto::Write::NestedGraph->compile($operation,choice_membership_resolver=>$resolver)},'direct nested entry retains whole bundle callback order');
    is $calls,0,'direct nested entry has zero resolver calls';
    $nested->{writes}{relationships}{children}{domain}{writes}{fields}{name}{validators}=[['length',[[min=>2]]]];
    my $good=Selecto::Write::Operation->new($nested)->insert({name=>'root',children=>[{name=>'child'}]})->compile(choice_membership_resolver=>$resolver);
    isa_ok $good->{command},'Selecto::Write::Graph';is $calls,1,'nested success invokes root choice exactly once';
    my $first=choice_domain('first');my $last=validator_domain('quantity','unknown-last-validator');
    my $multi=Selecto::Write::Multi->new->insert('first',$first,{name=>'root'})->insert('last',$last,{quantity=>1});
    refuses('unsupported_write_rule',sub {$multi->compile(choice_membership_resolver=>$resolver)},'last member active syntax refuses before first member callback');
    is $calls,1,'batch failure adds no resolver calls';
    $last->{writes}{fields}{quantity}{validators}=[['number',[[greater_than=>0]]]];
    my $accepted=Selecto::Write::Multi->new->insert('first',$first,{name=>'root'})->insert('last',$last,{quantity=>1})->compile(choice_membership_resolver=>$resolver);
    isa_ok $accepted->{command},'Selecto::Write::Batch';is $calls,2,'complete batch invokes first membership exactly once';
};

subtest 'one cumulative validator budget spans fields and batch members' => sub {
    require Selecto::Limits;require Selecto::Write::FieldValidators;
    my $limits=Selecto::Limits->new(max_rule_work=>40_000);
    my $raw=validator_domain('name',['length',[[min=>1]]]);
    my $value='x'x3000;
    isa_ok(Selecto::Write::FieldValidators->with_budget(sub {compile($raw,{name=>$value})},limits=>$limits)->{command},
        'Selecto::Write::Command','one member fits the trusted cumulative work budget');
    my $multi=Selecto::Write::Multi->new(operations=>[map {['m'.$_,Selecto::Write::Operation->new($raw)->insert({name=>$value})]} 1..5]);
    refuses('evaluation_limit',sub {Selecto::Write::FieldValidators->with_budget(sub {$multi->compile},limits=>$limits)},
        'individually admissible batch members cannot reset cumulative work');
    my $many=domain();my %values;
    for my $index (1..5) {my$field='text'.$index;push @{$many->{source}{fields}},$field;$many->{source}{columns}{$field}={type=>'string'};
        $many->{writes}{fields}{$field}={insertable=>JSON::PP::true,updatable=>JSON::PP::true,validators=>[['length',[[min=>1]]]]};$values{$field}=$value}
    refuses('evaluation_limit',sub {Selecto::Write::FieldValidators->with_budget(sub {compile($many,{%values})},limits=>$limits)},
        'individually admissible fields cannot reset cumulative work');
    isa_ok(Selecto::Write::FieldValidators->with_budget(sub {compile($raw,{name=>$value})},limits=>$limits)->{command},
        'Selecto::Write::Command','failed budget scope does not poison a later independent compile');
    my $nested=nested_domain();$nested->{writes}{relationships}{children}{domain}{writes}{fields}{name}{validators}=[['length',[[min=>1]]]];
    my $calls=0;my $operation=Selecto::Write::Operation->new($nested)->insert({name=>'root',children=>[map {{name=>$value}} 1..5]});
    refuses('evaluation_limit',sub {Selecto::Write::FieldValidators->with_budget(sub {$operation->compile(choice_membership_resolver=>sub {$calls++;Selecto::Domain::Choices->valid('allowed')})},limits=>$limits)},
        'nested child validators share the outer cumulative work budget');
    is $calls,0,'nested work exhaustion occurs before the first deferred root callback';
};
subtest 'native Multi run shares compiler and execution work' => sub {
    eval {require DBI;require DBD::SQLite;require Selecto;1} or plan skip_all=>'DBD::SQLite required';
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});$db->do('PRAGMA temp_store=MEMORY');
    $db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)');
    my $raw={name=>'items',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id name)],columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},
        writes=>{operations=>{insert=>{enabled=>JSON::PP::true}},fields=>{name=>{insertable=>JSON::PP::true,validators=>[['length',[[min=>1]]]]}}}};
    my $limits=Selecto::Limits->new(max_rule_work=>16_000);my $adapter=Selecto->adapter(sqlite=>(dbh=>$db));
    my $host=Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>$adapter,limits=>$limits);
    my $multi=Selecto::Write::Multi->new->insert('one',$raw,{name=>'x'x3000});
    my $compiled=Selecto::Write::FieldValidators->with_budget(sub {$multi->compile},limits=>$limits);
    isa_ok $compiled->{command},'Selecto::Write::Batch','compile alone fits the configured budget';
    my $native=$host->execute_batch($compiled->{command},engines=>[$host]);
    is scalar(@$native),1,'native dispatch alone fits the same configured budget';
    is $db->selectrow_array('SELECT count(*) FROM items'),1,'standalone native control really inserts';
    $db->do('DELETE FROM items');my $mutations=0;$db->sqlite_trace(sub {$mutations++ if $_[0]=~/\A\s*INSERT\s+INTO\s+"?items\b/i});
    refuses('evaluation_limit',sub {$multi->run($host)},'one public run cannot spend two independent full budgets');
    is $mutations,0,'combined exhaustion occurs before any native business insert';
    is $db->selectrow_array('SELECT count(*) FROM items'),0,'combined exhaustion preserves physical storage';
    my $larger=Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>$adapter,limits=>Selecto::Limits->new(max_rule_work=>30_000));
    is_deeply [sort keys %{$multi->run($larger)}],['one'],'adequate shared budget executes the actual named native result';
    is $db->selectrow_array('SELECT count(*) FROM items'),1,'adequate shared budget really inserts once';
    is $db->selectrow_array('PRAGMA temp_store'),2,'native budget proof keeps TEMP in memory';
    is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}],[],'native budget proof opens only memory schemas';
    $db->disconnect;
};
subtest 'opaque action provenance is not an alternate authored compile route' => sub {
    require Selecto::Action;require Selecto::Verification::WriteModel;
    my $raw=Selecto::Verification::WriteModel::work_items();
    $raw->{writes}{fields}{state}{validators}=[['inclusion',['archived']]];
    my $handle=Selecto::Action->planned_operation($raw,{action=>'archive',target=>7});
    refuses('opaque_planned_operation',sub {Selecto::Write::PortableCommand->compile($handle)},'actual planned action remains an opaque native-execution handle');
};
done_testing;
