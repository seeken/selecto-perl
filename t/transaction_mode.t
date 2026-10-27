use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use lib 't/lib';
use TestSelecto;
use Selecto;

# How a write's transaction meets the host's: begin/commit on an idle handle,
# a savepoint inside an open transaction and in external mode (which never
# begins or commits; DuckDB has no savepoints and runs the write directly),
# and the host's own transaction API through transaction_handler.

my $domain = TestSelecto::writable_domain(
    name => 'Items', table => 'items', fields => { id => 'integer', name => 'string' },
);

sub insert_command {
    my ($id) = @_;
    return Selecto::Write::Command->new(
        operation => 'insert', relation => 'items',
        assignments => { id => $id, name => "item $id" }, expected_count => 1,
    );
}

sub engine_for {
    my ($adapter) = @_;
    return Selecto::Engine->new(domain => $domain, adapter => $adapter);
}

sub error_of {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

SKIP: {
    skip 'DBD::SQLite is not installed', 1 unless eval { require DBD::SQLite; 1 };

    my $connect = sub {
        my (%attributes) = @_;
        my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
            RaiseError => 1, PrintError => 0, AutoCommit => 1, %attributes,
        });
        $dbh->do('CREATE TABLE items (id integer primary key, name text not null)');
        $dbh->commit unless $dbh->{AutoCommit};
        return $dbh;
    };
    my $ids = sub {
        my ($dbh) = @_;
        return [map { $_->[0] } @{$dbh->selectall_arrayref('SELECT id FROM items ORDER BY id')}];
    };

    subtest 'SQLite' => sub {
        my $dbh = $connect->();
        $dbh->do(q{INSERT INTO items VALUES (1, 'baseline')});
        my $engine = engine_for(Selecto->adapter(sqlite => (dbh => $dbh)));

        $engine->execute_write(insert_command(2));
        ok($dbh->{AutoCommit}, 'a standalone write leaves the handle idle');
        is_deeply($ids->($dbh), [1, 2], 'a standalone write commits on its own');
        $dbh->do('DELETE FROM items WHERE id = 2');

        $dbh->begin_work;
        $engine->execute_write(insert_command(2));
        $engine->execute_batch(Selecto::Write::Batch->new(insert_command(3), insert_command(4)));
        ok(!$dbh->{AutoCommit}, 'the writes do not end the host transaction');
        $dbh->rollback;
        is_deeply($ids->($dbh), [1], 'the writes roll back with the host transaction');

        $dbh->begin_work;
        $dbh->do(q{INSERT INTO items VALUES (5, 'host')});
        my $error = error_of(sub {
            $engine->execute_batch(Selecto::Write::Batch->new(insert_command(6), insert_command(1)));
        });
        isa_ok($error, 'Selecto::Error', 'a failed write inside a host transaction');
        ok(!$dbh->{AutoCommit}, 'a failed write leaves the host transaction open');
        $dbh->do(q{INSERT INTO items VALUES (7, 'host again')});
        $dbh->commit;
        is_deeply($ids->($dbh), [1, 5, 7], 'a failed write undoes only itself and the host commits the rest');

        $dbh->do('BEGIN');
        $engine->execute_write(insert_command(8));
        $dbh->do('ROLLBACK');
        is_deeply($ids->($dbh), [1, 5, 7], 'a transaction opened with raw BEGIN is detected too');

        my $file = $connect->(AutoCommit => 0);
        my $manual = engine_for(Selecto->adapter(sqlite => (dbh => $file)));
        $manual->execute_write(insert_command(1));
        $file->rollback;
        is_deeply($ids->($file), [], 'an AutoCommit => 0 handle is never committed by a managed write');
        $manual->execute_write(insert_command(2));
        $file->commit;
        is_deeply($ids->($file), [2], 'the host commits a managed write on an AutoCommit => 0 handle');

        my $external = engine_for(Selecto->adapter(sqlite => (dbh => $dbh, transaction_mode => 'external')));
        is(error_of(sub { $external->execute_write(insert_command(9)) })->code, 'invalid_adapter',
            'external mode still refuses an AutoCommit handle');
        $dbh->begin_work;
        $external->execute_write(insert_command(9));
        ok(!$dbh->{AutoCommit}, 'external mode leaves the transaction to the host');
        $dbh->rollback;
        is_deeply($ids->($dbh), [1, 5, 7], 'external writes roll back with the host');

        my $calls = 0;
        my $handled = engine_for(Selecto->adapter(sqlite => (
            dbh => $dbh,
            transaction_handler => sub {
                my ($work) = @_;
                ++$calls;
                $dbh->begin_work;
                my $value = eval { $work->() };
                if (my $error = $@) { $dbh->rollback; die $error; }
                $dbh->commit;
                return $value;
            },
        )));
        $handled->execute_write(insert_command(10));
        is($calls, 1, 'a transaction handler runs the write');
        is_deeply($ids->($dbh), [1, 5, 7, 10], 'the handler committed the write');
        my $skipping = engine_for(Selecto->adapter(sqlite => (dbh => $dbh, transaction_handler => sub { 'skipped' })));
        is(error_of(sub { $skipping->execute_write(insert_command(11)) })->code, 'invalid_adapter',
            'a handler that never runs the write fails closed');
        is_deeply($ids->($dbh), [1, 5, 7, 10], 'nothing ran under the skipping handler');
        for my $bad (
            [transaction_handler => 'not code'],
            [transaction_handler => sub { $_[0]->() }, transaction_mode => 'external'],
        ) {
            my $adapter = Selecto->adapter(sqlite => (dbh => $dbh, @$bad));
            is(error_of(sub { engine_for($adapter)->execute_write(insert_command(12)) })->code,
                'invalid_adapter', 'an unusable transaction handler is refused');
        }
        is_deeply($ids->($dbh), [1, 5, 7, 10], 'refused handlers write nothing');
    };
}

