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
my $c={schema_version=>1,name=>'Orders',source=>{source_table=>'orders',primary_key=>'id',fields=>[qw(id mode quoted_amount piece_count)],columns=>{id=>{type=>'integer'},mode=>{type=>'string'},quoted_amount=>{type=>'decimal',unit=>{kind=>'currency',code=>'USD'}},piece_count=>{type=>'integer',unit=>{kind=>'count'}}},associations=>{}},schemas=>{},joins=>{}};
my $before=Selecto::Domain->parse($c,strict=>1)->fingerprint;
$c->{ratio_measures}{amount_per_piece}={label=>'Amount per piece',numerator=>{field=>'quoted_amount',function=>'sum'},denominator=>{field=>'piece_count',function=>'sum'}};
my $d=Selecto::Domain->parse($c,strict=>1);
isnt $d->fingerprint,$before,'ratio declaration affects fingerprint';
is_deeply(Selecto::RatioMeasures->definitions($d)->{amount_per_piece}{unit},{kind=>'ratio',numerator=>{kind=>'currency',code=>'USD'},denominator=>{kind=>'count'}},'unit derived as numerator per denominator');
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1});
$dbh->do('CREATE TABLE orders(id INTEGER,mode TEXT,quoted_amount INTEGER,piece_count INTEGER)');
$dbh->do(q{INSERT INTO orders VALUES(1,'air',100,1),(2,'air',100,9),(3,'road',80,0)});
my $e=Selecto::Engine->new(domain=>$d,adapter=>Selecto::SQLite->new(dbh=>$dbh));
my $x=Selecto::RatioMeasures->expression(Selecto::RatioMeasures->definitions($d)->{amount_per_piece});
is_deeply $e->all($e->query->select('mode',$x->as('amount_per_piece'))->group_by(['mode'])->order_by('mode'))->{rows},[['air',20],['road',undef]],'ratio of sums and NULL zero denominator';
for my $bad (['numerator','function','avg'],['numerator','field','mode'],['denominator','field','missing']) {
 my $copy=dclone($c);$copy->{ratio_measures}{amount_per_piece}{$bad->[0]}{$bad->[1]}=$bad->[2];
 ok !eval{Selecto::Domain->parse($copy,strict=>1);1},'invalid ratio operand refused';
}
done_testing;
