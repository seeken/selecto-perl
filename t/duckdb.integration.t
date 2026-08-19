use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;

plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };

my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do('CREATE TABLE selecto_perl_duckdb_items (id integer primary key, name varchar not null, active boolean not null, total decimal(12,2) not null)');
$dbh->do(q{INSERT INTO selecto_perl_duckdb_items VALUES (1, 'baseline', true, 10.50)});

my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
my $domain = Selecto::Domain->new(
    name => 'DuckDBItems', table => 'selecto_perl_duckdb_items',
    fields => { id => 'integer', name => 'string', active => 'boolean', total => 'decimal' },
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $query = $engine->query->select(qw(id name active total))
    ->where(Selecto::Expression->eq(name => q{baseline' OR 1=1 --}));

like($engine->compile($query)->sql, qr/"s0"\."name" = \?/, 'DuckDB uses prepared positional parameters');
is_deeply($engine->all($query)->{rows}, [], 'bound injection-shaped input remains data');
is($adapter->normalize_type('timestamp'), 'naive_datetime', 'DuckDB types normalize portably');
ok($adapter->supports('transactions'), 'DuckDB declares transaction support');

my $upsert = Selecto::Write::Command->new(
    operation => 'upsert', relation => 'selecto_perl_duckdb_items',
    assignments => { id => 1, name => 'updated', active => 0, total => '2.50' },
    metadata => { conflict_target => ['id'], upsert_update_fields => [qw(name active total)] },
);
is($engine->execute_write($upsert)->affected_rows, 1, 'DuckDB reports native upsert rows');

my $insert = Selecto::Write::Command->new(
    operation => 'insert', relation => 'selecto_perl_duckdb_items',
    assignments => { id => 2, name => 'must-roll-back', active => 1, total => '1.00' },
);
my $missing = Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_duckdb_items',
    assignments => { name => 'never' },
    predicate => Selecto::Expression->eq(id => 999),
);
eval { $engine->execute_batch(Selecto::Write::Batch->new($insert, $missing)); 1 };
is($@->code, 'cardinality_mismatch', 'DuckDB reports portable batch cardinality errors');
is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_duckdb_items'), 1, 'DuckDB rolls back the batch atomically');

$dbh->disconnect;
done_testing;
