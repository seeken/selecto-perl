use 5.034;
use strict;
use warnings;
use Test::More;
use POSIX ();
use Time::HiRes qw(setitimer ITIMER_REAL time);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# A host's alarm at any point of a read, idle or in its transaction: afterwards nothing of
# the read remains, no BEGIN READ ONLY, no read-only state, and the host's next INSERT stores.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $n = $ENV{SELECTO_PERL_ALARM_READS} // 150;
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS ra_t, ra_l');
$admin->do($_) for @clean, 'CREATE TABLE ra_t (id INT PRIMARY KEY, org TEXT NOT NULL)', 'CREATE TABLE ra_l (hit INT PRIMARY KEY)', q{INSERT INTO ra_t VALUES (1, 't1'), (2, 't1')};
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'RA', source => {source_table => 'ra_t', primary_key => 'id', tenant_field => 'org',
    fields => [qw(id org)], columns => {id => {type => 'integer'}, org => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}});
my $serial = 0;
# (A one-shot timer can go off as the host cancels it: that is the host's to allow for,
# and it must not end this test. It is counted, and it never touches the handle.)
my $late = 0;
$SIG{ALRM} = sub { $late++ };
for my $mode (qw(alone host)) {
    for my $route (qw(read hand-built stream bounded)) {
        my $dbh = TestPostgreSQL->connect;
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter)->with_scope(tenant => 't1');
        my %work = (read => sub { $engine->all($engine->query->select('id')) }, 'hand-built' => sub { $adapter->execute_query(Selecto::Statement->new(sql => 'SELECT id FROM ra_t', params => [], adapter_name => 'postgresql')) },
            stream => sub { my $s = $engine->stream($engine->query->select('id')); 1 while $s->next; $s->close }, bounded => sub { my $s = $engine->stream($engine->query->select('id'), bounded => 1, fetch_size => 1); 1 while $s->next; $s->close });
        my $started = time;
        $work{$route}->() for 1 .. 10;
        my $span = (time - $started) / 10;
        my @bad;
        for (1 .. $n) {
            my $hit = ++$serial * 10;
            if ($mode eq 'host') { $dbh->begin_work; $dbh->do("INSERT INTO ra_l VALUES ($hit)") }
            eval {
                local $SIG{ALRM} = sub { die "alarm\n" };
                eval { setitimer(ITIMER_REAL, 0.00002 + rand($span * 1.2)); $work{$route}->(); setitimer(ITIMER_REAL, 0); 1 };
                setitimer(ITIMER_REAL, 0);
            };
            my $held = POSIX::SigSet->new;
            POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new, $held);
            push @bad, 'the alarm is left blocked' if $held->ismember(POSIX::SIGALRM());
            my $status = $dbh->pg_ping;
            push @bad, "status $status" if $status != ($mode eq 'host' ? 3 : 1);
            push @bad, 'read only left' if (eval { ($dbh->selectrow_array('SHOW transaction_read_only'))[0] } // 'unknown') ne 'off';
            push @bad, 'DBI state' if $mode eq 'alone' && !$dbh->{AutoCommit};
            my $stored = eval { $dbh->do('INSERT INTO ra_l VALUES (' . ($hit + 1) . ')'); $dbh->commit if $mode eq 'host'; 1 };
            push @bad, 'host write refused: ' . ($dbh->errstr // '') unless $stored;
            eval { $dbh->rollback } unless $dbh->{AutoCommit};
            my ($count) = $admin->selectrow_array("SELECT count(*) FROM ra_l WHERE hit IN ($hit, " . ($hit + 1) . ')');
            push @bad, "stored $count" unless $count == ($mode eq 'host' ? 2 : 1);
            last if @bad;
        }
        is_deeply(\@bad, [], "$mode, $route: $n alarms leave nothing behind");
        $dbh->disconnect;
    }
}
is($late, 0, 'no alarm arrived after the host stopped waiting');
$admin->do($_) for @clean;
$admin->disconnect;
done_testing;
