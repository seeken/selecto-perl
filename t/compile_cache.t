use strict;
use warnings;
use Test::More;
use DBI;
use Selecto;
use Selecto::Expression;
use Selecto::Query;
use Selecto::Limits;

my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
$dbh->do('CREATE TABLE items (id INTEGER, tenant_id INTEGER, label TEXT)');
$dbh->do(q{INSERT INTO items VALUES (7,11,'a'),(7,22,'b'),(9,11,'c')});
my $adapter=Selecto->adapter(sqlite=>dbh=>$dbh);
my $domain=Selecto::Domain->new(name=>'cache',table=>'items',tenant_field=>'tenant_id',
    fields=>{id=>'integer',tenant_id=>'integer',label=>'string'});
my $base=Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
my $engine=$base->with_scope(tenant=>11);
my $b=$base->with_scope(tenant=>22);
my $q=Selecto::Query->new->select('id','label')->where(Selecto::Expression->eq('id',7));
my $renders=0;
my $original=\&Selecto::SQL::_compile_single;
no warnings 'redefine';
local *Selecto::SQL::_compile_single=sub { ++$renders; goto &$original };

sub parity {
    my ($e,$query,$label)=@_;
    my $on=$e->compile($query);
    my $off;
    { local $adapter->{compile_cache}=0; $off=$e->compile($query) }
    is_deeply($on->to_hash,$off->to_hash,"$label: SQL/columns/values parity");
    is_deeply($on->relations,$off->relations,"$label: relation evidence parity");
    return $on;
}
my $first=$engine->compile($q);
my $before=$renders;
is_deeply($engine->compile($q)->to_hash,$first->to_hash,'warmed output');
is($renders,$before,'second compile hits');
is_deeply($first->params,[11,7],'tenant A parameters');
is_deeply($b->compile($q)->params,[22,7],'tenant B gets its current parameters');
is_deeply($engine->all($q)->{rows},[[7,'a']],'tenant A real read');
is_deeply($b->all($q)->{rows},[[7,'b']],'tenant B real read after A');
parity($b,$q,'tenant B');

$q=$q->clear_where->where(Selecto::Expression->eq('id',9));
$before=$renders;
is_deeply($engine->compile($q)->params,[11,9],'new query binds current value');
is($renders,$before,'changed value shares the structural plan');
parity($engine,$q,'changed bind');
$q=$q->clear_where->where(Selecto::Expression->gt('id',7));
parity($engine,$q,'changed operator');
$q=$q->replace_selections(Selecto::Expression->field('id')->as('chosen'),'label');
parity($engine,$q,'new alias');
$q=$q->limit(4)->offset(2)->order_by('id');
parity($engine,$q,'pagination and ordering');
for my $values ([7],[7,9],[9,7]) {
    my $in=Selecto::Query->new->select('id')->where(Selecto::Expression->in('id',$values));
    is_deeply(parity($engine,$in,'IN arity/current values')->params,[11,@$values],'IN parameters');
}
my $derived=$domain->with_required_predicate(Selecto::Expression->gt('id',2));
my $required=Selecto::Engine->new(domain=>$derived,adapter=>$adapter);
parity($required,$q,'new required predicate');
isnt($derived->fingerprint,$domain->fingerprint,'with_required_predicate refreshes fingerprint');
for my $value (3,4) {
    my $filter=$base->require_tenant_filter('id',$value);
    my $fq=Selecto::Query->new->select('id');
    $filter->compile($fq) for 1..2;
    is_deeply(parity($filter,$fq,'required filter')->params,[$value],'current required filter');
}
my $other=$domain->with_tenant_field('id');
isnt($other->fingerprint,$domain->fingerprint,'with_tenant_field refreshes fingerprint');
parity(Selecto::Engine->new(domain=>$other,adapter=>$adapter)->with_scope(tenant=>7),
    Selecto::Query->new->select('label'),'new tenant field');
isnt($engine->read_domain->fingerprint,$domain->fingerprint,'scoped read domain refreshes fingerprint');

# Limits, QueryBinding and policy remain live; a hit is never admission.
my $limited=Selecto::Engine->new(domain=>$domain,adapter=>$adapter,
    limits=>Selecto::Limits->new(max_value_bytes=>8));
