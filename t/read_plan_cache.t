use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use Selecto;
use Selecto::SQL::ReadPlan;
use Selecto::Limits;
use Selecto::API::EngineHandler;
use Selecto::API::Explorer;
use JSON::PP;
use lib 't/lib';
use TestSelecto;

local $ENV{SELECTO_PERL_PLAN_CACHE} = 1;
my $json = JSON::PP->new->canonical->allow_nonref;
plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1, PrintError=>0});
$dbh->do('CREATE TABLE items (id INTEGER, tenant_id INTEGER, name TEXT)');
$dbh->do(q{INSERT INTO items VALUES (1,1,'one'),(2,2,'two'),(3,1,'three')});
my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
sub domain {
    return Selecto::Domain->new(name=>'Items', table=>'items',
        fields=>{id=>'integer', tenant_id=>'integer', name=>'string'}, @_);
}
my $domain = domain();
sub engine { Selecto::Engine->new(domain=>$_[0] // $domain, adapter=>$_[1] // $adapter, @_[2..$#_]) }
my $engine = engine();
sub observation {
    my ($engine,$query,$execute) = @_;
    my $result = eval {
        my $statement = $engine->compile($query);
        +{statement=>$statement->to_hash, relations=>$statement->relations,
            ($execute ? (rows=>$engine->all($query)->{rows}) : ())};
    };
    if (my $error = $@) {
        return $json->encode({error=>ref($error) eq 'Selecto::Error' ? $error->to_hash : "$error"});
    }
    return $json->encode($result);
}
sub parity {
    my ($label,$engine,$query,$execute) = @_;
    my $warm = observation($engine,$query,$execute);
    local $ENV{SELECTO_PERL_PLAN_CACHE} = 0;
    is(observation($engine,$query,$execute),$warm,$label);
    return $warm;
}
my $query = $engine->query->select('id','name')->where(Selecto::Expression->eq('id',1));
parity('cold plan agrees',$engine,$query,1);
parity('warm plan agrees',$engine,$query,1);
is_deeply($engine->all($query)->{rows},[[1,'one']],'warmed query returns actual synthetic row');
ok(keys(%{$adapter->{_selecto_read_plans}{entries}}), 'plan actually warmed');
my $entry_count = keys %{$adapter->{_selecto_read_plans}{entries}};
parity('new parameter reuses SQL with fresh binds',$engine,
    $query->where(Selecto::Expression->eq('id',2)),1);
is(scalar keys %{$adapter->{_selecto_read_plans}{entries}},$entry_count,'parameter values are slots, not cache identities');
for my $pair (
    ['selection', $query->select('name')],
    ['alias', $query->select(Selecto::Expression->field('id')->as('number'))],
    ['ordering', $query->order_by('id','desc')],
    ['limit', $query->limit(1)],
    ['offset', $query->offset(1)],
    ['filter', $query->where(Selecto::Expression->gt('id',1))],
    ['duplicate output refusal', $query->select('id','id')],
    ['unknown field refusal', $query->select('missing')],
    ['computed expression fallback', $query->select(Selecto::Expression->count)],
) { parity($pair->[0],$engine,$pair->[1],1) }
# Direct edits, not only immutable builders, must invalidate plans.
$engine->compile($query);
$query->{predicate}{arguments}[1]{arguments}[0] = 3;
parity('in-place value change',$engine,$query,1);
$query->{selections}[0]{alias_name} = 'new_id';
parity('in-place selection alias change',$engine,$query,1);
$query->{orders} = [[Selecto::Expression->field('id'),'desc']];
parity('in-place order change',$engine,$query,1);

my $flat = Selecto::Query->new->select('id','name');
my $tenant_domain = domain(tenant_field=>'tenant_id');
my @tenants = map { engine($tenant_domain,$adapter,scope=>{tenant=>$_}) } (1,2);
for (1..3) {
    parity('interleaved tenant one on shared adapter',$tenants[0],$flat,1);
    parity('interleaved tenant two on shared adapter',$tenants[1],$flat,1);
}
like(call_parity('required filter excludes warmed tenant',sub {
    $tenants[0]->require_tenant_filter('tenant_id',2)->compile($flat)->to_hash
}),qr/tenant_mismatch|tenant_scope_mismatch/,'tenant disagreement still refuses');
my $row_scoped=$engine->require_tenant_filter('id',1);
parity('required tenant filter one',$row_scoped,$flat,1);
my $other_scoped=$engine->require_tenant_filter('id',2);
parity('required tenant filter two',$other_scoped,$flat,1);
my $needed=engine(domain(tenant_required=>1),$adapter);
like(parity('missing required read scope after warm',$needed,$flat,0),qr/tenant_scope_missing/,'required scope is still checked');

my @actors = map { engine($domain,$adapter,write_context=>{actor=>$_,roles=>[$_]}) } ('reader','admin');
parity('actor one',$actors[0],$flat,1);
parity('actor two',$actors[1],$flat,1);
my $required = engine($domain->with_required_predicate(Selecto::Expression->eq('tenant_id',1)));
parity('required predicate',$required,$flat,1);
parity('required predicate warm',$required,$flat,1);
$required->{domain}{required_predicate} = Selecto::Expression->eq('tenant_id',2);
parity('required predicate mutation',$required,$flat,1);
my $reloaded = engine(domain(name=>'Reloaded',required_predicate=>Selecto::Expression->eq('id',2)));
parity('reloaded domain policy',$reloaded,$flat,1);
my $strict = engine($domain,$adapter,mode=>'strict');
parity('strict policy refusal',$strict,$flat,0);
parity('strict bound query',$strict,$strict->query->select('id'),1);
my $tight = $engine->with_limits(Selecto::Limits->new(max_generated_parameters=>1));
my $too_many = Selecto::Query->new->select('id')->where(Selecto::Expression->all(
    Selecto::Expression->gt('id',0),Selecto::Expression->lt('id',9)));
$engine->compile($too_many);
parity('tightened limits after warm',$tight,$too_many,0);
my $prefix = engine()->with_read_context({prefix=>'main'});
parity('prefix identity',$prefix,$flat,1);

my $pg = Selecto->adapter(postgresql=>dbh=>TestSelecto::DBH->new);
my $pg_engine = engine($domain,$pg);
parity('PostgreSQL dialect',$pg_engine,$flat,0);
parity('SQLite after PostgreSQL',$engine,$flat,1);
$pg->{canonical_sql} = 1;
parity('SQL canonical formatting bypass',$pg_engine,$flat,0);
$pg->{canonical_sql} = 0;
$pg->{dbh}{pg_server_version} = 180006;
parity('server capability change',$pg_engine,$flat,0);

# Warm through the public canonical handler, then replace exposure policy.
my $public = Selecto::Domain->parse({schema_version=>1,name=>'Public items',
    source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id tenant_id name)],
        columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},
    schemas=>{},joins=>{}});
