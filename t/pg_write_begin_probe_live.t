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

# On a driver without a local transaction status, a single managed write asks
# whether the host has a transaction open in its own first round trip (BEGIN
# and a SELECT as one simple query) instead of a pg_ping before it. What the
# caller sees in every connection state is what the ping gave: a raw host
# BEGIN gets a savepoint and keeps its transaction and isolation level, a
# failed host transaction refuses with 25P02, a lost or busy connection fails
# as before, and nothing is half-applied.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless TestPostgreSQL->configured;
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

# The stock driver's view, whichever DBD::Pg is installed.
{
    package Local::StockDB;
    our @ISA = ('DBI::db');
    sub can {
        return undef if $_[1] eq 'pg_pipeline' || $_[1] eq 'pg_transaction_status';
        return shift->SUPER::can(@_);
    }
    # A failure of the BEGIN-and-SELECT exchange itself, after $DO (if any)
    # has run: what a cancel or timeout landing on it would leave.
    our ($FAIL, $DO);
    sub selectrow_array {
        my $self = shift;
        if ($FAIL && $_[0] =~ /\ABEGIN; SELECT/) {
            $self->do($DO) if $DO;
            die "probe interrupted\n";
        }
        return $self->SUPER::selectrow_array(@_);
    }
}

my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'WriteProbe',
    source => {source_table => 'wp_t', primary_key => 'id', fields => [qw(id note level)],
        columns => {id => {type => 'integer'}, note => {type => 'string'}, level => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}}}});
