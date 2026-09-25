use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Selecto;
use Selecto::Write ();

plan skip_all => 'DBD::DuckDB is not installed' unless eval {require DBD::DuckDB; 1};

my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef,
    {RaiseError=>1, PrintError=>0, AutoCommit=>1});
$dbh->do(q{SET TIME ZONE 'UTC'});
$dbh->do(q{CREATE TEMP TABLE transport_values (
    id INTEGER PRIMARY KEY, happened TIMESTAMP, instant TIMESTAMPTZ,
    nano TIMESTAMP_NS, amount DECIMAL(38,6), label VARCHAR, active BOOLEAN)});
$dbh->do(q{INSERT INTO transport_values VALUES
    (1,'1969-12-31 23:59:59.999999','1969-12-31 23:59:59.999999+00',
       '1969-12-31 23:59:59.999999999',2.000001,'1969-12-31 23:59:59.999999',true),
    (2,'1970-01-01 00:00:00.000001','1970-01-01 00:00:00.000001+00',
       '1970-01-01 00:00:00.000000001',10.000001,'10.5000',false),
    (3,'1970-01-01 00:00:00.100001','1970-01-01 00:00:00.100001+00',
       '1970-01-01 00:00:00.100000001',9007199254740993.000001,'plain',true),
    (4,NULL,NULL,NULL,NULL,NULL,NULL),
    (5,'1970-01-01 00:00:00.000001','1970-01-01 00:00:00.000001+00',
       '1970-01-01 00:00:00.000000001',10.000001,'duplicate',true)});
my $adapter = Selecto->adapter(duckdb => (dbh=>$dbh));
my $domain = Selecto::Domain->new(name=>'Transport values', table=>'transport_values', fields=>{
    id=>'integer', happened=>'naive_datetime', instant=>'utc_datetime', nano=>'naive_datetime',
    amount=>'decimal', label=>'string', active=>'boolean',
});
my $engine = Selecto::Engine->new(domain=>$domain, adapter=>$adapter,
    write_policy=>'permissive');    # legacy domain without a write policy
my $query = $engine->query->select(qw(id happened instant nano amount label active))->order_by('id');
my $expected = [
    [1,'1969-12-31T23:59:59.999999','1969-12-31T23:59:59.999999',
        '1969-12-31T23:59:59.999999999','2.000001','1969-12-31 23:59:59.999999',1],
    [2,'1970-01-01T00:00:00.000001','1970-01-01T00:00:00.000001',
        '1970-01-01T00:00:00.000000001','10.000001','10.5000',0],
    [3,'1970-01-01T00:00:00.100001','1970-01-01T00:00:00.100001',
        '1970-01-01T00:00:00.100000001','9007199254740993.000001','plain',1],
    [4,undef,undef,undef,undef,undef,undef],
    [5,'1970-01-01T00:00:00.000001','1970-01-01T00:00:00.000001',
        '1970-01-01T00:00:00.000000001','10.000001','duplicate',1],
];
is_deeply $engine->all($query)->{rows}, $expected,
    'microseconds, nanoseconds, exact decimals and NULLs survive while lookalike strings stay unchanged';

for my $zone ('UTC', 'Pacific/Honolulu', 'Asia/Kathmandu') {
    $dbh->do("SET TIME ZONE '$zone'"); # Independently authored fixture zones.
    my $expected_instant = $dbh->selectall_arrayref('SELECT CAST(instant AS VARCHAR) FROM transport_values ORDER BY id');
    for my $row (@$expected_instant) {
        next unless defined $row->[0];
        $row->[0] =~ s/ /T/;
        $row->[0] =~ s/\+00(?::00)?\z//;
    }
    is_deeply $engine->all($engine->query->select('instant')->order_by('id'))->{rows}, $expected_instant,
        "raw instants use the database session $zone, not the process timezone";
}
$dbh->do(q{SET TIME ZONE 'UTC'});