my $public_engine=engine($public);
my $handler=Selecto::API::EngineHandler->new;
sub call_result {
    my ($call)=@_;
    my $result=eval {$call->()};
    if(my $error=$@) {return $json->encode({error=>ref($error) eq 'Selecto::Error' ? $error->to_hash : "$error"})}
    return $json->encode($result);
}
sub call_parity {
    my ($label,$call)=@_;
    my $on=call_result($call);
    local $ENV{SELECTO_PERL_PLAN_CACHE}=0;
    is(call_result($call),$on,$label);
    return $on;
}
my $public_call=sub {$handler->query($public_engine,{select=>['id','name'],order_by=>[{field=>'id'}]})};
call_parity('public canonical warm',$public_call) for 1..2;
$public->{contract}{source}{columns}{name}{hidden}=1;
like(call_parity('hidden-field policy after warm',$public_call),qr/hidden_field/,'hidden field still refuses');
delete $public->{contract}{source}{columns}{name}{hidden};
$public->{contract}{redact_fields}=['name'];
like(call_parity('redacted-field policy after warm',$public_call),qr/hidden_field/,'redacted field still refuses');
$public->{contract}{redact_fields}=[];
call_parity('policy restored',$public_call);
call_parity('canonical refusal after warm',sub {$handler->query($public_engine,{select=>[{aggregate=>'count'}],group_by=>['name']})});
my $explorer=Selecto::API::Explorer->new(id=>'plan',publication=>'plan',clock=>'2026-11-15T00:00:00Z',base_path=>'/explorer');
my $features=$json->decode($explorer->request($public_engine,
    {method=>'GET',path=>'/explorer/explorer-features'})->{body});
