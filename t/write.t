use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;

my $dbh = TestSelecto::DBH->new({ affected => 1 });
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $command = Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { name => 'after' },
    predicate => Selecto::Expression->eq('id', 7),
);
is_deeply($adapter->preview_write($command), {
    sql => 'UPDATE "items" SET "name" = $1 WHERE "id" = $2',
    params => ['after', 7],
}, 'portable update preview separates SQL and params');
my $result = $adapter->execute_write($command);
is_deeply($result->to_hash, { operation => 'update', affected_rows => 1 }, 'write result reports logical affected rows');
is_deeply($dbh->events, ['BEGIN', 'COMMIT'], 'single write is transactional');

my $external_dbh = TestSelecto::DBH->new({ affected => 1 });
$external_dbh->{AutoCommit} = 0;
my $external = Selecto::PostgreSQL->new(dbh => $external_dbh, transaction_mode => 'external');
my $external_result = $external->execute_write($command);
is($external_result->affected_rows, 1, 'external transaction mode executes the write');
is_deeply($external_dbh->events, [],
    'external transaction mode leaves begin, commit, and rollback to the caller');

my $autocommit_dbh = TestSelecto::DBH->new({ affected => 1 });
$autocommit_dbh->{AutoCommit} = 1;
my $unsafe_external = Selecto::PostgreSQL->new(
    dbh => $autocommit_dbh, transaction_mode => 'external',
);
eval { $unsafe_external->execute_write($command) };
is($@->code, 'invalid_adapter', 'external mode fails closed when AutoCommit is enabled');
is_deeply($autocommit_dbh->events, [], 'rejected external transaction dispatches nothing');

my $invalid_mode = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new, transaction_mode => 'sometimes');
eval { $invalid_mode->execute_write($command) };
is($@->code, 'invalid_adapter', 'unknown transaction mode fails closed');

my $rollback_dbh = TestSelecto::DBH->new({ affected => 1 }, { affected => 0 });
my $rollback_adapter = Selecto::PostgreSQL->new(dbh => $rollback_dbh);
my $insert = Selecto::Write::Command->new(
    operation => 'insert', relation => 'items', assignments => { id => 8, name => 'temporary' },
);
my $missing = Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { name => 'never' },
    predicate => Selecto::Expression->eq('id', 999),
);
eval { $rollback_adapter->execute_batch(Selecto::Write::Batch->new($insert, $missing)) };
is($@->code, 'cardinality_mismatch', 'batch rejects an unexpected row count');
is_deeply($rollback_dbh->events, ['BEGIN', 'ROLLBACK'], 'failed batch rolls back atomically');

eval {
    $adapter->preview_write(Selecto::Write::Command->new(
        operation => 'insert', relation => 'items;drop_table', assignments => { id => 1 },
    ));
};
is($@->code, 'invalid_identifier', 'write relation cannot smuggle SQL');

done_testing;
