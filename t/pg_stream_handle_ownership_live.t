use 5.034;
use strict;
use warnings;
use Test::More;
use POSIX ();
use Scalar::Util qw(blessed refaddr);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::Write ();
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# On a handle with no transaction open a bounded stream runs in a transaction of its
# own, so the handle is the stream's until it closes: anything else sent on it would run
# in that transaction and be rolled back with it. It is refused before it is sent
# (handle_owned_by_stream), Selecto's own calls included. Once the stream ends, however
# it ends, the handle and its callbacks are the host's again. In the host's transaction
# nothing of this applies. Also: a host that ends its own transaction is told so, and a
# cancel stays a cancel, on a savepoint's end and with RaiseError off.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS ho_t, ho_l', 'DROP FUNCTION IF EXISTS ho_fail(int)');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE ho_t (id INT PRIMARY KEY)', 'INSERT INTO ho_t SELECT generate_series(1, 5)', 'CREATE TABLE ho_l (hit INT)',
    q{CREATE FUNCTION ho_fail(int) RETURNS int LANGUAGE plpgsql AS $$BEGIN IF $1 = 3 THEN RAISE EXCEPTION 'row 3'; END IF; RETURN $1; END$$};
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HO', source => {source_table => 'ho_t', primary_key => 'id',
    fields => ['id'], columns => {id => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {},
    writes => {operations => {insert => {enabled => 1}}, fields => {id => {insertable => 1}}}});
sub kind { my ($e) = @_; return 'ok' unless defined $e; return blessed($e) && $e->can('details') ? join('/', $e->code, $e->details->{category} // $e->details->{state} // '') : "untyped: $e" }
sub try { my ($code) = @_; return eval { $code->(); 1 } ? 'ok' : kind($@) }
sub stored { join ',', @{$admin->selectcol_arrayref('SELECT hit FROM ho_l ORDER BY hit')} }
sub open_stream { my ($e) = @_; my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1); $s->next; $s }

subtest 'on an idle handle nothing else reaches the server while the stream is open' => sub {
    $admin->do('DELETE FROM ho_l');
    my $dbh = TestPostgreSQL->connect;
    my $early = $dbh->prepare('INSERT INTO ho_l VALUES (?)');
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    my $e = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    my $s = open_stream($e);
    my %calls = (
        do => sub { $dbh->do('INSERT INTO ho_l VALUES (1)') }, prepare => sub { $dbh->prepare('SELECT 1') },
        prepare_cached => sub { $dbh->prepare_cached('SELECT 1') }, selectrow_array => sub { $dbh->selectrow_array('SELECT 1') },
        selectall_arrayref => sub { $dbh->selectall_arrayref('SELECT 1') }, 'execute (prepared before)' => sub { $early->execute(2) },
        begin_work => sub { $dbh->begin_work }, commit => sub { $dbh->commit }, rollback => sub { $dbh->rollback },
        ping => sub { $dbh->ping }, pg_ping => sub { $dbh->pg_ping }, func => sub { $dbh->func('pg_ping') },
        last_insert_id => sub { $dbh->last_insert_id(undef, undef, 'ho_l', undef) }, 'AutoCommit on' => sub { $dbh->{AutoCommit} = 1 },
        'a Selecto read' => sub { $e->all($e->query->select('id')) }, 'a Selecto stream' => sub { open_stream($e) },
        'a Selecto write' => sub { $e->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'ho_t', assignments => {id => 9})) },
    );
    for my $name (sort keys %calls) { is(try($calls{$name}), 'handle_owned_by_stream/', "$name refuses") }
    is(try(sub { $dbh->quote('x'); $dbh->err; $dbh->state; $dbh->{Name}; local $dbh->{PrintError} = 0 }), 'ok', 'what sends nothing still works');
    ok(eval { 1 while $s->next; 1 }, 'the stream reads on') or diag $@;
    is(stored(), '', 'nothing of it reached the server');
    is(try(sub { $early->execute(3) }), 'ok', 'after the close a statement prepared before runs');
    is(stored(), '3', 'and is stored');
    $dbh->disconnect;
};

for my $end (qw(drain close drop error)) {
    subtest "after the stream ends ($end) the handle and its callbacks are the host's" => sub {
        my $dbh = TestPostgreSQL->connect;
        my $calls = 0;
        my $host = {do => sub { $calls++; return }};
        $dbh->{Callbacks} = $host;
        my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
        # (A read first: under SELECTO_PG_SQL_LINT the lint wraps the host's callbacks on
        # the handle's first use. What the stream must give back is what it found.)
        $e->all($e->query->select('id'));
        my $found = $dbh->{Callbacks};
        my $ok = eval {
            if ($end eq 'error') {
                my $s = $e->adapter->stream_query(Selecto::Statement->new(sql => 'SELECT ho_fail(id) FROM ho_t ORDER BY id', columns => ['id'], adapter_name => 'postgresql'), bounded => 1, fetch_size => 1);
                1 while $s->next;
            } else {
                my $s = open_stream($e);
                is(try(sub { $dbh->do('SELECT 1') }), 'handle_owned_by_stream/', 'while open: refused');
                if ($end eq 'drain') { 1 while $s->next } elsif ($end eq 'close') { $s->close } else { undef $s }
            }
            1;
        };
        ok($end eq 'error' ? !$ok : $ok, "the stream ended ($end)") or diag $@;
        is(refaddr($dbh->{Callbacks}), refaddr($found), "the host's own callbacks are back, the same");
        my $before = $calls;
        is(try(sub { $dbh->do('SELECT 1') }), 'ok', 'the host uses the handle');
        is($calls, $before + 1, "and its own callback runs");
        ok($dbh->{AutoCommit} && $dbh->pg_ping == 1, 'idle, as before the stream');
        $dbh->disconnect;
    };
}