my $value=Selecto::Query->new->select('id')->where(Selecto::Expression->eq('id','ok'));
$limited->compile($value) for 1..2;
my $ok=eval { $limited->compile($value->clear_where->where(Selecto::Expression->eq('id','x' x 20))); 1 };
ok(!$ok,'large current bind refused after a hit');
is(ref($@),'Selecto::Error','parameter refusal remains typed');
$ok=eval { $limited->compile(Selecto::Query->new->select('missing')); 1 };
ok(!$ok,'unknown field refused');
my $locked=Selecto::Query->new->select('id')->_copy(row_lock=>'update');
$ok=eval { $base->compile($locked); 1 };
ok(!$ok,'update lock requires live session');
my $hand=Selecto::Statement->new(sql=>'SELECT 1',columns=>['one']);
ok(!defined($hand->relations),'hand SQL has no generated relation evidence');
is_deeply($adapter->execute_query($hand)->{rows},[[1]],'hand SQL follows normal execution');

my $wide=Selecto::Domain->new(name=>'wide',table=>'items',fields=>{id=>'integer'},
    associations=>{map { ('r'.$_=>{table=>'related'.$_,fields=>{id=>'integer'},owner_key=>'id',related_key=>'id'}) } 1..80});
my $we=Selecto::Engine->new(domain=>$wide,adapter=>$adapter);
my $wq=Selecto::Query->new->select('id');
$we->compile($wq) for 1..2;
my $tight=Selecto::Engine->new(domain=>$wide,adapter=>$adapter,
    limits=>Selecto::Limits->new(max_expression_nodes=>50));
my @errors;
for my $enabled (1,0) {
    local $adapter->{compile_cache}=$enabled;
    eval { $tight->compile($wq) };
    push @errors,ref($@) eq 'Selecto::Error' ? $@->to_hash : 'not refused';
}
is_deeply($errors[0],$errors[1],'source proof replays identical budget refusal/details');
ok(ref($errors[0]) eq 'HASH','cached proof still admits current limits');
my $text=Selecto::Query->new->select('id')->where(Selecto::Expression->all(
    Selecto::Expression->eq('id',1),Selecto::Expression->starts_with('label','needle')));
like(parity($base,$text,'unsupported child fallback')->sql,qr/SUBSTR/,'unsupported child never dropped');

my $joined=Selecto::Domain->new(name=>'joined',table=>'items',fields=>{id=>'integer'},
    associations=>{other=>{table=>'labels',fields=>{id=>'integer',label=>'string'},owner_key=>'id',related_key=>'id'}});
my $je=Selecto::Engine->new(domain=>$joined,adapter=>$adapter);
my $jq=Selecto::Query->new->select('id','other.label');
$je->compile($jq); $before=$renders;
my $js=$je->compile($jq);
is($renders,$before,'joined plan hits');
is_deeply($js->relations,['"items"','"labels"'],'hit retains root and joined physical relations');
parity($je,$jq,'joined evidence');

my $small=Selecto->adapter(sqlite=>dbh=>$dbh,compile_cache_size=>2);
my $e=Selecto::Engine->new(domain=>$domain,adapter=>$small);
my @queries=map { Selecto::Query->new->select('id')->limit($_) } 1..3;
$e->compile($_) for @queries[0,1];
$e->compile($queries[0]);
$e->compile($queries[2]);
$before=$renders;
$e->compile($queries[0]);
is($renders,$before,'most recent LRU entry survives');
$e->compile($queries[1]);
is($renders,$before+1,'oldest LRU entry evicted');
my $disabled=Selecto::Engine->new(domain=>$domain,adapter=>$small,compile_cache=>0);
$before=$renders; $disabled->compile($queries[0]) for 1..2;
is($renders,$before+2,'engine opt-out always renders');
{ local $small->{compile_cache}=0;
  $before=$renders; $e->compile($queries[0]) for 1..2;
  is($renders,$before+2,'adapter opt-out always renders'); }
my $safe=$e->compile($queries[0]);
$safe->{params}=[999]; $safe->{columns}[0]='poison'; $safe->{sql}='poison';
isnt($e->compile($queries[0])->sql,'poison','statement SQL cannot poison plan');
is_deeply($e->compile($queries[0])->columns,['id'],'statement columns cannot poison plan');

