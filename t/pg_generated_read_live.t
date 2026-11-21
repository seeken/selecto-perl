use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use File::Temp qw(tempfile);
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use Selecto;
use Selecto::BoundedQuery;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::PostgreSQL ();
use Selecto::Statement;
use lib 't/lib';
use TestPostgreSQL ();

# User ruling of 2026-11-20 (it narrows the earlier read ruling): with no
# transaction open, a generated read is one autocommit statement, with no
# READ ONLY and no transaction of its own. A hand-built read keeps its READ
# ONLY transaction, which is what refuses a hand-built write (25006). A read
# with a deadline, and a bounded stream, keep the transaction they need. A
# server statement_timeout is sent only when a deadline is asked for, and the
# session's value is unchanged afterwards. The UTF8 check reads libpq's local
# value. Consequence: a generated read that reaches a view or function of the
# host's that writes commits that write.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless TestPostgreSQL->configured;
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

# A handle whose driver has neither pg_pipeline nor pg_transaction_status,
# over the same driver, so both read paths run whichever DBD::Pg is installed.
{
    package Local::StockDB;
    our @ISA = ('DBI::db');
    sub can {
        return undef if $_[1] eq 'pg_pipeline' || $_[1] eq 'pg_transaction_status';
        return shift->SUPER::can(@_);
    }
}

