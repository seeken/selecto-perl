use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use Scalar::Util qw(weaken);
use Selecto;
use Selecto::SQL::ReadPlan;
use Selecto::Retarget;
use Selecto::Frozen;

local $ENV{SELECTO_PERL_FREEZE_DOMAINS} = 1;
local $ENV{SELECTO_PERL_PLAN_CACHE} = 1;
plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1,PrintError=>0});
$dbh->do('CREATE TABLE items(id INTEGER, tenant_id INTEGER, label TEXT)');
$dbh->do(q{INSERT INTO items VALUES(1,1,'one'),(2,2,'two')});
sub domain {
    Selecto::Domain->new(name=>'Items',table=>'items', fields=>{id=>'integer',tenant_id=>'integer',label=>'string'},
        associations=>{child=>{table=>'items',fields=>{id=>'integer',label=>'string'},owner_key=>'id',related_key=>'id'}}, @_);
}
sub refused {
    my ($label, $call) = @_;
    ok(!eval {$call->();1}, $label);
    like("$@", qr/frozen|read.only/, "$label explains immutability");
}
{
 package FrozenCopyHook;
 our $CALLS=0;
 sub STORABLE_freeze { ++$CALLS; return ('payload'); }
 sub STORABLE_thaw { $_[0]{restored}=$_[2]; }
}
my $hook_copy=Selecto::Frozen->copy({hook=>bless({}, 'FrozenCopyHook')});
is($FrozenCopyHook::CALLS,1,'mutable metadata preserves its original Storable hook');
is($hook_copy->{hook}{restored},'payload','mutable metadata preserves Storable thaw semantics');
my ($weak_domain, $weak_copy);
{
 my $owned=domain();
 $weak_domain=$owned; weaken($weak_domain);
 my $copy=$owned->as_contract;
 $weak_copy=$copy; weaken($weak_copy);
}
ok(!defined($weak_domain), "freeze metadata does not retain its domain");
ok(!defined($weak_copy), "copy traversal does not retain returned documents");
my $d = domain();
ok($d->is_frozen, 'explicit environment enables domain freezing');
my $id = $d->frozen_identity;
$d->freeze;
is($d->frozen_identity,$id,'repeated freeze preserves identity');
refused('existing field edit',sub {$d->{fields}{id}='string'});
refused('new field edit',sub {$d->{fields}{new}='string'});
refused('root deletion',sub {delete $d->{table}});
refused('hash clear',sub {%{$d->{fields}}=()});
refused('association edit',sub {$d->{associations}{child}{table}='elsewhere'});
is($d->resolve('id')->{type},'integer','failed clear leaves graph intact');
my $contract=$d->as_contract;
$contract->{source}{columns}{id}{type}='string';
is($d->resolve('id')->{type},'integer','document getters are mutable independent copies');
my $mutable=domain(freeze=>0);
my $before=\$mutable->{fields}{id};
$mutable->freeze;
refused('scalar alias acquired before freezing',sub {$$before='string'});
my $derived=$d->with_required_predicate(Selecto::Expression->eq('id',1));
ok($derived->is_frozen,'predicate derivation finalized');
isnt($derived->frozen_identity,$id,'predicate derivation gets fresh identity');
isnt($d->with_tenant_field('tenant_id')->frozen_identity,$id,'tenant derivation gets fresh identity');
isnt(domain()->frozen_identity,$id,'reload gets fresh identity');
my $target=Selecto::Retarget->target($d,'child');
my $retarget=Selecto::Retarget->target_domain($d,$target);
ok($retarget->is_frozen,'retarget result finalized');
isnt($retarget->frozen_identity,$id,'retarget gets fresh identity');
my $raw_bool = 1;
my $bool = bless \$raw_bool, "JSON::PP::Boolean";
my $bool_graph = {flag => $bool};
Selecto::Frozen->freeze($bool_graph);
refused("retained Boolean scalar edit", sub { $$bool = 0 });
my $array=Selecto::Domain->parse({name=>'I',source=>{source_table=>'items',fields=>['id'],columns=>{id=>{type=>'integer'}}},schemas=>{},joins=>{},required_selected=>['id']});
for my $op (
    ['array replacement',sub {$array->{contract}{required_selected}[0]='tenant_id'}],
    ['array push',sub {push @{$array->{contract}{required_selected}},'label'}],
    ['array splice',sub {splice @{$array->{contract}{required_selected}},0,1}],
    ['array resize',sub {$#{$array->{contract}{required_selected}}=3}],
    ['array clear',sub {@{$array->{contract}{required_selected}}=()}],
    ['array pop',sub {pop @{$array->{contract}{required_selected}}}],
    ['array shift',sub {shift @{$array->{contract}{required_selected}}}],
    ['array unshift',sub {unshift @{$array->{contract}{required_selected}},'label'}],
    ['array delete',sub {delete $array->{contract}{required_selected}[0]}],
) {refused(@$op)}
my $a=Selecto->adapter(sqlite=>dbh=>$dbh);
my $e=Selecto::Engine->new(domain=>$d,adapter=>$a);
my $q=$e->query->select('id','label')->where(Selecto::Expression->eq('id',1));
my $qv=$q->version;
ok(!exists $a->{transaction_mode}, "adapter transaction mode starts lazy");
my $s=$e->compile($q);
ok(!exists $a->{transaction_mode}, "key does not autovivify a lazy transaction attribute");
is($a->transaction_mode, "managed", "later writes still obtain the original transaction default");
my $key=Selecto::SQL::ReadPlan::_key($a,$d,$q); # standalone compile has separate authority
like($key,qr/frozen-v1/,'key uses frozen identities');
my $entries=keys %{$a->{_selecto_read_plans}{entries}};
my $unknown=$e->query->select("id");
$unknown->{custom_callback}=sub { die "must not run" };
$unknown->freeze;
ok(!defined(Selecto::SQL::ReadPlan::_key($a,$d,$unknown)),"explicit freeze does not admit custom query records");
is_deeply($e->all($q)->{rows},[[1,'one']],'warm plan executes current query');
is(scalar(keys %{$a->{_selecto_read_plans}{entries}}),$entries,'same query/authority reuses its plan');
my $literal=$q->{predicate}{arguments}[1]{arguments};
refused('nested direct query poke detected',sub {$literal->[0]=2});
refused('direct query root poke detected',sub {$q->{limit_value}=1});
is($q->version,$qv,'rejected edits do not advance version');
is_deeply($e->all($q)->{rows},[[1,'one']],'failed poke cannot change the warmed plan');
refused('authority nested role edit',sub {push @{$e->{write_context}{roles}},'admin'});
my $e2=$e->with_write_context({actor=>'second',roles=>['admin']});
$e2->compile($q);
cmp_ok(scalar(keys %{$a->{_selecto_read_plans}{entries}}),'>',$entries,'public authority transition separates plans');
my $plain=domain(freeze=>0);
my $ea=Selecto::Engine->new(domain=>$plain,adapter=>Selecto->adapter(sqlite=>dbh=>$dbh));
my $pq=$ea->query(freeze=>0)->select('id')->where(Selecto::Expression->eq('id',1));
$ea->compile($pq);
$pq->{predicate}{arguments}[1]{arguments}[0]=2;
is_deeply($ea->all($pq)->{rows},[[2]],'mutable query literal never serves stale plan');
$plain->{required_predicate}=Selecto::Expression->eq('id',1);
is_deeply($ea->all($pq)->{rows},[],'unfrozen domain required-predicate edit invalidates snapshot');
$plain->{required_predicate}=undef;
$plain->{table}='missing_relation';
like($ea->compile($pq)->sql,qr/missing_relation/,'unfrozen root edit invalidates snapshot');
my $opt=$e->query(freeze=>0)->select('id');
$e->compile($opt);$opt->{limit_value}=1;
like($e->compile($opt)->sql,qr/LIMIT 1/,'query opt-out keeps safe snapshot fallback on frozen domain');

# Every public transformation producing query intent passes through _copy.
# The original remains unchanged and the returned query advances its version.
my $base=Selecto::Query->new->select('id');
my $child=Selecto::Query->new->select('id');
my $join={owner_key=>'id',related_key=>'id',type=>'inner'};
my @changes=(
 [select=>sub {$_[0]->select('label')}], [where=>sub {$_[0]->where(Selecto::Expression->eq('id',2))}],
 [filter=>sub {$_[0]->filter(Selecto::Expression->eq('id',2))}],
 [group_by=>sub {$_[0]->group_by('id')}], [group_by_rollup=>sub {$_[0]->group_by_rollup('id')}],
 [order_by=>sub {$_[0]->order_by('id')}], [replace_selections=>sub {$_[0]->replace_selections('label')}],
 [replace_orders=>sub {$_[0]->replace_orders([['id','desc']])}], [retarget=>sub {$_[0]->retarget('child')}],
 (map {my $m=$_;[$m=>sub {$_[0]->$m($child)}]} qw(union union_all intersect except)),
 [with_cte=>sub {$_[0]->with_cte('c',$d,$child)}],
 [with_recursive_cte=>sub {$_[0]->with_recursive_cte('r',$d,$child,$child,join=>$join,recursive_join=>$join,max_depth=>3)}],
 [lateral_join=>sub {$_[0]->lateral_join('l',$d,$child,correlations=>{id=>'id'})}],
 [json_rowset=>sub {$_[0]->json_rowset('payload','j',{value=>'string'})}],
 [with_member=>sub {$_[0]->with_member('m')}], [without_members=>sub {$_[0]->without_members}],
 [with_values=>sub {$_[0]->with_values([[1]],as=>'v',columns=>['id'])}],
 [with_subquery=>sub {$_[0]->with_subquery('s')}],
 [subquery_join=>sub {$_[0]->subquery_join('s',$d,$child,on=>[{left=>'id',right=>'id'}])}],
 [with_lateral=>sub {$_[0]->with_lateral('l')}],
 [function_lateral=>sub {$_[0]->function_lateral('f',[1],as=>'f')}],
 [array_rowset=>sub {$_[0]->array_rowset('tags','ar')}],
 [with_applied_query_library=>sub {$_[0]->with_applied_query_library({segments=>['x']})}],
 [count_query=>sub {$_[0]->count_query('id')}], [limit=>sub {$_[0]->limit(1)}], [offset=>sub {$_[0]->offset(1)}],
 [use_timezone=>sub {$_[0]->use_timezone('UTC')}], [for_share=>sub {$_[0]->for_share}],
);
for my $change (@changes) {
 my($name,$call)=@$change;
 my $next=$call->($base);
 cmp_ok($next->version,'>',$base->version,"$name advances returned query version");
 isnt($next->identity,$base->identity,"$name returns distinct query identity");
}
my $owned=$e->query->select('id');
my $joined=$owned->join('child');
cmp_ok($joined->version,'>',$owned->version,'declared join advances version');
my $next=$q->limit(1);
cmp_ok($next->version,'>',$q->version,'fluent copy from sealed query advances version');
is($q->version,$qv,'fluent transformation preserves original version');

# Tightening limits uses a fresh immutable budget identity.
my $tight = $e->with_limits(Selecto::Limits->new(max_generated_parameters=>1));
$tight->compile($q);
ok(Selecto::Frozen->identity($tight->limits), "with_limits seals its new budget");

# No domain walk, query walk, eligibility resolution or JSON hash is needed
# for a warmed integer key. Per-request compiler obligations remain separate.
$e->compile($q);
{
 no warnings 'redefine';
 local *Selecto::SQL::ReadPlan::_plain=sub {die "unexpected traversal\n"};
 local *Selecto::SQL::ReadPlan::_field=sub {die "unexpected eligibility replay\n"};
 is_deeply($e->all($q)->{rows},[[1,'one']],'warm key avoids deep traversal while execution/governance still runs');
 is_deeply($tight->all($q)->{rows},[[1,'one']],'tightened budget also has a warm integer key');
}
done_testing;
