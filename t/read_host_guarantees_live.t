use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use Scalar::Util qw(blessed);
use Time::HiRes qw(time sleep);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R66: a read's R55 protection must not weaken what the host's transaction
# guarantees. Each of these passed every other suite while broken in another
# runtime.
my $x = 'Selecto::Expression';
my $domain = sub {
    my ($table, %options) = @_;
    Selecto::Domain->parse({schema_version => 1, name => "D$table", source => {source_table => $table, primary_key => 'id',
        ($options{untenanted} ? () : (tenant_field => 'org')), fields => [qw(id org oncall)],
        columns => {id => {type => 'integer'}, org => {type => 'string'}, oncall => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {}});
};
my $state = sub { my ($error) = @_; return blessed($error) && ref($error->details) eq 'HASH' ? ($error->details->{sqlstate} // '') : '' };
my $category = sub { my ($error) = @_; return blessed($error) && ref($error->details) eq 'HASH' ? ($error->details->{category} // '') : '' };

subtest postgresql => sub {
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
    my @clean = ('DROP VIEW IF EXISTS r66_slow', 'DROP TABLE IF EXISTS r66_doctors, r66_other');
    my $admin = TestPostgreSQL->connect;
    $admin->do('SET client_min_messages TO warning');
    $admin->do($_) for @clean, 'CREATE TABLE r66_doctors (id INT PRIMARY KEY, org TEXT NOT NULL, oncall INT NOT NULL)', 'CREATE TABLE r66_other (id INT)',
        q{CREATE VIEW r66_slow AS SELECT id, org, oncall FROM public.r66_doctors, pg_catalog.pg_sleep(3)};
    my $reset = sub { $admin->do('DELETE FROM r66_doctors'); $admin->do(q{INSERT INTO r66_doctors VALUES (1, 't1', 1), (2, 't1', 1)}) };
    my $open = sub {
        my $dbh = TestPostgreSQL->connect;
        $dbh->do('SET client_min_messages TO error');
        return ($dbh, Selecto::Engine->new(domain => $domain->($_[0] // 'r66_doctors'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1'));
    };
    my %reads = (
        read => sub { my ($e) = @_; $e->all($e->query->select('id')->where($x->eq('oncall', 1))->order_by('id'))->{rows} },
        'bounded stream' => sub { my ($e) = @_; my $s = $e->stream($e->query->select('id')->where($x->eq('oncall', 1))->order_by('id'), bounded => 1, fetch_size => 1);
            my @rows; while (my $row = $s->next) { push @rows, $row } $s->close; \@rows },
    );
    for my $name (sort keys %reads) {
        my $read = $reads{$name};
        # (a) Both sessions read, then each takes a doctor off call.
        $reset->();
        my ($a, $ea) = $open->();
        my ($b, $eb) = $open->();
        $_->do('BEGIN ISOLATION LEVEL SERIALIZABLE') for $a, $b;
        my @seen = ($read->($ea), $read->($eb));
        is(scalar(@{$seen[0]}), 2, "$name: the read answers");
        $a->do('UPDATE r66_doctors SET oncall = 0 WHERE id = 1');
        $b->do('UPDATE r66_doctors SET oncall = 0 WHERE id = 2');
        $a->do('COMMIT');
        ok(!eval { $b->do('COMMIT'); 1 } && $b->state eq '40001', "$name first in a SERIALIZABLE transaction: write skew still fails 40001");
        is(($admin->selectrow_array('SELECT count(*) FROM r66_doctors WHERE oncall = 1'))[0], 1, "$name: one doctor stays on call");
        eval { $b->do('ROLLBACK') };
        $_->disconnect for $a, $b;

        # (a) DEFERRABLE on a writable transaction does not wait for a safe snapshot.
        $reset->();
        my ($peer) = $open->();
        $peer->do('BEGIN ISOLATION LEVEL SERIALIZABLE');
        $peer->do('UPDATE r66_doctors SET org = org WHERE id = 1');
        my ($c, $ec) = $open->();
        $c->do('BEGIN ISOLATION LEVEL SERIALIZABLE DEFERRABLE');
        $c->do(q{SET LOCAL statement_timeout = '1500ms'});
        my $started = time;
        ok(eval { $read->($ec); 1 }, "$name: a writable DEFERRABLE host does not wait") or diag $@;
        cmp_ok(time - $started, '<', 1, 'at once');
        $c->do('ROLLBACK');
        $peer->do('ROLLBACK');
        $_->disconnect for $c, $peer;

        # The first read fixes REPEATABLE READ's snapshot.
        $reset->();
        my ($d, $ed) = $open->();
        $d->do('BEGIN ISOLATION LEVEL REPEATABLE READ');
        is(scalar(@{$read->($ed)}), 2, "$name: REPEATABLE READ's first read");
        $admin->do(q{INSERT INTO r66_doctors VALUES (3, 't1', 1)});
        is(scalar(@{$read->($ed)}), 2, "$name: fixes the snapshot");
        # And its table stays locked against DDL until the host ends.
        $admin->do(q{SET lock_timeout = '150ms'});
        my $altered = eval { $admin->do('ALTER TABLE r66_doctors ADD COLUMN extra INT'); 1 };
        ok(!$altered, "$name: the table the host read stays locked against DDL");
        $admin->do('SET lock_timeout = 0');
        $d->do('ROLLBACK');
        $admin->do('ALTER TABLE r66_doctors DROP COLUMN extra') if $altered;
        $d->disconnect;
    }

    # A relation that cannot be held is the read's to report, and costs the host nothing.
    {
        my ($h, $eh) = $open->('r66_gone');
        $h->begin_work;
        $h->do('INSERT INTO r66_other VALUES (1)');
        ok(!eval { $eh->all($eh->query->select('id')); 1 }, 'a read of a missing relation refuses in a host transaction');
        is(($h->selectrow_array('SELECT count(*) FROM r66_other'))[0], 1, 'and the host transaction lives on');
        $h->rollback;
        # A lock wait while holding stands, as the read's would.
        my ($l, $el) = $open->();
        $admin->begin_work;
        $admin->do('LOCK TABLE r66_doctors IN ACCESS EXCLUSIVE MODE');
        $l->begin_work;
        $l->do('INSERT INTO r66_other VALUES (1)');
        $l->do(q{SET LOCAL lock_timeout = '100ms'});
        ok(!eval { $el->all($el->query->select('id')); 1 }, 'a lock timeout in a read fails');
        is($state->($@), '55P03', 'as 55P03');
        is(($l->selectrow_array('SELECT count(*) FROM r66_other'))[0], 1, 'and the host keeps its write');
        $l->rollback;
        $admin->rollback;
        $_->disconnect for $h, $l;
    }

    # (d) A cancellation and a deadlock keep their SQLSTATE, on their own and in a
    # host transaction, which survives what can be survived.
    my ($a, $ea) = $open->('r66_slow');
    $a->do(q{SET statement_timeout = '150ms'});
    my $query = $ea->query->select('id');
    ok(!eval { $ea->all($query); 1 }, 'a timed-out read fails');
    is($state->($@), '57014', 'a timeout keeps 57014');
    is($category->($@), 'query_canceled', 'and its category');
    $a->begin_work;
    $a->do(q{INSERT INTO r66_other VALUES (1)});
    ok(!eval { $ea->all($query); 1 }, 'in a host transaction too');
    is($state->($@), '57014', 'with 57014');
    is(($a->selectrow_array('SELECT count(*) FROM r66_other'))[0], 1, 'and the host keeps its write');
    $a->rollback;
    $a->do('SET statement_timeout = 0');
    my $pid = ($a->selectrow_array('SELECT pg_backend_pid()'))[0];
    my $child = fork // die;
    if (!$child) {
        my $killer = TestPostgreSQL->connect;
        sleep 0.3;
        $killer->do('SELECT pg_cancel_backend(?)', undef, $pid);
        $killer->{InactiveDestroy} = 0;
        $killer->disconnect;
        require POSIX;
        POSIX::_exit(0);
    }
    ok(!eval { $ea->all($query); 1 }, 'a read cancelled from outside fails');
    is($state->($@), '57014', 'with 57014');
    waitpid($child, 0);
    $a->disconnect;

    # This session waits last with the short deadlock_timeout, so it is the victim.
    $reset->();
    my ($p, $ep) = $open->();
    if (eval { $p->do(q{SET deadlock_timeout = '100ms'}); 1 }) {
        $p->begin_work;
        $p->do('UPDATE r66_doctors SET oncall = 1 WHERE id = 1');
        my $other = fork // die;
        if (!$other) {
            $_->{InactiveDestroy} = 1 for $p, $admin;
            my $peer = TestPostgreSQL->connect;
            $peer->begin_work;
            $peer->do('UPDATE r66_doctors SET oncall = 1 WHERE id = 2');
            eval { $peer->do('UPDATE r66_doctors SET oncall = 1 WHERE id = 1') };
            eval { $peer->rollback };
            $peer->disconnect;
            require POSIX;
            POSIX::_exit(0);
        }
        sleep 0.4;
        my $read = eval { $ep->all($ep->query->select('id')->where($x->eq('id', 2))->for_share); 1 };
        my $error = $@;
        ok(!$read, 'a deadlock in a read fails');
        is($state->($error), '40P01', 'and keeps 40P01 through the savepoint');
        is($category->($error), 'deadlock_detected', 'and its category');
        $p->rollback;
        waitpid($other, 0);
    }
    $p->disconnect;
    $admin->do($_) for @clean;
    $admin->disconnect;
};

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
            $dbh->do(q{SET SESSION time_zone = '+00:00', sql_mode = 'STRICT_TRANS_TABLES', NAMES utf8mb4, innodb_lock_wait_timeout = 1});
            return $dbh;
        };
        my @clean = ('DROP VIEW IF EXISTS r66_slow, r66_audit_v', 'DROP FUNCTION IF EXISTS r66_audit', 'DROP FUNCTION IF EXISTS r66_sleep', 'DROP TABLE IF EXISTS r66_doctors, r66_log, r66_mylog');
        my $admin = $connect->();
        $admin->do($_) for @clean, 'CREATE TABLE r66_doctors (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL, oncall INT NOT NULL) ENGINE=InnoDB',
            'CREATE TABLE r66_log (id INT) ENGINE=InnoDB', 'CREATE TABLE r66_mylog (id INT) ENGINE=MyISAM',
            q{CREATE FUNCTION r66_sleep() RETURNS INT DETERMINISTIC NO SQL BEGIN DO SLEEP(3); RETURN 1; END},
            q{CREATE VIEW r66_slow AS SELECT id, org, oncall FROM r66_doctors WHERE r66_sleep() = 1},
            q{CREATE FUNCTION r66_audit(i INT) RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN INSERT INTO r66_log VALUES (i); INSERT INTO r66_mylog VALUES (i); RETURN i; END},
            q{CREATE VIEW r66_audit_v AS SELECT id, org, r66_audit(oncall) AS oncall FROM r66_doctors};
        my $reset = sub { $admin->do('DELETE FROM r66_doctors'); $admin->do(q{INSERT INTO r66_doctors VALUES (1, 't1', 1), (2, 't1', 1)}) };
        my $open = sub {
            my $dbh = $connect->();
            my $table = $_[0] // 'r66_doctors';
            my $e = Selecto::Engine->new(domain => $domain->($table, untenanted => $table ne 'r66_doctors'), adapter => Selecto->adapter($name => (dbh => $dbh)));
            return ($dbh, $table eq 'r66_doctors' ? $e->with_scope(tenant => 't1') : $e);
        };
        my $read = sub { my ($e) = @_; $e->all($e->query->select('id')->where($x->eq('oncall', 1))->order_by('id'))->{rows} };

        # (b) The read is the transaction's first InnoDB access.
        $reset->();
        my ($a, $ea) = $open->();
        $a->begin_work;
        is(scalar(@{$read->($ea)}), 2, 'the first read of a REPEATABLE READ transaction');
        $admin->do(q{INSERT INTO r66_doctors VALUES (3, 't1', 1)});
        is(scalar(@{$read->($ea)}), 2, 'fixes its snapshot');
        is(($a->selectrow_array('SELECT count(*) FROM r66_doctors'))[0], 2, "and the host's own read agrees");
        $a->rollback;
        $a->disconnect;
        for my $before ('', 'SELECT count(*) FROM r66_log', 'INSERT INTO r66_log VALUES (5)') {
            my $label = $before ? " after: $before" : ' first';
            $reset->();
            my ($b, $eb) = $open->();
            $b->do('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
            $b->begin_work;
            $b->do($before) if $before;
            is(scalar(@{$read->($eb)}), 2, "SERIALIZABLE read$label");
            ok(!eval { $admin->do('UPDATE r66_doctors SET oncall = 0 WHERE id = 1'); 1 }, "SERIALIZABLE read$label: keeps its shared locks");
            $b->rollback;
            $b->disconnect;
        }
        $admin->do('DELETE FROM r66_log');
        $reset->();
        my ($c, $ec) = $open->();
        $c->begin_work;
        $read->($ec);
        my $ddl = $connect->();
        $ddl->do('SET SESSION lock_wait_timeout = 1');
        my $altered = eval { $ddl->do('ALTER TABLE r66_doctors ADD COLUMN extra INT'); 1 };
        ok(!$altered, 'the table the host read stays locked against DDL');
        $c->rollback;
        $ddl->do('ALTER TABLE r66_doctors DROP COLUMN extra') if $altered;
        $c->disconnect;
        $ddl->disconnect;

        # (c) A read must not end the host's table locks.
        # (s0 is the alias of a compiled read's root, which a host must lock too: so
        # under FLUSH TABLES t, which cannot name it, the read refuses, as it did.)
        for my $lock ('LOCK TABLES r66_doctors READ, r66_doctors AS s0 READ', 'LOCK TABLES r66_doctors WRITE, r66_doctors AS s0 WRITE',
            'FLUSH TABLES r66_doctors WITH READ LOCK', 'FLUSH TABLES WITH READ LOCK') {
            $reset->();
            my ($d, $ed) = $open->();
            $admin->do('SET SESSION lock_wait_timeout = 1');
            $d->do($lock);
            ok(eval { $read->($ed); 1 } || $lock =~ /\AFLUSH TABLES r66/, "$lock: the read runs") or diag $@;
            ok(!eval { $admin->do('UPDATE r66_doctors SET org = org, oncall = oncall + 1 WHERE id = 1'); 1 }, "$lock: holds after the read");
            is(($d->selectrow_array('SELECT @@autocommit'))[0], 1, "$lock: autocommit is back");
            $d->do('UNLOCK TABLES');
            ok(eval { $admin->do('UPDATE r66_doctors SET oncall = oncall + 1 WHERE id = 1'); 1 }, "$lock: until the host unlocks");
            $d->disconnect;
        }

        # A one-shot SET TRANSACTION is the read's, as it was: the next one is the session's.
        my ($f, $ef) = $open->();
        $f->do('SET TRANSACTION READ ONLY');
        $read->($ef);
        $f->begin_work;
        ok(eval { $f->do('INSERT INTO r66_log VALUES (9)'); 1 }, 'the read does not leave the next transaction read only') or diag $@;
        $f->rollback;
        $f->disconnect;

        # (d) Timeouts, lock waits and deadlocks stand.
        my ($g, $eg) = $open->('r66_slow');
        my $variable = $name eq 'mysql' ? 'max_execution_time = 200' : 'max_statement_time = 0.2';
        $g->do("SET SESSION $variable");
        my $slow = $eg->query->select('id');
        ok(!eval { $eg->all($slow); 1 }, 'a timed-out read fails');
        is($category->($@), 'query_canceled', 'as query_canceled');
        $g->begin_work;
        $g->do('INSERT INTO r66_log VALUES (1)');
        ok(!eval { $eg->all($slow); 1 }, 'in a host transaction too');
        is($category->($@), 'query_canceled', 'as query_canceled');
        is(($g->selectrow_array('SELECT count(*) FROM r66_log'))[0], 1, 'and the host keeps its write');
        $g->rollback;
        $g->disconnect;
        $reset->();
        my ($h, $eh) = $open->();
        $admin->begin_work;
        $admin->do('UPDATE r66_doctors SET org = org, oncall = 2 WHERE id = 1');
        $h->do('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
        $h->begin_work;
        $h->do('INSERT INTO r66_log VALUES (2)');
        ok(!eval { $read->($eh); 1 }, 'a lock wait timeout in a SERIALIZABLE read fails');
        is($category->($@), 'lock_timeout', 'as lock_timeout');
        is(($h->selectrow_array('SELECT count(*) FROM r66_log'))[0], 1, 'and the host keeps its write');
        $h->rollback;
        $admin->rollback;
        $h->disconnect;

        # (e) On its own a write refuses, MyISAM included. In the host's transaction
        # the read runs as written, and its write is the host's to commit or undo.
        $reset->();
        $admin->do($_) for 'DELETE FROM r66_log', 'DELETE FROM r66_mylog';
        my ($k, $ek) = $open->('r66_audit_v');
        my $audit = $ek->query->select('id', 'oncall')->order_by('id');
        ok(!eval { $ek->all($audit); 1 } && $category->($@) eq 'read_only_transaction', 'a writing view refuses on its own');
        is(($admin->selectrow_array('SELECT (SELECT count(*) FROM r66_log) + (SELECT count(*) FROM r66_mylog)'))[0], 0, 'and writes nothing to either table');
        $k->begin_work;
        is(scalar(@{$ek->all($audit)->{rows}}), 2, 'in the host transaction it reads');
        $k->rollback;
        is(($admin->selectrow_array('SELECT count(*) FROM r66_log'))[0], 0, "the host's rollback undoes what is transactional");
        is(($admin->selectrow_array('SELECT count(*) FROM r66_mylog'))[0], 2, 'and cannot undo the rest');
        $k->disconnect;
        $admin->do($_) for @clean;
        $admin->disconnect;
    };
}

done_testing;