sub failure {
    my ($work) = @_;
    return undef if eval { $work->(); 1 };
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    return $error;
}
sub trace {
    my ($dbh, $work) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    $dbh->pg_server_trace($fh);
    my $ok = eval { $work->(); 1 };
    my $error = $@;
    $dbh->pg_server_untrace if $dbh->{Active};
    close $fh;
    open my $read, '<', $path or die $!;
    my $text = do { local $/; <$read> };
    close $read;
    return ($text, $ok ? undef : $error);
}
# The statements sent (libpq 14 and later name each message), in order.
sub sent {
    my ($wire) = @_;
    return undef unless $wire =~ /\tF\t/;
    return [map { /\tQuery\t\s*"([A-Z]+)/ ? $1 : 'Parse' } grep { /\tF\t\d+\t(?:Query|Parse)\t/ } split /\n/, $wire];
}

my @clean = ('DROP TABLE IF EXISTS wp_t', 'DROP FUNCTION IF EXISTS public.wp_level()');
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
$admin->do($_) for @clean, 'CREATE TABLE wp_t (id INT PRIMARY KEY, note TEXT, level TEXT)',
    q{CREATE FUNCTION public.wp_level() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.level := pg_catalog.current_setting('transaction_isolation'); RETURN NEW; END $$},
    'CREATE TRIGGER wp_level BEFORE UPDATE ON wp_t FOR EACH ROW EXECUTE FUNCTION public.wp_level()';
END { if ($admin) { eval { $admin->do($_) } for @clean } }
my $reset = sub { $admin->do('DELETE FROM wp_t'); $admin->do(q{INSERT INTO wp_t VALUES (1, 'n', NULL), (2, 'n', NULL)}) };
my $notes = sub { join ',', map { $_->[0] } @{$admin->selectall_arrayref('SELECT note FROM wp_t ORDER BY id')} };
my $update = sub {
    my ($note, $id) = @_;
    return Selecto::Write::Command->new(operation => 'update', relation => 'wp_t', assignments => {note => $note},
        predicate => $x->eq('id', $id // 1));
};
# A fresh stock handle that prints server warnings, and its engine.
my $open = sub {
    my $dbh = TestPostgreSQL->connect(PrintWarn => 1);
    bless $dbh, 'Local::StockDB';
    $dbh->do('SET client_min_messages TO notice');
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    return ($dbh, $adapter, Selecto::Engine->new(domain => $domain, adapter => $adapter));
};
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

subtest 'idle handle' => sub {
    $reset->();
    my ($dbh, $adapter, $engine) = $open->();
    my ($wire, $error) = trace($dbh, sub { $engine->execute_write($update->('one')) });
    is($error, undef, 'the write succeeds');
    SKIP: {
        my $sent = sent($wire);
        skip 'this libpq trace does not name messages', 1 unless defined $sent;
        is_deeply($sent, [qw(BEGIN Parse COMMIT)], 'three statements: BEGIN with its check, the write, COMMIT');
    }
    unlike($wire, qr/DBD::Pg ping/, 'no ping');
    is($notes->(), 'one,n', 'the row is written');
    is($admin->selectrow_array('SELECT level FROM wp_t WHERE id = 1'), 'read committed', 'under READ COMMITTED');
    ok($dbh->{AutoCommit}, 'AutoCommit is on');
    is($dbh->pg_ping, 1, 'and the connection is idle');

    # Refused after its statement ran: its own transaction is rolled back.
    ($wire, $error) = trace($dbh, sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(
        operation => 'update', relation => 'wp_t', assignments => {note => 'many'},
        predicate => $x->in('id', [1, 2]), expected_count => 1)) });
    is(blessed($error) && $error->code, 'cardinality_mismatch', 'a write that matches too many rows is refused');
    like($wire, qr/ROLLBACK/, 'its transaction is rolled back');
    is($notes->(), 'one,n', 'nothing it changed remains');
    is($dbh->pg_ping, 1, 'the connection is idle');
    $dbh->disconnect;
};

subtest 'raw host BEGIN' => sub {
    $reset->();
    my ($dbh, $adapter, $engine) = $open->();
    @warnings = ();
    $dbh->do('BEGIN ISOLATION LEVEL REPEATABLE READ');
    $dbh->do(q{UPDATE wp_t SET note = 'host' WHERE id = 2});
    my ($wire, $error) = trace($dbh, sub { $engine->execute_write($update->('inside')) });
    is($error, undef, 'a write inside the host transaction succeeds');
    like($wire, qr/SAVEPOINT/, 'in a savepoint');
    unlike($wire, qr/COMMIT|ISOLATION LEVEL/, 'without committing or setting a level');
    is($dbh->pg_ping, 3, "the host's transaction is still open");
    is(($dbh->selectrow_array('SHOW transaction_isolation'))[0], 'repeatable read', 'at its own isolation level');
    is($notes->(), 'n,n', 'nothing is visible outside it');
    $dbh->do('ROLLBACK');
    is($notes->(), 'n,n', "the host's rollback undoes the write");
    is_deeply(\@warnings, [], 'the server warning about the BEGIN is not printed');

    $dbh->do('BEGIN');
    $engine->execute_write($update->('kept'));
    $dbh->do('COMMIT');
    is($notes->(), 'kept,n', "the host's commit keeps it");
    $dbh->disconnect;
};

subtest 'failed host transaction' => sub {
    $reset->();
    my ($dbh, $adapter, $engine) = $open->();
    $dbh->do('BEGIN');
    eval { $dbh->do('SELECT 1/0') };
    my $error = failure(sub { $engine->execute_write($update->('never')) });
    ok($error, 'the write is refused');
    is($error && $error->code, 'query_error', 'as a database error');
    is($error && $error->details->{sqlstate}, '25P02', 'with SQLSTATE 25P02');
    is($dbh->pg_ping, 4, "the host's failed transaction is left for the host");
    $dbh->do('ROLLBACK');
    is($notes->(), 'n,n', 'nothing was written');
    $dbh->disconnect;
};

subtest 'session default isolation' => sub {
    $reset->();
    my ($dbh, $adapter, $engine) = $open->();
    $dbh->do(q{SET default_transaction_isolation TO 'serializable'});
    my ($wire, $error) = trace($dbh, sub { $engine->execute_write($update->('first')) });
    is($error, undef, 'the write succeeds');
    is($admin->selectrow_array('SELECT level FROM wp_t WHERE id = 1'), 'read committed', 'under READ COMMITTED');
    SKIP: {
        my $sent = sent($wire);
        skip 'this libpq trace does not name messages', 1 unless defined $sent;
        is_deeply($sent, [qw(BEGIN ROLLBACK BEGIN Parse COMMIT)], 'the new transaction is begun again with the level');
    }
    ($wire, $error) = trace($dbh, sub { $engine->execute_write($update->('second', 2)) });
    is($error, undef, 'the next write succeeds');
    like($wire, qr/DBD::Pg ping/, 'after asking pg_ping');
    like($wire, qr/BEGIN ISOLATION LEVEL READ COMMITTED/, 'with the level in its BEGIN');
    is($admin->selectrow_array('SELECT level FROM wp_t WHERE id = 2'), 'read committed', 'under READ COMMITTED');
    is(($dbh->selectrow_array('SHOW default_transaction_isolation'))[0], 'serializable', 'the session default is untouched');
    $dbh->disconnect;
};

subtest 'lost and busy connections' => sub {
    $reset->();
    my ($dbh, $adapter, $engine) = $open->();
    $admin->do('SELECT pg_terminate_backend(?)', undef, $dbh->{pg_pid});
    select(undef, undef, undef, 0.2);
    my $error = failure(sub { $engine->execute_write($update->('lost')) });
    is($error && $error->code, 'query_error', 'a terminated backend fails the write');
    like($error && $error->details->{sqlstate} // '', qr/\A08/, 'as a connection failure');
    is($notes->(), 'n,n', 'nothing was written');

    ($dbh, $adapter, $engine) = $open->();
    $dbh->do('COPY wp_t (id, note) FROM STDIN');
    $error = failure(sub { $engine->execute_write($update->('busy')) });
    is($error && $error->code, 'transaction_state_unsafe', 'a handle in COPY is refused');
    is($error && $error->details->{state}, 'active', 'as busy');
    is($notes->(), 'n,n', 'nothing was written');
    $dbh->disconnect;
};

subtest 'an interrupted check' => sub {
    $reset->();
    my ($dbh, $adapter, $engine) = $open->();
    {
        local $Local::StockDB::FAIL = 1;
        my $error = failure(sub { $engine->execute_write($update->('none')) });
        is($error && $error->code, 'query_error', 'nothing sent: the failure is raised');
        is($dbh->pg_ping, 1, 'and the connection stays idle');
        ok($dbh->{Active}, 'and open');
    }
    {
        local $Local::StockDB::FAIL = 1;
        local $Local::StockDB::DO = 'BEGIN';
        my $error = failure(sub { $engine->execute_write($update->('open')) });
        is($error && $error->code, 'transaction_state_unsafe', 'a transaction left open by it is not used');
        is($error && $error->details->{state}, 'unknown', 'its owner is unknown');
        ok(!$dbh->{Active}, 'the connection is closed');
    }
    is($notes->(), 'n,n', 'nothing was written');
};

done_testing;
