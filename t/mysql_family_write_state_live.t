use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use POSIX ();
use Scalar::Util qw(blessed);
use Time::HiRes qw(sleep);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::Write ();

# MySQL/MariaDB write state against concurrent sessions: a deadlock victim
# keeps its typed retryable error, and RETURNING images come from locking
# reads, never from the transaction's REPEATABLE READ snapshot.

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';
plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };

my $x = 'Selecto::Expression';

sub open_db {
    my ($backend, $url) = @_;
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url, $backend);
    return DBI->connect($dsn, $username, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
}

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub domain {
    return TestSelecto::writable_domain(name => 'Rows', table => 'selecto_ws_rows',
        fields => {id => 'integer', code => 'string', hits => 'integer'}, conflict_targets => [['code']]);
}

for my $specification (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($backend, $environment) = @$specification;
    subtest "$backend write state" => sub {
        plan skip_all => "$environment is not configured"
            unless defined($ENV{$environment}) && $ENV{$environment} ne '';
        my $url = $ENV{$environment};
        my $dbh = open_db($backend, $url);
        my $reset = sub {
            $dbh->do('DROP TABLE IF EXISTS selecto_ws_rows');
            $dbh->do('CREATE TABLE selecto_ws_rows (id int primary key, code varchar(20) not null, hits int not null, '
                . 'unique key ws_code (code)) ENGINE=InnoDB');
            $dbh->do(q{INSERT INTO selecto_ws_rows VALUES (1, 'r', 1)});
        };

        subtest 'an upsert that is the deadlock victim keeps its typed retryable error' => sub {
            $reset->();
            my $engine = Selecto::Engine->new(domain => domain(), adapter => Selecto->adapter($backend => (dbh => $dbh)));
            $dbh->begin_work;
            $dbh->do('UPDATE selecto_ws_rows SET hits = hits + 1 WHERE id = 1');
            pipe(my $reader, my $writer) or die "pipe: $!";
            my $pid = fork;
            die "fork failed\n" unless defined $pid;
            if (!$pid) {
                close $reader;
                my $other = open_db($backend, $url);
                $other->begin_work;
                # Heavier than the host transaction, so the server picks the
                # host as the deadlock victim.
                $other->do('INSERT INTO selecto_ws_rows VALUES (?, ?, 0)', undef, 200 + $_, "f$_") for 1 .. 20;
                $other->do(q{INSERT INTO selecto_ws_rows VALUES (100, 'k', 0)});
                syswrite $writer, "ready\n";
                my $ok = eval { $other->do('UPDATE selecto_ws_rows SET hits = hits + 10 WHERE id = 1'); 1 };
                eval { $ok ? $other->rollback : $other->rollback };
                POSIX::_exit(0);
            }
            close $writer;
            my $line = <$reader>;
            sleep 0.5;
            my $upsert = Selecto::Write::Command->new(operation => 'upsert', relation => 'selecto_ws_rows',
                assignments => {id => 101, code => 'k', hits => 5},
                metadata => {conflict_target => ['code'], upsert_update_fields => ['hits']});
            my $code = code_of(sub { $engine->execute_write($upsert) });
            eval { $dbh->rollback };
            waitpid($pid, 0);
            is($code, 'database_deadlock_detected', 'the deadlock is reported as database_deadlock_detected');
        };

        subtest 'a RETURNING delete returns the row it deleted, not the snapshot' => sub {
            $reset->();
            my $other = open_db($backend, $url);
            my $engine = Selecto::Engine->new(domain => domain(), adapter => Selecto->adapter($backend => (dbh => $dbh)));
            $dbh->begin_work;
            $dbh->selectall_arrayref('SELECT hits FROM selecto_ws_rows WHERE id = 1');
            $other->do('UPDATE selecto_ws_rows SET hits = 2 WHERE id = 1');
            my $result;
            my $code = code_of(sub { $result = $engine->execute_write(Selecto::Write::Command->new(operation => 'delete',
                relation => 'selecto_ws_rows', predicate => $x->eq('id', 1), metadata => {returning => ['id', 'hits']})) });
            $dbh->commit;
            is($code, 'ok', 'the delete runs');
            is_deeply($result && $result->values, {id => 1, hits => 2}, 'it returns the committed row it deleted');
            $other->disconnect;
        };

        subtest 'a no-op RETURNING update returns the current row, not the snapshot' => sub {
            $reset->();
            my $other = open_db($backend, $url);
            my $engine = Selecto::Engine->new(domain => domain(), adapter => Selecto->adapter($backend => (dbh => $dbh)));
            $dbh->begin_work;
            $dbh->selectall_arrayref('SELECT hits FROM selecto_ws_rows WHERE id = 1');
            $other->do('UPDATE selecto_ws_rows SET hits = 5 WHERE id = 1');
            my $result;
            my $code = code_of(sub { $result = $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
                relation => 'selecto_ws_rows', assignments => {hits => 5}, predicate => $x->eq('id', 1),
                metadata => {returning => ['id', 'hits']})) });
            $dbh->commit;
            is($code, 'ok', 'the update runs');
            is_deeply($result && $result->values, {id => 1, hits => 5}, 'it returns the row as it is now');
            $other->disconnect;
        };

        subtest 'a no-op RETURNING upsert returns the current row, not the snapshot' => sub {
            $reset->();
            my $other = open_db($backend, $url);
            my $engine = Selecto::Engine->new(domain => domain(), adapter => Selecto->adapter($backend => (dbh => $dbh)));
            $dbh->begin_work;
            $dbh->selectall_arrayref('SELECT hits FROM selecto_ws_rows WHERE id = 1');
            $other->do('UPDATE selecto_ws_rows SET hits = 7 WHERE id = 1');
            my $result;
            my $code = code_of(sub { $result = $engine->execute_write(Selecto::Write::Command->new(operation => 'upsert',
                relation => 'selecto_ws_rows', assignments => {id => 1, code => 'r', hits => 7},
                metadata => {conflict_target => ['code'], upsert_update_fields => ['hits'], returning => ['id', 'hits']})) });
            $dbh->commit;
            is($code, 'ok', 'the upsert runs');
            is_deeply($result && $result->values, {id => 1, hits => 7}, 'it returns the row as it is now');
            $other->disconnect;
        };

        $dbh->do('DROP TABLE IF EXISTS selecto_ws_rows');
        $dbh->disconnect;
    };
}

done_testing;
