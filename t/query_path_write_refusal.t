use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;
use Selecto;

# The query path (execute_query and stream_query) never persists a write.
# SQL taken from a write preview, a raw data-modifying statement, a
# data-modifying CTE, several statements in one string, or transaction
# control handed to it leaves every row unchanged, whether the handle is in
# AutoCommit or inside a host transaction that commits afterwards. Governed
# reads keep working in both, and the host's transaction state is restored.

my $table = 'selecto_perl_qpath_items';
my @baseline = ([1, 'a'], [2, 'b']);
my $domain = TestSelecto::writable_domain(
    name => 'Items', table => $table, fields => { id => 'integer', name => 'string' },
);

sub error_of {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

sub code_of {
    my ($error) = @_;
    return 'no error' unless defined $error;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "unstructured: $error";
}

sub rows_of {
    my ($dbh) = @_;
    return [map { [0 + $_->[0], "$_->[1]"] }
        @{$dbh->selectall_arrayref("SELECT id, name FROM $table ORDER BY id")}];
}

sub statement {
    my ($adapter, $sql, @params) = @_;
    return Selecto::Statement->new(
        sql => $sql, params => \@params, columns => ['id'], adapter_name => $adapter->name,
    );
}

sub command {
    my ($operation, %args) = @_;
    return Selecto::Write::Command->new(operation => $operation, relation => $table, %args);
}

sub drain {
    my ($stream) = @_;
    while ($stream->next) { }
    $stream->close;
    return;
}

# Every way to smuggle a write into the query path, for one adapter: each is
# [label, statement, refused before it reaches the database].
sub attempts {
    my ($backend, $adapter) = @_;
    my $p = sub { return $adapter->placeholder($_[0]); };
    my @previews = (
        command('update', assignments => { name => 'z' },
            predicate => Selecto::Expression->eq('id', 1), expected_count => 1),
        command('insert', assignments => { id => 3, name => 'c' }, expected_count => 1),
        command('delete', predicate => Selecto::Expression->eq('id', 2), expected_count => 1),
    );
    push @previews, command('update', assignments => { name => 'r' },
        predicate => Selecto::Expression->eq('id', 1), expected_count => 1, returning => ['id'])
        if $adapter->write_capabilities->{returning};
    my @attempts = map {
        my $preview = $adapter->preview_write($_);
        ["preview $_->{operation}", statement($adapter, $preview->{sql}, @{$preview->{params}}), 1];
    } @previews;
    my $delete = "DELETE FROM $table WHERE id = 2";
    push @attempts, map { [$_->[0], statement($adapter, @{$_}[1 .. $#$_]), 1] } (
        ['raw insert', "INSERT INTO $table (id, name) VALUES (" . $p->(1) . ', ' . $p->(2) . ')', 4, 'raw'],
        ['raw delete', "DELETE FROM $table WHERE id = " . $p->(1), 2],
        ['commented delete', "/* read */ $delete"],
        ['line-commented delete', "-- read\n$delete"],
        ['parenthesized delete', "($delete)"],
        ['two statements', "SELECT 1 AS id; $delete"],
        ['statement after commit', "SELECT 1 AS id; COMMIT; $delete"],
        ['commit first', "COMMIT; $delete"],
        ['trailing commit', 'SELECT 1 AS id; COMMIT'],
        ['separator in a comment', 'SELECT 1 AS id /* ; */'],
        ['separator in a literal', q{SELECT ';' AS id}],
        ['commit', 'COMMIT'],
        ['NUL character', "SELECT 1 AS id\0$delete"],
        ['DDL', "DROP TABLE $table"],
        ['CREATE TABLE AS', "CREATE TABLE ${table}_copy AS SELECT * FROM $table"],
    );
    push @attempts, map { [$_->[0], statement($adapter, $_->[1]), 1] } (
        ['pragma', 'PRAGMA query_only = 0'],
        ['commit, pragma, delete', "COMMIT; PRAGMA query_only = 0; $delete"],
    ) if $backend eq 'sqlite';
    push @attempts, map { [$_->[0], statement($adapter, $_->[1]), 1] } (
        ['hash-commented delete', "# read\n$delete"],
        ['executable comment', "SELECT 1 AS id /*!50000 , (SELECT 1) */"],
        ['dash without space', "--x\n$delete"],
    ) if $backend eq 'mysql' || $backend eq 'mariadb';
    push @attempts, map { [$_->[0], statement($adapter, $_->[1]), 1] } (
        ['batch commit', "SELECT 1 AS id COMMIT $delete"],
        ['batch rollback', "SELECT 1 AS id ROLLBACK $delete"],
        ['batch exec', "SELECT 1 AS id EXEC('$delete')"],
        ['openrowset', "SELECT * FROM OPENROWSET('SQLNCLI', 'Server=x;', '$delete')"],
    ) if $backend eq 'mssql';
    # Single SELECT or WITH statements the database itself must refuse.
    if ($backend eq 'postgresql') {
        push @attempts,
            ['data-modifying CTE', statement($adapter,
                "WITH changed AS (UPDATE $table SET name = \$1 WHERE id = \$2 RETURNING id) SELECT id FROM changed",
                'cte', 1), 0],
            ['select into', statement($adapter, "SELECT * INTO ${table}_copy FROM $table"), 0];
    }
    # MariaDB has no CTE before DELETE.
    push @attempts, ['CTE before delete', statement($adapter,
        "WITH doomed AS (SELECT 2 AS id) DELETE FROM $table WHERE id IN (SELECT id FROM doomed)"), 0]
        if $backend eq 'sqlite' || $backend eq 'mysql';
    return @attempts;
}

sub exercise {
    my (%args) = @_;
    my ($backend, $connect) = @args{qw(backend connect)};
    my $dbh = $connect->();
    my $observer = $args{observer} ? $connect->() : $dbh;
    my $reset = sub {
        $dbh->do("DROP TABLE IF EXISTS ${table}_copy");
        $dbh->do("DROP TABLE IF EXISTS $table");
        $dbh->do("CREATE TABLE $table (id BIGINT PRIMARY KEY, name VARCHAR(100) NOT NULL)");
        $dbh->do("INSERT INTO $table (id, name) VALUES (1, 'a'), (2, 'b')");
    };
    $reset->();
    my $adapter = Selecto->adapter($backend => (dbh => $dbh));
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    my $no_savepoints = $backend eq 'duckdb';

    for my $attempt (attempts($backend, $adapter)) {
        my ($label, $statement, $unsent) = @$attempt;
        my $error = error_of(sub { $adapter->execute_query($statement) });
        ok($error, "$backend execute refuses $label");
        # SQL Server has no read-only mode: what reaches it is rolled back.
        is(code_of($error), 'invalid_query', "$backend execute names $label an invalid query")
            if $unsent || $backend ne 'mssql';
        is_deeply(rows_of($observer), \@baseline, "$backend execute persists nothing: $label");
        ok($dbh->{AutoCommit}, "$backend execute restores AutoCommit: $label");

        $error = error_of(sub { drain($adapter->stream_query($statement)) });
        ok($error, "$backend stream refuses $label");
        is_deeply(rows_of($observer), \@baseline, "$backend stream persists nothing: $label");
        ok($dbh->{AutoCommit}, "$backend stream restores AutoCommit: $label");

        # A host transaction that commits afterwards.
        $dbh->begin_work;
        $error = error_of(sub { $adapter->execute_query($statement) });
        ok($error, "$backend execute inside a host transaction refuses $label");
        is(code_of($error), 'query_transaction_unsupported',
            "$backend cannot isolate a query inside a host transaction: $label")
            if $no_savepoints && !$unsent;
        is(code_of($error), 'invalid_query', "$backend refuses $label before the database inside a host transaction")
            if $unsent;
        my $stream_error = error_of(sub { drain($adapter->stream_query($statement)) });
        ok($stream_error, "$backend stream inside a host transaction refuses $label");
        ok(!$dbh->{AutoCommit}, "$backend leaves the host transaction open: $label");
        $dbh->commit;
        is_deeply(rows_of($observer), \@baseline, "$backend host commit persists nothing: $label");
        $reset->();
    }

    # One trailing separator is allowed.
    is_deeply($adapter->execute_query(statement($adapter, "SELECT id FROM $table WHERE id = 1;\n"))->{rows},
        [[1]], "$backend runs a single statement with a trailing separator");

    # Governed reads still work, in AutoCommit and inside host transactions.
    my $query = $engine->query->select('id', 'name')->order_by('id');
    is_deeply($engine->all($query)->{rows}, \@baseline, "$backend governed read");
    ok($dbh->{AutoCommit}, "$backend governed read leaves AutoCommit on");
    my $stream = $engine->stream($query, fetch_size => 1);
    is_deeply($stream->next, $baseline[0], "$backend governed stream reads its first row");
    is_deeply($engine->all($query)->{rows}, \@baseline, "$backend reads again while a stream is open");
    is_deeply($stream->next, $baseline[1], "$backend governed stream reads on");
    $stream->close;
    ok($dbh->{AutoCommit}, "$backend governed stream restores AutoCommit");

    $dbh->begin_work;
    $dbh->do("UPDATE $table SET name = 'host' WHERE id = 1");
    if ($no_savepoints) {
        is(code_of(error_of(sub { $engine->all($query) })), 'query_transaction_unsupported',
            "$backend refuses a query inside a host transaction it cannot isolate");
        is(code_of(error_of(sub { $engine->stream($query) })), 'query_transaction_unsupported',
            "$backend refuses a stream inside a host transaction it cannot isolate");
    } else {
        is_deeply($engine->all($query)->{rows}, [[1, 'host'], [2, 'b']],
            "$backend governed read inside a host transaction sees the host's writes");
        drain($engine->stream($query));
        my $error = error_of(sub { $adapter->execute_query(statement($adapter, "DELETE FROM $table")) });
        is(code_of($error), 'invalid_query', "$backend refuses a write inside the host transaction");
        $dbh->do("UPDATE $table SET name = 'host again' WHERE id = 2");
        ok(!$dbh->{AutoCommit}, "$backend governed reads leave the host transaction open");
    }
    $dbh->rollback;
    # DBD::DuckDB 0.16 opens a new transaction after rollback and never ends it.
    $dbh->do('ROLLBACK') if $backend eq 'duckdb';
    is_deeply(rows_of($observer), \@baseline, "$backend host rollback still undoes the host's own writes");

    # A raw transaction the host opened without DBI's begin_work.
    if ($no_savepoints) {
        $dbh->do('BEGIN');
        is(code_of(error_of(sub { $engine->all($query) })), 'query_transaction_unsupported',
            "$backend refuses a query inside a raw host transaction");
        $dbh->do('ROLLBACK');
    }

    $dbh->do("DROP TABLE $table");
    return $dbh;
}

SKIP: {
    skip 'DBD::SQLite is not installed', 1 unless eval { require DBD::SQLite; 1 };
    subtest 'SQLite' => sub {
        my $dbh;
        my $connect = sub {
            return $dbh //= DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
                {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        };
        exercise(backend => 'sqlite', connect => $connect);

        my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
        is($dbh->selectrow_array('PRAGMA query_only'), 0, 'query_only is off again after queries');
        $dbh->do('PRAGMA query_only = ON');
        $adapter->execute_query(statement($adapter, 'SELECT 1 AS id'));
        is($dbh->selectrow_array('PRAGMA query_only'), 1, "the host's query_only setting is restored");
        $dbh->do('PRAGMA query_only = OFF');

        $dbh->do("CREATE TABLE $table (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
        $dbh->do("INSERT INTO $table VALUES (1, 'a'), (2, 'b')");
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
        my $stream = $engine->stream($engine->query->select('id')->order_by('id'), fetch_size => 1);
        $stream->next;
        is(code_of(error_of(sub {
            $engine->execute_write(command('delete', predicate => Selecto::Expression->eq('id', 2)));
        })), 'invalid_adapter', 'a governed write waits for the open stream on its handle');
        $stream->close;
        $engine->execute_write(command('delete', predicate => Selecto::Expression->eq('id', 2)));
        is_deeply(rows_of($dbh), [[1, 'a']], 'the write runs once the stream is closed');
    };
}

SKIP: {
    skip 'DBD::DuckDB is not installed', 1 unless eval { require DBD::DuckDB; 1 };
    subtest 'DuckDB' => sub {
        my $dbh;
        my $connect = sub {
            return $dbh //= DBI->connect('dbi:DuckDB:dbname=:memory:', '', '',
                {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        };
        exercise(backend => 'duckdb', connect => $connect);
    };
}

SKIP: {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    skip 'SELECTO_PERL_TEST_POSTGRES_URL is not configured', 1 unless defined($url) && length $url;
    skip 'DBD::Pg is not installed', 1 unless eval { require DBD::Pg; 1 };
    skip 'Selecto::Certification is not installed', 1 unless eval { require Selecto::Certification; 1 };
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
    my $connect = sub {
        my $handle = DBI->connect($dsn, $username, $password,
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
        $handle->do('SET client_min_messages TO warning');
        return $handle;
    };
    subtest 'PostgreSQL' => sub {
        my $dbh = exercise(backend => 'postgresql', connect => $connect, observer => 1);
        my $observer = $connect->();
        $dbh->do("CREATE TABLE $table (id BIGINT PRIMARY KEY, name VARCHAR(100) NOT NULL)");
        $dbh->do("INSERT INTO $table (id, name) VALUES (1, 'a'), (2, 'b')");
        my $adapter = Selecto->adapter(postgresql => (dbh => $dbh, transaction_mode => 'external'));
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
        my $locked = $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))->for_share;

        # A governed FOR SHARE read keeps its lock for the host's transaction.
        $dbh->begin_work;
        is_deeply($engine->all($locked)->{rows}, [[1]], 'a governed row-lock read runs in the host transaction');
        my $blocked = error_of(sub {
            $observer->do("SELECT id FROM $table WHERE id = 1 FOR UPDATE NOWAIT");
        });
        like("$blocked", qr/could not obtain lock|lock_not_available/i,
            'the share lock is held until the host transaction ends');
        $dbh->do("UPDATE $table SET name = 'locked' WHERE id = 1");
        $dbh->commit;
        is_deeply(rows_of($observer), [[1, 'locked'], [2, 'b']], 'the host commits its write after the locked read');
        $dbh->do("UPDATE $table SET name = 'a' WHERE id = 1");
        is_deeply($engine->all($locked)->{rows}, [[1]], 'a governed row-lock read runs in AutoCommit');
        ok($dbh->{AutoCommit}, 'the row-lock read leaves AutoCommit on');

        # A row-lock statement altered after compilation is no longer trusted.
        my $tampered = $adapter->compile($domain, $locked);
        $tampered->{sql} = "WITH changed AS (UPDATE $table SET name = 'x' RETURNING id) " . $tampered->{sql};
        $dbh->begin_work;
        is(code_of(error_of(sub { $adapter->execute_query($tampered) })), 'invalid_query',
            'an altered row-lock statement is refused inside a host transaction');
        $dbh->commit;
        is_deeply(rows_of($observer), \@baseline, 'the altered statement persisted nothing');

        # A serializable host transaction reads, then writes, then commits.
        $dbh->begin_work;
        $dbh->do('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
        is_deeply($engine->all($engine->query->select('id')->order_by('id'))->{rows}, [[1], [2]],
            'a read inside a serializable host transaction');
        $engine->execute_write(command('update', assignments => { name => 'serial' },
            predicate => Selecto::Expression->eq('id', 2), expected_count => 1));
        $dbh->commit;
        is_deeply(rows_of($observer), [[1, 'a'], [2, 'serial']], 'the host writes and commits after the read');

        # A failed query no longer poisons the host transaction.
        $dbh->begin_work;
        ok(error_of(sub { $adapter->execute_query(statement($adapter, 'SELECT 1 / 0 AS id')) }),
            'a failing query inside a host transaction');
        $dbh->do("UPDATE $table SET name = 'after failure' WHERE id = 1");
        $dbh->commit;
        is_deeply(rows_of($observer), [[1, 'after failure'], [2, 'serial']],
            'the host transaction stays usable after a failed query');

        # A transaction the host opened with SQL, which DBI cannot see.
        my $plain = Selecto->adapter(postgresql => (dbh => $dbh));
        $dbh->do('BEGIN');
        $dbh->do("UPDATE $table SET name = 'raw host' WHERE id = 1");
        is_deeply($plain->execute_query($adapter->compile($domain,
            $engine->query->select('name')->where(Selecto::Expression->eq('id', 1))))->{rows},
            [['raw host']], "a read inside the host's raw transaction sees its write");
        is(code_of(error_of(sub { $plain->execute_query(statement($plain,
            "WITH gone AS (DELETE FROM $table RETURNING id) SELECT id FROM gone")) })),
            'invalid_query', "a write inside the host's raw transaction is refused");
        $dbh->do('COMMIT');
        is_deeply(rows_of($observer), [[1, 'raw host'], [2, 'serial']],
            "the host's raw transaction commits only its own write");

        # PostgreSQL buffers a result client-side, so a stream ends its guard
        # at once and the handle is free while the host consumes it.
        my $managed = Selecto::Engine->new(domain => $domain,
            adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
        my $stream = $managed->stream($managed->query->select('id')->order_by('id'), fetch_size => 1);
        ok($dbh->{AutoCommit}, 'a PostgreSQL stream holds no transaction open');
        $managed->execute_write(command('update', assignments => { name => 'during' },
            predicate => Selecto::Expression->eq('id', 1), expected_count => 1));
        is_deeply([map { $stream->next } 1 .. 2], [[1], [2]], 'the stream still yields its rows');
        $stream->close;
        is_deeply(rows_of($observer), [[1, 'during'], [2, 'serial']], 'a write while the stream is open commits');
        $dbh->do("DROP TABLE $table");
    };
}

for my $specification (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($backend, $environment) = @$specification;
    SKIP: {
        my $url = $ENV{$environment};
        skip "$environment is not configured", 1 unless defined($url) && length $url;
        skip 'DBD::MariaDB is not installed', 1 unless eval { require DBD::MariaDB; 1 };
        skip 'Selecto::Certification is not installed', 1 unless eval { require Selecto::Certification; 1 };
        my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url, $backend);
        subtest $backend => sub {
            exercise(backend => $backend, observer => 1, connect => sub {
                return DBI->connect($dsn, $username, $password,
                    {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
            });
        };
    }
}

SKIP: {
    my $url = $ENV{SELECTO_PERL_TEST_MSSQL_URL};
    skip 'SELECTO_PERL_TEST_MSSQL_URL is not configured', 1 unless defined($url) && length $url;
    skip 'DBD::ODBC is not installed', 1 unless eval { require DBD::ODBC; 1 };
    skip 'Selecto::Certification is not installed', 1 unless eval { require Selecto::Certification; 1 };
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url, 'mssql');
    subtest 'SQL Server' => sub {
        exercise(backend => 'mssql', observer => 1, connect => sub {
            return DBI->connect($dsn, $username, $password,
                {RaiseError => 1, PrintError => 0, AutoCommit => 1, LongReadLen => 1_048_576});
        });
    };
}

done_testing;
