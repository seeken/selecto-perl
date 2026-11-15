use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP;
use Selecto;
use Selecto::Write;
use lib 't/lib';
use TestPostgreSQL;
plan skip_all=>'PostgreSQL not configured' unless TestPostgreSQL->configured;
my $dbh=TestPostgreSQL->connect;
my ($port,$marker)=$dbh->selectrow_array(q{SELECT current_setting('port'),current_setting('selecto.perf_storage',true)});
# The test itself uses temporary synthetic tables; this task runs on RAM only.
local $ENV{SELECTO_PERL_PLAN_CACHE}=1;
$dbh->do('CREATE TEMP TABLE plan_session (id INTEGER, tenant_id INTEGER, name TEXT)');
$dbh->do(q{INSERT INTO plan_session VALUES(1,1,'one'),(2,2,'two')});
my $domain=Selecto::Domain->new(name=>'Session plans',table=>'plan_session',
    fields=>{id=>'integer',tenant_id=>'integer',name=>'string'},tenant_field=>'tenant_id');
my $adapter=Selecto->adapter(postgresql=>dbh=>$dbh,canonical_values=>1);
my $e=Selecto::Engine->new(domain=>$domain,adapter=>$adapter,scope=>{tenant=>1});
my $q=$e->query->select('id','name');
my $json=JSON::PP->new->canonical->allow_nonref;
sub result {
 my ($call)=@_;
 my $result=eval {$call->()};
 return $json->encode({error=>$@->to_hash}) if ref($@) eq 'Selecto::Error';
 die $@ if $@;
 return $json->encode($result);
}
sub parity {
 my ($label,$call)=@_;
 my $on=result($call);
 local $ENV{SELECTO_PERL_PLAN_CACHE}=0;
 is(result($call),$on,$label);
 return $on;
}
parity('warm managed read',sub {$e->all($q)->{rows}}) for 1..2;
ok(keys %{$adapter->{_selecto_read_plans}{entries}},'live plan actually warmed');
$dbh->do(q{SET client_encoding='LATIN1'});
like(parity('R65 encoding checked after warm',sub {$e->all($q)->{rows}}),qr/client_encoding/,'encoding refusal preserved');
$dbh->do(q{SET client_encoding='UTF8'});
$dbh->begin_work;
parity('R66 host transaction after warm',sub {$e->all($q)->{rows}});
ok(!$dbh->{AutoCommit},'host transaction still open');
$dbh->rollback;
for my $mode (0,1) {
 parity("canonical values mode $mode after warm",sub {$e->all($q,canonical_values=>$mode)->{rows}});
}
parity('export mode after warm',sub {$e->all($q,export_scalars=>1)->{rows}});
parity('TB007 unchanged after read warm',sub {$e->execute_write(Selecto::Write::Command->new(
 operation=>'update',relation=>'plan_session',assignments=>{name=>'x'},predicate=>Selecto::Expression->eq('id',1)))});
SKIP: {
 skip 'driver has no pipeline capability API',3 unless $dbh->can('pg_can_pipeline');
 $dbh->{pg_pipeline}=0;
 parity('pipeline disabled after warm',sub {$e->all($q)->{rows}});
 $dbh->{pg_pipeline}=1;
 ok($adapter->_pg_pipeline_available,'pipeline capability enabled');
 parity('pipeline enabled after warm',sub {$e->all($q)->{rows}});
}
$dbh->disconnect;
done_testing;
