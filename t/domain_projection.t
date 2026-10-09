use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Domain::Projection;

my $fixtures = do { open my $fh, '<:raw', 't/fixtures/domain_projection.json' or die $!; local $/; JSON::PP->new->utf8->decode(<$fh>) };
my $original = $fixtures->{D023}{governed_domain};
my $before = dclone($original);
sub caught { my ($run) = @_; my $ok = eval { $run->(); 1 }; return $ok ? undef : $@; }
sub field { my ($result, $id) = @_; return (grep { $_->{id} eq $id } @{$result->{fields}})[0]; }
my %wanted = (
 query => [qw(components custom_columns json_schemas subfilters window_functions pagination retarget)],
 write => [qw(components columns writes actions capabilities source_relationships choice_sources)],
 ui => [qw(components columns redact_fields detail_actions actions capabilities choice_sources)],
 api => [qw(components columns custom_columns json_schemas subfilters window_functions pagination retarget redact_fields writes actions capabilities source_relationships choice_sources detail_actions)],
 query_contract => ['components']);
my %expected = (
 query => [qw(custom_columns json_schemas pagination retarget subfilters window_functions)],
 write => [qw(actions capabilities choice_sources columns source_relationships writes)],
 ui => [qw(actions capabilities choice_sources columns components detail_actions redact_fields)],
 api => [qw(actions capabilities choice_sources columns custom_columns detail_actions json_schemas pagination redact_fields retarget source_relationships subfilters window_functions writes)],
 query_contract => []);
for my $consumer (sort keys %wanted) {
 my $result = Selecto::Domain->project($original, $consumer);
 is_deeply([sort grep { exists $result->{$_} } @{$wanted{$consumer}}], $expected{$consumer}, "$consumer exposes original inspected section boundary");
 is_deeply($original, $before, "$consumer leaves complete input unchanged");
 ok(!exists($result->{unexpected_sensitive}), "$consumer uses section allowlists");
}
my $contract = Selecto::Domain->project($original, 'query_contract');
my $private = field($contract, 'private_metric');
is_deeply({map { $_ => $private->{$_} } qw(capability detail_selectable field type)},
 {capability=>'work_items.private_metric', detail_selectable=>JSON::PP::true,field=>'private_metric',type=>'integer'}, 'source field descriptors preserve governed metadata without UI overrides');
my $title = field($contract, 'title_key');
is_deeply({map { $_ => $title->{$_} } qw(capability detail_selectable field source type)},
 {capability=>'work_items.read',detail_selectable=>JSON::PP::true,field=>'title_key',source=>'custom_column',type=>'string'}, 'custom descriptors use actual declared metadata');