my $stream = $engine->stream($query, fetch_size=>2);
my @streamed;
while (my $row = $stream->next) { push @streamed, $row; }
is_deeply \@streamed, $expected, 'streamed values have the same exact decoding';
ok $stream->closed, 'exact-value stream closes at exhaustion';

my $ordered = $engine->query->select(qw(id amount))->where(Selecto::Expression->not_null('amount'))
    ->order_by('amount')->order_by('id')->offset(1)->limit(2);
is_deeply $engine->all($ordered)->{rows}, [[2,'10.000001'],[5,'10.000001']],
    'ordering and paging use numeric values before transport rather than lexical text order';
my $aggregate = $engine->query->select(
    Selecto::Expression->min('amount')->as('minimum'),
    Selecto::Expression->max('amount')->as('maximum'),
    Selecto::Expression->min('happened')->as('first'),
    Selecto::Expression->max('happened')->as('last'));
is_deeply $engine->all($aggregate)->{rows},
    [['2.000001','9007199254740993.000001','1969-12-31T23:59:59.999999','1970-01-01T00:00:00.100001']],
    'aggregate comparison and result types remain native';
my $grouped = $engine->query->select('happened', Selecto::Expression->count->as('total'))
    ->group_by('happened')->order_by('happened');
is_deeply $engine->all($grouped)->{rows}, [
    ['1969-12-31T23:59:59.999999',1],['1970-01-01T00:00:00.000001',2],
    ['1970-01-01T00:00:00.100001',1],[undef,1]], 'grouping remains on native timestamps';
my $windowed = $engine->query->select('id',
    Selecto::Expression->window('lag',['happened'],order_by=>['id'])->as('previous'))
    ->order_by('id')->limit(3);
is_deeply $engine->all($windowed)->{rows}, [[1,undef],[2,'1969-12-31T23:59:59.999999'],[3,'1970-01-01T00:00:00.000001']],
    'window values are decoded only after native window evaluation';
my $left = $engine->query->select('happened')->where(Selecto::Expression->in('id',[1,2]));
my $right = $engine->query->select('happened')->where(Selecto::Expression->eq('id',5));
is_deeply $engine->all($left->union($right)->order_by('happened'))->{rows},
    [['1969-12-31T23:59:59.999999'],['1970-01-01T00:00:00.000001']], 'UNION deduplicates native timestamps';
is_deeply $engine->all($left->union_all($right)->order_by('happened'))->{rows},
    [['1969-12-31T23:59:59.999999'],['1970-01-01T00:00:00.000001'],['1970-01-01T00:00:00.000001']],
    'UNION ALL retains duplicate native timestamps';
is_deeply $engine->all($left->except($right)->order_by('happened'))->{rows},
    [['1969-12-31T23:59:59.999999']], 'EXCEPT compares native operands before transport';

my $cte = $engine->query->with_cte('typed_values', $domain,
    $engine->query->select(qw(id amount happened)), columns=>[qw(id amount happened)],
    join=>{owner_key=>'id',related_key=>'id',type=>'inner'})
    ->select('id','typed_values.happened')
    ->where(Selecto::Expression->gt('typed_values.amount','2.0000009'))->order_by('id');
is_deeply $engine->all($cte)->{rows}, [[1,'1969-12-31T23:59:59.999999'],
    [2,'1970-01-01T00:00:00.000001'],[3,'1970-01-01T00:00:00.100001'],[5,'1970-01-01T00:00:00.000001']],
    'CTE values retain native types and precision before final result decoding';