my $unicode=Selecto::Domain->new(name=>"wide \x{96ea}",table=>'items',fields=>{id=>'integer'});
my $uq=Selecto::Query->new->select(Selecto::Expression->field('id')->as("alias |\x{96ea}:"));
parity(Selecto::Engine->new(domain=>$unicode,adapter=>$adapter),$uq,'Unicode/delimiters');
my $owned=$engine->query->select('label')->where(Selecto::Expression->eq('id',7));
is_deeply($engine->all($owned)->{rows},[['a']],'owned query warms under A');
is_deeply($b->all($owned)->{rows},[['b']],'owned sibling query rebinds B');
my $fresh=Selecto::Engine->new(domain=>Selecto::Domain->new(name=>'cache',table=>'items',tenant_field=>'tenant_id',
    fields=>{id=>'integer',tenant_id=>'integer',label=>'string'}),adapter=>$adapter)->with_scope(tenant=>22);
my $fresh_query=Selecto::Query->new->select('label')->where(Selecto::Expression->eq('id',7));
$b->compile($fresh_query); $before=$renders;
is_deeply($fresh->compile($fresh_query)->params,[22,7],'fresh equivalent domain has current binds');
is($renders,$before,'equivalent domain fingerprint shares a plan');

my $policy_raw={schema_version=>1,name=>'policy',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id tenant_id label)],
    columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer'},label=>{type=>'string'}},associations=>{}},
    required_selected=>['tenant_id'],required_order_by=>[['id','asc']]};
for my $selected ('tenant_id','id') {
    my $pd=Selecto::Domain->parse({%$policy_raw,required_selected=>[$selected]});
    my $pe=Selecto::Engine->new(domain=>$pd,adapter=>$adapter);
    is_deeply(parity($pe,Selecto::Query->new->select('label'),'required policy')->columns,
        [$selected,'label'],'required selection applied');
}
my $dynamic_raw={schema_version=>1,name=>'dynamic',source=>{source_table=>'items',primary_key=>'id',fields=>['id'],
    columns=>{id=>{type=>'integer'}},associations=>{}},query_members=>{ctes=>{dynamic=>{query=>{kind=>'declared_callback'}}}}};
my ($builder_value,$calls)=(1,0);
my $dynamic=Selecto::Engine->new(domain=>Selecto::Domain->parse($dynamic_raw),adapter=>$adapter,
    member_builders=>{'ctes:dynamic'=>sub { ++$calls; $_[0]->query->select('id')->where(Selecto::Expression->eq('id',$builder_value)) }});
my $dq=$dynamic->query->with_cte('dynamic')->select('id');
$dynamic->compile($dq); $builder_value=2;
is_deeply($dynamic->compile($dq)->params,[2],'builder current state bound');
is($calls,2,'builder runs on every call');
parity($dynamic,$dq,'callback source');

# Unexpected compiler binds must never produce a reusable candidate plan.
{
    my $guard=Selecto->adapter(sqlite=>dbh=>$dbh);
    my $ge=Selecto::Engine->new(domain=>$domain,adapter=>$guard);
    my $gq=Selecto::Query->new->select('id')->where(Selecto::Expression->eq('id',7));
    my $attempts=0;
    local *Selecto::SQL::_compile_single=sub {
        ++$attempts;
        my $s=$original->(@_);
        if ($s->params->[0] =~ /\A\0selecto bind:/) {
            return Selecto::Statement->new(sql=>'poison',columns=>['poison'],params=>['unexpected']);
        }
        return $s;
    };
    is_deeply($ge->compile($gq)->params,[7],'unexpected speculative bind falls back to current values');
    isnt($ge->compile($gq)->sql,'poison','unexpected bind never installs a plan');
    is($attempts,4,'both attempts render candidate and ordinary fallback');
}
my $opaque=Selecto::Query->new->select('id')->where(Selecto::Expression->eq('label',"\0selecto bind:999\0"));
is_deeply(parity($base,$opaque,'marker-like application value')->params,["\0selecto bind:999\0"],
    'application values cannot become slot indexes');

SKIP: {
    pipe(my $read,my $write) or skip 'pipe unavailable',2;
    my $pid=fork(); skip 'fork unavailable',2 unless defined $pid;
    if (!$pid) {
        close $read; my $start=$renders;
        my $s=$e->compile($queries[0]);
        print {$write} ($renders-$start),"\n",$s->sql,"\n";
        close $write; require POSIX; POSIX::_exit(0);
    }
    close $write; my @lines=<$read>; close $read; waitpid($pid,0);
    is($lines[0],"1\n",'child discards inherited plans');
    like($lines[1] // '',qr/SELECT/,'child rebuilds without DBI execution');
}
done_testing;
