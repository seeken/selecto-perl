use strict; use warnings;
use Selecto;
my $backend = shift @ARGV;
if ($backend eq 'core') { die 'driver loaded' if grep { /^DBD\// } keys %INC; print "CORE_IMPORT_OK\n"; exit; }
use DBI;
my %classes = (postgresql=>'PostgreSQL',mysql=>'MySQL',mariadb=>'MariaDB',sqlite=>'SQLite',duckdb=>'DuckDB');
my $class = 'Selecto::'.$classes{$backend};
(my $file = "$class.pm") =~ s{::}{/}g; require $file;
my $host=$ENV{DB_HOST};my $port=$ENV{DB_PORT};
my %dsns = (postgresql=>"dbi:Pg:dbname=single_backend;host=$host;port=$port",mysql=>"dbi:MariaDB:database=single_backend;host=$host;port=$port",mariadb=>"dbi:MariaDB:database=single_backend;host=$host;port=$port",sqlite=>'dbi:SQLite:dbname=:memory:',duckdb=>'dbi:DuckDB:dbname=:memory:');
my $c=DBI->connect($dsns{$backend},$backend eq 'postgresql'?'postgres':'root','',{RaiseError=>1,AutoCommit=>1});
$c->do('CREATE TABLE smoke_items(id integer PRIMARY KEY,name varchar(40))');
$c->do("INSERT INTO smoke_items VALUES(1,'selected')");
my $d=Selecto::Domain->new(name=>'Smoke',table=>'smoke_items',fields=>{id=>'integer',name=>'string'});
my $e=Selecto::Engine->new(domain=>$d,adapter=>$class->new(dbh=>$c));
my $r=$e->all($e->query->select('id','name'));
die 'wrong rows' unless @{$r->{rows}}==1 && $r->{rows}[0][0]==1 && $r->{rows}[0][1] eq 'selected';
print "SELECTED_QUERY_OK $backend\n";
$c->disconnect;

open my $features, '>', '/evidence/imported-modules.txt' or die 'evidence write failed';
print {$features} "$_\n" for sort keys %INC;
close $features;