my $domain = sub {
    my ($table) = @_;
    return Selecto::Domain->parse({schema_version => 1, name => "D$table", source => {source_table => $table, primary_key => 'id',
        tenant_field => 'org', fields => [qw(id org note)],
        columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}});
};
sub statement {
    return Selecto::Statement->new(sql => $_[0], params => $_[1] // [], columns => $_[2] // ['n'], adapter_name => 'postgresql');
}
sub failure {
    my ($work) = @_;
    return undef if eval { $work->(); 1 };
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    return $error;
}
# What the client sent while $work ran, as libpq's protocol trace.
sub trace {
    my ($dbh, $work) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    $dbh->pg_server_trace($fh);
    my $ok = eval { $work->(); 1 };
    my $error = $@;
    $dbh->pg_server_untrace;
    close $fh;
    open my $read, '<', $path or die $!;
    my $text = do { local $/; <$read> };
    close $read;
    die $error unless $ok;
    return $text;
}
my $control = qr/\b(?:BEGIN|START TRANSACTION|READ ONLY|ROLLBACK|COMMIT|SAVEPOINT|statement_timeout)\b/;
# libpq 14 and later name each message; one Query or Parse is one statement.
sub statements {
    my ($wire) = @_;
    return undef unless $wire =~ /\tF\t/;
    return scalar(() = $wire =~ /\tF\t\d+\t(?:Query|Parse)\t/g);
}

my @clean = ('DROP VIEW IF EXISTS gr_state_v, gr_audit_v, gr_slow_v', 'DROP FUNCTION IF EXISTS public.gr_audit(text)', 'DROP TABLE IF EXISTS gr_t, gr_log');
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
$admin->do($_) for @clean, 'CREATE TABLE gr_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT)', 'CREATE TABLE gr_log (note TEXT)',
    q{INSERT INTO gr_t SELECT g, 't1', 'n' FROM generate_series(1, 6) g},
    q{CREATE VIEW gr_state_v AS SELECT id, org, pg_catalog.current_setting('transaction_read_only') || ':' || CAST(pg_catalog.txid_current() AS text) AS note FROM public.gr_t},
    q{CREATE FUNCTION public.gr_audit(s text) RETURNS text LANGUAGE plpgsql AS $$ BEGIN INSERT INTO public.gr_log VALUES (s); RETURN s; END $$},
    q{CREATE VIEW gr_audit_v AS SELECT id, org, public.gr_audit(note) AS note FROM public.gr_t},
    q{CREATE VIEW gr_slow_v AS SELECT id, org, note FROM public.gr_t WHERE pg_catalog.pg_sleep(0.3) IS NOT NULL};
END { if ($admin) { eval { $admin->do($_) } for @clean } }
my $logged = sub { ($admin->selectrow_array('SELECT count(*) FROM public.gr_log'))[0] };

for my $stock (0, 1) {
    my $probe = TestPostgreSQL->connect;
    my $native = $probe->can('pg_pipeline') || $probe->can('pg_transaction_status');
    $probe->disconnect;
    next if $stock && !$native;    # the installed driver is the stock one: already run
    my $driver = $stock ? 'without pipeline or local status' : $native ? 'pipeline driver' : 'stock driver';
    subtest $driver => sub {
        my $dbh = TestPostgreSQL->connect;
        bless $dbh, 'Local::StockDB' if $stock;
        $dbh->do('SET client_min_messages TO error');
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        my $local = $dbh->can('pg_transaction_status') ? 1 : 0;
        my $engine = sub { Selecto::Engine->new(domain => $domain->($_[0]), adapter => $adapter)->with_scope(tenant => 't1') };
        $admin->do('DELETE FROM gr_log');

        # A generated read: one statement, in no transaction of Selecto's.
        my $state = $engine->('gr_state_v');
        my $query = $state->query->select('id', 'note')->order_by('id');
        my ($result, @xid);
        my $wire = trace($dbh, sub { $result = $state->all($query) });
        unlike($wire, $control, 'a generated read sends no transaction control and no timeout');
        like($wire, qr/gr_state_v/, 'it sends its statement');
        SKIP: {
            my $sent = statements($wire);
            skip 'this libpq trace does not name messages', 1 unless defined $sent;
            # (Without local status nothing asks the server first either: a
            # generated read runs as written wherever it is.)
            is($sent, 1, 'one statement, one round trip');
        }
        is(scalar(@{$result->{rows}}), 6, 'and answers');
        like($result->{rows}[0][1], qr/\Aoff:\d+\z/, 'the read is not READ ONLY');
        push @xid, $result->{rows}[0][1] =~ /(\d+)\z/;
        push @xid, $state->all($query)->{rows}[0][1] =~ /(\d+)\z/;
        isnt($xid[0], $xid[1], 'each read is its own statement, not part of a transaction');
        is(($admin->selectrow_array('SELECT pg_catalog.txid_status(CAST(? AS bigint))', undef, $_))[0], 'committed',
            'and it committed: nothing was rolled back') for @xid;
        ok($dbh->{AutoCommit}, 'AutoCommit is unchanged');
        is($dbh->pg_ping, 1, 'and the connection is idle');
        is(($dbh->selectrow_array('SELECT pg_catalog.txid_current_if_assigned()'))[0], undef, 'no transaction is left open');

        # Unasked, a failed host transaction is still refused as one: the
        # server ran nothing (25P02) and the transaction stays the host's.
        $dbh->do('BEGIN');
        eval { local $dbh->{PrintError} = 0; $dbh->do('SELECT 1/0') };
        my $unasked = eval { $state->all($query); 1 } ? undef : $@;
        is(eval { $unasked->code }, 'transaction_state_unsafe', 'a generated read in a failed host transaction is refused');
        is(eval { $unasked->details->{state} }, 'inerror', 'as a failed transaction');
        is($dbh->pg_ping, 4, 'which is left for the host to roll back');
        $dbh->do('ROLLBACK');
        is(scalar(@{$state->all($query)->{rows}}), 6, 'and reads answer again after it does');

        # The documented consequence: what the host's view writes is committed.
        my $audit = $engine->('gr_audit_v');
        my $audited = $audit->query->select('id', 'note')->order_by('id');
        ok(eval { $audit->all($audited); 1 }, 'a generated read through a view that writes runs') or diag $@;
        is($logged->(), 6, "and the view's write is committed");
        ok(eval { my $s = $audit->stream($audited); while ($s->next) { } 1 }, 'so does an unbounded stream, one statement too') or diag $@;
        is($logged->(), 12, 'with its write committed');
        my $refused = failure(sub { my $s = $audit->stream($audited, bounded => 1, fetch_size => 2); while ($s->next) { } });
        is($refused && $refused->details->{category}, 'read_only_transaction', "a bounded stream keeps its cursor's READ ONLY transaction");
        is($logged->(), 12, 'and writes nothing');

        # A hand-built read keeps the READ ONLY transaction: a write refuses.
        my $written = failure(sub { $adapter->execute_query(statement(q{WITH w AS (INSERT INTO gr_log VALUES ('hand') RETURNING note) SELECT note FROM w})) });
        is($written && $written->details->{category}, 'read_only_transaction', 'a hand-built write refuses');
        is($written && $written->details->{sqlstate}, '25006', 'with SQLSTATE 25006');
        $written = failure(sub { $adapter->execute_query(statement('SELECT note FROM gr_audit_v')) });
        is($written && $written->details->{sqlstate}, '25006', 'so does a hand-built read through the view that writes');
        is($logged->(), 12, 'and nothing is written');
        $wire = trace($dbh, sub { $result = $adapter->execute_query(statement(q{SELECT pg_catalog.current_setting('transaction_read_only')})) });
        is($result->{rows}[0][0], 'on', 'a hand-built read runs READ ONLY');
        like($wire, qr/BEGIN READ ONLY NOT DEFERRABLE/, 'in a transaction of its own');
        like($wire, qr/ROLLBACK/, 'rolled back');
        is($dbh->pg_ping, 1, 'which leaves the connection idle');

        # A deadline is enforced on the server, and only when asked for.
        my $slow = $engine->('gr_slow_v');
        for my $session ('0', '7s') {
            $dbh->do("SET statement_timeout = '$session'");
            my $started = time;
            my $late = failure(sub { Selecto::BoundedQuery->all($slow, $slow->query->select('id')->order_by('id'), max_rows => 100, timeout_ms => 150) });
            ok($late, "session timeout $session: a read past its deadline fails");
            is($late && $late->details->{sqlstate}, '57014', "session timeout $session: canceled by the server's statement_timeout");
            cmp_ok(time - $started, '<', 1.5, "session timeout $session: on the server, before the read would have ended");
            is(($dbh->selectrow_array('SHOW statement_timeout'))[0], $session, "session timeout $session: the session value is unchanged afterwards");
            is($dbh->pg_ping, 1, "session timeout $session: the connection is idle");
            $wire = trace($dbh, sub { $result = $state->all($query) });
            unlike($wire, $control, "session timeout $session: the next generated read sends no timeout");
            is(scalar(@{$result->{rows}}), 6, "session timeout $session: and answers");
        }
        $dbh->do('SET statement_timeout = 0');

        # A session that is not UTF8 is refused, from libpq's local value.
        $dbh->do(q{SET client_encoding = 'LATIN1'});
        my $encoding;
        $wire = trace($dbh, sub { $encoding = failure(sub { $state->all($query) }) });
        is($encoding && $encoding->details->{reason}, 'client_encoding', 'a generated read in a LATIN1 session refuses');
        unlike($wire, qr/gr_state_v|client_encoding/, 'before its statement is sent, and without asking the server');
        $encoding = failure(sub { $adapter->execute_query(statement('SELECT 1')) });
        is($encoding && $encoding->details->{reason}, 'client_encoding', 'so does a hand-built read');
        $dbh->do(q{SET client_encoding = 'UTF8'});
        is(scalar(@{$state->all($query)->{rows}}), 6, 'back in UTF8 the read answers');
        $dbh->disconnect;
        my ($dsn, @auth) = TestPostgreSQL->connection;
        my $latin = DBI->connect($dsn . q{;options='-c client_encoding=LATIN1'}, @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        bless $latin, 'Local::StockDB' if $stock;
        my $other = Selecto::Engine->new(domain => $domain->('gr_state_v'), adapter => Selecto::PostgreSQL->new(dbh => $latin))->with_scope(tenant => 't1');
        $encoding = failure(sub { $other->all($other->query->select('id', 'note')->order_by('id')) });
        is($encoding && $encoding->details->{reason}, 'client_encoding', 'a connection that begins in LATIN1 is refused too');
        $latin->disconnect;

        # A lost connection is refused as an unknown state, with or without
        # the question: the backend is ended from outside, in no transaction
        # and inside a raw host BEGIN, and the handle is disconnected.
        for my $lost ('backend terminated', 'backend terminated in a host transaction', 'handle disconnected') {
            my $gone = TestPostgreSQL->connect;
            bless $gone, 'Local::StockDB' if $stock;
            my $reader = Selecto::Engine->new(domain => $domain->('gr_state_v'), adapter => Selecto::PostgreSQL->new(dbh => $gone))->with_scope(tenant => 't1');
            my $read = $reader->query->select('id', 'note')->order_by('id');
            is(scalar(@{$reader->all($read)->{rows}}), 6, "$lost: the connection reads first");
            $gone->do('BEGIN') if $lost =~ /host transaction/;
            if ($lost eq 'handle disconnected') {
                $gone->disconnect;
            } else {
                my $pid = $gone->{pg_pid};
                $admin->do('SELECT pg_catalog.pg_terminate_backend(?)', undef, $pid);
                for (1 .. 50) {
                    last unless ($admin->selectrow_array('SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE pid = ?', undef, $pid))[0];
                    select undef, undef, undef, 0.02;
                }
            }
            my $error = failure(sub { $reader->all($read) });
            is($error && $error->code, 'transaction_state_unsafe', "$lost: a generated read is refused");
            is($error && $error->details->{state}, 'unknown', "$lost: as an unknown connection state");
            eval { local $gone->{PrintError} = 0; $gone->disconnect };
        }
    };
}

$admin->do($_) for @clean;
$admin->disconnect;
undef $admin;
done_testing;
