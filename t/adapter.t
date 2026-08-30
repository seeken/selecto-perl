use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use lib 't/fixtures/Selecto-Adapter-FutureDB/lib';
use TestSelecto;
use Selecto;

is_deeply(
    [grep { exists $INC{$_} } qw(
        Selecto/DuckDB.pm
        Selecto/MariaDB.pm
        Selecto/MSSQL.pm
        Selecto/MySQL.pm
        Selecto/PostgreSQL.pm
        Selecto/SQLite.pm
    )],
    [],
    'loading the core leaves concrete adapters unloaded',
);

my $dbh = TestSelecto::DBH->new;
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
isa_ok($adapter, 'Selecto::PostgreSQL', 'default registry builds PostgreSQL by name');
my $sqlite = Selecto->adapter(sqlite => (dbh => $dbh));
isa_ok($sqlite, 'Selecto::SQLite', 'default registry builds SQLite by name');
my $duckdb = Selecto->adapter(duckdb => (dbh => $dbh));
isa_ok($duckdb, 'Selecto::DuckDB', 'default registry builds DuckDB by name');
my $mysql = Selecto->adapter(mysql => (dbh => $dbh));
isa_ok($mysql, 'Selecto::MySQL', 'default registry builds MySQL by name');
my $mariadb = Selecto->adapter(mariadb => (dbh => $dbh));
isa_ok($mariadb, 'Selecto::MariaDB', 'default registry builds MariaDB by name');
my $mssql = Selecto->adapter(mssql => (dbh => $dbh));
isa_ok($mssql, 'Selecto::MSSQL', 'default registry builds Microsoft SQL Server by name');
is_deeply(
    Selecto->available_adapters,
    ['duckdb', 'mariadb', 'mssql', 'mysql', 'postgresql', 'sqlite'],
    'available adapter names are discoverable',
);
is($adapter->contract_version, 1, 'adapter contract is versioned');

eval { Selecto->adapter(oracle => (dbh => $dbh)) };
is($@->code, 'unknown_adapter', 'unregistered databases fail with a portable adapter error');

require Selecto::Adapter::FutureDB;
my $future = Selecto->adapter(futuredb => (dbh => $dbh));
isa_ok($future, 'Selecto::Adapter', 'a separately implemented database can register without core changes');
is($future->name, 'futuredb', 'registered adapter retains its portable name');

eval {
    Selecto::Adapter::Registry->default->register(
        futuredb => 'Selecto::Adapter::FutureDB',
        contract_version => 1,
    );
};
is($@->code, 'duplicate_adapter', 'duplicate stable adapter names fail closed');

eval {
    Selecto::Adapter::Registry->new->register(
        legacydb => 'Selecto::Adapter::FutureDB',
        contract_version => 999,
    );
};
is($@->code, 'adapter_contract_mismatch', 'adapter contract version mismatches fail closed');

done_testing;
