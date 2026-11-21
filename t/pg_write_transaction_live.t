use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use File::Temp qw(tempfile);
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::PostgreSQL ();
use Selecto::Write ();
use lib 't/lib';
use TestPostgreSQL ();

# A single managed write on an idle handle opens its own transaction with one
# statement, BEGIN ISOLATION LEVEL READ COMMITTED, and ends it with COMMIT or
# ROLLBACK as text: one round trip fewer than begin_work followed by SET
# TRANSACTION. AutoCommit stays on meanwhile. The level still overrides the
# session default, a refused write is still undone, and a transaction host
# code runs in (Selecto::Engine::transaction, or the host's own) is still a
# DBI transaction with AutoCommit off.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless TestPostgreSQL->configured;
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

# A handle whose driver has neither pg_pipeline nor pg_transaction_status,
# over the same driver, so the stock path runs whichever DBD::Pg is installed.
{
    package Local::StockDB;
    our @ISA = ('DBI::db');
    sub can {
        return undef if $_[1] eq 'pg_pipeline' || $_[1] eq 'pg_transaction_status';
        return shift->SUPER::can(@_);
    }
}

my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'WriteBegin',
    source => {source_table => 'wb_t', primary_key => 'id', fields => [qw(id name note level)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, note => {type => 'string'}, level => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
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
    return ($text, $ok ? undef : $error);
}
# libpq 14 and later name each message; one Query or Parse is one statement.
sub statements {
    my ($wire) = @_;
    return undef unless $wire =~ /\tF\t/;
    return scalar(() = $wire =~ /\tF\t\d+\t(?:Query|Parse)\t/g);
}

my @clean = ('DROP TABLE IF EXISTS wb_t', 'DROP FUNCTION IF EXISTS public.wb_level()', 'DROP FUNCTION IF EXISTS public.wb_refuse()');
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
$admin->do($_) for @clean, 'CREATE TABLE wb_t (id INT PRIMARY KEY, name TEXT, note TEXT, level TEXT)',
    q{CREATE FUNCTION public.wb_level() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.level := pg_catalog.current_setting('transaction_isolation'); RETURN NEW; END $$},
    'CREATE TRIGGER wb_level BEFORE UPDATE ON wb_t FOR EACH ROW EXECUTE FUNCTION public.wb_level()',
    q{CREATE FUNCTION public.wb_refuse() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'refused at commit'; END $$},
    q{CREATE CONSTRAINT TRIGGER wb_refuse AFTER UPDATE ON wb_t DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.note = 'at commit') EXECUTE FUNCTION public.wb_refuse()};
END { if ($admin) { eval { $admin->do($_) } for @clean } }
my $reset = sub { $admin->do('DELETE FROM wb_t'); $admin->do(q{INSERT INTO wb_t VALUES (1, 'a', 'n', NULL), (2, 'x', 'n', NULL), (3, 'x', 'n', NULL)}) };
my $rows = sub { $admin->selectall_arrayref('SELECT id, note, level FROM wb_t ORDER BY id') };
my $update = sub {
    my ($note, $predicate, %more) = @_;
    return Selecto::Write::Command->new(operation => 'update', relation => 'wb_t', assignments => {note => $note},
        predicate => $predicate, %more);
};

