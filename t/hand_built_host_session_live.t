use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R71: a hand-built read runs in the host's session, and its answer is the driver's.
my $flat = sub { join '|', map { join ',', map { ref($_) ? join('+', @$_) : $_ // 'NULL' } @$_ } @{$_[0]} };
my $answer = sub {
    my ($adapter, $name, $sql) = @_;
    my $rows = eval { $adapter->execute_query(Selecto::Statement->new(sql => $sql, params => [], adapter_name => $name))->{rows} };
    return $flat->($rows) if $rows;
    my $error = $@;
    return 'refused ' . (blessed($error) ? ($error->details->{reason} // $error->details->{category} // $error->code) : "$error");
};

subtest postgresql => sub {
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
    my $admin = TestPostgreSQL->connect;
    $admin->do('SET client_min_messages TO warning');
    my @clean = ('DROP SCHEMA IF EXISTS hs_a CASCADE', 'DROP SCHEMA IF EXISTS hs_b CASCADE');
    $admin->do($_) for @clean, 'CREATE SCHEMA hs_a', 'CREATE SCHEMA hs_b',
        'CREATE FUNCTION hs_b.f() RETURNS int LANGUAGE sql AS $$ SELECT 6 $$', 'CREATE FUNCTION hs_a.f() RETURNS int LANGUAGE sql AS $$ SELECT 5 $$',
        'CREATE TABLE hs_a.t (id int)', 'INSERT INTO hs_a.t VALUES (1)', 'CREATE TABLE hs_b.t (id int)', 'INSERT INTO hs_b.t VALUES (2)',
        q{CREATE TYPE hs_a.k AS ENUM ('x')}, q{CREATE TYPE hs_b.k AS ENUM ('y')},
        'CREATE FUNCTION hs_a.e(int, int) RETURNS boolean LANGUAGE sql AS $$ SELECT false $$', 'CREATE OPERATOR hs_a.=== (LEFTARG = int, RIGHTARG = int, FUNCTION = hs_a.e)',
        'CREATE FUNCTION hs_b.e(int, int) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$', 'CREATE OPERATOR hs_b.=== (LEFTARG = int, RIGHTARG = int, FUNCTION = hs_b.e)';
    for my $set ('SET search_path = hs_a, hs_b', 'SET search_path = hs_b, hs_a', 'SET search_path = "$user", public', q{SET DateStyle = 'German'}, q{SET TimeZone = 'Asia/Tokyo'}) {
        for my $sql ('SELECT hs_a.f(), f()', 'SELECT id FROM t', q{SELECT 'x'::k}, 'SELECT 1 === 1', 'SELECT current_schema()', 'SELECT current_schemas(false)', 'SHOW search_path', 'SHOW TimeZone',
            'EXPLAIN (COSTS OFF) SELECT 1', q{SELECT current_setting('search_path')}, q{SELECT '2026-01-02'::date}) {
            for my $host (0, 1) {
                my ($native, $dbh) = (TestPostgreSQL->connect, TestPostgreSQL->connect);
                $_->do($set) for $native, $dbh;
                my $expected = eval { $flat->($native->selectall_arrayref($sql)) };
                my $state = $native->state;
                my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
                $dbh->begin_work if $host;
                my $got = $answer->($adapter, 'postgresql', $sql);
                $dbh->rollback if $host;
                if (defined $expected) { is($got, $expected, ($host ? 'host: ' : 'alone: ') . "$set: $sql") }
                else { like($got, qr/\Arefused/, "$set: as the driver, it fails: $sql ($state)") }
                $_->disconnect for $native, $dbh;
            }
        }
    }
    # A row lock is the host's to take, on every route: a stream's would end with its batch.
    for my $sql ('SELECT id FROM hs_a.t FOR UPDATE', 'SELECT id FROM hs_a.t FOR NO KEY UPDATE', 'SELECT id FROM hs_a.t FOR SHARE', 'SELECT id FROM hs_a.t FOR KEY SHARE') {
        for my $host (0, 1) {
            for my $bounded (0, 1) {
                my $dbh = TestPostgreSQL->connect;
                my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
                $dbh->begin_work if $host;
                my $opened = eval { my $s = $adapter->stream_query(Selecto::Statement->new(sql => $sql, params => [], columns => ['a'], adapter_name => 'postgresql'), ($bounded ? (bounded => 1, fetch_size => 1) : ())); 1 while $s->next; $s->close; 1 };
                my $error = $@;
                ok(!$opened && blessed($error), ($host ? 'host, ' : 'alone, ') . ($bounded ? 'bounded stream: ' : 'stream: ') . "refused typed: $sql") or diag $error;
                eval { $dbh->rollback } if $host;
                $dbh->disconnect;
            }
        }
    }
    # A read's end that fails reaches the host: rolled back to, else closed, and never the host's ROLLBACK.
    for my $case (['RELEASE fails', qr/\ARELEASE SAVEPOINT selecto_read/, 1], ['nothing ends it', qr/\A(?:RELEASE|ROLLBACK TO) SAVEPOINT selecto_read/, 100]) {
        my ($label, $fails, $times) = @$case;
        my $dbh = TestPostgreSQL->connect;
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        $dbh->begin_work;
        $dbh->do('INSERT INTO hs_a.t VALUES (70)');
        my $read = do {
            no warnings 'redefine';
            my $do = \&DBD::Pg::db::do;
            my $left = $times;
            local *DBD::Pg::db::do = sub { my ($h, $sql) = @_; die "DBD::Pg::db do failed: injected\n" if ($sql // '') =~ $fails && $left-- > 0; return $do->(@_) };
            eval { $adapter->execute_query(Selecto::Statement->new(sql => 'SELECT 1', params => [], columns => ['a'], adapter_name => 'postgresql')); 1 };
        };
        my $error = $@;
        ok(!$read && blessed($error), "$label: the read reports it") or diag $error;
        if ($times == 1) {
            ok($dbh->{Active}, "$label: rolled back to its savepoint, the connection stands");
            is(($dbh->selectrow_array('SHOW transaction_read_only'))[0], 'off', "$label: nothing read only left");
            $dbh->do('INSERT INTO hs_a.t VALUES (71)');
            $dbh->commit;
            is(($admin->selectrow_array('SELECT count(*) FROM hs_a.t WHERE id IN (70, 71)'))[0], 2, "$label: the host's work stands");
            $admin->do('DELETE FROM hs_a.t WHERE id IN (70, 71)');
        } else {
            ok(!$dbh->{Active}, "$label: the connection is closed");
            ok(!eval { $dbh->do('INSERT INTO hs_a.t VALUES (71)'); $dbh->commit; 1 }, "$label: the host hears of it");
            is(($admin->selectrow_array('SELECT count(*) FROM hs_a.t WHERE id IN (70, 71)'))[0], 0, "$label: nothing is reported stored that is not");
        }
        $dbh->disconnect;
    }
    # Still read only, and still UTF8.
    {
        my $dbh = TestPostgreSQL->connect;
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        is($answer->($adapter, 'postgresql', 'EXPLAIN ANALYZE INSERT INTO hs_a.t VALUES (9)'), 'refused read_only_transaction', 'EXPLAIN ANALYZE of a write refuses');
        is($answer->($adapter, 'postgresql', 'SHOW transaction_read_only'), 'on', 'and the read is read only');
        $dbh->do(q{SET client_encoding = 'LATIN1'});
        is($answer->($adapter, 'postgresql', 'SELECT 1'), 'refused client_encoding', 'R65 stands');
        $dbh->disconnect;
    }
    is(($admin->selectrow_array('SELECT count(*) FROM hs_a.t'))[0], 1, 'nothing written');
    $admin->do($_) for @clean;
    $admin->disconnect;
};

for my $family (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($name, $env) = @$family;
    subtest $name => sub {
        plan skip_all => "$env is not set" unless ($ENV{$env} // '') ne '';
        plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };
        my $url = Mojo::URL->new($ENV{$env});
        my $db = $url->path->to_string =~ s{\A/}{}r;
        my $connect = sub {
            my (%options) = @_;
            my ($user, $password) = split /:/, $url->userinfo // '', 2;
            return DBI->connect('dbi:MariaDB:' . ($options{nodb} ? '' : "database=$db;") . 'host=' . $url->host . ';port=' . $url->port, $user, $password,
                {RaiseError => 1, PrintError => 0, AutoCommit => $options{auto} // 1});
        };
        my $admin = $connect->();
        my @clean = ('DROP TABLE IF EXISTS hs_t, hs_l');
        $admin->do($_) for @clean, 'CREATE TABLE hs_t (id INT PRIMARY KEY, note VARCHAR(20), d DECIMAL(6,2), ts TIMESTAMP NULL) ENGINE=InnoDB', 'CREATE TABLE hs_l (id INT) ENGINE=InnoDB',
            q{INSERT INTO hs_t VALUES (1, 'a', 1.50, '2026-01-02 03:04:05')};
        for my $set (q{SET time_zone = '+09:00'}, q{SET sql_mode = ''}) {
            for my $sql ('SELECT ts FROM hs_t', 'SELECT d FROM hs_t', 'SELECT @@session.time_zone', 'SELECT @@sql_mode', 'SHOW COLUMNS FROM hs_t', 'DESCRIBE hs_t', 'EXPLAIN SELECT id FROM hs_t') {
                my ($native, $dbh) = ($connect->(), $connect->());
                $_->do($set) for $native, $dbh;
                is($answer->(Selecto->adapter($name => (dbh => $dbh)), $name, $sql), $flat->($native->selectall_arrayref($sql)), "$set: $sql");
                $_->disconnect for $native, $dbh;
            }
        }
        # A classifier fails closed: comments the server reads, and a mode that moves where strings end.
        my $state = sub { join '|', map { $_->[0] } @{$admin->selectall_arrayref('SELECT id FROM hs_t ORDER BY id')} };
        for my $set (undef, q{SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES'}) {
            for my $sql (q{WITH c AS (SELECT 1 AS a) /*!50000 DELETE FROM hs_t */}, q{WITH c AS (SELECT 1 AS a) /*! DELETE FROM hs_t WHERE id = 1 */ SELECT a FROM c}, q{SELECT 1 /*!50000 , (SELECT 1) */},
                q{WITH c AS (SELECT '\' AS a) DELETE hs_t FROM hs_t WHERE note = '\' OR 1 = 1}, q{WITH c AS (SELECT '\'), d AS (SELECT ') DELETE hs_t FROM hs_t -- ' AS a) SELECT 1},
                q{WITH c AS (SELECT 'x\') SELECT 2, (SELECT 1) AS a) UPDATE (hs_t) SET note = 'z'}, q{EXPLAIN ANALYZE DELETE FROM hs_t},
                q{WITH c AS (SELECT 1 AS `a\`) UPDATE hs_t SET note = 'z'}, q{WITH c AS (SELECT 1 AS `a\`) UPDATE (hs_t) SET note = 'z'}) {
                my $dbh = $connect->();
                $dbh->do($set) if $set;
                $dbh->begin_work;
                # (Under that mode one of these is a harmless SELECT 1, in the other a DELETE:
                # only the server can say which, and the row is what matters.)
                my $result = $answer->(Selecto->adapter($name => (dbh => $dbh)), $name, $sql);
                like($result, qr/\Arefused/, ($set ? 'NO_BACKSLASH_ESCAPES: ' : '') . "refused: $sql") unless $set && $sql =~ /d AS \(SELECT/;
                $dbh->commit;
                $dbh->disconnect;
                is($state->(), '1', 'and nothing deleted');
                is(($admin->selectrow_array('SELECT note FROM hs_t'))[0], 'a', 'or changed');
            }
        }
        # Row locks are the host's to take: every form refuses, on every route (R72).
        for my $sql (q{SELECT id FROM hs_t FOR UPDATE}, q{SELECT id FROM hs_t LOCK IN SHARE MODE}, q{SELECT id FROM hs_t FOR /* c */ UPDATE}, ($name eq 'mysql' ? q{SELECT id FROM hs_t FOR SHARE} : ())) {
            for my $host (0, 1) {
                my $dbh = $connect->();
                my $adapter = Selecto->adapter($name => (dbh => $dbh));
                $dbh->begin_work if $host;
                like($answer->($adapter, $name, $sql), qr/\Arefused hand_built_not_a_read/, ($host ? 'host: ' : 'alone: ') . "refused: $sql");
                ok(!eval { $adapter->stream_query(Selecto::Statement->new(sql => $sql, params => [], columns => ['a'], adapter_name => $name)); 1 }, 'and as a stream');
                $dbh->rollback if $host;
                $dbh->disconnect;
            }
        }
        # What the server can tell apart answers: EXPLAIN ANALYZE of a read, in the host's transaction too.
        if ($name eq 'mysql') {
            my $dbh = $connect->();
            $dbh->begin_work;
            unlike($answer->(Selecto->adapter($name => (dbh => $dbh)), $name, 'EXPLAIN ANALYZE SELECT id FROM hs_t'), qr/\Arefused/, 'EXPLAIN ANALYZE of a read answers');
            $dbh->rollback;
            $dbh->disconnect;
        }
        # A connection Selecto has to close stays closed, whatever the driver would like to do.
        for my $open (['begin_work', sub { $_[0]->begin_work }], ['START TRANSACTION', sub { $_[0]->do('START TRANSACTION') }]) {
            my ($label, $begin) = @$open;
            $admin->do('DELETE FROM hs_l');
            my ($user, $password) = split /:/, $url->userinfo // '', 2;
            my $dbh = DBI->connect("dbi:MariaDB:database=$db;host=" . $url->host . ';port=' . $url->port . ';mariadb_auto_reconnect=1', $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
            $dbh->do(q{SET SESSION time_zone = '+00:00', sql_mode = 'STRICT_TRANS_TABLES', NAMES utf8mb4});
            my $adapter = Selecto->adapter($name => (dbh => $dbh));
            $begin->($dbh);
            $dbh->do('INSERT INTO hs_l VALUES (1)');
            # (As an out-of-step connection is closed: the echo that proves it does not come back.)
            {
                no warnings 'redefine';
                local *Selecto::MySQLFamily::_in_step = sub { 0 };
                local $adapter->{_selecto_operation} = 1;
                $adapter->normalize_error("alarm\n");
            }
            ok(!$dbh->{Active}, "$label: closed");
            ok(!eval { $dbh->do('INSERT INTO hs_l VALUES (2)'); 1 }, "$label: the host's next statement fails, with reconnect asked for");
            ok(!eval { $dbh->do('COMMIT'); 1 }, "$label: and so does its COMMIT");
            is(($admin->selectrow_array('SELECT count(*) FROM hs_l'))[0], 0, "$label: nothing is reported stored that is not");
        }
        # Whose transaction it is: known before anything is sent, however the host opened it.
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HS', source => {source_table => 'hs_t', primary_key => 'id',
            fields => [qw(id note)], columns => {id => {type => 'integer'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}});
        for my $open (['begin_work', sub { $_[0]->begin_work }, sub { $_[0]->commit }], ['AutoCommit off', sub {}, sub { $_[0]->commit }, 0],
            ['START TRANSACTION', sub { $_[0]->do('START TRANSACTION') }, sub { $_[0]->do('COMMIT') }], ['SET autocommit = 0', sub { $_[0]->do('SET autocommit = 0') }, sub { $_[0]->do('COMMIT') }]) {
            my ($label, $begin, $end, $auto) = @$open;
            for my $fail (undef, qr/\ASET TRANSACTION READ ONLY\z/) {
                for my $work ('read', 'hand-built') {
                    my $case = "$label, $work" . ($fail ? ', killed' : '');
                    $admin->do('DELETE FROM hs_l');
                    my $dbh = $connect->(auto => $auto);
                    $dbh->do(q{SET SESSION time_zone = '+00:00', sql_mode = 'STRICT_TRANS_TABLES', NAMES utf8mb4});
                    my $adapter = Selecto->adapter($name => (dbh => $dbh));
                    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
                    my @sent;
                    $begin->($dbh);
                    $dbh->do('INSERT INTO hs_l VALUES (1)');
                    {
                        no warnings 'redefine';
                        my $do = \&DBD::MariaDB::db::do;
                        my $left = 1;
                        local *DBD::MariaDB::db::do = sub {
                            my ($h, $sql) = @_;
                            push @sent, $sql;
                            die "DBD::MariaDB::db do failed: Query execution was interrupted\n" if $fail && $sql =~ $fail && $left-- > 0;
                            return $do->(@_);
                        };
                        eval { $work eq 'read' ? $engine->all($engine->query->select('id')) : $adapter->execute_query(Selecto::Statement->new(sql => 'SELECT id FROM hs_t', params => [], adapter_name => $name)) };
                    }
                    is_deeply([grep { /\A(?:ROLLBACK|COMMIT|SET autocommit)/ } @sent], [], "$case: nothing that ends a transaction was sent");
                    $dbh->do('INSERT INTO hs_l VALUES (2)');
                    $end->($dbh);
                    $dbh->do('SET autocommit = 1') if $label eq 'SET autocommit = 0';
                    $dbh->disconnect;
                    is(($admin->selectrow_array('SELECT count(*) FROM hs_l'))[0], 2, "$case: the host's work is all there");
                }
            }
        }
        # Locks are the host's, wherever the session stands.
        for my $nodb (0, 1) {
            my $dbh = $connect->(nodb => $nodb);
            my $table = "`$db`.hs_t";
            $dbh->do("LOCK TABLES $table READ");
            is($answer->(Selecto->adapter($name => (dbh => $dbh)), $name, "SELECT id FROM $table"), '1', ($nodb ? 'no default database: ' : '') . 'a read under LOCK TABLES');
            $admin->do('SET SESSION lock_wait_timeout = 1');
            ok(!eval { $admin->do('UPDATE hs_t SET note = note, d = d + 0 WHERE id = 1'); 1 }, 'and the lock holds after it');
            $admin->do('SET SESSION lock_wait_timeout = 30');
            $dbh->do('UNLOCK TABLES');
            $dbh->disconnect;
        }
        $admin->do($_) for @clean;
        $admin->disconnect;
    };
}

done_testing;
