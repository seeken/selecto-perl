use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Write;
use Selecto::Write::Operation;
use Selecto::Write::NestedGraph;
use Selecto::Write::Multi;
use Selecto::Domain::QueryContract;

sub copy {Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value}}
sub error {
    my ($run)=@_;my $ok=eval {$run->();1};return undef if $ok;
    my $e=$@;ok ref($e) eq 'Selecto::Error','refusal is a typed public error';return $e;
}
sub domain {
    my ($table,$fields)=@_;return {source=>{source_table=>$table,primary_key=>'id',fields=>$fields,
        columns=>{map {$_=>{type=>$_ eq 'name'?'string':'integer'}} @$fields},associations=>{}},schemas=>{},
        writes=>{operations=>{map {$_=>{enabled=>JSON::PP::true,($_ ne 'insert'?(require_filter=>JSON::PP::true):())}} qw(insert update delete)},
            fields=>{map {$_=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}} grep {$_ ne 'id' && $_ ne 'parent_id'} @$fields}}};
}
sub root {
    my $root=domain('parents',[qw(id name)]);my $child=domain('children',[qw(id parent_id name quantity)]);
    $root->{writes}{relationships}{children}={writable=>JSON::PP::true,cardinality=>'many',ownership=>'owned',
        domain=>$child,child_key=>'parent_id',identity_fields=>['id'],allowed_ops=>[qw(insert update delete)],strategy=>'sync',delete_missing=>JSON::PP::true};
    return $root;
}
sub compile {Selecto::Write::Operation->new($_[0])->insert($_[1])->compile}
my $raw=root();my $values={name=>'parent',children=>[[['name','pair'],['quantity',2]]]};
my $graph=compile($raw,$values)->{command};
is_deeply $graph->nodes->[1]{command}->assignments,{name=>'pair',quantity=>2},'nested public ordered field/value input is retained';
my $ordered=compile($raw,[['name','ordered-root'],['children',[[['name','ordered-child']]]]])->{command};
is_deeply [map {$_->{command}->assignments->{name}} @{$ordered->nodes}],['ordered-root','ordered-child'],'root ordered pairs lower genuine nested topology';
my $root_dup=error(sub {compile($raw,[['name','root'],['children',[]],[{'$atom'=>'children'},[]]])});
is $root_dup->code,'duplicate_assignment_identifier','root marker/string nested duplicate refuses before lowering';
my $dup=error(sub {compile($raw,{name=>'parent',children=>[[['name','one'],[{'$atom'=>'name'},'two']]]})});
is $dup->code,'duplicate_assignment_identifier','marker/string normalized duplicate cannot be laundered through nested object';
$values->{children}[0][0][1]='mutated';
is $graph->nodes->[1]{command}->assignments->{name},'pair','compiled child owns its authored input';
my $m=$graph->metadata;$m->{root_returning}='all';
is $graph->metadata->{root_returning},'none','graph informational metadata getter is independent';
isa_ok $graph->validate,'Selecto::Write::Graph','public validate reconstructs native topology';
is_deeply $graph->public_returning('root'),[],'public result intent excludes native binding-derived returning';
is_deeply $graph->validate->public_returning('root'),[],'graph validation retains original public returning intent';
my $visible=$graph->public_returning('root');push @$visible,'id';
is_deeply $graph->public_returning('root'),[],'public returning getter is an independent copy';
$graph->{metadata}{root_returning}='all';
is_deeply $graph->public_returning('root'),[],'mutable informational metadata cannot change private result intent';

