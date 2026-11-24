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

# The integer classification and lookup extend the reference charge relation
# to retain numeric range filters and associated to-one predicates.
sub contract {
 my %columns=(map {$_=>{type=>'integer'}} qw(id account_id group_order_id merged_into_order_id piece_count));
 $columns{kind}={type=>'string'};
 $columns{quoted_amount}={type=>'decimal'};
 $columns{haul_cost}={type=>'decimal'};
 my %associations=(charges=>{queryable=>'charges',owner_key=>'id',related_key=>'order_id',cardinality=>'many'},
 assigned_charges=>{queryable=>'charges',owner_key=>'id',related_key=>'assigned_order_id',cardinality=>'many'});
 for my $target (qw(order_id assigned_order_id)) {
  $associations{"group_$target"}={queryable=>'charges',owner_key=>'id',related_key=>$target,cardinality=>'many',
   through=>{table=>'orders',owner_key=>'group_order_id',related_key=>'id',source_scope_key=>'account_id',through_scope_key=>'account_id',target_scope_key=>'account_id'}};
 }
 my $rev=['and', [['in','charge_type.side',['revenue','both']], ['not',['in','charge_code',[8100,8200]]]]];
 $columns{charges_billed}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>'charges',function=>'sum',field=>'billed_amount',where=>$rev,default=>0}};
 $columns{charges_paid}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>'charges',function=>'sum',field=>'paid_amount',where=>['and',[['in','charge_type.side',['cost','both']],['not',['in','charge_code',[8100,8200]]]]],default=>0}};
 $columns{charge_count}={type=>'integer',computed=>{kind=>'association_aggregate',association=>'charges',function=>'count',field=>'id'}};
 $columns{charge_count_zero}={type=>'integer',computed=>{kind=>'association_aggregate',association=>'charges',function=>'count',field=>'id',default=>0}};
 for my $fn(qw(min max)) {$columns{"charge_$fn"}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>'charges',function=>$fn,field=>'paid_amount'}}}
 $columns{total_billed}={type=>'decimal',computed=>{kind=>'expression',expression=>['add',['coalesce',['field','quoted_amount'],['literal',0]],['field','charges_billed']]}};
 $columns{total_paid}={type=>'decimal',computed=>{kind=>'expression',expression=>['add',['coalesce',['field','haul_cost'],['literal',0]],['field','charges_paid']]}};
 $columns{margin}={type=>'decimal',computed=>{kind=>'expression',expression=>['subtract',['field','total_billed'],['field','total_paid']]}};
 for my $side(qw(billed paid)) {
  my @parts;
  for my $assoc(sort keys %associations) {
   my %prefix = (charges => 'unassigned_charges', assigned_charges => 'assigned_charges',
       group_order_id => 'group_charges', group_assigned_order_id => 'group_assigned_charges');
   my $id="$prefix{$assoc}_$side";
   my @filters=($side eq 'billed' ? ['in','charge_code',[7100,7200]] : ['lt','charge_code',8000]);
   push @filters,['is_null','assigned_order_id'] if $assoc eq 'charges' || $assoc eq 'group_order_id';
   $columns{$id}={type=>'decimal',computed=>{kind=>'association_aggregate',association=>$assoc,function=>'sum',field=>$side eq 'billed'?'billed_amount':'paid_amount',where=>['and',\@filters],default=>0,
    ($assoc =~ /^group_/ ? (through_owner_keys=>[qw(group_order_id merged_into_order_id)],through_exclude_owner_field=>'id') : ())}};
   my $part=['field',$id];
   $part=['case',[['eq','kind','GroupHead'],$part],['else',['literal',0]]] if $assoc ne 'charges' && $assoc ne 'assigned_charges';
   push @parts,$part;
  }
  my $expr=shift @parts; $expr=['add',$expr,$_] for @parts;
  $columns{"correlated_$side"}={type=>'decimal',computed=>{kind=>'expression',expression=>$expr}};
 }
 return {schema_version=>1,name=>'Orders',source=>{source_table=>'orders',primary_key=>'id',tenant_field=>'account_id',fields=>[sort keys %columns],columns=>\%columns,associations=>\%associations},
 schemas=>{charges=>{source_table=>'order_charges',primary_key=>'id',tenant_field=>'account_id',fields=>[qw(id account_id order_id assigned_order_id charge_code billed_amount paid_amount)],columns=>{(map {$_=>{type=>'integer'}} qw(id account_id order_id assigned_order_id charge_code)),billed_amount=>{type=>'decimal'},paid_amount=>{type=>'decimal'}},associations=>{charge_type=>{queryable=>'charge_types',owner_key=>'charge_code',related_key=>'code'}}},
 charge_types=>{source_table=>'charge_types',primary_key=>'code',tenant_field=>'account_id',fields=>[qw(code account_id side)],columns=>{code=>{type=>'integer'},account_id=>{type=>'integer'},side=>{type=>'string'}},associations=>{}}},
 joins=>{(map {$_=>{type=>'left',joins=>{charge_type=>{type=>'left'}}}} keys %associations)}};
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
 $dbh->do($_) for ('CREATE TEMP TABLE orders(id INTEGER,account_id INTEGER,group_order_id INTEGER,merged_into_order_id INTEGER,piece_count INTEGER,kind TEXT,quoted_amount DECIMAL(12,2),haul_cost DECIMAL(12,2))',
 'CREATE TEMP TABLE order_charges(id INTEGER,account_id INTEGER,order_id INTEGER,assigned_order_id INTEGER,charge_code INTEGER,billed_amount DECIMAL(12,2),paid_amount DECIMAL(12,2))',
 'CREATE TEMP TABLE charge_types(code INTEGER,account_id INTEGER,side TEXT)',
 q{INSERT INTO charge_types VALUES(7100,1001,'revenue'),(7200,1001,'both'),(7300,1001,'cost'),(8100,1001,'revenue'),(8200,1001,'cost'),(7100,1002,'cost')},
 q{INSERT INTO orders VALUES(1,1001,NULL,NULL,2,'SplitSource',100,50),(2,1001,1,NULL,1,'SplitPart',NULL,0),(3,1001,3,3,0,'GroupHead',NULL,NULL),(4,1001,3,3,1,'GroupMember',NULL,NULL),(5,1001,NULL,3,3,'GroupMember',NULL,NULL),(6,1001,NULL,NULL,0,'Standalone',NULL,NULL),(1,1002,NULL,NULL,1,'Standalone',999,999)},
 q{INSERT INTO order_charges VALUES(1,1001,1,NULL,7100,10,5),(2,1001,1,NULL,7200,20,8),(3,1001,1,2,7100,80,60),(4,1001,1,2,7200,15,10),(5,1001,1,NULL,8100,999,999),(6,1001,1,NULL,8200,999,999),(7,1001,1,NULL,7300,0,7),(8,1001,4,NULL,7100,40,30),(9,1001,4,5,7100,60,45),(10,1001,5,NULL,7200,12,9),(11,1002,1,NULL,7100,5000,5000)});
 my $domain=Selecto::Domain->parse(contract(),strict=>1)->with_required_predicate(Selecto::Expression->eq('account_id',1001));
 my $adapter=($backend->[0] eq 'sqlite'?'Selecto::SQLite':$backend->[0] eq 'duckdb'?'Selecto::DuckDB':'Selecto::PostgreSQL')->new(dbh=>$dbh,temporary_relations=>1);
 my $engine=Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
 my $q=$engine->query->select('id','charges_billed','charges_paid','total_billed','margin')->order_by('id');
 my $rows=numbers($engine->all($q)->{rows});
 is_deeply $rows,[[1,125,25,225,150],[2,0,0,0,0],[3,0,0,0,0],[4,100,0,100,100],[5,12,9,12,3],[6,0,0,0,0]],'filtered sums through to-one, default zero, expressions and tenant bounds';
 is_deeply $engine->all($engine->query->select(Selecto::Expression->count))-> {rows},[[6]],'baseline owner count';
 is_deeply numbers($engine->all($engine->query->select('charges_billed',Selecto::Expression->count)->group_by(['charges_billed'])->order_by('charges_billed'))->{rows}),[[0,3],[12,1],[100,1],[125,1]],'grouped computed totals preserve owner count';
 is_deeply $engine->all($engine->query->select(Selecto::Expression->count)->where(Selecto::Expression->gt('charges_billed',0)))->{rows},[[3]],'filter does not fan out';
 is_deeply numbers($engine->all($engine->query->select(Selecto::Expression->sum('charges_billed')))->{rows}),[[237]],'sum of per-owner aggregates';
 is_deeply $engine->all($engine->query->select('charge_count','charge_min','charge_max')->where(Selecto::Expression->eq('id',6)))->{rows},[[undef,undef,undef]],'omitted defaults return NULL with no matching rows';
 is_deeply numbers($engine->all($engine->query->select('charge_count','charge_min','charge_max')->where(Selecto::Expression->eq('id',1)))->{rows}),[[7,5,999]],'count min and max over matching tenant rows';
 is_deeply $engine->all($engine->query->select('charge_count_zero')->where(Selecto::Expression->eq('id',6)))->{rows},[[0]],'count default zero for no matching rows';
 my $actual=$engine->all($engine->query->select('id','correlated_billed','correlated_paid')->order_by('id'))->{rows};
 my $expected=$dbh->selectall_arrayref(q{
 SELECT l.id,
 COALESCE((SELECT SUM(c.billed_amount) FROM order_charges c WHERE c.account_id=l.account_id AND c.charge_code IN(7100,7200) AND
 (c.assigned_order_id=l.id OR (c.order_id=l.id AND c.assigned_order_id IS NULL) OR
 (l.kind='GroupHead' AND EXISTS(SELECT 1 FROM orders leg WHERE leg.account_id=l.account_id AND leg.id<>l.id AND
 (leg.group_order_id=l.id OR leg.merged_into_order_id=l.id) AND (c.assigned_order_id=leg.id OR (c.order_id=leg.id AND c.assigned_order_id IS NULL)))))),0),
 COALESCE((SELECT SUM(c.paid_amount) FROM order_charges c WHERE c.account_id=l.account_id AND c.charge_code<8000 AND
 (c.assigned_order_id=l.id OR (c.order_id=l.id AND c.assigned_order_id IS NULL) OR
 (l.kind='GroupHead' AND EXISTS(SELECT 1 FROM orders leg WHERE leg.account_id=l.account_id AND leg.id<>l.id AND
 (leg.group_order_id=l.id OR leg.merged_into_order_id=l.id) AND (c.assigned_order_id=leg.id OR (c.order_id=leg.id AND c.assigned_order_id IS NULL)))))),0)
 FROM orders l WHERE l.account_id=1001 ORDER BY l.id});
 is_deeply numbers($actual),numbers($expected),'synthetic order split and group totals match independently written SQL rule';
 is_deeply numbers($actual),[[1,30,20],[2,95,70],[3,112,84],[4,40,30],[5,72,54],[6,0,0]],'Order OR bridge counts overlapping parent keys once and excludes self';
 $dbh->disconnect;
 };
}
my $bad=contract();$bad->{source}{columns}{charges_billed}{computed}{function}='raw_sql';
ok !eval{Selecto::Domain->parse($bad,strict=>1);1},'aggregate function allowlist';
for my $invalid (
 {through_owner_keys=>['group_order_id','group_order_id']},
 {through_owner_keys=>['merged_into_order_id']},
 {through_exclude_owner_field=>'missing'},
) {
 my $copy=contract();
 @{$copy->{source}{columns}{group_charges_billed}{computed}}{keys %$invalid}=values %$invalid;
 ok !eval{Selecto::Domain->parse($copy,strict=>1);1},'invalid OR bridge key declaration refused';
}
{
 package OpsUnsupportedAdapter;
 use Mojo::Base 'Selecto::SQLite';
 sub name {'unsupported_ops'}
}
my $unsupported=Selecto::Engine->new(domain=>Selecto::Domain->parse(contract(),strict=>1),adapter=>OpsUnsupportedAdapter->new(dbh=>bless({},'OpsFakeDBH')));
my $ok=eval{$unsupported->compile($unsupported->query->select('charges_billed'));1};
ok !$ok && ref($@) && $@->code eq 'unsupported_feature','other dialects refuse association aggregates explicitly';
done_testing;
