use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP qw(decode_json);
use Storable qw(dclone);
use Selecto ();
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
$dbh->do('CREATE TABLE mcp_c_parent(id INTEGER,tenant_id TEXT)');
$dbh->do('CREATE TABLE mcp_c_child(id INTEGER,parent_id INTEGER,tenant_id TEXT,payload TEXT,tags TEXT,active INTEGER,other INTEGER)');
$dbh->do(q{INSERT INTO mcp_c_parent VALUES(1,'A')});
$dbh->do(q{INSERT INTO mcp_c_child VALUES(11,1,'A','{ "b":2,"a":1 }','["x","y"]',1,12),(12,1,'A','{}','[]',0,12),(13,1,'B','{"a":1,"b":2}','["x","y"]',1,14)});
my $raw={schema_version=>1,name=>'Synthetic typed children',source=>{source_table=>'mcp_c_parent',primary_key=>'id',tenant_field=>'tenant_id',fields=>[qw(id tenant_id)],columns=>{id=>{type=>'integer'},tenant_id=>{type=>'string'}},associations=>{children=>{queryable=>'children',field=>'children',owner_key=>'id',related_key=>'parent_id',cardinality=>'many',where=>{id=>['ne',['field','other']]}}}},schemas=>{children=>{source_table=>'mcp_c_child',primary_key=>'id',tenant_field=>'tenant_id',fields=>[qw(id parent_id tenant_id payload tags active other)],columns=>{id=>{type=>'integer'},parent_id=>{type=>'integer'},tenant_id=>{type=>'string'},payload=>{type=>'json'},tags=>{type=>'array',items=>'string'},active=>{type=>'boolean'},other=>{type=>'integer'}},associations=>{}}},joins=>{children=>{type=>'left'}}};
my $d=Selecto::Domain->parse(dclone($raw));my $e=Selecto::Engine->new(domain=>$d,adapter=>Selecto->adapter(sqlite=>(dbh=>$dbh)))->with_scope(tenant=>'A');
my $E='Selecto::Expression';
my $rows=sub {my ($field,$value)=@_;my $expression=$E->related_rows('children',['id'],filters=>[[$field,$value]],order_by=>[['id','asc']],limit=>10)->as('children');my $r=$e->all($e->query->select($expression));decode_json($r->{rows}[0][0]);};
is_deeply $rows->('payload',{a=>1,b=>2}),[{id=>11}],'public related_rows API compares typed JSON literals structurally';
is_deeply $rows->('tags',['x','y']),[{id=>11}],'public related_rows API compares typed arrays';
is_deeply $rows->('active',JSON::PP::true),[{id=>11}],'boolean literal child comparison';
is_deeply decode_json($e->all($e->query->select($E->related_rows('children',['id'],order_by=>[['id','asc']])))->{rows}[0][0]),[{id=>11}],'finite target-local inequality and tenant pin apply in the correlated read';
for my $value ({raw_sql=>'literal'},['field','other']) {
    eval {$rows->('id',$value)};
    is ref($@)?$@->code:'','invalid_query','structured scalar cannot become a child expression';
}
for my $bad (['sql','1=1'],['ne',['field','missing']],['ne',['field','children.other']],['eq',['field','other']]) {
    my $copy=dclone($raw);$copy->{source}{associations}{children}{where}{id}=$bad;
    eval {Selecto::Domain->parse($copy)};
    is ref($@)?$@->code:'','invalid_domain','unsafe or undeclared policy operand refused by public parser';
}
my $copy=dclone($raw);$copy->{schemas}{children}{columns}{other}{computed}={kind=>'expression',expression=>['field','id']};
eval {Selecto::Domain->parse($copy)};is ref($@)?$@->code:'','invalid_domain','inequality cannot access a computed target field';
is $dbh->selectrow_array('PRAGMA query_only'),0,'failed compilation leaves connection reusable';
if ($ENV{SELECTO_PERL_MCP_TEST_POSTGRES_URL}) {
 subtest 'PostgreSQL public value formats'=>sub {
    require Mojo::URL;require Selecto::PostgreSQL;
    my $url=Mojo::URL->new($ENV{SELECTO_PERL_MCP_TEST_POSTGRES_URL});
    die 'test requires the explicit RAM PostgreSQL endpoint' unless ($url->host//'') eq '127.0.0.1' && $url->port && $url->port!=5432;
    my $database=$url->path->to_string;$database=~s{^/}{};
    my $pg=eval {DBI->connect('dbi:Pg:dbname='.$database.';host=127.0.0.1;port='.$url->port,$url->username,$url->password,{RaiseError=>1,PrintError=>0})};
    die 'RAM PostgreSQL unavailable' unless $pg;
    my $adapter=Selecto->adapter(postgresql=>(dbh=>$pg));
    eval {$adapter->prepare_read_values};is ref($@)?$@->code:'','invalid_transaction','value formats cannot alter an unbounded host session';
    $pg->do(q{SET DateStyle TO 'SQL, DMY'});$pg->do(q{SET IntervalStyle TO 'iso_8601'});$pg->begin_work;
    ok $adapter->prepare_read_values,'public adapter read-format API';
    is $pg->selectrow_array('SHOW DateStyle'),'ISO, YMD','date text pinned in read transaction';
    is $pg->selectrow_array('SHOW IntervalStyle'),'postgres','interval text pinned in read transaction';
    $pg->rollback;
    is $pg->selectrow_array('SHOW DateStyle'),'SQL, DMY','rollback restores prior date format';
    is $pg->selectrow_array('SHOW IntervalStyle'),'iso_8601','rollback restores prior interval format';
    $pg->disconnect;
 };
}
done_testing;
