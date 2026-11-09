use 5.034;
use strict;
use warnings;
use Test::More;
use POSIX ();
use Scalar::Util qw(blessed refaddr);
use DBI ();
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::Write ();
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# Owning a handle must not write to the host's log.
my @WARNINGS;
$SIG{__WARN__} = sub { push @WARNINGS, $_[0] };

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

# The handle's identity, not its attributes, says it is owned: a clone is never owned.
subtest 'a handle cloned during the stream is its own' => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    my $clone = $dbh->clone;
    my $ce = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $clone));
    is(try(sub { $ce->all($ce->query->select('id')) }), 'ok', 'a Selecto read on the clone runs while the stream is open');
    eval { 1 while $s->next };
    is(try(sub { $ce->all($ce->query->select('id')) }), 'ok', 'and after it');
    is(try(sub { my $c = open_stream($ce); 1 while $c->next; 1 }), 'ok', 'a bounded stream on the clone runs');
    $clone->disconnect;
    $dbh->disconnect;
};

# DBI runs no '*' callback for a call nested in another DBI call: each sending method
# has its own key, and visit_child_handles (which runs host code where none fires) is
# refused.
subtest 'host code running inside a DBI call is refused too' => sub {
    $admin->do('DELETE FROM ho_l');
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    my $inner = 'not run';
    {
        # (An error set on the handle runs the host's HandleError inside DBI's set_err.)
        local $dbh->{HandleError} = sub { $inner = try(sub { $dbh->do('INSERT INTO ho_l VALUES (5)') }); return 0 };
        eval { $dbh->set_err(1, 'host error'); 1 };
    }
    is($inner, 'handle_owned_by_stream/', "a statement in the host's HandleError refuses");
    is(try(sub { $dbh->visit_child_handles(sub { 1 }) }), 'handle_owned_by_stream/', 'visit_child_handles refuses');
    eval { 1 while $s->next };
    is(stored(), '', 'nothing of it reached the server');
    $dbh->disconnect;
};

subtest "the host's callbacks cannot be changed under the stream" => sub {
    my $dbh = TestPostgreSQL->connect;
    my $sth = $dbh->prepare('INSERT INTO ho_l VALUES (?)');
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    is(try(sub { $dbh->{Callbacks} = {} }), 'handle_owned_by_stream/', 'a STORE of the handle\'s Callbacks refuses');
    is(try(sub { $sth->{Callbacks} = {} }), 'handle_owned_by_stream/', "and of a statement handle's");
    ok(!eval { $dbh->{Callbacks}{do} = sub { return }; 1 }, 'an edit of them in place dies');
    is(try(sub { $sth->{NULLABLE} }), 'handle_owned_by_stream/', 'NULLABLE, a catalog query, refuses');
    eval { 1 while $s->next };
    my $mine = {do => sub { return }};
    $dbh->{Callbacks} = $mine;
    is(refaddr($dbh->{Callbacks}), refaddr($mine), 'after the stream the host sets its own');
    $dbh->disconnect;
};

subtest "a ROLLBACK TO a savepoint taken before the stream is not the host's transaction ending" => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    $dbh->begin_work;
    $dbh->do('SAVEPOINT host_sp');
    my $s = open_stream($e);
    $dbh->do('ROLLBACK TO SAVEPOINT host_sp');
    my $outcome = eval { 1 while $s->next; 1 } ? 'ok' : (blessed($@) ? join('/', $@->code, $@->details->{reason} // $@->details->{state} // '') : "$@");
    is($outcome, 'query_rule_not_evaluable/stream_cursor_gone', 'the stream says its cursor is gone');
    is($dbh->pg_ping, 3, "and the host's transaction goes on");
    $dbh->rollback;
    $dbh->disconnect;
};

subtest "a query budget's check says the handle is the stream's" => sub {
    my $dbh = TestPostgreSQL->connect;
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    my $e = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    my $budget = $adapter->begin_query_budget(timeout_ms => 5000);
    my $s = open_stream($e);
    is(try(sub { $budget->check }), 'handle_owned_by_stream/', 'a check that would re-arm says so, not unavailable');
    eval { 1 while $s->next };
    $budget->close;
    $dbh->disconnect;
};

# DBI's quote_identifier asks get_info inside DBI: quoting keeps working while a
# top-level get_info, and the ones that send SQL, refuse.
subtest 'quoting works on a handle a stream owns; get_info does not' => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    is(eval { $dbh->quote_identifier('a"b') } // kind($@), '"a""b"', 'quote_identifier');
    is(eval { $dbh->quote_identifier(undef, 'public', 'ho_t') } // kind($@), '"public"."ho_t"', 'a qualified name');
    is(try(sub { $dbh->get_info($_) }), 'handle_owned_by_stream/', "get_info($_) refuses") for 29, 25, 10005;
    my $n = 1;
    $n++ while $s->next;
    ok($n > 1, 'the stream drains');
    is($dbh->get_info(29), '"', 'get_info works once the stream ends');
    $dbh->disconnect;
};

subtest 'connect_cached never hands out a handle a stream owns' => sub {
    my ($dsn, @auth) = TestPostgreSQL->connection;
    my %attributes = (RaiseError => 1, PrintError => 0, AutoCommit => 1, private_selecto_test_cache => 1);
    my $dbh = DBI->connect_cached($dsn, @auth, \%attributes);
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
    my $s = open_stream($e);
    my $again = eval { DBI->connect_cached($dsn, @auth, \%attributes) };
    ok($again && refaddr($again) != refaddr($dbh), 'it opens another connection') or diag 'the owned handle came back, or none';
    eval { 1 while $s->next };
    $again->disconnect if $again && refaddr($again) != refaddr($dbh);
    $dbh->disconnect;
};

is_deeply \@WARNINGS, [], 'opening, using and closing streams warns nothing';

done_testing;
