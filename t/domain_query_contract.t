use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Domain::QueryContract;
open my $fh, '<:raw', 't/fixtures/query_policy.json' or die $!;
my $fixtures = JSON::PP->new->utf8->decode(do { local $/; <$fh> });
close $fh;
my $original = $fixtures->{D019}{governed_domain};
my $before = dclone($original);
sub caught { my ($run) = @_; my $ok = eval { $run->(); 1 }; return $ok ? undef : $@; }
sub codes { return [sort map { $_->{code} } @{$_[0]{errors}}] }
my $project = Selecto::Domain->project_query_contract($original);
is_deeply($original, $before, 'complete original declaration is unchanged');
is_deeply($project->{declaration}, $original, 'all unrelated rich metadata remains in the projection');
is_deeply($project->{defaults}, {default_selected => [qw(id title state priority)], required_selected => ['tenant_id'],
 required_filters => [['tenant_id',7]], required_order_by => [['priority','desc']], required_group_by => ['state']},
 'public API projects actual original defaults');
my ($filter) = grep { $_->{id} eq 'state' } @{$project->{filters}};
is_deeply({map { $_ => $filter->{$_} } qw(id field type virtual comparators)}, {id=>'state',field=>'state',type=>'string',virtual=>JSON::PP::false,
 comparators=>[qw(eq neq contains starts_with ends_with in not_in is_null not_null)]}, 'declared field string comparator metadata');