my $bad=root();$bad->{writes}{relationships}{children}{child_key}='absent';ok error(sub {compile($bad,{name=>'parent',children=>[{name=>'child'}]})}),'child ownership key must exist';
$bad=root();$bad->{writes}{relationships}{children}{identity_fields}=['absent'];ok error(sub {compile($bad,{name=>'parent',children=>[{name=>'child'}]})}),'stable child identity fields must exist';
$bad=root();$bad->{writes}{relationships}{children}{validation}={field_rules=>{}};
ok error(sub {compile($bad,{name=>'parent',children=>[{name=>'child'}]})}),'malformed field rule list refuses as typed error';
$bad=root();$bad->{writes}{relationships}{children}{validation}={field_rules=>[{field=>'quantity',type=>'number',greater_than=>0}]};
isa_ok compile($bad,{name=>'parent',children=>[{name=>'child',quantity=>2}]})->{command},'Selecto::Write::Graph','canonical legacy numeric-bound policy accepts';
ok error(sub {compile($bad,{name=>'parent',children=>[{name=>'child',quantity=>-1}]})}),'canonical numeric-bound policy refuses failing child';
$bad=root();$bad->{writes}{relationships}{children}{validation}={unique_fields=>['name']};
ok error(sub {compile($bad,{name=>'parent',children=>[{name=>'same'},{name=>'same'}]})}),'cross-child declared uniqueness uses actual candidates';
$bad=root();$bad->{writes}{relationships}{children}{validation}={aggregate_rules=>[{operation=>'sum',field=>'quantity',maximum=>5,representations=>['full_set']}]};
isa_ok compile($bad,{name=>'parent',children=>[{name=>'one',quantity=>3}]})->{command},'Selecto::Write::Graph','full-set aggregate accepts admitted actual insert payload';
my $update=sub {Selecto::Write::Operation->new($bad)->update({name=>'parent',children=>[{name=>'one',quantity=>3},{name=>'two',quantity=>3}]})->filter(['id',1])->compile};
ok error($update),'sum policy checks the complete full-set payload';
$bad=root();$bad->{writes}{relationships}{children}{write}={modes=>['delta'],create=>JSON::PP::true,update=>JSON::PP::true,delete=>JSON::PP::true};delete @{$bad->{writes}{relationships}{children}}{qw(strategy delete_missing)};
my $delta=Selecto::Write::Operation->new($bad)->update({name=>'parent',children=>{create=>[{name=>'created'}],update=>[{id=>1,name=>'updated'}],delete=>[{id=>2}]}})->filter(['id',1])->compile->{command};
is_deeply [map {$_->{command}->operation} @{$delta->nodes}],[qw(update insert update delete)],'delta retains ordered actual native semantic operations';
is_deeply $delta->owned_sets,[],'delta never invents omitted-child deletion';
my $missing=error(sub {Selecto::Write::Operation->new($bad)->update({name=>'parent',children=>{update=>[{name=>'missing-id'}]}})->filter(['id',1])->compile});
is $missing->code,'invalid_graph','explicit child update requires identity';
my $long='r'x22000;$bad=root();$bad->{writes}{relationships}{$long}=delete $bad->{writes}{relationships}{children};
ok error(sub {compile($bad,{name=>'parent',$long=>[map {{name=>"child$_"}} 1..20]})}),'generated repeated relationship paths are cumulatively bounded';

my $op=Selecto::Write::Operation->new(domain('items',[qw(id name)]))->insert({name=>'one'});
my $multi=Selecto::Write::Multi->new(operations=>[['one',$op]]);
my $entries=$multi->operations;$entries->[0][0]='changed';push @$entries,['extra',$op];
is_deeply [map {$_->[0]} @{$multi->operations}],['one'],'Multi operations getter owns names/list';
is scalar @{$multi->compile->{command}->commands},1,'unmutated Multi compiles actual one-command batch';
ok error(sub {Selecto::Write::Multi->new(operations=>[['one',$op],['one',$op]])->compile}),'duplicate name refuses before compilation';
ok error(sub {Selecto::Write::Multi->new(operations=>[[42,$op]])}),'numeric operation name refuses';
is_deeply [map {$_->[0]} @{Selecto::Write::Multi->new(operations=>[['42',$op]])->operations}],['42'],'authored numeric-looking string remains legitimate name';
my $fake=bless \(my $token=0),'Selecto::Write::Multi';ok error(sub {$fake->operations}),'forged opaque Multi refuses';
my $result=Selecto::Write::Result->new(operation=>'insert',affected_rows=>1,metadata=>{batch_index=>0,enabled=>JSON::PP::true,nested=>{value=>'old'}});
my $meta=$result->metadata;$meta->{nested}{value}='new';${$meta->{enabled}}=0;
is_deeply $result->metadata,{batch_index=>0,enabled=>JSON::PP::true,nested=>{value=>'old'}},'Result metadata copies nested fields and Boolean referents';
is_deeply $result->to_hash->{metadata},$result->metadata,'public result hash retains actual metadata';
my $hook=0;{
    package PortableNested::Hook;use overload '""'=>sub {$hook++;'evil'},fallback=>1;
}
my $object=bless {},'PortableNested::Hook';
ok error(sub {Selecto::Write::Operation->new(root())->insert({name=>'parent',children=>[{name=>$object}]})}),'nested resources refuse before interpretation';
ok error(sub {Selecto::Write::Graph->new(nodes=>$graph->nodes,metadata=>{object=>$object})}),'graph metadata refuses executable objects';
is $hook,0,'no overloaded value callback ran';
my %tied;{package PortableNested::Tie;sub TIEHASH {bless {},shift}sub FIRSTKEY {$hook++;undef}sub FETCH {$hook++;undef}}
tie %tied,'PortableNested::Tie';
ok error(sub {Selecto::Write::Operation->new(root())->insert(\%tied)}),'tied nested input refuses';
is $hook,0,'tied metadata admission ran no callbacks';
done_testing;
