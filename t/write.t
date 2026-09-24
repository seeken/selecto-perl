use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();

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
my $result = $adapter->execute_write_unsafe($command);
is_deeply($result->to_hash, { operation => 'update', affected_rows => 1 }, 'write result reports logical affected rows');
is_deeply($dbh->events, ['BEGIN', 'COMMIT'], 'single write is transactional');

my $existing_transaction_dbh = TestSelecto::DBH->new({affected => 1});
$existing_transaction_dbh->{AutoCommit} = 0;
my $existing_transaction_adapter = Selecto::PostgreSQL->new(
    dbh => $existing_transaction_dbh,
);
$existing_transaction_adapter->execute_write_unsafe($command);
is_deeply $existing_transaction_dbh->events, ['COMMIT'],
    'managed writes reuse an already-open DBI transaction without begin_work noise';

my $failed_write_dbh = TestSelecto::DBH->new({
    execute_error => 'invalid input syntax for type date',
});
my $failed_write_adapter = Selecto::PostgreSQL->new(dbh => $failed_write_dbh);
my $execution_error = eval {
    $failed_write_adapter->execute_write_unsafe(Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => {id => 9},
        metadata => {returning => ['id']},
    ));
    undef;
} // $@;
is $execution_error->code, 'query_error',
    'a false DBI execute result is reported as an execution error';
isnt $execution_error->code, 'write_returning_missing',
    'a failed write is not masked as a missing RETURNING row';
is_deeply $failed_write_dbh->events, ['BEGIN', 'ROLLBACK'],
    'a false DBI execute result rolls back the managed transaction';

my $constraint_error = $failed_write_adapter->normalize_error(
    qq{DBD::Pg::st execute failed: ERROR: null value in column "lic_no" of relation "truck" violates not-null constraint},
);
is $constraint_error->code, 'database_not_null_violation',
    'PostgreSQL not-null failures retain a specific public error code';
is $constraint_error->message, 'Required field lic_no was not provided.',
    'PostgreSQL not-null failures identify the omitted field';
is_deeply $constraint_error->details, {
    constraint => 'not_null', field => 'lic_no', relation => 'truck',
}, 'constraint errors expose safe machine-readable context without row values';

my $unique_error = $failed_write_adapter->normalize_error(
    qq{ERROR: duplicate key value violates unique constraint "items_code_key"\nDETAIL: Key (tenant_id, code)=(41, secret) already exists.},
);
is $unique_error->code, 'database_unique_violation',
    'PostgreSQL unique failures retain a specific public error code';
is_deeply $unique_error->details, {
    constraint => 'unique', fields => [qw(tenant_id code)],
}, 'unique errors expose field names but never conflicting values';

my $external_dbh = TestSelecto::DBH->new({ affected => 1 });
$external_dbh->{AutoCommit} = 0;
my $external = Selecto::PostgreSQL->new(dbh => $external_dbh, transaction_mode => 'external');
my $external_result = $external->execute_write_unsafe($command);
is($external_result->affected_rows, 1, 'external transaction mode executes the write');
is_deeply($external_dbh->events, [],
    'external transaction mode leaves begin, commit, and rollback to the caller');

my $autocommit_dbh = TestSelecto::DBH->new({ affected => 1 });
$autocommit_dbh->{AutoCommit} = 1;
my $unsafe_external = Selecto::PostgreSQL->new(
    dbh => $autocommit_dbh, transaction_mode => 'external',
);
eval { $unsafe_external->execute_write_unsafe($command) };
is($@->code, 'invalid_adapter', 'external mode fails closed when AutoCommit is enabled');
is_deeply($autocommit_dbh->events, [], 'rejected external transaction dispatches nothing');

my $invalid_mode = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new, transaction_mode => 'sometimes');
eval { $invalid_mode->execute_write_unsafe($command) };
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
eval { $rollback_adapter->execute_batch_unsafe(Selecto::Write::Batch->new($insert, $missing)) };
is($@->code, 'cardinality_mismatch', 'batch rejects an unexpected row count');
is_deeply($rollback_dbh->events, ['BEGIN', 'ROLLBACK'], 'failed batch rolls back atomically');

eval {
    $adapter->preview_write(Selecto::Write::Command->new(
        operation => 'insert', relation => 'items;drop_table', assignments => { id => 1 },
    ));
};
is($@->code, 'invalid_identifier', 'write relation cannot smuggle SQL');

my $guard_error = eval {
    $adapter->preview_write(Selecto::Write::Command->new(
        operation => 'insert', relation => 'items', assignments => {name => 'unscoped'},
        scope_predicate => Selecto::Expression->eq('tenant_id', 7),
    ));
    undef;
} // $@;
is $guard_error->code, 'query_rule_not_evaluable',
    'an insert missing a query-guard field remains rejected';
is $guard_error->message, 'query rule requires insert field tenant_id',
    'the query-guard error identifies the omitted insert field';
is_deeply $guard_error->details, {
    field => 'tenant_id', missing_fields => ['tenant_id'],
}, 'the query-guard error includes a machine-readable missing field';

for my $expected (2, 1) {
    my $returning_dbh = TestSelecto::DBH->new({ affected => 0, rows => [[7], [8]] });
    my $returning_adapter = Selecto::PostgreSQL->new(dbh => $returning_dbh);
    my $returning_command = Selecto::Write::Command->new(
        operation => 'update', relation => 'items', assignments => { name => 'after' },
        predicate => Selecto::Expression->gt('id', 0), expected_count => $expected,
        metadata => { returning => ['id'] },
    );
    my $returned = eval { $returning_adapter->execute_write_unsafe($returning_command) };
    if ($expected == 2) {
        is_deeply($returned->to_hash, {operation => 'update', affected_rows => 2, values => {id => 7}},
            'returning counts all returned rows rather than a provisional driver count');
        is_deeply($returning_dbh->events, ['BEGIN', 'COMMIT'], 'exhausted returning write commits');
    } else {
        is($@->code, 'cardinality_mismatch', 'returning detects a multi-row cardinality mismatch');
        is_deeply($returning_dbh->events, ['BEGIN', 'ROLLBACK'], 'returning mismatch rolls back');
    }
    is($returning_dbh->prepared->[0]{index}, 2, 'entire returning result is consumed');
}

done_testing;
