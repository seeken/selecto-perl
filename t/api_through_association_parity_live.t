use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

my $database = $ENV{SELECTO_API_TEST_DATABASE};
plan skip_all => 'API PostgreSQL database is not configured' unless defined $database && length $database;
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };
my $dbh = DBI->connect("dbi:Pg:dbname=$database;host=/tmp", undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TEMP TABLE records(id INTEGER PRIMARY KEY,tenant_id INTEGER)');
$dbh->do('CREATE TEMP TABLE tags(id BIGINT,tenant_id INTEGER,label TEXT,active INTEGER)');
$dbh->do('CREATE TEMP TABLE record_tags(record_id INTEGER,tag_id TEXT,tenant_id INTEGER,active INTEGER,deleted_at TEXT)');
$dbh->do('INSERT INTO records VALUES(1,7),(2,7),(3,7),(4,8)');
$dbh->do(q{INSERT INTO tags VALUES(10,7,'allowed',2),(10,8,'other target tenant',2),(9007199254740993,7,'large',2),(11,7,'disabled target',0),(12,7,'disabled bridge',2),(13,7,'deleted bridge',2),(14,7,'other bridge tenant',2)});
$dbh->do(q{INSERT INTO record_tags VALUES(1,'9007199254740993',7,1,NULL),(1,'10',7,1,NULL),(1,'11',7,1,NULL),(1,'12',7,0,NULL),(1,'13',7,1,'deleted'),(1,'14',8,1,NULL),(3,'11',7,1,NULL),(4,'10',8,1,NULL)});
my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', domain_fingerprint => 'sha256:through-api', name => 'Records',
    source => {source_table => 'records', primary_key => 'id', fields => [qw(id tenant_id)],
        columns => {id => {type => 'integer'}, tenant_id => {type => 'integer', internal => 1}},
        associations => {tags => {queryable => 'tags', owner_key => 'id', related_key => 'id', cardinality => 'many',
            where => {active => 2}, through => {table => 'record_tags', owner_key => 'record_id', related_key => 'tag_id',
                source_scope_key => 'tenant_id', through_scope_key => 'tenant_id', target_scope_key => 'tenant_id',
                target_key_cast => 'string', where => {active => 1, deleted_at => undef}}}}},
    schemas => {tags => {source_table => 'tags', primary_key => 'id', fields => [qw(id tenant_id label active)],
        columns => {id => {type => 'integer'}, tenant_id => {type => 'integer', internal => 1}, label => {type => 'string'}, active => {type => 'integer'}}, associations => {}}},
    joins => {tags => {type => 'left'}},
})->with_required_predicate(Selecto::Expression->eq('tenant_id',7));
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
my $handler = Selecto::API::EngineHandler->new;
my $intent = {select => ['id', [qw(tags.id tags.label tags.active)]], order_by => [{field => 'id', direction => 'asc'}]};
my $result = $handler->query($engine, $intent);
is_deeply $handler->query($engine, {select => ['id','tags.label'], order_by => [
    {field => 'id', direction => 'asc'}, {field => 'tags.label', direction => 'asc'}]})->{rows},
    [[1,'allowed'],[1,'large'],[2,undef],[3,undef]],
    'filtered targets do not add null rows alongside permitted targets';
is_deeply $result->{rows}, [[1,[[10,'allowed',2],['9007199254740993','large',2]]],[2,[]],[3,[]]],
    'through collection retains bridge and target policies, exact IDs, target columns and parent cardinality';
is_deeply $result->{subtables}, {tags => {columns => [qw(tags.id tags.label tags.active)]}},
    'subtable metadata uses selected output names';
like(JSON::PP->new->encode($result->{rows}), qr/"9007199254740993"/,
    'unsafe child integer has a JSON string type, not only string-equal value');
like(JSON::PP->new->encode($result->{rows}), qr/\[10,"allowed",2\]/,
    'safe child integers retain numeric JSON types');
is_deeply $handler->query($engine, {select => ['id','tags.label'], filters => [{field => 'id', op => 'gte', value => 2}],
    order_by => [{field => 'id', direction => 'asc'}]})->{rows}, [[2,undef],[3,undef]],
    'left joins preserve missing and filtered targets';
is_deeply $handler->query($engine, {select => ['id','tags.label'], filters => [{field => 'tags.label', op => 'eq', value => 'allowed'}]})->{rows},
    [[1,'allowed']], 'flat through selection cannot cross either tenant boundary';
my $objects = $handler->query($engine, {%$intent, row_format => 'objects', limit => 1});
is scalar @{$objects->{rows}}, 1, 'paging counts parents';
is_deeply $objects->{rows}[0]{tags}, [
    {'tags.id' => 10, 'tags.label' => 'allowed', 'tags.active' => 2},
    {'tags.id' => '9007199254740993', 'tags.label' => 'large', 'tags.active' => 2},
], 'object child rows retain target values';
ok !eval { $handler->query($engine, {select => ['id',['tags.tenant_id']]}); 1 }, 'internal child scope column is not exposed';
$dbh->disconnect;
done_testing;