# A DBI-shaped handle that records transaction control.
package RecordingDBH {
    sub new {
        my ($class, %options) = @_;
        return bless { AutoCommit => 1, events => [], answers => {}, %options }, $class;
    }
    # Savepoint names are unique per process; number them per handle in the
    # order they appear, so a pair still has to name the same savepoint.
    sub events {
        my (%seen, $count);
        return [map {
            (my $event = $_) =~ s{\bselecto_write_[0-9a-f]+_[0-9a-f]{8}\b}{$seen{$&} //= 'selecto_write_' . ++$count}ge;
            $event;
        } @{$_[0]{events}}];
    }
    sub begin_work {
        my ($self) = @_;
        push @{$self->{events}}, 'begin_work';
        if ($self->{fail_begin}) { $self->{errstr} = 'begin refused'; return undef; }
        $self->{AutoCommit} = 0;
        return 1;
    }
    sub commit {
        my ($self) = @_;
        push @{$self->{events}}, 'commit';
        if ($self->{fail_commit}) { $self->{errstr} = 'commit refused'; return undef; }
        $self->{AutoCommit} = 1;
        return 1;
    }
    sub rollback { push @{$_[0]{events}}, 'rollback'; $_[0]{AutoCommit} = 1; return 1; }
    sub do {
        my ($self, $sql) = @_;
        # The MySQL-family metadata-lock read is catalog, not transaction
        # control: answered without an event.
        return '0E0' if $sql =~ /\bLIMIT 0\z/;
        push @{$self->{events}}, $sql;
        if (defined($self->{fail_do}) && $sql =~ $self->{fail_do}) {
            ($self->{errstr}, $self->{err}) = ("$sql refused", $self->{fail_errno});
            return undef;
        }
        return '0E0';
    }
    sub selectrow_array {
        my ($self, $sql) = @_;
        if (defined($self->{session}) && $sql =~ /SELECT VERSION\(\), \@\@SESSION\.time_zone\b/) {
            push @{$self->{events}}, 'SESSION';
            # VERSION() of the adapter's own server family comes first.
            return (($sql =~ /\ASET STATEMENT / ? '11.4.5-MariaDB' : '8.4.5'),
                @{$self->{session}}[0 .. ($sql =~ /\@\@SESSION\.transaction_read_only\z/ ? 9 : 7)]);
        }
        # The session comparison after reads and writes: unchanged.
        if (defined($self->{session}) && $sql eq 'SELECT @@SESSION.time_zone, @@SESSION.sql_mode') {
            push @{$self->{events}}, 'STATE';
            return @{$self->{session}}[0, 5];
        }
        # The MySQL-family storage checks: an InnoDB base table, no shadow.
        return ('items', 'CREATE TABLE `items` (`id` int)') if $sql =~ /SHOW CREATE TABLE/;
        return ('InnoDB') if $sql =~ /SELECT ENGINE FROM information_schema\.TABLES/;
        push @{$self->{events}}, $sql;
        return exists $self->{answers}{$sql} ? ($self->{answers}{$sql}) : die "no answer for $sql\n";
    }
    sub prepare {
        my ($self, $sql) = @_;
        push @{$self->{events}}, 'write';
        return RecordingSTH->new(owner => $self);
    }
    sub errstr { return $_[0]{errstr}; }
    sub err    { return $_[0]{err}; }
    sub state  { return ''; }
}

package RecordingSTH {
    sub new { my ($class, %args) = @_; return bless {%args}, $class; }
    sub bind_param { return 1; }
    sub execute {
        my ($self) = @_;
        my $affected = shift(@{$self->{owner}{affected} // []});
        $self->{rows} = $affected // 1;
        return 1;
    }
    sub rows { return $_[0]{rows}; }
    sub fetchrow_array { return; }
    sub fetchall_arrayref { return []; }
    sub err { return undef; }
    sub errstr { return undef; }
}

package main;

{
    package RecordingSQLite;
    use Mojo::Base 'Selecto::SQLite';
    # This DBH double observes generic transaction control, without a SQLite catalog.
    sub _admit_plan_storage { return; }
    sub write_capabilities { return Selecto::SQL::write_capabilities($_[0]); }
}

my $write = sub {
    my ($adapter, $id) = @_;
    return error_of(sub { engine_for($adapter)->execute_write(insert_command($id // 2)) });
};

subtest 'standalone and failed begin' => sub {
    my $idle = RecordingDBH->new;
    ok(!$write->(Selecto->adapter(postgresql => (dbh => $idle))), 'standalone write succeeds');
    is_deeply($idle->events, ['begin_work', 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED', 'write', 'commit'], 'an idle handle begins and commits');

    my $refused = RecordingDBH->new(fail_begin => 1);
    my $error = $write->(Selecto->adapter(postgresql => (dbh => $refused)));
    isa_ok($error, 'Selecto::Error', 'a failed begin');
    is($error->code, 'query_error', 'a failed begin is a query_error');
    is_deeply($refused->events, ['begin_work'], 'a transaction that never began is not rolled back');

    my $uncommitted = RecordingDBH->new(fail_commit => 1);
    $error = $write->(Selecto->adapter(postgresql => (dbh => $uncommitted)));
    is($error->code, 'query_error', 'a failed commit is a Selecto error');
    is_deeply($uncommitted->events, ['begin_work', 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED', 'write', 'commit', 'rollback'],
        'a failed commit rolls back the write\'s own transaction');

    my $mismatch = RecordingDBH->new(affected => [0]);
    is($write->(Selecto->adapter(postgresql => (dbh => $mismatch)))->code, 'cardinality_mismatch',
        'a cardinality mismatch is reported unchanged');
    is_deeply($mismatch->events, ['begin_work', 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED', 'write', 'rollback'], 'and rolls back its own transaction');
};

subtest 'savepoints inside an open DBI transaction' => sub {
    my $open = RecordingDBH->new(AutoCommit => 0);
    ok(!$write->(Selecto->adapter(postgresql => (dbh => $open))), 'the write succeeds');
    is_deeply($open->events, ['SAVEPOINT selecto_write_1', 'write', 'RELEASE SAVEPOINT selecto_write_1'],
        'AutoCommit off means a savepoint, never commit');

    my $failing = RecordingDBH->new(AutoCommit => 0, affected => [0]);
    is($write->(RecordingSQLite->new(dbh => $failing))->code, 'cardinality_mismatch',
        'a failed write inside the host transaction keeps its error');
    is_deeply($failing->events, [
        'SELECT 1', 'SAVEPOINT selecto_write_1', 'write',
        'ROLLBACK TO SAVEPOINT selecto_write_1', 'RELEASE SAVEPOINT selecto_write_1',
    ], 'a failed write rolls back only to its savepoint (SQLite opens the host transaction first)');

    my $no_savepoint = RecordingDBH->new(AutoCommit => 0, fail_do => qr/\ASAVEPOINT/);
    my $error = $write->(Selecto->adapter(postgresql => (dbh => $no_savepoint)));
    is($error->code, 'query_error', 'a refused savepoint is a Selecto error');
    is_deeply($no_savepoint->events, ['SAVEPOINT selecto_write_1'],
        'a refused savepoint touches nothing else');

    my $no_release = RecordingDBH->new(AutoCommit => 0, fail_do => qr/\ARELEASE/);
    is($write->(Selecto->adapter(postgresql => (dbh => $no_release)))->code, 'query_error',
        'a refused release is a Selecto error');
    is_deeply($no_release->events, [
        'SAVEPOINT selecto_write_1', 'write', 'RELEASE SAVEPOINT selecto_write_1',
        'ROLLBACK TO SAVEPOINT selecto_write_1', 'RELEASE SAVEPOINT selecto_write_1',
    ], 'a refused release rolls the write back to its savepoint');

    my $external = RecordingDBH->new(AutoCommit => 0);
    ok(!$write->(Selecto->adapter(postgresql => (dbh => $external, transaction_mode => 'external'))),
        'external write succeeds');
    is_deeply($external->events, ['SAVEPOINT selecto_write_1', 'write', 'RELEASE SAVEPOINT selecto_write_1'],
        'external mode never begins or commits, and runs the write in its own savepoint');
    my $external_failed = RecordingDBH->new(AutoCommit => 0, affected => [0]);
    is($write->(Selecto->adapter(postgresql => (dbh => $external_failed, transaction_mode => 'external')))->code,
        'cardinality_mismatch', 'an external write refused after its statement');
    is_deeply($external_failed->events, ['SAVEPOINT selecto_write_1', 'write', 'ROLLBACK TO SAVEPOINT selecto_write_1',
        'RELEASE SAVEPOINT selecto_write_1'], 'rolls back to its own savepoint, never the host transaction');
};

subtest 'MySQL and MariaDB' => sub {
    # A UTC, utf8mb4, strict session that decodes exactly; a write on a
    # handle whose AutoCommit is on also reads @@autocommit and
    # @@transaction_read_only.
    my @session = ('UTC', 'UTC', 'utf8mb4', 'utf8mb4', 'utf8mb4', 'STRICT_TRANS_TABLES', "\x{1F600}",
        '2024-03-10 02:30:00.500000');
    for my $name (qw(mysql mariadb)) {
        # A server transaction the driver did not open (a raw BEGIN, a pooled
        # handle left in one) makes SET TRANSACTION fail with 1568, and a
        # session autocommit=0 is an implicit one: both are refused before
        # any transaction control, on both servers.
        my $raw = RecordingDBH->new(session => [@session, 1, 0], fail_do => qr/\ASET TRANSACTION/, fail_errno => 1568);
        my $error = $write->(Selecto->adapter($name => (dbh => $raw)));
        is($error && $error->code, 'invalid_adapter', "$name refuses a transaction opened outside the driver");
        is_deeply($raw->events, ['SESSION', 'SET TRANSACTION READ WRITE'], 'before any transaction control');
        my $implicit = RecordingDBH->new(session => [@session, 0, 0]);
        $error = $write->(Selecto->adapter($name => (dbh => $implicit)));
        is($error && $error->code, 'invalid_adapter', "$name refuses a session left at autocommit=0");
        is_deeply($implicit->events, ['SESSION'], 'before any transaction control');

        my $idle = RecordingDBH->new(session => [@session, 1, 0]);
        ok(!$write->(Selecto->adapter($name => (dbh => $idle))), "$name write succeeds");
        is_deeply($idle->events, ['SESSION', 'SET TRANSACTION READ WRITE', 'begin_work', 'write', 'STATE', 'commit'],
            "$name begins and commits on an idle connection, comparing the session before it commits");
        my $read_only = RecordingDBH->new(session => [@session, 1, 1]);
        ok(!$write->(Selecto->adapter($name => (dbh => $read_only))), "$name write on a read-only session default");
        is($read_only->events->[1], 'SET TRANSACTION READ ONLY', "$name keeps the session's own access mode");

        my $manual = RecordingDBH->new(AutoCommit => 0, session => [@session]);
        ok(!$write->(Selecto->adapter($name => (dbh => $manual))), "$name write inside begin_work succeeds");
        is_deeply($manual->events, ['SESSION', 'SAVEPOINT selecto_write_1', 'write', 'STATE', 'RELEASE SAVEPOINT selecto_write_1'],
            "$name with AutoCommit off uses a savepoint");

        my $unknown = RecordingDBH->new;
        is($write->(Selecto->adapter($name => (dbh => $unknown)))->code, 'query_error',
            "$name refuses a connection whose session cannot be read");
        is_deeply([grep { $_ eq 'begin_work' || $_ eq 'write' } @{$unknown->events}], [],
            'before any transaction control');
    }
};

subtest 'SQL Server' => sub {
    my $raw = RecordingDBH->new(answers => { 'SELECT @@TRANCOUNT' => 1 });
    ok(!$write->(Selecto->adapter(mssql => (dbh => $raw))), 'SQL Server write succeeds');
    is_deeply($raw->events, [
        'SELECT @@TRANCOUNT', 'SELECT @@TRANCOUNT', 'SAVE TRANSACTION selecto_write_1', 'write',
    ], 'SQL Server uses SAVE TRANSACTION inside an open transaction and has no release');

    my $failing = RecordingDBH->new(AutoCommit => 0, affected => [0], answers => { 'SELECT @@TRANCOUNT' => 2 });
    is($write->(Selecto->adapter(mssql => (dbh => $failing)))->code, 'cardinality_mismatch',
        'a failed SQL Server write keeps its error');
    is_deeply($failing->events, [
        'SELECT @@TRANCOUNT', 'SAVE TRANSACTION selecto_write_1', 'write',
        'ROLLBACK TRANSACTION selecto_write_1',
    ], 'a failed SQL Server write rolls back to its savepoint');

    my $implicit = RecordingDBH->new(AutoCommit => 0, answers => { 'SELECT @@TRANCOUNT' => 0 });
    ok(!$write->(Selecto->adapter(mssql => (dbh => $implicit))), 'implicit-transaction write succeeds');
    is_deeply($implicit->events, ['SELECT @@TRANCOUNT', 'write'],
        'with AutoCommit off and nothing pending the write is left for the host to commit');
    my $implicit_failure = RecordingDBH->new(AutoCommit => 0, affected => [0], answers => { 'SELECT @@TRANCOUNT' => 0 });
    $write->(Selecto->adapter(mssql => (dbh => $implicit_failure)));
    is_deeply($implicit_failure->events, ['SELECT @@TRANCOUNT', 'write', 'rollback'],
        'and a failure there rolls back only the write');

    my $idle = RecordingDBH->new(answers => { 'SELECT @@TRANCOUNT' => 0 });
    $write->(Selecto->adapter(mssql => (dbh => $idle)));
    is_deeply($idle->events, ['SELECT @@TRANCOUNT', 'begin_work', 'write', 'commit'],
        'SQL Server begins and commits on an idle connection');
};

subtest 'PostgreSQL detects a raw BEGIN' => sub {
    no warnings 'once';
    local *RecordingDBH::pg_ping = sub { push @{$_[0]{events}}, 'pg_ping'; return $_[0]{ping}; };
    my $raw = RecordingDBH->new(ping => 3);
    $write->(Selecto->adapter(postgresql => (dbh => $raw)));
    is_deeply($raw->events, ['pg_ping', 'SAVEPOINT selecto_write_1', 'write', 'RELEASE SAVEPOINT selecto_write_1'],
        'idle in a transaction means a savepoint');
    my $idle = RecordingDBH->new(ping => 1);
    $write->(Selecto->adapter(postgresql => (dbh => $idle)));
    is_deeply($idle->events, ['pg_ping', 'begin_work', 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED', 'write', 'commit'], 'idle means begin and commit');
};

subtest 'DuckDB' => sub {
    my $idle = RecordingDBH->new;
    ok(!$write->(Selecto->adapter(duckdb => (dbh => $idle))), 'DuckDB write succeeds');
    is_deeply($idle->events, ['BEGIN', 'write', 'COMMIT'], 'DuckDB controls its own transaction with SQL');

    my $raw = RecordingDBH->new(fail_do => qr/\ABEGIN\z/);
    is($write->(Selecto->adapter(duckdb => (dbh => $raw)))->code, 'query_error',
        'a refused DuckDB BEGIN is a Selecto error');
    is_deeply($raw->events, ['BEGIN'], 'a refused DuckDB BEGIN rolls back nothing');

    my $open = RecordingDBH->new(AutoCommit => 0);
    is($write->(Selecto->adapter(duckdb => (dbh => $open)))->code, 'invalid_adapter',
        'DuckDB has no savepoints and refuses a managed write inside an open transaction');
    is_deeply($open->events, [], 'and touches nothing');

    my $external = RecordingDBH->new(AutoCommit => 0);
    ok(!$write->(Selecto->adapter(duckdb => (dbh => $external, transaction_mode => 'external'))),
        'DuckDB external write succeeds');
    is_deeply($external->events, ['write'], 'DuckDB honours external mode');
};

done_testing;
