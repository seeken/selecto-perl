use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Selecto;
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';

plan skip_all => 'DBD::ODBC is not installed' unless eval { require DBD::ODBC; 1 };
plan skip_all => 'SELECTO_PERL_TEST_MSSQL_URL is not configured'
    unless defined($ENV{SELECTO_PERL_TEST_MSSQL_URL}) && $ENV{SELECTO_PERL_TEST_MSSQL_URL} ne '';

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts(
    $ENV{SELECTO_PERL_TEST_MSSQL_URL}, 'mssql'
);
my $dbh = DBI->connect($dsn, $username, $password, {
    RaiseError => 1,
    PrintError => 0,
    AutoCommit => 1,
});
ok($dbh->{odbc_has_unicode}, 'DBD::ODBC was built with Unicode support');

my $table = 'selecto_perl_mssql_products';
$dbh->do("DROP TABLE IF EXISTS [$table]");
$dbh->do("CREATE TABLE [$table] (id int primary key, external_id nvarchar(80) not null unique, name nvarchar(120) not null, active bit not null, amount decimal(30,2) not null)");
$dbh->do("INSERT INTO [$table] VALUES (1, N'baseline', N'Renée 東京', 1, 10.50), (2, N'exact', N'precision', 0, 1234567890123456789012345678.90)");

my $domain = Selecto::Domain->new(
    name => 'Products',
    table => $table,
    fields => {
        id => 'integer', external_id => 'string', name => 'string',
        active => 'boolean', amount => 'decimal',
    },
);
my $adapter = Selecto->adapter(mssql => (dbh => $dbh));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

my $result = $engine->all(
    $engine->query->select('id', 'name', 'active', 'amount')
        ->where(Selecto::Expression->eq('external_id', 'baseline'))
);
is_deeply(
    $result,
    { columns => [qw(id name active amount)], rows => [[1, 'Renée 東京', 1, '10.5']] },
    'SQL Server executes a public Unicode query with exact typed values',
);

my $exact = $engine->all(
    $engine->query->select('amount')->where(Selecto::Expression->eq('external_id', 'exact'))
);
is(
    $exact->{rows}[0][0],
    '1234567890123456789012345678.9',
    'SQL Server preserves a 30-digit decimal without floating-point conversion',
);

my $attack = q{baseline'; DROP TABLE [selecto_perl_mssql_products]; --};
my $attack_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('external_id', $attack))
);
is_deeply($attack_result->{rows}, [], 'attack-shaped input remains a bound value');
is($dbh->selectrow_array("SELECT count(*) FROM [$table]"), 2, 'attack-shaped input cannot change the table');

my $upsert = Selecto::Write::Command->new(
    operation => 'upsert',
    relation => $table,
    assignments => {
        id => 1, external_id => 'baseline', name => 'after', active => 1, amount => '20.25',
    },
    metadata => {
        conflict_target => ['external_id'],
        upsert_update_fields => ['name', 'amount'],
    },
);
is($engine->execute_write($upsert)->affected_rows, 1, 'SQL Server inserts or updates one logical upsert row');
is($engine->execute_write($upsert)->affected_rows, 1, 'SQL Server normalizes a repeated upsert to one logical row');

my $first = Selecto::Write::Command->new(
    operation => 'insert', relation => $table,
    assignments => {
        id => 3, external_id => 'rollback', name => 'must-roll-back', active => 0, amount => '30.00',
    },
);
my $missing = Selecto::Write::Command->new(
    operation => 'update', relation => $table,
    assignments => { name => 'never' },
    predicate => Selecto::Expression->eq('external_id', 'missing'),
);
my $ok = eval { $engine->execute_batch(Selecto::Write::Batch->new($first, $missing)); 1 };
ok(!$ok, 'a failed exact-cardinality batch is rejected');
isa_ok($@, 'Selecto::Error');
is($@->code, 'cardinality_mismatch', 'the failed batch uses the portable error contract');
is($dbh->selectrow_array("SELECT count(*) FROM [$table]"), 2, 'the failed batch rolls back atomically');

$dbh->do("DROP TABLE [$table]");
$dbh->disconnect;

done_testing;