my $request={method=>'POST',path=>'/explorer/explorer-query',content_type=>'application/json',body=>{
    format=>'selecto.explorer-query',format_version=>1,
    domain=>{fingerprint=>$features->{domain}{fingerprint}},features=>{revision=>$features->{revision}},
    request_id=>'plan',query=>{select=>['id','name'],limit=>2}}};
my $explorer_call=sub {$explorer->request($public_engine,$request)};
call_parity('Explorer read after canonical warm',$explorer_call) for 1..2;
is($explorer_call->()->{status},200,'Explorer warm request actually reads rows');
$request->{body}{query}{select}=['missing'];
call_parity('Explorer field refusal after warm',$explorer_call);


# LRU eviction must keep a recently used entry instead of acting as FIFO.
my $lru_adapter=Selecto->adapter(sqlite=>dbh=>$dbh);
my $lru_engine=engine($domain,$lru_adapter);
for(0..63) {$lru_engine->compile($flat->limit($_))}
my %before=%{$lru_adapter->{_selecto_read_plans}{entries}};
$lru_engine->compile($flat->limit(0));
my ($newest)=sort {$before{$b}{used}<=>$before{$a}{used}} keys %before;
$lru_engine->compile($flat->limit(64));
ok(exists($lru_adapter->{_selecto_read_plans}{entries}{$newest}),'recently touched LRU entry retained');
is(scalar(keys %{$lru_adapter->{_selecto_read_plans}{entries}}),64,'LRU evicts exactly one entry at capacity');

# A returned Statement must never become mutable cache state.
my $s = $engine->compile($flat);
$s->{sql} = 'bad'; $s->{columns}[0] = 'bad'; $s->{_selecto_relations}[0] = 'bad';
parity('returned statement mutation is isolated',$engine,$flat,1);
for (0..85) { $engine->compile($flat->limit($_)) }
my $cache = $adapter->{_selecto_read_plans};
ok(keys(%{$cache->{entries}}) <= Selecto::SQL::ReadPlan::MAX_ENTRIES(),'entry count bound');
ok($cache->{bytes} <= Selecto::SQL::ReadPlan::MAX_BYTES(),'payload byte bound');
parity('evicted plan recompiles',$engine,$flat,1);
my $ticks = $cache->{tick};
{
    local $ENV{SELECTO_PERL_PLAN_CACHE} = 0;
    $engine->compile($flat);
}
is($cache->{tick},$ticks,'off switch bypasses warmed cache');
$adapter->{plan_cache} = 0;
$engine->compile($flat);
is($cache->{tick},$ticks,'adapter switch bypasses warmed cache');
$adapter->{plan_cache} = 1;

# Reproducible random composed-query parity, executed in SQLite memory.
srand(417);
for my $i (1..100) {
    my @fields = rand() < .5 ? ('id','name') : ('tenant_id','name');
    my $q = $engine->query->select(@fields)->where(
        Selecto::Expression->gt('id', int(rand(4))));
    $q=$q->order_by('id',rand()<.5?'asc':'desc') if rand()<.7;
    $q=$q->limit(int(rand(4))) if rand()<.5;
    parity("random query $i",$engine,$q,1);
    parity("random warmed query $i",$engine,$q,1);
}
done_testing;
