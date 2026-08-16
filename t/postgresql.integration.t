use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::Certification ();

my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
my $dbh = DBI->connect($dsn, $username, $password, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1,
});
$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_items');
$dbh->do('CREATE TABLE selecto_perl_test_items (id integer primary key, name text not null)');
$dbh->do(q{INSERT INTO selecto_perl_test_items VALUES (1, 'baseline')});

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'selecto_perl_test_items', fields => { id => 'integer', name => 'string' },
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
my $result = $engine->all($engine->query->select('id', 'name')->order_by('id'));
is_deeply($result, { columns => ['id', 'name'], rows => [[1, 'baseline']] }, 'public query API executes through DBD::Pg');

my $first = Selecto::Write::Command->new(
    operation => 'insert', relation => 'selecto_perl_test_items', assignments => { id => 2, name => 'must-roll-back' },
);
my $second = Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_test_items', assignments => { name => 'never' },
    predicate => Selecto::Expression->eq('id', 999),
);
eval { $engine->execute_batch(Selecto::Write::Batch->new($first, $second)) };
is($@->code, 'cardinality_mismatch', 'live batch reports portable cardinality error');
is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_test_items'), 1, 'failed live batch rolls back atomically');

$dbh->do('DROP TABLE IF EXISTS selecto_perl_test_items');
$dbh->disconnect;
done_testing;
