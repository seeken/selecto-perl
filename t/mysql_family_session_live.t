use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::Write ();

# Every MySQL/MariaDB read, stream and write checks the session first, per
# call: a UTC time zone, utf8mb4 character sets, a strict sql_mode and exact
# client decoding. A session the host changed after an earlier call is
# refused with invalid_connection before anything runs. On MariaDB a write
# also refuses a server transaction opened outside the driver.

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';
plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };

sub open_db {
    my ($backend, $url) = @_;
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url, $backend);
    return DBI->connect($dsn, $username, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
}

sub failure {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error')
        ? $error->code . '/' . (($error->details // {})->{reason} // '') : "died: $error";
}

for my $specification (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($backend, $environment) = @$specification;
    subtest "$backend session contract" => sub {
        plan skip_all => "$environment is not configured"
            unless defined($ENV{$environment}) && $ENV{$environment} ne '';
        my $dbh = open_db($backend, $ENV{$environment});
        $dbh->do('DROP TABLE IF EXISTS selecto_session_rows');
        $dbh->do('CREATE TABLE selecto_session_rows (id int primary key, name varchar(20)) ENGINE=InnoDB');
        $dbh->do(q{INSERT INTO selecto_session_rows VALUES (1, 'a')});
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($backend => (dbh => $dbh)),
            domain => TestSelecto::writable_domain(name => 'Rows', table => 'selecto_session_rows',
                fields => {id => 'integer', name => 'string'}));
        my $read = sub { $engine->all($engine->query->select('id', 'name')) };
        my $stream = sub { my $s = $engine->stream($engine->query->select('id')); while ($s->next) { } $s->close };
        my $write = sub {
            $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_session_rows',
                assignments => {name => 'b'}, predicate => Selecto::Expression->eq('id', 1)));
        };
        my ($mode) = $dbh->selectrow_array('SELECT @@SESSION.sql_mode');
        my $restore = sub {
            $dbh->do(q{SET time_zone = '+00:00'});
            $dbh->do('SET NAMES utf8mb4');
            $dbh->do('SET SESSION sql_mode = ?', undef, $mode);
        };
        $restore->();
        is(failure($read), 'ok', 'a UTC, utf8mb4, strict session reads');
        is(failure($stream), 'ok', 'and streams');
        is(failure($write), 'ok', 'and writes');
        $dbh->do(q{SET time_zone = 'SYSTEM'});
        my ($system) = $dbh->selectrow_array('SELECT @@system_time_zone');
        is(failure($read), $system eq 'UTC' || $system eq '+00:00' ? 'ok' : 'invalid_connection/session_time_zone',
            "SYSTEM is accepted only when the server's own zone is UTC ($system)");

        for my $case (
            [q{SET time_zone = '+01:00'}, 'session_time_zone'],
            [q{SET time_zone = '-00:30'}, 'session_time_zone'],
            ['SET SESSION sql_mode = ?', 'session_sql_mode', 'NO_ENGINE_SUBSTITUTION'],
            ['SET character_set_results = latin1', 'session_character_set'],
            ['SET character_set_client = latin1', 'session_character_set'],
        ) {
            my ($sql, $reason, @bind) = @$case;
            $restore->();
            is(failure($read), 'ok', 'the session is valid before the host changes it');
            $dbh->do($sql, undef, @bind);
            my $expected = "invalid_connection/$reason";
            is(failure($read), $expected, "a read after '$sql' is refused ($reason)");
            is(failure($stream), $expected, 'a stream too');
            is(failure($write), $expected, 'a write too');
        }
        $restore->();
        is($dbh->selectrow_array('SELECT name FROM selecto_session_rows WHERE id = 1'), 'b',
            'refused writes changed nothing');

        $dbh->do('UPDATE selecto_session_rows SET name = ? WHERE id = 1', undef, 'a');
        $dbh->do('START TRANSACTION');
        $dbh->do('INSERT INTO selecto_session_rows VALUES (2, ?)', undef, 'host');
        my $outcome = failure($write);
        $dbh->do('ROLLBACK');
        if ($backend eq 'mariadb') {
            is($outcome, 'invalid_adapter/transaction_outside_driver',
                'a write on a server transaction opened outside the driver is refused');
            is($dbh->selectrow_array('SELECT COUNT(*) FROM selecto_session_rows'), 1, 'the host work was not committed');
        }
        # MySQL has no way to report it: hosts open transactions with begin_work.

        $dbh->do('DROP TABLE selecto_session_rows');
        $dbh->disconnect;
    };
}

done_testing;
