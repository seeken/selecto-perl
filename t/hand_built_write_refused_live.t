use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use Scalar::Util qw(blessed);
use Time::HiRes ();
use Selecto;
use Selecto::Statement;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# No permissive writes: a hand-built statement on a read path writes nothing, on
# its own or inside the host's transaction. A read may run as written.
my $outcome = sub {
    my ($adapter, $name, $sql, @params) = @_;
    my $statement = Selecto::Statement->new(sql => $sql, params => [@params], columns => ['a'], adapter_name => $name);
    my $rows = eval { $adapter->execute_query($statement)->{rows} };
    return 'answered' if $rows;
    my $error = $@;
    return 'refused' if blessed($error) && ($error->code eq 'query_rule_not_evaluable' || ($error->details->{category} // '') eq 'read_only_transaction');
    return 'failed';
};

subtest postgresql => sub {
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
    my $admin = TestPostgreSQL->connect;
    $admin->do('SET client_min_messages TO warning');
    my @clean = ('DROP TABLE IF EXISTS hb_t, hb_new, hb_new2 CASCADE', 'DROP PROCEDURE IF EXISTS hb_p()', 'DROP FUNCTION IF EXISTS hb_f()', 'DROP SEQUENCE IF EXISTS hb_s');
    $admin->do($_) for @clean, 'CREATE TABLE hb_t (id INT PRIMARY KEY, note TEXT)', q{INSERT INTO hb_t VALUES (1, 'a')}, 'CREATE SEQUENCE hb_s',
        q{CREATE PROCEDURE hb_p() LANGUAGE sql AS $$ INSERT INTO hb_t VALUES (90, 'proc') $$},
        q{CREATE FUNCTION hb_f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN INSERT INTO hb_t VALUES (91, 'fn'); RETURN 1; END $$};
    my @writes = (
        q{INSERT INTO hb_t VALUES (10, 'x')}, q{UPDATE hb_t SET note = 'x'}, q{DELETE FROM hb_t},
        q{INSERT INTO hb_t VALUES (11, 'x') RETURNING id}, q{UPDATE hb_t SET note = 'x' RETURNING id}, q{DELETE FROM hb_t RETURNING id},
        q{WITH w AS (INSERT INTO hb_t VALUES (12, 'x') RETURNING id) SELECT id FROM w},
        q{WITH w AS (DELETE FROM hb_t RETURNING id) SELECT count(*) FROM w},
        q{SELECT id INTO hb_new FROM hb_t}, q{CREATE TABLE hb_new2 AS SELECT id FROM hb_t},
        q{COPY hb_t FROM PROGRAM 'true'}, q{CALL public.hb_p()}, q{DO $$ BEGIN INSERT INTO hb_t VALUES (13, 'x'); END $$},
        q{EXPLAIN ANALYZE INSERT INTO hb_t VALUES (14, 'x')}, q{EXPLAIN (ANALYZE) DELETE FROM hb_t},
        q{SELECT public.hb_f()}, q{SELECT pg_catalog.nextval('public.hb_s')}, q{SELECT pg_catalog.setval('public.hb_s', 50)},
        q{SELECT 1; DELETE FROM hb_t}, q{COMMIT; DELETE FROM hb_t}, q{ROLLBACK; INSERT INTO hb_t VALUES (15, 'x')},
        q{/* c */ DELETE FROM hb_t}, q{-- c
DELETE FROM hb_t}, q{(SELECT 1); DELETE FROM hb_t}, q{TRUNCATE hb_t}, q{SELECT 1 FROM hb_t FOR UPDATE},
    );
    my $state = sub { join '|', map { $_->[0] } @{$admin->selectall_arrayref(q{SELECT id::text || note FROM hb_t ORDER BY id})}, [($admin->selectrow_array(q{SELECT last_value FROM hb_s}))[0]],
        [($admin->selectrow_array(q{SELECT count(*) FROM pg_class WHERE relname IN ('hb_new', 'hb_new2')}))[0]] };
    my $clean = $state->();
    for my $sql (@writes) {
        for my $host (0, 1) {
            my $dbh = TestPostgreSQL->connect;
            $dbh->do('SET client_min_messages TO error');
            my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
            my $where = $host ? 'host transaction' : 'alone';
            $dbh->begin_work if $host;
            $dbh->do('CREATE TEMP TABLE hb_mine (id INT)') if $host;
            is($outcome->($adapter, 'postgresql', $sql), 'refused', "$where: refused: " . ($sql =~ s/\n/ /gr));
            if ($host) {
                ok(eval { $dbh->selectrow_array('SELECT count(*) FROM hb_mine'); 1 }, "$where: the host's transaction lives on") or diag $@;
                $dbh->commit;
            }
            is($state->(), $clean, "$where: nothing written");
            $dbh->disconnect;
        }
    }
    for my $sql (q{SELECT id FROM hb_t}, q{WITH c AS (SELECT id FROM hb_t) SELECT * FROM c}, q{VALUES (1)}, q{TABLE hb_t}, q{(SELECT 1)}, q{/* c */ SELECT 1}, q{-- c
SELECT 1}, q{SELECT 1;}, q{SELECT 'x;y'}, q{SELECT 'a; delete' AS a, 'it''s; into' AS b}, q{SELECT note FROM hb_t WHERE note <> 'update; drop'},
        q{SELECT $tag$;$tag$::text = $tag$;$tag$::text WHERE false}) {
        # (A dollar quote is not one reading of the text: its semicolon refuses, below.)
        next if $sql =~ /\$tag/;
        for my $host (0, 1) {
            my $dbh = TestPostgreSQL->connect;
            my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
            $dbh->begin_work if $host;
            is($outcome->($adapter, 'postgresql', $sql), 'answered', ($host ? 'host transaction' : 'alone') . ': a read reads: ' . ($sql =~ s/\n/ /gr));
            $dbh->rollback if $host;
            $dbh->disconnect;
        }
    }
    # Where the text has more than one reading, a word in a literal counts: a comment
    # or a dollar quote could end it, for all this text knows.
    for my $sql (q{SELECT $$;$$}, q{SELECT ';' /* c */}, q{SELECT E'\\'; DELETE FROM hb_t --'}, q{SELECT 1 /* ' */; DELETE FROM hb_t WHERE note = '1'}) {
        my $dbh = TestPostgreSQL->connect;
        is($outcome->(Selecto::PostgreSQL->new(dbh => $dbh), 'postgresql', $sql), 'refused', "refused as it stands: $sql");
        is($state->(), $clean, 'and nothing written');
        $dbh->disconnect;
    }
    # A hand-built read in the host's transaction keeps its table's lock, whatever its
    # words: the plan says what it does, not the text.
    $admin->do('ALTER TABLE hb_t ADD COLUMN "delete" TEXT, ADD COLUMN "update" TEXT');
    for my $sql ('SELECT id FROM public.hb_t WHERE id = 1', q{SELECT id FROM public.hb_t WHERE note <> 'update'}, q{SELECT "delete" FROM public.hb_t}, q{SELECT id, "update" FROM public.hb_t},
        q{SELECT id AS "merge" FROM public.hb_t}, q{SELECT id FROM public.hb_t WHERE note <> 'delete' /* c */}, q{WITH "update" AS (SELECT id FROM public.hb_t) SELECT id FROM "update"}) {
        my $dbh = TestPostgreSQL->connect;
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        $dbh->begin_work;
        is($outcome->($adapter, 'postgresql', $sql), 'answered', "a hand-built read: $sql");
        $admin->do(q{SET lock_timeout = '150ms'});
        my $altered = eval { $admin->do('ALTER TABLE hb_t ADD COLUMN extra INT'); 1 };
        ok(!$altered, 'its table stays locked against DDL');
        $admin->do('SET lock_timeout = 0');
        $dbh->rollback;
        $admin->do('ALTER TABLE hb_t DROP COLUMN extra') if $altered;
        $dbh->disconnect;
    }
    # One that will refuse keeps nothing: planning it took a lock, which goes back.
    for my $sql (q{WITH w AS (DELETE FROM public.hb_t RETURNING id) SELECT id FROM w}, 'SELECT id FROM public.hb_t FOR UPDATE', 'SELECT id FROM public.hb_t FOR SHARE') {
        my $dbh = TestPostgreSQL->connect;
        $dbh->begin_work;
        is($outcome->(Selecto::PostgreSQL->new(dbh => $dbh), 'postgresql', $sql), 'refused', "refused: $sql");
        is(($admin->selectrow_array(q{SELECT count(*) FROM pg_locks WHERE relation = 'hb_t'::regclass AND mode <> 'AccessShareLock' AND pid = ?}, undef, $dbh->{pg_pid}))[0], 0, 'and no lock of a writer stays');
        $dbh->rollback;
        $dbh->disconnect;
    }
    # The host's deadline covers the plan: a table another session holds cannot keep a read past it.
    {
        my $locker = TestPostgreSQL->connect;
        $locker->begin_work;
        $locker->do('LOCK TABLE hb_t IN ACCESS EXCLUSIVE MODE');
        my $dbh = TestPostgreSQL->connect;
        $dbh->begin_work;
        $dbh->do(q{SET LOCAL statement_timeout = '200ms'});
        my $started = Time::HiRes::time();
        my $done = eval { Selecto::PostgreSQL->new(dbh => $dbh)->execute_query(Selecto::Statement->new(sql => 'SELECT id FROM public.hb_t', params => [], columns => ['a'], adapter_name => 'postgresql')); 1 };
        my $error = $@;
        ok(!$done, 'a read behind an exclusive lock does not answer');
        cmp_ok(Time::HiRes::time() - $started, '<', 2, 'and it stops at the deadline');
        is(blessed($error) && $error->details->{sqlstate}, q{57014}, q{as a cancellation});
        $dbh->rollback;
        $dbh->disconnect;
        $locker->rollback;
        $locker->disconnect;
    }
    $admin->do('ALTER TABLE hb_t DROP COLUMN "delete", DROP COLUMN "update"');
    # The same with a parameter.
    {
        my $dbh = TestPostgreSQL->connect;
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        $dbh->begin_work;
        is($outcome->($adapter, 'postgresql', 'SELECT id FROM public.hb_t WHERE id = $1', 1), 'answered', 'a hand-built read with a parameter');
        $admin->do(q{SET lock_timeout = '150ms'});
        my $altered = eval { $admin->do('ALTER TABLE hb_t ADD COLUMN extra INT'); 1 };
        ok(!$altered, 'its table stays locked against DDL');
        $admin->do('SET lock_timeout = 0');
        $dbh->rollback;
        $admin->do('ALTER TABLE hb_t DROP COLUMN extra') if $altered;
        $dbh->disconnect;
    }
    $admin->do($_) for @clean;
    $admin->disconnect;
};

for my $family (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($name, $env) = @$family;
    subtest $name => sub {
        plan skip_all => "$env is not set" unless ($ENV{$env} // '') ne '';
        plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };
        my $url = Mojo::URL->new($ENV{$env});
        my $connect = sub {
            my ($user, $password) = split /:/, $url->userinfo // '', 2;
            my $db = $url->path->to_string =~ s{\A/}{}r;
            my $dbh = DBI->connect("dbi:MariaDB:database=$db;host=" . $url->host . ';port=' . $url->port, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
            $dbh->do(q{SET SESSION time_zone = '+00:00', sql_mode = 'STRICT_TRANS_TABLES', NAMES utf8mb4});
            return $dbh;
        };
        my $admin = $connect->();
        my @clean = ('DROP TABLE IF EXISTS hb_t, hb_new', 'DROP PROCEDURE IF EXISTS hb_p', 'DROP FUNCTION IF EXISTS hb_f', ($name eq 'mariadb' ? 'DROP SEQUENCE IF EXISTS hb_s' : ()));
        $admin->do($_) for @clean, ($name eq 'mariadb' ? 'CREATE SEQUENCE hb_s' : ()), 'CREATE TABLE hb_t (id INT PRIMARY KEY, note VARCHAR(10)) ENGINE=InnoDB', q{INSERT INTO hb_t VALUES (1, 'a')},
            q{CREATE PROCEDURE hb_p() MODIFIES SQL DATA INSERT INTO hb_t VALUES (90, 'proc')},
            q{CREATE FUNCTION hb_f() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN INSERT INTO hb_t VALUES (91, 'fn'); RETURN 1; END};
        my $state = sub { join '|', (map { $_->[0] } @{$admin->selectall_arrayref(q{SELECT CONCAT(id, note) FROM hb_t ORDER BY id})}),
            ($name eq 'mariadb' ? ($admin->selectrow_array('SELECT next_not_cached_value FROM hb_s'))[0] : ()) };
        my $clean = $state->();
        for my $sql (q{INSERT INTO hb_t VALUES (10, 'x')}, q{UPDATE hb_t SET note = 'x'}, q{DELETE FROM hb_t}, q{REPLACE INTO hb_t VALUES (1, 'x')},
            ($name eq 'mariadb' ? (q{SELECT NEXTVAL(hb_s)}, q{SELECT NEXT VALUE FOR hb_s}, q{SELECT SETVAL(hb_s, 50)}) : ()),
            ($name eq 'mariadb' ? (q{SELECT NEXT /* c */ VALUE FOR hb_s}, q{SELECT NEXTVAL /* c */ (hb_s)}) : ()),
            q{WITH c AS (SELECT 1 AS id) DELETE hb_t FROM hb_t JOIN c ON c.id = hb_t.id}, q{WITH c AS (SELECT 'x' AS note) UPDATE hb_t JOIN c SET hb_t.note = c.note}, q{SELECT 1 INTO @hb_x},
            q{WITH c AS (SELECT 1 AS id) UPDATE (hb_t) SET note = 'x'}, q{WITH c AS (SELECT 1 AS id) /* c */ UPDATE (hb_t) SET note = 'x'}, q{WITH RECURSIVE c (id) AS (SELECT 1), d AS (SELECT 2) UPDATE (hb_t) SET note = 'x'}, q{SELECT id FROM hb_t INTO OUTFILE '/tmp/hb_never'},
            q{SELECT @hb_x := 1}, q{SELECT 1 /*! INTO @hb_x */}, q{SELECT 1 /*M! INTO @hb_x */}, q{CALL hb_p()}, q{TRUNCATE hb_t}, q{CREATE TABLE hb_new (id INT)}, q{SELECT 1; DELETE FROM hb_t}, q{COMMIT},
            q{/* c */ DELETE FROM hb_t}, q{# c
DELETE FROM hb_t}) {
            for my $host (0, 1) {
                my $dbh = $connect->();
                my $adapter = Selecto->adapter($name => (dbh => $dbh));
                my $where = $host ? 'host transaction' : 'alone';
                $dbh->begin_work if $host;
                is($outcome->($adapter, $name, $sql) ne 'answered' ? 1 : 0, 1, "$where: not answered: " . ($sql =~ s/\n/ /gr));
                $dbh->commit if $host;
                is($state->(), $clean, "$where: nothing written");
                $dbh->disconnect;
            }
        }
        for my $host (0, 1) {
            my $dbh = $connect->();
            my $adapter = Selecto->adapter($name => (dbh => $dbh));
            $dbh->begin_work if $host;
            my $result = $outcome->($adapter, $name, 'SELECT hb_f()');
            $dbh->rollback if $host;
            # (In the host's transaction it runs as written, as a view's does: the
            # host's rollback undoes it.)
            is($state->(), $clean, ($host ? 'host transaction' : 'alone') . ': a function that writes wrote nothing') or diag $result;
            for my $sql ('SELECT id FROM hb_t', q{SELECT REPLACE(note, 'a', 'b') FROM hb_t}, q{SELECT INSERT(note, 1, 1, 'z') FROM hb_t}, q{SELECT TRUNCATE(1.55, 1)},
                q{SELECT note FROM hb_t WHERE note <> 'delete; into := update'}, q{WITH c AS (SELECT 'update' AS a) SELECT a FROM c},
                q{WITH c (a) AS (SELECT 1), d AS (SELECT REPLACE('a', 'a', 'b') AS b) SELECT a, REPLACE(b, 'b', 'c') FROM c, d}, q{WITH `update` AS (SELECT 1 AS a) SELECT a FROM `update`}) {
                $dbh->begin_work if $host;
                is($outcome->($adapter, $name, $sql), 'answered', ($host ? 'in a host transaction' : 'alone') . ": a read reads as written: $sql");
                $dbh->rollback if $host;
            }
            $dbh->disconnect;
        }
        $admin->do($_) for @clean;
        $admin->disconnect;
    };
}

subtest duckdb => sub {
    plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do($_) for 'CREATE TABLE hb_t (id INTEGER, note VARCHAR)', q{INSERT INTO hb_t VALUES (1, 'a')}, 'CREATE SEQUENCE hb_s';
    my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
    my $state = sub { join '|', map { $_->[0] } @{$dbh->selectall_arrayref(q{SELECT CAST(id AS VARCHAR) || note FROM hb_t ORDER BY id})} };
    my $clean = $state->();
    for my $sql (q{INSERT INTO hb_t VALUES (10, 'x')}, q{UPDATE hb_t SET note = 'x'}, q{DELETE FROM hb_t}, q{WITH c AS (SELECT 1) INSERT INTO hb_t VALUES (11, 'x')},
        q{CREATE TABLE hb_new AS SELECT 1}, q{COPY hb_t TO '/tmp/hb_never.csv'}, q{SELECT 1; DELETE FROM hb_t}, q{COMMIT}) {
        for my $mode ('alone', 'BEGIN', 'begin_work') {
            $dbh->do('BEGIN') if $mode eq 'BEGIN';
            $dbh->begin_work if $mode eq 'begin_work';
            is($outcome->($adapter, 'duckdb', $sql) ne 'answered' ? 1 : 0, 1, "$mode: not answered: $sql");
            $mode eq 'BEGIN' ? $dbh->do('COMMIT') : $mode eq 'begin_work' ? $dbh->commit : ();
            is($state->(), $clean, "$mode: nothing written");
        }
    }
    is($outcome->($adapter, 'duckdb', 'SELECT id FROM hb_t'), 'answered', 'a plain read reads on its own');
    is($outcome->($adapter, 'duckdb', q{SELECT nextval('hb_s')}), 'refused', 'nextval refuses on its own');
    my $sequence = sub { ($dbh->selectrow_array('SELECT last_value FROM duckdb_sequences() WHERE sequence_name = ?', undef, 'hb_s'))[0] // 'unused' };
    my $before = $sequence->();
    for my $mode ('BEGIN', 'begin_work') {
        for my $sql ('SELECT id FROM hb_t', q{SELECT note FROM hb_t WHERE note <> 'delete; update'}, q{SELECT replace(note, 'a', 'b') FROM hb_t}) {
            $mode eq 'BEGIN' ? $dbh->do('BEGIN') : $dbh->begin_work;
            is($outcome->($adapter, 'duckdb', $sql), 'answered', "$mode: a read reads as written: $sql");
            # (The driver's rollback leaves a transaction open after begin_work: a read wrote nothing to keep.)
            $mode eq 'BEGIN' ? $dbh->do('ROLLBACK') : $dbh->commit;
        }
        $mode eq 'BEGIN' ? $dbh->do('BEGIN') : $dbh->begin_work;
        is($outcome->($adapter, 'duckdb', q{SELECT nextval('hb_s')}), 'refused', "$mode: nextval refuses");
        $mode eq 'BEGIN' ? $dbh->do('COMMIT') : $dbh->commit;
        is($sequence->(), $before, "$mode: and the sequence stands");
    }
    $dbh->disconnect;
};

subtest sqlite => sub {
    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do($_) for 'CREATE TABLE hb_t (id INTEGER, note TEXT)', q{INSERT INTO hb_t VALUES (1, 'a')};
    my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
    my $state = sub { join '|', map { "$_->[0]$_->[1]" } @{$dbh->selectall_arrayref(q{SELECT id, note FROM hb_t ORDER BY id})} };
    my $clean = $state->();
    for my $sql (q{INSERT INTO hb_t VALUES (10, 'x')}, q{DELETE FROM hb_t}, q{WITH c AS (SELECT 1) DELETE FROM hb_t}, q{SELECT 1; DELETE FROM hb_t}, q{PRAGMA query_only = 0}) {
        for my $host (0, 1) {
            $dbh->begin_work if $host;
            is($outcome->($adapter, 'sqlite', $sql) ne 'answered' ? 1 : 0, 1, ($host ? 'host: ' : 'alone: ') . "not answered: $sql");
            $dbh->commit if $host;
            is($state->(), $clean, 'nothing written');
        }
    }
    is($outcome->($adapter, 'sqlite', 'SELECT id FROM hb_t'), 'answered', 'a plain read reads');
    $dbh->disconnect;
};

done_testing;