for my $case (
    [Selecto::Expression->eq('amount','2.0000011'), []],
    [Selecto::Expression->gt('amount','2.0000009'), [1,2,3,5]],
    [Selecto::Expression->between('amount','2.0000009','2.0000011'), [1]],
    [Selecto::Expression->in('amount',['2.0000011','10.0000011']), []],
    [Selecto::Expression->eq('amount','9007199254740993.000001'), [3]],
) {
    my $rows = $engine->all($engine->query->select('id')->where($case->[0])->order_by('id'))->{rows};
    is_deeply [map {$_->[0]} @$rows], $case->[1], 'numeric comparison preserves the parameter scale and exact digits';
}
my $mutation = Selecto::Write::Command->new(operation=>'update',relation=>'transport_values',
    assignments=>{amount=>Selecto::Write::Expression->increment('amount','0.000001')},
    predicate=>Selecto::Expression->eq('id',3), metadata=>{returning=>['amount']});
is_deeply $engine->execute_write($mutation)->values, {amount=>'9007199254740993.000002'},
    'mutation arithmetic never routes an exact decimal parameter through floating point';

$dbh->do(q{CREATE TEMP TABLE transport_identifiers (id BIGINT, label VARCHAR)});
$dbh->do(q{INSERT INTO transport_identifiers VALUES (9007199254740992,'001'),(9007199254740993,'1')});
my $identifiers = Selecto::Engine->new(adapter=>$adapter,domain=>Selecto::Domain->new(
    name=>'Exact identifiers',table=>'transport_identifiers',fields=>{id=>'integer',label=>'string'}));
is_deeply $identifiers->all($identifiers->query->select('id')->where(
    Selecto::Expression->eq('id','9007199254740993')))->{rows}, [['9007199254740993']],
    'big integer input and output remain exact';
is_deeply $identifiers->all($identifiers->query->select('label')->where(
    Selecto::Expression->eq('label','001')))->{rows}, [['001']],
    'numeric-looking text binds as text and retains leading zeroes';

$dbh->do(q{CREATE TEMP TABLE transport_nested AS SELECT [1,2,NULL] AS items,
    STRUCT_PACK(kind := 'TIMESTAMP', exact := 'not a timestamp', native := 'original') AS user_struct,
    CAST('abc' AS BLOB) AS bytes, CAST('{"n":1.00}' AS JSON) AS document});
my $nested = Selecto::Engine->new(adapter=>$adapter, domain=>Selecto::Domain->new(
    name=>'Nested values',table=>'transport_nested', fields=>{items=>'array',user_struct=>'json',bytes=>'binary',document=>'json'}));
is_deeply $nested->all($nested->query->select(qw(items user_struct bytes document)))->{rows},
    [[[1,2,undef],{kind=>'TIMESTAMP',exact=>'not a timestamp',native=>'original'},'abc','{"n":1.00}']],
    'ordinary arrays, structs resembling transport metadata, blobs and JSON remain native values';

my $input = q{value' OR 1=1 -- ?};
my $bound = $engine->query->select('id')->where(Selecto::Expression->eq('label',$input));
is_deeply $engine->compile($bound)->params, [$input], 'transport does not add or duplicate caller bindings';
is_deeply $engine->all($bound)->{rows}, [], 'injection-shaped input remains bound data';
is_deeply $engine->all($query->limit(0))->{rows}, [], 'empty results retain their empty shape';

for my $operation (qw(insert update delete)) {
    my $command = Selecto::Write::Command->new(operation=>$operation, relation=>'transport_values',
        ($operation eq 'delete' ? () : (assignments=>{
            ($operation eq 'insert' ? (id=>6) : ()),
            happened=>'1969-12-31 23:59:59.999999',
            instant=>'1969-12-31 23:59:59.999999+00', amount=>'9007199254740993.000001'})),
        ($operation eq 'insert' ? () : (predicate=>Selecto::Expression->eq('id',6))),
        metadata=>{returning=>[qw(id happened instant amount)]});
    my $result = $engine->execute_write($command);
    is_deeply $result->values,
        {id=>6,happened=>'1969-12-31T23:59:59.999999',instant=>'1969-12-31T23:59:59.999999',amount=>'9007199254740993.000001'},
        "$operation RETURNING preserves exact typed values";
    is $result->affected_rows, 1, "$operation RETURNING preserves affected count";
}
$dbh->disconnect;
done_testing;