is($filter->{capability}, 'work_items.read', 'filter capability remains declared metadata');
my ($function) = grep { $_->{id} eq 'normalize_title' } @{$project->{functions}};
is_deeply({map { $_ => $function->{$_} } qw(id kind sql_name allowed_in returns args)}, {id=>'normalize_title',kind=>'scalar',sql_name=>'lower',allowed_in=>[qw(select filter order_by)],returns=>'string',args=>[{name=>'value',source=>'selector',type=>'string'}]}, 'actual function declaration projects independently');
is($function->{capability}, 'work_items.read', 'function capability remains declared metadata');
$project->{declaration}{source}{columns}{title}{type} = 'changed';
$project->{functions}[0]{args}[0]{name} = 'changed';
is_deeply($original, $before, 'returned metadata cannot modify input');
my $invalid = $fixtures->{D020}{invalid_domain};
my $report = Selecto::Domain->validate_query_contract($invalid);
ok(!$report->{valid}, 'original invalid policy does not validate');
is_deeply(codes($report), [qw(query_field_not_found query_function_call_site_not_allowed)], 'both independent original errors accumulate');
is_deeply($report->{errors}[0]{path}, ['required_selected',0], 'missing field has contextual path');
is_deeply($report->{errors}[1], {code=>'query_function_call_site_not_allowed',path=>['required_group_by',0,'function'],function=>'normalize_title',call_site=>'group_by',allowed_in=>['select']}, 'containing group placement survives selector argument validation');
my $fix_field=dclone($invalid);$fix_field->{required_selected}=['tenant_id'];
is_deeply(codes(Selecto::Domain->validate_query_contract($fix_field)), ['query_function_call_site_not_allowed'], 'repairing field leaves only forbidden placement');
my $fix_site=dclone($invalid);push @{$fix_site->{functions}{normalize_title}{allowed_in}},'group_by';
is_deeply(codes(Selecto::Domain->validate_query_contract($fix_site)), ['query_field_not_found'], 'repairing placement leaves only missing field');
push @{$fix_field->{functions}{normalize_title}{allowed_in}},'group_by';
ok(Selecto::Domain->validate_query_contract($fix_field)->{valid}, 'valid declared grouped invocation metadata');
for my $site (qw(default_selected required_selected required_group_by required_order_by)) {
 my $c=dclone($original);$c->{functions}{normalize_title}{allowed_in}=[qw(select group_by order_by)];
 my $udf=['udf','normalize_title',['title']];$c->{$site}=$site eq 'required_order_by'?[[$udf,'desc']]:[$udf];
 ok(Selecto::Domain->validate_query_contract($c)->{valid}, "$site invokes function with actual allowed contextual site");
}
for my $control (
 ['missing function',sub { $_[0]{required_selected}=[['udf','missing',['title']]] },'query_function_not_found'],
 ['missing argument selector',sub { $_[0]{required_selected}=[['udf','normalize_title',['missing']]] },'query_field_not_found'],
 ['wrong arity',sub { $_[0]{required_selected}=[['udf','normalize_title',[]]] },'query_function_arg_count_mismatch'],
 ['malformed required selector',sub { $_[0]{required_selected}=[{}] },'invalid_query_field_reference'],
 ['malformed registry',sub { $_[0]{functions}=[] },'invalid_section_shape'],
 ['unsafe SQL function identifier',sub { $_[0]{functions}{normalize_title}{sql_name}='lower);DELETE FROM work_items;--' },'invalid_function_sql_name'],
 ['invalid call site',sub { $_[0]{functions}{normalize_title}{allowed_in}=['execute'] },'invalid_function_call_site'],
 ['invalid argument source',sub { $_[0]{functions}{normalize_title}{args}[0]{source}='callback' },'invalid_function_arg_source'],
 ['invalid returns',sub { $_[0]{functions}{normalize_title}{returns}={} },'invalid_function_returns'],
 ['empty table function returns',sub { $_[0]{functions}{normalize_title}{kind}='table';$_[0]{functions}{normalize_title}{returns}={columns=>{}} },'invalid_function_returns'],
 ['missing table function columns',sub { $_[0]{functions}{normalize_title}{kind}='table';$_[0]{functions}{normalize_title}{returns}={} },'invalid_function_returns'],
 ['malformed table function columns',sub { $_[0]{functions}{normalize_title}{kind}='table';$_[0]{functions}{normalize_title}{returns}={columns=>[]} },'invalid_function_returns'],
 ['missing explicit filter field',sub { $_[0]{filters}{state}{field}='missing' },'query_field_not_found'],
 ['invalid comparator',sub { $_[0]{filters}{state}{comparators}=['DROP'] },'invalid_filter_comparator'],
 ['malformed order',sub { $_[0]{required_order_by}=[['priority','DROP']] },'invalid_query_order'],
 ['malformed filter',sub { $_[0]{required_filters}=[{}] },'invalid_query_filter'],
 ['malformed function spec with reference',sub { $_[0]{functions}{normalize_title}=[];$_[0]{required_selected}=[['udf','normalize_title',['title']]] },'invalid_section_shape'],
) {
 my ($label,$edit,$code)=@$control;my$c=dclone($original);$edit->($c);
 my $r=Selecto::Domain->validate_query_contract($c);
 ok(grep($_ eq $code,@{codes($r)}), "$label has an actual bounded diagnostic");
 my $error=caught(sub { Selecto::Domain->project_query_contract($c) });
 is(ref($error)?$error->code:'none','invalid_query_contract',"$label prevents projection");
}
my $changed=dclone($original);$changed->{filters}{state}={field=>'priority',type=>'integer',operators=>['gte'],capability=>'different'};
$changed->{functions}{normalize_title}={kind=>'scalar',sql_name=>'upper',allowed_in=>['select'],returns=>'text',args=>[{name=>'caption',source=>'value',type=>'text'}]};
my $p=Selecto::Domain->project_query_contract($changed);
my ($f)=grep {$_->{id} eq 'state'} @{$p->{filters}};
is_deeply([@$f{qw(field type comparators capability)}],['priority','integer',['gte'],'different'],'filter metadata follows changed declaration');
my($fn)=grep {$_->{id} eq 'normalize_title'} @{$p->{functions}};
is_deeply([@$fn{qw(sql_name allowed_in returns args)}],['upper',['select'],'text',[{name=>'caption',source=>'value',type=>'text'}]],'function metadata follows changed declaration');
delete $changed->{filters}{state}{field};
$changed->{filters}{virtual_filter}={type=>'string'};
my($virtual)=grep {$_->{id} eq 'virtual_filter'} @{Selecto::Domain->project_query_contract($changed)->{filters}};
ok($virtual->{virtual},'undeclared implicit field is virtual metadata');is_deeply($virtual->{comparators},[],'virtual metadata does not infer executable comparisons');
my $calls=0;
{package QueryContractEvil;use overload '""'=>sub{$calls++;'evil'},'bool'=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub STORABLE_freeze{$calls++;die 'callback'}sub TO_JSON{$calls++;die 'callback'}}
for my $bad (sub{$calls++},bless({},'QueryContractEvil'),bless({},'0')) {
 my$c=dclone($original);$c->{audit_extension}=$bad;
 for my $method (qw(project_query_contract validate_query_contract)) {
  my$error=caught(sub {Selecto::Domain->$method($c)});
  is(ref($error)?$error->code:'none','invalid_query_contract',"$method refuses executable/unknown object before copying");
 }
}
is($calls,0,'callbacks, overloads, serialization and subclass hooks are never invoked');
{package QueryContractTied;sub TIEHASH{bless {},shift}sub FIRSTKEY{$calls++;die 'tied hook'}sub FETCH{$calls++;die 'tied hook'}}
tie my %tied,'QueryContractTied';
my$error=caught(sub {Selecto::Domain->project_query_contract(\%tied)});
is(ref($error)?$error->code:'none','invalid_query_contract','tied root refuses before hooks');is($calls,0,'tied callbacks are not invoked');
for my $control (qw(cycle depth breadth bytes alias)) {
 my$c=dclone($original);
 if($control eq 'cycle'){$c->{audit_cycle}=$c}
 elsif($control eq 'depth'){my$n={};$c->{audit_deep}=$n;for(1..70){$n->{next}={};$n=$n->{next}}}
 elsif($control eq 'breadth'){$c->{audit_wide}=[(1)x10001]}
 elsif($control eq 'bytes'){$c->{audit_large}='x'x131073}
 else{my$n=['leaf'];for(1..14){$n=[$n,$n]}$c->{audit_alias}=$n}
 my$e=caught(sub{Selecto::Domain->validate_query_contract($c)});
 is(ref($e)?$e->code:'none','invalid_query_contract',"$control refuses before unbounded projection");
}
my $raw=Selecto::Domain->new(name=>'Simple',table=>'simple',fields=>{id=>'integer'});
my $e=caught(sub{Selecto::Domain->project_query_contract($raw)});
is(ref($e)?$e->code:'none','invalid_query_contract','metadata boundary requires explicit plain contract rather than object hooks');
my $long_id='s'x4096;
my $compact={source=>{columns=>{id=>{type=>'integer'}},fields=>['id']},schemas=>{$long_id=>{fields=>[map{"f$_"}1..40],columns=>{map{("f$_"=>{type=>'integer'})}1..40}}}};
is_deeply(Selecto::Domain::QueryContract->copy_declaration($compact),$compact,'compact prefix amplification input fits raw metadata admission');
for my $method(qw(project_query_contract validate_query_contract)){
 my$error=caught(sub{Selecto::Domain->$method($compact)});
 is(ref($error)?$error->code:'none','invalid_query_contract',"$method refuses compact generated prefix amplification before storage");
}
my$diagnostics={source=>{columns=>{id=>{type=>'integer'}}},functions=>{$long_id=>{kind=>'scalar',sql_name=>'lower',returns=>'string',args=>[map{{}}1..40]}}};
is_deeply(Selecto::Domain::QueryContract->copy_declaration($diagnostics),$diagnostics,'compact repeated diagnostic input fits raw metadata admission');
for my $method(qw(project_query_contract validate_query_contract)){
 my$error=caught(sub{Selecto::Domain->$method($diagnostics)});
 is(ref($error)?$error->code:'none','invalid_query_contract',"$method bounds emitted repeated long diagnostic identifiers");
}
my$copy=Selecto::Domain::QueryContract->copy_declaration($invalid);
is_deeply($copy,$invalid,'shared plain declaration admission preserves semantically invalid policy for other projections');
$copy->{source}{source_table}='changed';
isnt($invalid->{source}{source_table},'changed','shared metadata copy is isolated');
my$copyerror=caught(sub{Selecto::Domain::QueryContract->copy_declaration({evil=>bless({},'QueryContractEvil')})});
is(ref($copyerror)?$copyerror->code:'none','invalid_query_contract','shared admission rejects executable objects');
is($calls,0,'shared admission still invokes no hooks');
done_testing;