for my $stock (0, 1) {
    my $probe = TestPostgreSQL->connect;
    my $native = $probe->can('pg_pipeline') || $probe->can('pg_transaction_status');
    $probe->disconnect;
    next if $stock && !$native;    # the installed driver is the stock one: already run
    subtest($stock ? 'without local status' : $native ? 'driver with local status' : 'stock driver', sub {
        my $dbh = TestPostgreSQL->connect;
        bless $dbh, 'Local::StockDB' if $stock;
        $dbh->do('SET client_min_messages TO warning');
        my $local = $dbh->can('pg_transaction_status') ? 1 : 0;
        my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };

        $reset->();
        $dbh->do(q{SET default_transaction_isolation TO 'serializable'});
        my ($wire, $error) = trace($dbh, sub { $engine->execute_write($update->('one', $x->eq('id', 1))) });
        is($error, undef, 'the write succeeds');
        like($wire, qr/BEGIN ISOLATION LEVEL READ COMMITTED/, 'its transaction begins with its isolation level');
        unlike($wire, qr/SET TRANSACTION/, 'and no SET TRANSACTION follows');
        like($wire, qr/COMMIT/, 'it commits');
        SKIP: {
            my $sent = statements($wire);
            skip 'this libpq trace does not name messages', 1 unless defined $sent;
            # BEGIN, the write and COMMIT. A driver without local transaction
            # status asks whether a transaction is open in its BEGIN; under
            # this session default its new transaction is then rolled back and
            # begun again with the level (t/pg_write_begin_probe_live.t).
            is($sent, $local ? 3 : 5, $local ? 'three statements' : 'five statements under a SERIALIZABLE default');
        }
        is_deeply($rows->()->[0], [1, 'one', 'read committed'], 'the row is written under READ COMMITTED, whatever the session default');
        ok($dbh->{AutoCommit}, 'AutoCommit is on afterwards');
        is($dbh->pg_ping, 1, 'and the connection is idle');
        is(($dbh->selectrow_array('SHOW default_transaction_isolation'))[0], 'serializable', 'the session default is untouched');
        $dbh->do(q{SET default_transaction_isolation TO DEFAULT});

        # Refused after its statement ran: undone, and the handle is usable.
        ($wire, $error) = trace($dbh, sub { $adapter->execute_write_unsafe(
            $update->('many', $x->eq('name', 'x'), expected_count => 1)) });
        ok(blessed($error) && $error->isa('Selecto::Error'), 'a write that matches too many rows is refused')
            and is($error->code, 'cardinality_mismatch', 'as a cardinality mismatch');
        like($wire, qr/ROLLBACK/, 'its transaction is rolled back');
        is_deeply([map { $_->[1] } @{$rows->()}], ['one', 'n', 'n'], 'nothing it changed remains');
        ok($dbh->{AutoCommit}, 'AutoCommit is on');
        is($dbh->pg_ping, 1, 'and the connection is idle');

        # Refused by the server at COMMIT (a deferred constraint).
        $error = failure(sub { $engine->execute_write($update->('at commit', $x->eq('id', 2))) });
        ok($error, 'a failure at COMMIT is raised') and is($error->details->{sqlstate}, 'P0001', 'with its SQLSTATE');
        {
            # (Also on a handle that does not raise errors by itself.)
            local $dbh->{RaiseError} = 0;
            ok(failure(sub { $engine->execute_write($update->('at commit', $x->eq('id', 2))) }),
                'and on a handle without RaiseError');
        }
        is_deeply([map { $_->[1] } @{$rows->()}], ['one', 'n', 'n'], 'and nothing was written');
        is($dbh->pg_ping, 1, 'the connection is idle');
        is_deeply($engine->execute_write($update->('two', $x->eq('id', 2)))->to_hash->{affected_rows}, 1, 'and the next write runs');

        # The host's transaction: a savepoint, never a BEGIN or COMMIT of ours.
        $dbh->begin_work;
        ($wire, $error) = trace($dbh, sub { $engine->execute_write($update->('host', $x->eq('id', 3))) });
        is($error, undef, 'a write inside the host transaction succeeds');
        unlike($wire, qr/ISOLATION LEVEL|COMMIT/, 'without beginning or committing anything');
        like($wire, qr/SAVEPOINT/, 'inside a savepoint');
        ok(!$dbh->{AutoCommit}, "the host's transaction is still open");
        $dbh->rollback;
        is($rows->()->[2][1], 'n', "and the host's rollback undoes the write");

        # Host code inside the engine's transaction keeps a DBI transaction.
        my $seen;
        $engine->transaction(sub {
            my ($tx) = @_;
            $seen = $dbh->{AutoCommit} ? 'on' : 'off';
            $tx->execute_write($update->('scoped', $x->eq('id', 3)));
        });
        is($seen, 'off', 'AutoCommit is off for host code inside Selecto::Engine::transaction');
        is($rows->()->[2][1], 'scoped', 'and its write commits with the transaction');
        ok($dbh->{AutoCommit}, 'AutoCommit is on again');
        is_deeply(\@warnings, [], 'nothing was warned about');
        $dbh->disconnect;
    });
}

done_testing;
