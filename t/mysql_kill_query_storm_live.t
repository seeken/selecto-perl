use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use POSIX ();
use Scalar::Util qw(blessed);
use Time::HiRes qw(time sleep);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();

# KILL QUERY can land on anything Selecto sends, the ROLLBACK and the restores
# included. Whatever it hits, the connection afterwards is either closed or as it
# was: autocommit on, nothing read only, nothing open.
my $x = 'Selecto::Expression';
my $seconds = $ENV{SELECTO_PERL_STORM_SECONDS} // 3;
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
        $admin->do($_) for 'DROP TABLE IF EXISTS kq_t, kq_log', 'CREATE TABLE kq_t (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL, note VARCHAR(20)) ENGINE=InnoDB',
            'CREATE TABLE kq_log (id INT) ENGINE=InnoDB', q{INSERT INTO kq_t VALUES (1, 't1', 'a'), (2, 't1', 'b')};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'KQ', source => {source_table => 'kq_t', primary_key => 'id', tenant_field => 'org',
            fields => [qw(id org note)], columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
            writes => {scope => {tenant => {field => 'org'}}, operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
        # What the storm may or may not hit, on purpose: a statement that ends a read
        # or a write fails, once and then for good.
        my $fail = sub {
            my ($sql, $times, $work) = @_;
            my $left = $times;
            no warnings 'redefine';
            my $do = \&DBD::MariaDB::db::do;
            local *DBD::MariaDB::db::do = sub {
                my ($dbh, $statement) = @_;
                if ($statement eq $sql && $left-- > 0) {
                    die "DBD::MariaDB::db do failed: Query execution was interrupted\n";
                }
                return $do->(@_);
            };
            return $work->();
        };
        my $read = sub { my ($e) = @_; $e->all($e->query->select('id'))->{rows} };
        my $write = sub { my ($e) = @_; $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'kq_t', assignments => {note => 'y'},
            predicate => $x->eq('id', 2), expected_count => undef)) };
        my $engine_for = sub { my ($dbh) = @_; Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)))->with_scope(tenant => 't1') };
        my $intact = sub {
            my ($dbh, $label) = @_;
            is_deeply([$dbh->selectrow_array('SELECT @@autocommit, @@SESSION.transaction_read_only')], [1, 0], "$label: autocommit on, not read only");
            ok(eval { $dbh->do('INSERT INTO kq_log VALUES (100)'); 1 }, "$label: the host's next write runs") or diag $@;
            is(($admin->selectrow_array('SELECT count(*) FROM kq_log WHERE id = 100'))[0], 1, "$label: and commits by itself");
            $admin->do('DELETE FROM kq_log');
        };
        for my $sql ('ROLLBACK AND NO CHAIN NO RELEASE', 'SET autocommit = 1') {
            my $dbh = $connect->();
            my $e = $engine_for->($dbh);
            is(scalar(@{$fail->($sql, 2, sub { $read->($e) })}), 2, "$sql interrupted twice: the read still answers");
            $intact->($dbh, "$sql interrupted twice");
            $dbh->disconnect;
            $dbh = $connect->();
            $e = $engine_for->($dbh);
            ok(!eval { $fail->($sql, 1000, sub { $read->($e) }); 1 }, "$sql interrupted for good: the read refuses");
            is(blessed($@) && $@->code, 'transaction_state_unsafe', 'typed');
            ok(!$dbh->{Active}, 'and the connection is closed, not left in the wrong mode');
        }
        {
            my $dbh = $connect->();
            my $e = $engine_for->($dbh);
            ok(!eval { $fail->('SET autocommit = 0', 1, sub { $read->($e) }); 1 }, 'a read that cannot start fails');
            $intact->($dbh, 'a read that could not start');
            $dbh->disconnect;
            # The write path: its rollback, and DBI's AutoCommit after it.
            my $bad = Selecto::Write::Command->new(operation => 'update', relation => 'kq_t', assignments => {note => 'z' x 100}, predicate => $x->eq('id', 2), expected_count => undef);
            $dbh = $connect->();
            $e = $engine_for->($dbh);
            ok(!eval { $fail->('ROLLBACK AND NO CHAIN NO RELEASE', 2, sub { $e->execute_write($bad) }); 1 }, 'a refused write, its rollback interrupted twice');
            $intact->($dbh, 'after that write');
            is(($admin->selectrow_array('SELECT note FROM kq_t WHERE id = 2'))[0], 'b', 'nothing of it stayed');
            $dbh->disconnect;
            $dbh = $connect->();
            $e = $engine_for->($dbh);
            ok(!eval { $fail->('ROLLBACK AND NO CHAIN NO RELEASE', 1000, sub { $e->execute_write($bad) }); 1 }, 'a refused write, its rollback lost for good');
            ok(!$dbh->{Active}, 'closes the connection');
            is(($admin->selectrow_array('SELECT note FROM kq_t WHERE id = 2'))[0], 'b', 'and nothing of it stayed');
        }

        my %count;
        my @bad;
        my $serial = 0;
        my $finish = time + $seconds;
        while (time < $finish) {
            my $dbh = $connect->();
            my $id = ($dbh->selectrow_array('SELECT CONNECTION_ID()'))[0];
            my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)))->with_scope(tenant => 't1');
            my $killer = fork // die;
            if (!$killer) {
                $_->{InactiveDestroy} = 1 for $dbh, $admin;
                my $k = $connect->();
                my $stop = time + 0.4;
                while (time < $stop) { eval { $k->do("KILL QUERY $id") }; }
                $k->disconnect;
                POSIX::_exit(0);
            }
            my $stop = time + 0.4;
            while (time < $stop && $dbh->{Active}) {
                my $kind = int(rand(2));
                my $ok = eval {
                    $kind ? $engine->all($engine->query->select('id')) : $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'kq_t',
                        assignments => {note => 'x'}, predicate => $x->eq('id', 1), expected_count => undef));
                    1;
                };
                $count{$ok ? 'answered' : 'interrupted'}++;
            }
            waitpid($killer, 0);
            # The storm is over. Closed, or exactly as it was.
            if (!$dbh->{Active}) {
                $count{closed}++;
                next;
            }
            my ($auto, $mode) = eval { $dbh->selectrow_array('SELECT @@autocommit, @@SESSION.transaction_read_only') };
            push @bad, "autocommit=" . ($auto // 'undef') . " read_only=" . ($mode // 'undef') unless ($auto // '') eq '1' && ($mode // '') eq '0';
            push @bad, 'DBI AutoCommit off' unless $dbh->{AutoCommit};
            push @bad, 'DBI BegunWork on' if $dbh->{BegunWork};
            my $mark = ++$serial;
            my $wrote = eval { $dbh->do('INSERT INTO kq_log VALUES (?)', undef, $mark); 1 };
            push @bad, 'the next write failed: ' . ($dbh->err // '') unless $wrote;
            push @bad, 'the next write did not commit by itself' if $wrote && !($admin->selectrow_array('SELECT count(*) FROM kq_log WHERE id = ?', undef, $mark))[0];
            $count{checked}++;
            $dbh->disconnect;
        }
        is_deeply(\@bad, [], 'no connection was left open in the wrong mode');
        ok($count{checked} // 0, 'and some connections came through to be checked');
        note explain \%count;
        diag join ' ', map { "$_=$count{$_}" } sort keys %count;
        $admin->do('DROP TABLE kq_t, kq_log');
        $admin->disconnect;
    };
}

done_testing;
