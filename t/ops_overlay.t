use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use DBI;
my $base = {
 schema_version=>1, name=>'Orders',
 source=>{source_table=>'orders',primary_key=>'id',fields=>['id'],columns=>{id=>{type=>'integer'}},
 associations=>{carrier=>{queryable=>'parties',owner_key=>'id',related_key=>'id',
 through=>{table=>'service_flags',owner_key=>'order_id',related_key=>'flag',where=>{flag=>'expedite'},target_key_cast=>'string'}}}},
 schemas=>{parties=>{source_table=>'parties',primary_key=>'id',fields=>[qw(id party_name)],columns=>{id=>{type=>'integer'},party_name=>{type=>'string'}},associations=>{}}},
 joins=>{carrier=>{type=>'left'}},
};
my $domain = Selecto::Domain->compose($base, {source=>{associations=>{carrier=>{through=>{
 table=>'order_party_roles',related_key=>'party_id',where=>{flag=>undef,role_id=>2},target_key_cast=>undef,
 }}}}});
my $bridge=$domain->as_contract->{source}{associations}{carrier}{through};
ok !exists $bridge->{target_key_cast}, 'overlay removes bridge cast';
is_deeply $bridge->{where}, {role_id=>2}, 'overlay removes old condition and installs role';
ok exists $base->{source}{associations}{carrier}{through}{target_key_cast}, 'base is untouched';
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1});
$dbh->do($_) for ('CREATE TABLE orders(id INTEGER)','CREATE TABLE parties(id INTEGER,party_name TEXT)',
 'CREATE TABLE order_party_roles(order_id INTEGER,party_id INTEGER,role_id INTEGER)',
 'INSERT INTO orders VALUES(1)',q{INSERT INTO parties VALUES(7,'Alpha'),(8,'Beta')},
 'INSERT INTO order_party_roles VALUES(1,7,2),(1,8,1)');
my $engine=Selecto::Engine->new(domain=>$domain,adapter=>Selecto::SQLite->new(dbh=>$dbh));
my $q=$engine->query->select('id','carrier.party_name');
unlike $engine->compile($q)->sql, qr/CAST/i, 'integer join has no cast';
is_deeply $engine->all($q)->{rows}, [[1,'Alpha']], 'composed bridge executes integer join';
ok !eval { Selecto::Domain->compose($base,{source=>{source_table=>undef}});1 }, 'required key deletion still fails strict parsing';
done_testing;
