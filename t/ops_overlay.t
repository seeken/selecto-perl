use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use DBI;
my $base = {
 schema_version=>1, name=>'Loads',
 source=>{source_table=>'loads',primary_key=>'id',fields=>['id'],columns=>{id=>{type=>'integer'}},
 associations=>{sales_rep=>{queryable=>'users',owner_key=>'id',related_key=>'id',
 through=>{table=>'load_flags',owner_key=>'load_id',related_key=>'info',where=>{type=>'E'},target_key_cast=>'string'}}}},
 schemas=>{users=>{source_table=>'users',primary_key=>'id',fields=>[qw(id name)],columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}}},
 joins=>{sales_rep=>{type=>'left'}},
};
my $domain = Selecto::Domain->compose($base, {source=>{associations=>{sales_rep=>{through=>{
 table=>'load_user_role',related_key=>'user_id',where=>{type=>undef,role_id=>2},target_key_cast=>undef,
 }}}}});
my $bridge=$domain->as_contract->{source}{associations}{sales_rep}{through};
ok !exists $bridge->{target_key_cast}, 'overlay removes bridge cast';
is_deeply $bridge->{where}, {role_id=>2}, 'overlay removes old condition and installs role';
ok exists $base->{source}{associations}{sales_rep}{through}{target_key_cast}, 'base is untouched';
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1});
$dbh->do($_) for ('CREATE TABLE loads(id INTEGER)','CREATE TABLE users(id INTEGER,name TEXT)',
 'CREATE TABLE load_user_role(load_id INTEGER,user_id INTEGER,role_id INTEGER)',
 'INSERT INTO loads VALUES(1)',q{INSERT INTO users VALUES(7,'Sales'),(8,'Dispatch')},
 'INSERT INTO load_user_role VALUES(1,7,2),(1,8,1)');
my $engine=Selecto::Engine->new(domain=>$domain,adapter=>Selecto::SQLite->new(dbh=>$dbh));
my $q=$engine->query->select('id','sales_rep.name');
unlike $engine->compile($q)->sql, qr/CAST/i, 'integer join has no cast';
is_deeply $engine->all($q)->{rows}, [[1,'Sales']], 'composed bridge executes integer join';
ok !eval { Selecto::Domain->compose($base,{source=>{source_table=>undef}});1 }, 'required key deletion still fails strict parsing';
done_testing;
