use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use POSIX ();
use Scalar::Util qw(blessed);
use Selecto::Statement;
use Time::HiRes qw(time setitimer ITIMER_REAL);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;

# A host's timeout around a read, by alarm: at any point, then one INSERT on the same
# handle. A reply left unread would answer that INSERT, which then reports success
# for a row never stored; a read cut off between statements would leave autocommit
# off, and the row would go at close. What is reported stored must be stored.
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
        $admin->do($_) for 'DROP TABLE IF EXISTS al_t, al_log', 'CREATE TABLE al_t (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL) ENGINE=InnoDB',
            'CREATE TABLE al_log (hit INT PRIMARY KEY) ENGINE=InnoDB', q{INSERT INTO al_t VALUES (1, 't1'), (2, 't1'), (3, 't1')};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'AL', source => {source_table => 'al_t', primary_key => 'id', tenant_field => 'org',
            fields => [qw(id org)], columns => {id => {type => 'integer'}, org => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}});
        # A host's exception stands inside an operation; asked directly, the adapter
        # always answers with a typed error.
        {
            my $adapter = Selecto->adapter($name => (dbh => $admin));
            my $error = $adapter->normalize_error('synthetic');
            ok(blessed($error) && $error->isa('Selecto::Error'), 'normalize_error is typed for anything it is given');
            ok($admin->{Active}, 'and an in-step connection stays open');
        }
        # An unsafe handler (POSIX::sigaction, as Sys::SigAction uses) dies inside the
        # driver while the reply is awaited, so it stays on the wire, and the host's
        # next statement would take it for its own. Selecto closes such a connection.
        # (In a child: an unsafe die can also take the process down, and that is a pass.)
        for my $host (0, 1) {
            my $where = $host ? 'in a host transaction' : 'alone';
            for my $sql ('SELECT SLEEP(0.25)', 'SELECT id FROM al_t WHERE SLEEP(0.1) = 0') {
                pipe(my $read, my $write) or die $!;
                my $pid = fork // die $!;
                unless ($pid) {
                    close $read;
                    $admin->{InactiveDestroy} = 1;
                    my $dbh = $connect->();
                    my $adapter = Selecto->adapter($name => (dbh => $dbh));
                    $dbh->begin_work if $host;
                    POSIX::sigaction(POSIX::SIGALRM(), POSIX::SigAction->new(sub { die "alarm\n" }));
                    my $done = eval { setitimer(ITIMER_REAL, 0.05); $adapter->execute_query(Selecto::Statement->new(sql => $sql, params => [], columns => ['a'], adapter_name => $name)); 1 };
                    my $error = $@;
                    setitimer(ITIMER_REAL, 0);
                    POSIX::sigaction(POSIX::SIGALRM(), POSIX::SigAction->new('IGNORE'));
                    select(undef, undef, undef, 0.4);
                    my $answer = $dbh->{Active} ? eval { ($dbh->selectrow_array(q{SELECT 'echo'}))[0] } // 'out of step' : 'closed';
                    print $write(($done ? 'finished' : "$error" =~ /alarm/ ? 'interrupted' : "other: $error") . " $answer\n");
                    close $write;
                    POSIX::_exit(0);
                }
                close $write;
                my $line = <$read> // 'crashed';
                waitpid($pid, 0);
                chomp $line;
                like($line, qr/\A(?:interrupted closed|interrupted echo|finished echo|crashed)\z/, "unsafe alarm $where, $sql: closed, or still in step");
            }
        }
        for my $route ('safe') {
            # The host's handler dies only while the host waits on the read. Outside it an
            # alarm held back until a guard lets go (the read's own end, or a handle's
            # cleanup) is only counted: it cannot fail the test after its checks pass.
            my (%count, %reported);
            local $SIG{ALRM} = sub { $count{late}++ };
            my $serial = 0;
            my $finish = time + $seconds;
            while (time < $finish) {
                my $dbh = $connect->();
                my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)))->with_scope(tenant => 't1');
                my $query = $engine->query->select('id');
                my $done = eval {
                    local $SIG{ALRM} = sub { die "alarm\n" };
                    setitimer(ITIMER_REAL, 0.0001 + rand(0.006));
                    $engine->all($query);
                    setitimer(ITIMER_REAL, 0);
                    1;
                };
                my $error = $@;
                eval { setitimer(ITIMER_REAL, 0) };
                $count{$done ? 'finished' : 'interrupted'}++;
                $count{alarm_kept}++ if !$done && "$error" =~ /alarm/;
                my $mark = ++$serial;
                if ($dbh->{Active}) { $reported{$mark} = 1 if eval { $dbh->do('INSERT INTO al_log VALUES (?)', undef, $mark); 1 } } else { $count{closed}++ }
                eval { $dbh->disconnect };
                undef $engine;
            }
            setitimer(ITIMER_REAL, 0);
            my %stored = map { ($_->[0] => 1) } @{$admin->selectall_arrayref('SELECT hit FROM al_log')};
            is_deeply([grep { !$stored{$_} } sort { $a <=> $b } keys %reported], [], "$route alarm: every write reported stored was stored");
            ok($count{interrupted}, "$route alarm: some reads were interrupted");
            diag "$route: " . join ' ', (map { "$_=$count{$_}" } sort keys %count), 'reported=' . keys(%reported);
            $admin->do('DELETE FROM al_log');
        }
        $admin->do('DROP TABLE al_t, al_log');
        $admin->disconnect;
    };
}

done_testing;
