use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# On a handle with no transaction open a bounded stream runs in a transaction of its
# own, and the handle is the stream's until it closes: what the host does on it between
# fetches is rolled back with that transaction. That is never a silent OK: the close
# says so (stream_host_work_discarded). In the host's transaction, a host that ends its
# own transaction mid-stream keeps its connection. A cancel on the end of one of
# Selecto's own savepoints stays a cancel.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS ho_t, ho_l');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE ho_t (id INT PRIMARY KEY)', 'INSERT INTO ho_t SELECT generate_series(1, 5)', 'CREATE TABLE ho_l (hit INT)';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HO', source => {source_table => 'ho_t', primary_key => 'id',
    fields => ['id'], columns => {id => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {}});
sub kind { my ($e) = @_; return blessed($e) && $e->can('details') ? join('/', $e->code, $e->details->{category} // $e->details->{state} // '') : "untyped: $e" }

my %between = (
    'a temporary table row' => [sub { $_[0]->do('INSERT INTO pg_temp.ho_tmp VALUES (1)') }, 'a write'],
    'a SET'                 => [sub { $_[0]->do(q{SET TimeZone = 'Europe/Paris'}) }, 'a setting'],
    'a session set_config'  => [sub { $_[0]->do(q{SELECT pg_catalog.set_config('lock_timeout', '9s', false)}) }, 'a setting'],
    'a transaction-level advisory lock' => [sub { $_[0]->do('SELECT pg_catalog.pg_advisory_xact_lock(4242)') }, 'a transaction-level advisory lock'],
);
for my $label (sort keys %between) {
    my ($act, $what) = @{$between{$label}};
    for my $end (qw(drain close drop)) {
        subtest "on an idle handle, $label between fetches, then $end" => sub {
            my $dbh = TestPostgreSQL->connect;
            $dbh->do('CREATE TEMP TABLE ho_tmp (x INT)');
            my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
            my @warnings;
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            my $ok = eval {
                my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
                $s->next;
                $act->($dbh);
                if ($end eq 'drain') { 1 while $s->next }
                elsif ($end eq 'close') { $s->close }
                else { undef $s }
                1;
            };
            my $error = $@;
            if ($end eq 'drop') {
                ok($ok, 'a dropped stream cannot raise');
                like(join('', @warnings), qr/rolled back with the stream's own transaction \(\Q$what\E\)/, 'it warns what was rolled back');
            } else {
                ok(!$ok, 'the stream does not end in a silent OK');
                is(kind($error), 'stream_host_work_discarded/', 'it says the work was rolled back');
                is_deeply(ref($error) ? $error->details->{discarded} : undef, [$what], 'and what');
            }
            ok($dbh->{Active} && $dbh->{AutoCommit} && $dbh->pg_ping == 1, 'the handle is idle and open');
            $dbh->disconnect;
        };
    }
}

subtest 'a session advisory lock is not rolled back, and is not reported' => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
    $s->next;
    $dbh->do('SELECT pg_catalog.pg_advisory_lock(4343)');
    ok(eval { 1 while $s->next; 1 }, 'the stream ends') or diag $@;
    is($dbh->selectrow_array(q{SELECT pg_catalog.count(*) FROM pg_catalog.pg_locks WHERE pid = pg_catalog.pg_backend_pid() AND locktype = 'advisory'}), 1, 'and the lock is held');
    $dbh->do('SELECT pg_catalog.pg_advisory_unlock_all()');
    $dbh->disconnect;
};

for my $how (qw(commit rollback COMMIT ROLLBACK)) {
    for my $route (qw(generated hand-built)) {
        subtest "the host ends its transaction mid-stream ($how, $route)" => sub {
            $admin->do('DELETE FROM ho_l');
            my $dbh = TestPostgreSQL->connect;
            my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
            my $e = Selecto::Engine->new(domain => $domain, adapter => $adapter);
            $how =~ /\A[a-z]/ ? $dbh->begin_work : $dbh->do('BEGIN');
            $dbh->do('INSERT INTO ho_l VALUES (1)');
            my $s = $route eq 'generated' ? $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1)
                : $adapter->stream_query(Selecto::Statement->new(sql => 'SELECT id FROM ho_t ORDER BY id', columns => ['id'], adapter_name => 'postgresql'), bounded => 1, fetch_size => 1);
            $s->next;
            if ($how eq 'commit') { $dbh->commit } elsif ($how eq 'rollback') { $dbh->rollback } else { $dbh->do($how) }
            my $ok = eval { 1 while $s->next; $s->close; 1 };
            my $error = $@;
            ok(!$ok, 'the stream does not go on');
            is(kind($error), 'transaction_state_unsafe/ownership_lost', "it says the transaction is not the one it opened in");
            ok($dbh->{Active}, 'the connection is kept');
            ok(eval { $dbh->do('INSERT INTO ho_l VALUES (2)'); 1 }, 'and the host writes on it');
            is(join(',', @{$admin->selectcol_arrayref('SELECT hit FROM ho_l ORDER BY hit')}), $how =~ /commit/i ? '1,2' : '2', "the host's work is as the host left it");
            $dbh->disconnect;
        };
    }
}

# A cancel at the start of a savepoint's end (as a cancel then would leave it).
for my $target (qw(selecto_catalog selecto_path)) {
    subtest "a cancel on the end of the $target savepoint stays a cancel" => sub {
        my $dbh = TestPostgreSQL->connect;
        my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
        $dbh->begin_work;
        $dbh->do('INSERT INTO ho_l VALUES (3)');
        my $fired = 0;
        no warnings 'redefine';
        my $do = \&DBD::Pg::db::do;
        local *DBD::Pg::db::do = sub {
            my ($h, $sql) = @_;
            if (!$fired && ($sql // '') =~ /^(?:ROLLBACK TO SAVEPOINT \S+; )?RELEASE SAVEPOINT ${target}_/) {
                $fired = 1;
                $do->($h, q{DO $$BEGIN RAISE EXCEPTION 'canceling statement due to user request' USING ERRCODE = '57014'; END$$});
                return undef;
            }
            return $do->(@_);
        };
        my $ok = eval { $e->all($e->query->select('id')->order_by('id')); 1 };
        my $error = $@;
        is($fired, 1, 'the cancel landed');
        ok(!$ok, 'the read does not answer');
        is(kind($error), 'query_error/query_canceled', 'it is a cancel');
        is($dbh->pg_ping, 3, "the host's transaction goes on");
        $dbh->rollback;
        $dbh->disconnect;
    };
}

done_testing;