subtest "in the host's transaction the host uses the handle between fetches" => sub {
    $admin->do('DELETE FROM ho_l');
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    $dbh->begin_work;
    my $s = open_stream($e);
    is(try(sub { $dbh->do('INSERT INTO ho_l VALUES (4)') }), 'ok', 'a host write between fetches runs');
    ok(eval { 1 while $s->next; 1 }, 'the stream reads on') or diag $@;
    $dbh->commit;
    is(stored(), '4', 'and the host commits it');
    $dbh->disconnect;
};

subtest "a forked child's copy of the stream ends nothing on the server" => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    my $pid = fork // die $!;
    unless ($pid) { $dbh->{InactiveDestroy} = 1; undef $s; POSIX::_exit(0) }
    waitpid($pid, 0);
    my $n = 1;
    ok(eval { $n++ while $s->next; 1 }, "the parent's stream reads on") or diag $@;
    is($n, 5, 'every row');
    $dbh->disconnect;
};

subtest 'the host ends its transaction on an AutoCommit-off handle mid-stream' => sub {
    my $dbh = TestPostgreSQL->connect(AutoCommit => 0);
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    $dbh->commit;
    is(try(sub { 1 while $s->next; $s->close }), 'transaction_state_unsafe/ownership_lost', 'the stream says the transaction is gone');
    ok($dbh->{Active}, 'the connection is kept');
    $dbh->disconnect;
};

subtest "a cancel on the end of the stream's own savepoint in the host's transaction is reported" => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    $dbh->begin_work;
    my $s = open_stream($e);
    my $fired = 0;
    no warnings 'redefine';
    my $do = \&DBD::Pg::db::do;
    local *DBD::Pg::db::do = sub {
        my ($h, $sql) = @_;
        if (!$fired && ($sql // '') =~ /\ARELEASE SAVEPOINT selecto_stream\w+_end\z/) {
            $fired = 1;
            $do->($h, q{DO $$BEGIN RAISE EXCEPTION 'canceling statement due to user request' USING ERRCODE = '57014'; END$$});
            return undef;
        }
        return $do->(@_);
    };
    is(try(sub { $s->close }), 'query_error/query_canceled', 'the close reports the cancel');
    is($fired, 1, 'which landed');
    is($dbh->pg_ping, 3, "the host's transaction goes on");
    $dbh->rollback;
    $dbh->disconnect;
};

for my $target (qw(selecto_catalog selecto_path)) {
    for my $raise (1, 0) {
        subtest "a cancel on the end of the $target savepoint stays a cancel (RaiseError $raise)" => sub {
            my $dbh = TestPostgreSQL->connect(RaiseError => $raise, PrintError => 0);
            my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
            $dbh->begin_work;
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
            is(try(sub { $e->all($e->query->select('id')->order_by('id')) }), 'query_error/query_canceled', 'the read reports the cancel');
            is($fired, 1, 'which landed');
            is($dbh->pg_ping, 3, "the host's transaction goes on");
            $dbh->rollback;
            $dbh->disconnect;
        };
    }
}

# With RaiseError off, a cancel on a catalog read itself is typed as one too.
subtest 'a cancel on a catalog read with RaiseError off is a cancel' => sub {
    my $dbh = TestPostgreSQL->connect(RaiseError => 0, PrintError => 0);
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    $dbh->begin_work;
    my $fired = 0;
    no warnings 'redefine';
    my %orig = map { ($_ => \&{"DBD::Pg::db::$_"}) } qw(selectrow_array do);
    local *DBD::Pg::db::selectrow_array = sub {
        my ($h, $sql) = @_;
        if (!$fired && !ref($sql) && $sql =~ /WITH ORDINALITY AS p\(name, ord\)/) {
            $fired = 1;
            $orig{do}->($h, 'SELECT pg_catalog.pg_cancel_backend(pg_catalog.pg_backend_pid()), pg_catalog.pg_sleep(1)');
            return;
        }
        return $orig{selectrow_array}->(@_);
    };
    is(try(sub { $e->all($e->query->select('id')->order_by('id')) }), 'query_error/query_canceled', 'the read reports the cancel');
    is($fired, 1, 'which landed');
    is($dbh->pg_ping, 3, "the host's transaction goes on");
    $dbh->rollback;
    $dbh->disconnect;
};

done_testing;
