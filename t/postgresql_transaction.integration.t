use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;

# Selecto writes on a PostgreSQL handle the host lends while its own
# transaction is open: savepoints, never the host's commit or rollback.

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
my $connect = sub {
    my (%attributes) = @_;
    return DBI->connect($dsn, $username, $password, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1, %attributes,
    });
};
my $table = 'selecto_perl_test_tx_items';
my $dbh = $connect->();
my $observer = $connect->();
$dbh->do('SET client_min_messages TO warning');

my $domain = Selecto::Domain->new(
    name => 'Items', table => $table, fields => { id => 'integer', name => 'string' },
);
my $engine_for = sub {
    my ($handle, %options) = @_;
    return Selecto::Engine->new(
        domain => $domain, write_policy => 'permissive',
        adapter => Selecto->adapter(postgresql => (dbh => $handle, %options)),
    );
};
my $insert = sub {
    my ($id) = @_;
    return Selecto::Write::Command->new(
        operation => 'insert', relation => $table,
        assignments => { id => $id, name => "item $id" }, expected_count => 1,
    );
};
my $update = sub {
    my ($id, $name) = @_;
    return Selecto::Write::Command->new(
        operation => 'update', relation => $table, assignments => { name => $name },
        predicate => Selecto::Expression->eq('id', $id), expected_count => 1,
    );
};
my $committed = sub {
    return [map { $_->[0] } @{$observer->selectall_arrayref("SELECT id FROM $table ORDER BY id")}];
};
my $error_of = sub {
    my ($code) = @_;
    return eval { $code->(); 1 } ? undef : $@;
};
my $reset = sub {
    $dbh->rollback unless $dbh->{AutoCommit};
    $dbh->do("DROP TABLE IF EXISTS $table");
    $dbh->do("CREATE TABLE $table (id integer primary key, name text not null)");
    $dbh->do("INSERT INTO $table VALUES (1, 'baseline')");
};

my $engine = $engine_for->($dbh);

subtest 'standalone write commits as before' => sub {
    $reset->();
    $engine->execute_write($insert->(2));
    is($dbh->pg_ping, 1, 'the connection is idle afterwards');
    is_deeply($committed->(), [1, 2], 'the write committed on its own');
};

subtest 'host begin_work, Selecto write, host rollback' => sub {
    $reset->();
    $dbh->begin_work;
    $engine->execute_write($insert->(2));
    $engine->execute_batch(Selecto::Write::Batch->new($insert->(3), $update->(1, 'renamed')));
    ok(!$dbh->{AutoCommit}, 'the write does not end the host transaction');
    is($dbh->pg_ping, 3, 'the server is still inside the host transaction');
    is_deeply($committed->(), [1], 'nothing is visible outside the host transaction');
    $dbh->rollback;
    is_deeply($committed->(), [1], 'the host rollback undid the writes');
    is($observer->selectrow_array("SELECT name FROM $table WHERE id = 1"), 'baseline', 'the update was undone too');
};

subtest 'failed write rolls back only its savepoint' => sub {
    $reset->();
    $dbh->begin_work;
    $dbh->do("INSERT INTO $table VALUES (5, 'host')");
    $engine->execute_write($insert->(6));
    my $duplicate = $error_of->(sub { $engine->execute_batch(Selecto::Write::Batch->new($insert->(7), $insert->(1))) });
    is($duplicate->code, 'database_unique_violation', 'the duplicate keeps its specific error');
    my $mismatch = $error_of->(sub { $engine->execute_write($update->(999, 'never')) });
    is($mismatch->code, 'cardinality_mismatch', 'a cardinality mismatch is reported');
    is($dbh->pg_ping, 3, 'the host transaction is still usable, not aborted');
    $dbh->do("INSERT INTO $table VALUES (8, 'host again')");
    $dbh->commit;
    is_deeply($committed->(), [1, 5, 6, 8], 'the host commit keeps its work and the successful write only');
};

subtest 'write inside an already failed host transaction' => sub {
    $reset->();
    $dbh->begin_work;
    ok(!eval { $dbh->do("SELECT missing_column FROM $table"); 1 }, 'the host transaction fails');
    my $error = $error_of->(sub { $engine->execute_write($insert->(2)) });
    isa_ok($error, 'Selecto::Error', 'the write');
    is($error->code, 'query_error', 'is a query_error');
    is($dbh->pg_ping, 4, 'the host transaction is left for the host to roll back');
    $dbh->rollback;
    is_deeply($committed->(), [1], 'nothing committed');
};

subtest 'raw BEGIN with AutoCommit on is detected' => sub {
    $reset->();
    $dbh->do('BEGIN');
    $engine->execute_write($insert->(2));
    is($dbh->pg_ping, 3, 'the raw transaction is still open');
    $dbh->do('ROLLBACK');
    is_deeply($committed->(), [1], 'the write rolled back with the raw transaction');
};

subtest 'AutoCommit => 0 handle' => sub {
    $reset->();
    my $manual = $connect->(AutoCommit => 0);
    my $manual_engine = $engine_for->($manual);
    $manual_engine->execute_write($insert->(2));
    is_deeply($committed->(), [1], 'a managed write does not commit an AutoCommit => 0 handle');
    $manual->rollback;
    is_deeply($committed->(), [1], 'the host rollback discards it');
    $manual_engine->execute_write($insert->(3));
    ok($error_of->(sub { $manual_engine->execute_write($insert->(3)) }), 'a duplicate fails');
    $manual_engine->execute_write($insert->(4));
    $manual->commit;
    is_deeply($committed->(), [1, 3, 4], 'the host commit keeps the successful writes');
    $manual->disconnect;
};

subtest 'external mode is unchanged' => sub {
    $reset->();
    my $external = $engine_for->($dbh, transaction_mode => 'external');
    is($error_of->(sub { $external->execute_write($insert->(2)) })->code, 'invalid_adapter',
        'external mode refuses an AutoCommit handle');
    $dbh->begin_work;
    $external->execute_write($insert->(2));
    is_deeply($committed->(), [1], 'external writes are not committed by Selecto');
    $dbh->commit;
    is_deeply($committed->(), [1, 2], 'the host commits them');
};

$dbh->rollback unless $dbh->{AutoCommit};
$dbh->do("DROP TABLE IF EXISTS $table");
$observer->disconnect;
$dbh->disconnect;
done_testing;
