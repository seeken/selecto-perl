use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use IO::Handle;
use POSIX ();
use Scalar::Util qw(blessed);
use Socket;
use Time::HiRes qw(time);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# A real pg_cancel_backend at a random moment of a read: whatever it hits, a guard
# included, it is a cancel, and a cancel is not a refusal. Afterwards an idle handle is
# idle, with AutoCommit on, and a host's healthy transaction still is one.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $n = $ENV{SELECTO_PERL_CANCEL_READS} // 120;
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS cs_t');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE cs_t (id INT PRIMARY KEY, org TEXT NOT NULL)', q{INSERT INTO cs_t SELECT i, 't1' FROM generate_series(1, 5) i};
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'CS', source => {source_table => 'cs_t', primary_key => 'id', tenant_field => 'org', fields => [qw(id org)],
    columns => {id => {type => 'integer'}, org => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}});
for my $mode (qw(alone host)) {
    for my $route (qw(read hand-built stream bounded)) {
        my ($dbh, $adapter, $engine, %work);
        my $connect = sub {
            $dbh = TestPostgreSQL->connect;
            $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
            $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter)->with_scope(tenant => 't1');
            %work = (read => sub { $engine->all($engine->query->select('id')) }, 'hand-built' => sub { $adapter->execute_query(Selecto::Statement->new(sql => 'SELECT id FROM cs_t', params => [], adapter_name => 'postgresql')) },
                stream => sub { my $s = $engine->stream($engine->query->select('id')); 1 while $s->next; $s->close }, bounded => sub { my $s = $engine->stream($engine->query->select('id'), bounded => 1, fetch_size => 2); 1 while $s->next; $s->close });
        };
        $connect->();
        socketpair(my $parent, my $child, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die $!;
        $_->autoflush(1) for $parent, $child;
        my $killer = fork // die $!;
        unless ($killer) {
            close $parent;
            $_->{InactiveDestroy} = 1 for $dbh, $admin;
            my $k = TestPostgreSQL->connect;
            my $cancel = $k->prepare('SELECT pg_catalog.pg_cancel_backend(?)');
            while (my $line = <$child>) {
                my ($pid, $wait) = split ' ', $line;
                my $until = time + $wait;
                1 while time < $until;
                $cancel->execute($pid);
                $cancel->finish;
                print $child "ok\n";
            }
            POSIX::_exit(0);
        }
        close $child;
        my $started = time;
        $work{$route}->() for 1 .. 10;
        my $span = (time - $started) / 10;
        my (%types, @bad);
        for (1 .. $n) {
            $connect->() unless $dbh->{Active};
            $dbh->begin_work if $mode eq 'host';
            print $parent "$dbh->{pg_pid} ", rand($span * 1.1), "\n";
            my $ok = eval { $work{$route}->(); 1 };
            my $error = $@;
            my $ack = <$parent>;
            unless ($ok) {
                my $type = blessed($error) && $error->can('details') ? join('/', $error->code, $error->details->{category} // $error->details->{reason} // '') : "untyped: $error";
                $types{$type}++;
            }
            next unless $dbh->{Active};
            my $status = $dbh->pg_ping;
            if ($mode eq 'alone') {
                push @bad, "idle handle left at status $status" if $status != 1;
                push @bad, 'AutoCommit left off' unless $dbh->{AutoCommit};
            } else {
                push @bad, 'a read that answered left the transaction failed' if $ok && $status == 4;
                eval { $dbh->rollback };
            }
            last if @bad;
        }
        close $parent;
        waitpid($killer, 0);
        is_deeply([grep { !m{\A(?:query_error|stream_cleanup_failed)/query_canceled\z} } sort keys %types], [], "$mode, $route: every interrupted read stayed a cancel") or diag explain \%types;
        is_deeply(\@bad, [], "$mode, $route: and left nothing behind");
        $dbh->disconnect if $dbh->{Active};
    }
}
$admin->do($_) for @clean;
done_testing;
