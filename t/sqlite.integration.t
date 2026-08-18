use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
});
$dbh->do('CREATE TABLE selecto_perl_test_items (id integer primary key, name text not null, amount decimal(12,2))');
$dbh->do(q{INSERT INTO selecto_perl_test_items VALUES (1, 'Renée 東京', 10.50)});

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'selecto_perl_test_items',
    fields => { id => 'integer', name => 'string', amount => 'decimal' },
);
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $result = $engine->all($engine->query->select('id', 'name', 'amount')->order_by('id'));
is_deeply(
    $result,
    { columns => ['id', 'name', 'amount'], rows => [[1, 'Renée 東京', 10.5]] },
    'public query API executes through DBD::SQLite',
);

is($adapter->placeholder(2), '?', 'SQLite uses DBI positional placeholders');
is($adapter->normalize_type('datetime'), 'naive_datetime', 'SQLite types normalize portably');
ok($adapter->supports('transactions'), 'SQLite declares transaction support');
ok(!$adapter->supports('returning'), 'SQLite does not overclaim unimplemented returning support');

my $unsupported = $engine->query->select(Selecto::Expression->datetime_format('name', 'month'));
eval { $engine->compile($unsupported) };
is($@->code, 'invalid_query', 'dialect-specific expressions fail closed until SQLite translations exist');

my $first = Selecto::Write::Command->new(
    operation => 'insert', relation => 'selecto_perl_test_items',
    assignments => { id => 2, name => 'must-roll-back', amount => 20 },
);
my $second = Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_test_items', assignments => { name => 'never' },
    predicate => Selecto::Expression->eq('id', 999),
);
eval { $engine->execute_batch(Selecto::Write::Batch->new($first, $second)) };
is($@->code, 'cardinality_mismatch', 'live batch reports a portable cardinality error');
is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_test_items'), 1, 'failed live batch rolls back atomically');

$dbh->disconnect;
done_testing;
