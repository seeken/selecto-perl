use strict;
use warnings;
use Test::More;
use DBI;
use Selecto;
use Selecto::Expression;
use Selecto::Query;

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1, PrintError=>0});
$dbh->do('CREATE TABLE items (id INTEGER, tenant_id INTEGER, label TEXT)');
my $insert = $dbh->prepare('INSERT INTO items VALUES (7,?,?)');
$insert->execute($_,"tenant $_") for 1..1000;
my $adapter = Selecto->adapter(sqlite=>dbh=>$dbh);
my $domain = Selecto::Domain->new(name=>'many tenants',table=>'items',tenant_field=>'tenant_id',
    fields=>{id=>'integer',tenant_id=>'integer',label=>'string'});
my $base = Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
my @engines = map { $base->with_scope(tenant=>$_) } 1..1000;
my $q = Selecto::Query->new->select('id','label')->where(Selecto::Expression->eq('id',7));
my $renders = 0;
my $original = \&Selecto::SQL::_compile_single;
no warnings 'redefine';
local *Selecto::SQL::_compile_single = sub { ++$renders; goto &$original };
my @fingerprints;
for my $tenant (1..1000) {
    my $engine = $engines[$tenant-1];
    push @fingerprints, $engine->read_domain->fingerprint;
    is_deeply($engine->compile($q)->params,[$tenant,7],"tenant $tenant current SQL params");
    is_deeply($engine->all($q)->{rows},[[7,"tenant $tenant"]],"tenant $tenant isolated real rows");
    is($engine->read_domain->fingerprint,$fingerprints[-1],"tenant $tenant public fingerprint unchanged");
}
is($renders,1,'1,000 tenant engines install one render plan');
is(scalar(keys %{ {map { $_=>1 } @fingerprints} }),1000,'public fingerprints retain tenant value coverage');
# The default 256-entry LRU would have evicted the first 744 plans under v2.
for my $tenant (1..1000, 1, 2, 1) {
    is_deeply($engines[$tenant-1]->compile($q)->params,[$tenant,7],"rotation tenant $tenant rebinds");
}
is($renders,1,'full second rotation and A-B-A reuse the one resident entry');
for my $tenant (1,2,1) {
    is_deeply($engines[$tenant-1]->all($q)->{rows},[[7,"tenant $tenant"]],"A-B-A tenant $tenant real read");
}
my $first = $engines[0]->compile($q);
$first->{params}[0] = 999;
$first->{columns}[0] = 'poison';
$first->{sql} = 'poison';
is_deeply($engines[1]->compile($q)->params,[2,7],'poisoned A statement cannot change B params');
is_deeply($engines[0]->all($q)->{rows},[[7,'tenant 1']],'poisoned statement cannot change A read');
is($renders,1,'poisoning does not change plan identity');

# Required structure, not just the optional query shape, distinguishes plans.
my $before = $renders;
my @predicates = (
    Selecto::Expression->gt('id',6),
    Selecto::Expression->lt('id',8),
    Selecto::Expression->in('id',[7]),
    Selecto::Expression->in('id',[7,8]),
    Selecto::Expression->eq('tenant_id',1),
);
for my $predicate (@predicates) {
    my $e = Selecto::Engine->new(domain=>$domain->with_required_predicate($predicate),adapter=>$adapter);
    my $on = $e->compile($q);
    my $off;
    {local $adapter->{compile_cache}=0; $off=$e->compile($q)}
    is_deeply($on->to_hash,$off->to_hash,'distinct required structure matches ordinary compiler');
}
is($renders-$before,9,'four new required structures render; matching tenant-equality shape shares (plus five uncached references)');
# Fresh domain objects with different required values must share too.
$before=$renders;
for my $value (2,3) {
    my $e=Selecto::Engine->new(domain=>$domain->with_required_predicate(
        Selecto::Expression->gt('id',$value)),adapter=>$adapter);
    is_deeply($e->compile($q)->params,[$value,7],'fresh required domain rebinds current value');
}
is($renders,$before,'fresh equivalent required structures share render fingerprint');
done_testing;