is(field($contract,'owners.name')->{source},'schema','schema fields have actual declared source kind');
is(field($contract,'owner.name')->{source},'join','declared join field descriptors derive the target schema');
is(field($contract,'owner.name')->{field},'name','joined local field identity remains distinct');
is_deeply($contract->{joins}[0]{fields},[qw(id name active tenant_id)],'join metadata derives target declared fields');
ok(!exists($contract->{declaration}) && !exists($contract->{components}), 'query-contract description excludes raw consumer sections');
for my $consumer (qw(query write ui api)) {
 my $result = Selecto::Domain->project($original,$consumer);
 is_deeply($result->{redact_fields}, ($consumer eq 'ui'||$consumer eq 'api')?['private_metric']:undef,"$consumer redaction boundary is actual metadata");
 ok(!exists($result->{redact_fields}),"$consumer redaction key is absent") if $consumer eq 'query'||$consumer eq 'write';
 $result->{source}{columns}{title}{type}='changed';
 is_deeply($original,$before,"$consumer returned source data is isolated");
}
$contract->{fields}[0]{type}='changed';$contract->{functions}[0]{args}[0]{name}='changed';
is_deeply($original,$before,'query-contract return is isolated from all authored metadata');
my $change=dclone($original);$change->{unexpected_sensitive}={secret=>'sensitive'};
for my $consumer (qw(query write ui api query_contract)) { ok(!exists(Selecto::Domain->project($change,$consumer)->{unexpected_sensitive}),"$consumer cannot leak new arbitrary sections"); }
$change=dclone($original);$change->{source}{columns}{private_metric}{type}='float';$change->{source}{columns}{private_metric}{capability}='changed.metric';$change->{custom_columns}{title_key}{capability}='changed.title';
my $changed=Selecto::Domain->project($change,'query_contract');
is_deeply([@{field($changed,'private_metric')}{qw(type capability)}],['float','changed.metric'],'source descriptor follows changed declarations');
is(field($changed,'title_key')->{capability},'changed.title','custom descriptor follows changed declaration');
for my $route (qw(source custom)) {
 for my $flag (qw(internal detail_selectable selectable)) {
  my$c=dclone($original);my$column=$route eq'source'?$c->{source}{columns}{private_metric}:$c->{custom_columns}{title_key};
  $column->{$flag}=$flag eq'internal'?JSON::PP::true:JSON::PP::false;
  my$d=field(Selecto::Domain->project($c,'query_contract'),$route eq'source'?'private_metric':'title_key');
  ok(!$d->{detail_selectable},"$route $flag withdraws detail selection metadata");
 }
}
$change=dclone($original);$change->{source}{columns}{private_metric}{detail_selectable}=JSON::PP::false;$change->{columns}{private_metric}{detail_selectable}=JSON::PP::true;
ok(!field(Selecto::Domain->project($change,'query_contract'),'private_metric')->{detail_selectable},'UI true cannot override source false');
$change=dclone($original);$change->{redact_fields}=['title'];
is_deeply(Selecto::Domain->project($change,'api')->{redact_fields},['title'],'redaction projection follows authored changes');
delete $change->{redact_fields};ok(!exists(Selecto::Domain->project($change,'ui')->{redact_fields}),'missing redaction remains absent');
for my $projection ('unknown_projection',undef,{},[],0) {
 my$error=caught(sub{Selecto::Domain->project($original,$projection)});
 is(ref($error)?$error->code:'none','invalid_domain_projection','unknown/malformed projection receives typed refusal');
 is(ref($error)?$error->details->{reason}:'none','unknown_projection','specific unknown-projection reason');
}
for my $control (
 ['malformed section',sub{$_[0]{components}=[]},'ui'],
 ['missing declared column',sub{delete $_[0]{source}{columns}{title}},'query_contract'],
 ['malformed column spec',sub{$_[0]{source}{columns}{title}=[]},'query_contract'],
 ['malformed surface boolean',sub{$_[0]{source}{columns}{title}{selectable}='yes'},'query_contract'],
 ['malformed surface list',sub{$_[0]{source}{columns}{title}{comparators}={}},'query_contract'],
 ['missing join target',sub{$_[0]{source}{associations}{owner}{queryable}='missing'},'query_contract']) {
 my($label,$edit,$projection)=@$control;my$c=dclone($original);$edit->($c);
 my$error=caught(sub{Selecto::Domain->project($c,$projection)});
 ok(ref($error) && ($error->code eq'invalid_domain_projection'||$error->code eq'invalid_query_contract'),"$label returns typed diagnostic");
}
my$calls=0;
{package ProjectionEvil;use overload '""'=>sub{$calls++;'evil'},'bool'=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub STORABLE_freeze{$calls++;die'callback'}sub TO_JSON{$calls++;die'callback'}}
for my$bad(sub{$calls++},bless({},'ProjectionEvil'),bless({},'0')) {
 my$c=dclone($original);$c->{unexpected_extension}=$bad;
 for my$projection(qw(query write ui api query_contract)) {
  my$error=caught(sub{Selecto::Domain->project($c,$projection)});
  is(ref($error)?$error->code:'none','invalid_query_contract',"$projection refuses executable metadata before projection");
 }
}
{package ProjectionTied;sub TIEHASH{bless{},shift}sub FIRSTKEY{$calls++;die'tied hook'}sub FETCH{$calls++;die'tied hook'}}
tie my%tied,'ProjectionTied';my$error=caught(sub{Selecto::Domain->project(\%tied,'ui')});
is(ref($error)?$error->code:'none','invalid_query_contract','tied root refuses before inspection');
is($calls,0,'callbacks, overloads, clone/getter and tied hooks never execute');
for my$kind(qw(cycle depth breadth bytes alias)) {
 my$c=dclone($original);
 if($kind eq'cycle'){$c->{extension}=$c}
 elsif($kind eq'depth'){my$n={};$c->{extension}=$n;for(1..70){$n->{next}={};$n=$n->{next}}}
 elsif($kind eq'breadth'){$c->{extension}=[(1)x10001]}
 elsif($kind eq'bytes'){$c->{extension}='x'x131073}
 else{my$n=['leaf'];for(1..14){$n=[$n,$n]}$c->{extension}=$n}
 my$e=caught(sub{Selecto::Domain->project($c,'query')});
 is(ref($e)?$e->code:'none','invalid_query_contract',"$kind cannot bypass shared metadata admission");
}
my$long='s'x4096;my$compact={source=>{columns=>{id=>{type=>'integer'}}},schemas=>{$long=>{columns=>{map{("f$_"=>{type=>'integer'})}1..40}}}};
my$e=caught(sub{Selecto::Domain->project($compact,'query_contract')});
ok(ref($e)&&($e->code eq'invalid_domain_projection'||$e->code eq'invalid_query_contract'),'compact generated prefix amplification refuses before large output');
is_deeply($original,$before,'all controls leave the original full fixture unchanged');
my$surface=Selecto::Domain->project($original,'query_contract');
${field($surface,'title')->{detail_selectable}}=0;
ok(field($surface,'private_metric')->{detail_selectable},'field Boolean flags have independent scalar referents');
is_deeply($original,$before,'returned surface Boolean mutation leaves complete original input unchanged');
my$raw_project=Selecto::Domain->project($original,'ui');
${$raw_project->{columns}{private_metric}{detail_selectable}}=1;
ok(!$original->{columns}{private_metric}{detail_selectable},'raw consumer Boolean mutation leaves original presentation flag unchanged');
my$dotted=('segment.'x1500).'last';
my$dotted_contract={source=>{columns=>{},associations=>{$dotted=>{queryable=>'target'}}},schemas=>{target=>{columns=>{}}},joins=>{$dotted=>{type=>'left'}}};
is_deeply(Selecto::Domain->project($dotted_contract,'query_contract')->{joins}[0]{path},[$dotted],'dotted declared join id stays one path component without split amplification');
my$huge_dotted=('x.'x28000).'last';
my$huge_contract={source=>{columns=>{},associations=>{$huge_dotted=>{queryable=>'target'}}},schemas=>{target=>{columns=>{}}},joins=>{$huge_dotted=>{type=>'left'}}};
my$path_error=caught(sub{Selecto::Domain->project($huge_contract,'query_contract')});
ok(ref($path_error)&&($path_error->code eq'invalid_domain_projection'||$path_error->code eq'invalid_query_contract'),'compact long dotted id cannot exceed generated output budget');
done_testing;
