use 5.034;
use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use DBI;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::RatioMeasures;
my $c={schema_version=>1,name=>'Loads',source=>{source_table=>'loads',primary_key=>'id',fields=>[qw(id region revenue units)],columns=>{id=>{type=>'integer'},region=>{type=>'string'},revenue=>{type=>'decimal',unit=>{kind=>'currency',code=>'USD'}},units=>{type=>'integer',unit=>{kind=>'count'}}},associations=>{}},schemas=>{},joins=>{}};
my $before=Selecto::Domain->parse($c,strict=>1)->fingerprint;
$c->{ratio_measures}{rpu}={label=>'Revenue per unit',numerator=>{field=>'revenue',function=>'sum'},denominator=>{field=>'units',function=>'sum'}};
my $d=Selecto::Domain->parse($c,strict=>1);
isnt $d->fingerprint,$before,'ratio declaration affects fingerprint';
is_deeply(Selecto::RatioMeasures->definitions($d)->{rpu}{unit},{kind=>'ratio',numerator=>{kind=>'currency',code=>'USD'},denominator=>{kind=>'count'}},'unit derived as numerator per denominator');
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1});
$dbh->do('CREATE TABLE loads(id INTEGER,region TEXT,revenue INTEGER,units INTEGER)');
$dbh->do(q{INSERT INTO loads VALUES(1,'A',100,1),(2,'A',100,9),(3,'B',80,0)});
my $e=Selecto::Engine->new(domain=>$d,adapter=>Selecto::SQLite->new(dbh=>$dbh));
my $x=Selecto::RatioMeasures->expression(Selecto::RatioMeasures->definitions($d)->{rpu});
is_deeply $e->all($e->query->select('region',$x->as('rpu'))->group_by(['region'])->order_by('region'))->{rows},[['A',20],['B',undef]],'ratio of sums and NULL zero denominator';
for my $bad (['numerator','function','avg'],['numerator','field','region'],['denominator','field','missing']) {
 my $copy=dclone($c);$copy->{ratio_measures}{rpu}{$bad->[0]}{$bad->[1]}=$bad->[2];
 ok !eval{Selecto::Domain->parse($copy,strict=>1);1},'invalid ratio operand refused';
}
done_testing;
