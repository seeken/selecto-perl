use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;

my $dbh = TestSelecto::DBH->new;
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
isa_ok($adapter, 'Selecto::PostgreSQL', 'default registry builds PostgreSQL by name');
my $sqlite = Selecto->adapter(sqlite => (dbh => $dbh));
isa_ok($sqlite, 'Selecto::SQLite', 'default registry builds SQLite by name');
my $mysql = Selecto->adapter(mysql => (dbh => $dbh));
isa_ok($mysql, 'Selecto::MySQL', 'default registry builds MySQL by name');
my $mariadb = Selecto->adapter(mariadb => (dbh => $dbh));
isa_ok($mariadb, 'Selecto::MariaDB', 'default registry builds MariaDB by name');
is_deeply(
    Selecto->available_adapters,
    ['mariadb', 'mysql', 'postgresql', 'sqlite'],
    'available adapter names are discoverable',
);
is($adapter->contract_version, 1, 'adapter contract is versioned');

eval { Selecto->adapter(oracle => (dbh => $dbh)) };
is($@->code, 'unknown_adapter', 'unregistered databases fail with a portable adapter error');

{
    package TestSelecto::FutureAdapter;
    use Mojo::Base 'Selecto::Adapter';
    sub name { return 'futuredb'; }
    sub dialect { return __PACKAGE__; }
    sub compile { return Selecto::Statement->new(sql => 'SELECT 1', adapter_name => 'futuredb'); }
    sub execute_query { return { columns => [], rows => [] }; }
    sub preview_write { return {}; }
    sub execute_write { return {}; }
    sub execute_batch { return []; }
}

$INC{'TestSelecto/FutureAdapter.pm'} = __FILE__;
my $registry = Selecto::Adapter::Registry->new
    ->register(futuredb => 'TestSelecto::FutureAdapter');
my $future = $registry->build(futuredb => (dbh => $dbh));
isa_ok($future, 'Selecto::Adapter', 'a separately implemented database can register without core changes');
is($future->name, 'futuredb', 'registered adapter retains its portable name');

done_testing;
