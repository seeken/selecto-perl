use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
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
$dbh->do('CREATE TEMP TABLE records(id INTEGER PRIMARY KEY,name TEXT NOT NULL,tenant_id INTEGER,secret TEXT)');
$dbh->do(q{INSERT INTO records VALUES(1,'a',7,'s'),(2,'b',8,'s'),(3,'c',7,'s')});
my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0',
    domain_fingerprint => 'sha256:api-write-parity', name => 'Records',
    source => {source_table => 'records', primary_key => 'id',
        fields => [qw(id name tenant_id secret)],
        columns => {id => {type => 'integer'}, name => {type => 'string'},
            tenant_id => {type => 'integer'}, secret => {type => 'string', internal => 1}},
        associations => {}}, schemas => {}, joins => {},
    writes => {operations => {
        insert => {enabled => 1}, update => {enabled => 1, bulk => 1},
        delete => {enabled => 1, bulk => 1},
        upsert => {enabled => 1, conflict_targets => [['id']]}},
        fields => {id => {insertable => 1}, name => {insertable => 1, updatable => 1},
            tenant_id => {insertable => 1}}},
});
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $engine = Selecto::Engine->new(
    domain => $domain->with_required_predicate(Selecto::Expression->eq('tenant_id',7)),
    adapter => $adapter);
my $handler = Selecto::API::EngineHandler->new;
my $one = {operation => 'update', assignments => {name => 'single'},
    filters => [{field => 'id', op => 'eq', value => 1}], returning => ['id','name']};
is_deeply $handler->write($engine,$one),
    {operation => 'update', affected_rows => 1, values => {id => 1, name => 'single'}},
    'Perl returning is a values object';
my $bulk = {operation => 'update', assignments => {name => 'bulk'},
    filters => [{field => 'id', op => 'gte', value => 1}], expected_count => 2, returning => ['name']};
is_deeply $handler->write($engine,$bulk),
    {operation => 'update', affected_rows => 2, values => {name => 'bulk'}},
    'Perl bulk returning exposes the first returned record and total affected count';
my $mismatch = {%$bulk, assignments => {name => 'rollback'}, expected_count => 1};
ok !eval { $handler->write($engine,$mismatch); 1 }, 'mismatch rejects';
is_deeply $dbh->selectall_arrayref('SELECT id,name FROM records ORDER BY id'),
    [[1,'bulk'],[2,'b'],[3,'bulk']], 'mismatch rolls back all rows and scope protects the other tenant';
my $insert = {operation => 'insert', assignments => {id => 4, name => 'inserted', tenant_id => 7},
    returning => ['id','name']};
is_deeply $handler->write($engine,$insert)->{values}, {id => 4, name => 'inserted'}, 'insert returning';
my $upsert = {operation => 'upsert', assignments => {id => 4, name => 'upserted', tenant_id => 7},
    conflict_target => ['id'], upsert_update_fields => ['name'], returning => ['name']};
is_deeply $handler->write($unscoped,$upsert)->{values}, {name => 'upserted'}, 'unscoped upsert returning';
my $delete = {operation => 'delete', filters => [{field => 'id', op => 'in', value => [1,2,3]}],
    expected_count => 2, returning => ['name']};
is_deeply $handler->write($engine,$delete),
    {operation => 'delete', affected_rows => 2, values => {name => 'bulk'}}, 'bulk delete returning';
is_deeply $dbh->selectall_arrayref('SELECT id,name FROM records ORDER BY id'),
    [[2,'b'],[4,'upserted']], 'only scoped records were deleted';

my $duplicate = eval {
    $handler->write($unscoped, {operation => 'insert',
        assignments => {id => 4, name => 'duplicate', tenant_id => 7}});
    undef;
} // $@;
is $duplicate->code, 'database_unique_violation',
    'live PostgreSQL duplicate key retains its public error code';
is_deeply $duplicate->details, {constraint => 'unique', fields => ['id']},
    'live duplicate key reports the field without leaking its value';

my $missing_database_field = eval {
    $handler->write($unscoped, {operation => 'insert',
        assignments => {id => 5, name => undef, tenant_id => 7}});
    undef;
} // $@;
is $missing_database_field->code, 'database_not_null_violation',
    'live PostgreSQL not-null failure retains its public error code';
is_deeply $missing_database_field->details,
    {constraint => 'not_null', field => 'name', relation => 'records'},
    'live not-null failure reports field and relation without row values';
$dbh->do('ALTER TABLE records ADD FOREIGN KEY (tenant_id) REFERENCES records(id) NOT VALID');
$dbh->do(q{ALTER TABLE records ADD CHECK (name <> 'invalid')});
my $missing_reference = eval {
    $handler->write($unscoped, {operation => 'insert',
        assignments => {id => 5, name => 'private missing parent', tenant_id => 9}});
    undef;
} // $@;
is $missing_reference->code, 'database_foreign_key_violation',
    'live PostgreSQL foreign-key failure retains its public error code';
is $missing_reference->message, 'A referenced record does not exist or is not available.',
    'foreign-key message does not reveal the missing key';
is_deeply $missing_reference->details, {constraint => 'foreign_key'},
    'foreign-key details contain only the safe category';

my $failed_check = eval {
    $handler->write($unscoped, {operation => 'insert',
        assignments => {id => 5, name => 'invalid', tenant_id => 2}});
    undef;
} // $@;
is $failed_check->code, 'database_check_violation',
    'live PostgreSQL check failure retains its public error code';
is $failed_check->message, 'A database validation constraint was not satisfied.',
    'check message does not reveal the rejected row';
is_deeply $failed_check->details, {constraint => 'check'},
    'check details contain only the safe category';
is_deeply $dbh->selectall_arrayref('SELECT id,name FROM records ORDER BY id'),
    [[2,'b'],[4,'upserted']], 'all failed inserts leave persisted rows unchanged';
$dbh->disconnect;
done_testing;
