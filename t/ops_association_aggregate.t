use 5.034;
use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use DBI;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::SQLite;
use Selecto::PostgreSQL;
use Selecto::DuckDB;
use lib 't/lib';
use TestPostgreSQL;

sub contract {
 my %columns=(map {$_=>{type=>'integer'}} qw(id tenant_id parent_id alt_parent_id units));
 $columns{type}={type=>'string'};
 $columns{customer_price}={type=>'decimal'};
 $columns{carrier_pay}={type=>'decimal'};
 my %associations=(charges=>{queryable=>'charges',owner_key=>'id',related_key=>'load_id',cardinality=>'many'},
 leg_charges=>{queryable=>'charges',owner_key=>'id',related_key=>'associated_load',cardinality=>'many'});
 for my $target (qw(load_id associated_load)) {
  $associations{"bundle_$target"}={queryable=>'charges',owner_key=>'id',related_key=>$target,cardinality=>'many',
   through=>{table=>'loads',owner_key=>'parent_id',related_key=>'id',source_scope_key=>'tenant_id',through_scope_key=>'tenant_id',target_scope_key=>'tenant_id'}};
 }
 my $rev=['and', [['in','transaction_type.type',['D','B']], ['not',['in','trx_typ',[11000,20000]]]]];
 $columns{charge_revenue}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>'charges',function=>'sum',field=>'alt_amt',where=>$rev,default=>0}};
 $columns{charge_cost}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>'charges',function=>'sum',field=>'amt',where=>['and',[['in','transaction_type.type',['C','B']],['not',['in','trx_typ',[11000,20000]]]]],default=>0}};
 $columns{charge_count}={type=>'integer',computed=>{kind=>'association_aggregate',association=>'charges',function=>'count',field=>'id'}};
 $columns{charge_count_zero}={type=>'integer',computed=>{kind=>'association_aggregate',association=>'charges',function=>'count',field=>'id',default=>0}};
 for my $fn(qw(min max)) {$columns{"charge_$fn"}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>'charges',function=>$fn,field=>'amt'}}}
 $columns{total_revenue}={type=>'decimal',computed=>{kind=>'expression',expression=>['add',['coalesce',['field','customer_price'],['literal',0]],['field','charge_revenue']]}};
 $columns{total_cost}={type=>'decimal',computed=>{kind=>'expression',expression=>['add',['coalesce',['field','carrier_pay'],['literal',0]],['field','charge_cost']]}};
 $columns{margin}={type=>'decimal',computed=>{kind=>'expression',expression=>['subtract',['field','total_revenue'],['field','total_cost']]}};
 for my $side(qw(revenue pay)) {
  my @parts;
  for my $assoc(sort keys %associations) {
   my $id="lhf_${side}_$assoc";
   my @filters=($side eq 'revenue' ? ['in','trx_typ',[101,306]] : ['lt','trx_typ',1000]);
   push @filters,['is_null','associated_load'] if $assoc eq 'charges' || $assoc =~ /_load_id$/;
   $columns{$id}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>$assoc,function=>'sum',field=>$side eq 'revenue'?'alt_amt':'amt',where=>['and',\@filters],default=>0,
    ($assoc =~ /^bundle_/ ? (through_owner_keys=>[qw(parent_id alt_parent_id)],through_exclude_owner_field=>'id') : ())}};
   my $part=['field',$id];
   $part=['case',[['eq','type','X'],$part],['else',['literal',0]]] if $assoc ne 'charges' && $assoc ne 'leg_charges';
   push @parts,$part;
  }
  my $expr=shift @parts; $expr=['add',$expr,$_] for @parts;
  $columns{"lhf_$side"}={type=>'decimal',computed=>{kind=>'expression',expression=>$expr}};
 }
 return {schema_version=>1,name=>'Synthetic loads',source=>{source_table=>'loads',primary_key=>'id',tenant_field=>'tenant_id',fields=>[sort keys %columns],columns=>\%columns,associations=>\%associations},
 schemas=>{charges=>{source_table=>'charges',primary_key=>'id',tenant_field=>'tenant_id',fields=>[qw(id tenant_id load_id associated_load trx_typ alt_amt amt)],columns=>{(map {$_=>{type=>'integer'}} qw(id tenant_id load_id associated_load trx_typ)),alt_amt=>{type=>'decimal'},amt=>{type=>'decimal'}},associations=>{transaction_type=>{queryable=>'transaction_types',owner_key=>'trx_typ',related_key=>'id'}}},
 transaction_types=>{source_table=>'transaction_types',primary_key=>'id',tenant_field=>'tenant_id',fields=>[qw(id tenant_id type)],columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer'},type=>{type=>'string'}},associations=>{}}},
 joins=>{(map {$_=>{type=>'left',joins=>{transaction_type=>{type=>'left'}}}} keys %associations)}};
}
sub numbers {
 my ($x)=@_;
 return [map {numbers($_)} @$x] if ref($x) eq 'ARRAY';
 return defined($x) ? 0+$x : undef;
}
my @backends=(['sqlite',sub{DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0})}]);
push @backends,['duckdb',sub{DBI->connect('dbi:DuckDB:dbname=:memory:','','',{RaiseError=>1,PrintError=>0})}] if eval{require DBD::DuckDB;1};
push @backends,['postgresql',sub{TestPostgreSQL->connect}] if TestPostgreSQL->configured;
for my $backend(@backends) {
 subtest $backend->[0]=>sub {
 my $dbh=$backend->[1]->();
 $dbh->do($_) for ('CREATE TEMP TABLE loads(id INTEGER,tenant_id INTEGER,parent_id INTEGER,alt_parent_id INTEGER,units INTEGER,type TEXT,customer_price DECIMAL(12,2),carrier_pay DECIMAL(12,2))',
 'CREATE TEMP TABLE charges(id INTEGER,tenant_id INTEGER,load_id INTEGER,associated_load INTEGER,trx_typ INTEGER,alt_amt DECIMAL(12,2),amt DECIMAL(12,2))',
 'CREATE TEMP TABLE transaction_types(id INTEGER,tenant_id INTEGER,type TEXT)',
 q{INSERT INTO transaction_types VALUES(101,7,'D'),(306,7,'B'),(501,7,'C'),(11000,7,'D'),(20000,7,'C'),(101,8,'C')},
 q{INSERT INTO loads VALUES(1,7,NULL,NULL,2,'S',100,50),(2,7,1,NULL,1,'S',NULL,0),(3,7,3,3,0,'X',NULL,NULL),(4,7,3,3,1,'S',NULL,NULL),(5,7,NULL,3,3,'S',NULL,NULL),(6,7,NULL,NULL,0,'S',NULL,NULL),(1,8,NULL,NULL,1,'S',999,999)},
 q{INSERT INTO charges VALUES(1,7,1,NULL,101,10,5),(2,7,1,NULL,306,20,8),(3,7,1,2,101,80,60),(4,7,1,2,306,15,10),(5,7,1,NULL,11000,999,999),(6,7,1,NULL,20000,999,999),(7,7,1,NULL,501,0,7),(8,7,4,NULL,101,40,30),(9,7,4,5,101,60,45),(10,7,5,NULL,306,12,9),(11,8,1,NULL,101,5000,5000)});
 my $domain=Selecto::Domain->parse(contract(),strict=>1)->with_required_predicate(Selecto::Expression->eq('tenant_id',7));
 my $adapter=($backend->[0] eq 'sqlite'?'Selecto::SQLite':$backend->[0] eq 'duckdb'?'Selecto::DuckDB':'Selecto::PostgreSQL')->new(dbh=>$dbh,temporary_relations=>1);
 my $engine=Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
 my $q=$engine->query->select('id','charge_revenue','charge_cost','total_revenue','margin')->order_by('id');
 my $rows=numbers($engine->all($q)->{rows});
 is_deeply $rows,[[1,125,25,225,150],[2,0,0,0,0],[3,0,0,0,0],[4,100,0,100,100],[5,12,9,12,3],[6,0,0,0,0]],'filtered sums through to-one, default zero, expressions and tenant bounds';
 is_deeply $engine->all($engine->query->select(Selecto::Expression->count))-> {rows},[[6]],'baseline owner count';
 is_deeply numbers($engine->all($engine->query->select('charge_revenue',Selecto::Expression->count)->group_by(['charge_revenue'])->order_by('charge_revenue'))->{rows}),[[0,3],[12,1],[100,1],[125,1]],'grouped computed totals preserve owner count';
 is_deeply $engine->all($engine->query->select(Selecto::Expression->count)->where(Selecto::Expression->gt('charge_revenue',0)))->{rows},[[3]],'filter does not fan out';
 is_deeply numbers($engine->all($engine->query->select(Selecto::Expression->sum('charge_revenue')))->{rows}),[[237]],'sum of per-owner aggregates';
 is_deeply $engine->all($engine->query->select('charge_count','charge_min','charge_max')->where(Selecto::Expression->eq('id',6)))->{rows},[[undef,undef,undef]],'omitted defaults return NULL with no matching rows';
 is_deeply numbers($engine->all($engine->query->select('charge_count','charge_min','charge_max')->where(Selecto::Expression->eq('id',1)))->{rows}),[[7,5,999]],'count min and max over matching tenant rows';
 is_deeply $engine->all($engine->query->select('charge_count_zero')->where(Selecto::Expression->eq('id',6)))->{rows},[[0]],'count default zero for no matching rows';
 my $actual=$engine->all($engine->query->select('id','lhf_revenue','lhf_pay')->order_by('id'))->{rows};
 my $expected=$dbh->selectall_arrayref(q{
 SELECT l.id,
 COALESCE((SELECT SUM(c.alt_amt) FROM charges c WHERE c.tenant_id=l.tenant_id AND c.trx_typ IN(101,306) AND
 (c.associated_load=l.id OR (c.load_id=l.id AND c.associated_load IS NULL) OR
 (l.type='X' AND EXISTS(SELECT 1 FROM loads leg WHERE leg.tenant_id=l.tenant_id AND leg.id<>l.id AND
 (leg.parent_id=l.id OR leg.alt_parent_id=l.id) AND (c.associated_load=leg.id OR (c.load_id=leg.id AND c.associated_load IS NULL)))))),0),
 COALESCE((SELECT SUM(c.amt) FROM charges c WHERE c.tenant_id=l.tenant_id AND c.trx_typ<1000 AND
 (c.associated_load=l.id OR (c.load_id=l.id AND c.associated_load IS NULL) OR
 (l.type='X' AND EXISTS(SELECT 1 FROM loads leg WHERE leg.tenant_id=l.tenant_id AND leg.id<>l.id AND
 (leg.parent_id=l.id OR leg.alt_parent_id=l.id) AND (c.associated_load=leg.id OR (c.load_id=leg.id AND c.associated_load IS NULL)))))),0)
 FROM loads l WHERE l.tenant_id=7 ORDER BY l.id});
 is_deeply numbers($actual),numbers($expected),'synthetic LHF split and bundle totals match independently written SQL rule';
 is_deeply numbers($actual),[[1,30,20],[2,95,70],[3,112,84],[4,40,30],[5,72,54],[6,0,0]],'LHF OR bridge counts overlapping parent keys once and excludes self';
 $dbh->disconnect;
 };
}
my $bad=contract();$bad->{source}{columns}{charge_revenue}{computed}{function}='raw_sql';
ok !eval{Selecto::Domain->parse($bad,strict=>1);1},'aggregate function allowlist';
for my $invalid (
 {through_owner_keys=>['parent_id','parent_id']},
 {through_owner_keys=>['alt_parent_id']},
 {through_exclude_owner_field=>'missing'},
) {
 my $copy=contract();
 @{$copy->{source}{columns}{lhf_revenue_bundle_load_id}{computed}}{keys %$invalid}=values %$invalid;
 ok !eval{Selecto::Domain->parse($copy,strict=>1);1},'invalid OR bridge key declaration refused';
}
{
 package OpsUnsupportedAdapter;
 use Mojo::Base 'Selecto::SQLite';
 sub name {'unsupported_ops'}
}
my $unsupported=Selecto::Engine->new(domain=>Selecto::Domain->parse(contract(),strict=>1),adapter=>OpsUnsupportedAdapter->new(dbh=>bless({},'OpsFakeDBH')));
my $ok=eval{$unsupported->compile($unsupported->query->select('charge_revenue'));1};
ok !$ok && ref($@) && $@->code eq 'unsupported_feature','other dialects refuse association aggregates explicitly';
done_testing;
