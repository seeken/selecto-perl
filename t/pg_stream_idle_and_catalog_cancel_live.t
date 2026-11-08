use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# On an idle handle a bounded stream runs in a transaction of Selecto's. One that locks
# rows refuses there: the host's writes between fetches would join that transaction
# and be rolled back at the close, each reporting OK. One that does not lock answers,
# and the host's statements between fetches see the host's settings.
# Inside the host's transaction a cancel that lands on one of Selecto's catalog reads,
# or on the stream's cursor check, is rolled back to (R72): the cancel reaches the
# host typed, and the host's transaction goes on.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS ic_t, ic_k, ic_l', 'DROP SCHEMA IF EXISTS ic_app CASCADE');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE SCHEMA ic_app', 'CREATE TABLE ic_t (id INT PRIMARY KEY, v INT NOT NULL DEFAULT 0)',
    'INSERT INTO ic_t SELECT generate_series(1, 5)', 'CREATE TABLE ic_k (v TEXT)', q{INSERT INTO ic_k VALUES ('public')},
    'CREATE TABLE ic_app.ic_k (v TEXT)', q{INSERT INTO ic_app.ic_k VALUES ('app')}, 'CREATE TABLE ic_l (hit INT)';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'IC', source => {source_table => 'ic_t', primary_key => 'id',
    fields => [qw(id v)], columns => {id => {type => 'integer'}, v => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {}});
sub engine { my ($dbh) = @_; return Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh)) }
sub kind { my ($e) = @_; return blessed($e) && $e->can('details') ? join('/', $e->code, $e->details->{category} // $e->details->{reason} // '') : "untyped: $e" }

subtest 'a stream that locks rows needs the host transaction' => sub {
    my $dbh = TestPostgreSQL->connect;
    my $e = engine($dbh);
    my @told;
    my $ok = eval {
        my $s = $e->stream($e->query->select('id')->order_by('id')->for_share, bounded => 1, fetch_size => 2);
        while (my $row = $s->next) { push @told, $dbh->do('UPDATE ic_t SET v = v + 100 WHERE id = ?', undef, $row->[0]) + 0 }
        1;
    };
    my $error = $@;
    ok(!$ok, 'on an idle handle it refuses');
    is(kind($error), 'query_rule_not_evaluable/row_lock_needs_transaction', 'and says why');
    is_deeply(\@told, [], 'before any host write could join it');
    ok($dbh->{AutoCommit}, 'the handle is as it was');
    is_deeply($admin->selectcol_arrayref('SELECT v FROM ic_t ORDER BY id'), [0, 0, 0, 0, 0], 'and nothing changed');
    $dbh->begin_work;
    my $n = 0;
    ok(eval { my $s = $e->stream($e->query->select('id')->order_by('id')->for_share, bounded => 1, fetch_size => 2); $n++ while $s->next; 1 },
        "in the host's transaction it answers") or diag $@;
    is($n, 5, 'every row');
    $dbh->rollback;
    $dbh->disconnect;
};

subtest "on an idle handle the handle is the stream's until it closes, and the host's again after" => sub {
    my $snap = q{SELECT pg_catalog.current_setting('TimeZone') || '|' || pg_catalog.current_setting('search_path') || '|' || (SELECT v FROM ic_k)};
    my $dbh = TestPostgreSQL->connect;
    $dbh->do($_) for q{SET TimeZone = 'Asia/Tokyo'}, 'SET search_path = ic_app, public';
    my $e = engine($dbh);
    my $before = $dbh->selectrow_array($snap);
    my $all = [map { $_->[0] } @{$e->all($e->query->select('id')->order_by('id'))->{rows}}];
    my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
    my @ids = map { $_->[0] } grep { defined } $s->next;
    my $between = eval { $dbh->selectrow_array($snap); 'ran' } // kind($@);
    my $ok = eval { while (my $row = $s->next) { push @ids, $row->[0] } $s->close; 1 };
    ok($ok, 'the stream answers') or diag $@;
    is($between, 'handle_owned_by_stream/', 'between fetches the host statement refuses');
    is_deeply(\@ids, $all, 'the stream reads what a read reads');
    is($dbh->selectrow_array($snap), $before, "after it the host's zone, path and tables are its own");
    $dbh->disconnect;
};

# A real cancel at one statement: the backend cancels itself in that statement's place,
# so the error, its SQLSTATE and the transaction state are the server's own.
sub cancelled_at {
    my ($match, $work, $skip) = @_;
    $skip //= 0;
    no warnings 'redefine';
    my %orig = map { ($_ => \&{"DBD::Pg::db::$_"}) } qw(selectrow_array do);
    my $fired = 0;
    my $cancel = sub {
        my ($dbh, $sql) = @_;
        $fired++;
        local $dbh->{RaiseError} = 0;
        local $dbh->{PrintError} = 0;
        # (What a message sends before its matching statement is sent first.)
        if ($sql =~ /\A(.*);\s*SELECT c\.statement/s) { $orig{do}->($dbh, $1) }
        $orig{do}->($dbh, 'SELECT pg_catalog.pg_cancel_backend(pg_catalog.pg_backend_pid()), pg_catalog.pg_sleep(1)');
        return;
    };
    local *DBD::Pg::db::selectrow_array = sub {
        my ($dbh, $sql) = @_;
        return $cancel->($dbh, $sql) if !$fired && !ref($sql) && $sql =~ $match && $skip-- <= 0;
        return $orig{selectrow_array}->(@_);
    };
    my $ok = eval { $work->(); 1 };
    return ($ok, $@, $fired);
}

for my $case (['the encoding check', qr/current_setting\('client_encoding'\)/, 'read'],
              ["a relation's qualification", qr/WITH ORDINALITY AS p\(name, ord\)/, 'read'],
              ["a relation's quoted name", qr/pg_catalog\.quote_ident\(n\.nspname\) OPERATOR/, 'read'],
              # (The first read of pg_cursors is the opening's, under its savepoint: the
              # one that matters is each FETCH's.)
              ["the stream's cursor check", qr/FROM pg_catalog\.pg_cursors/, 'stream', 1]) {
    my ($label, $match, $route, $skip) = @$case;
    subtest "a cancel on $label inside the host's transaction" => sub {
        my $dbh = TestPostgreSQL->connect;
        my $e = engine($dbh);
        $admin->do('DELETE FROM ic_l');
        $dbh->begin_work;
        $dbh->do('INSERT INTO ic_l VALUES (1)');
        my ($ok, $error, $fired) = cancelled_at($match, sub {
            if ($route eq 'read') { $e->all($e->query->select('id')->order_by('id')) }
            else { my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 2); 1 while $s->next; $s->close }
        }, $skip);
        is($fired, 1, 'the cancel landed');
        ok(!$ok, 'the operation fails');
        is(kind($error), 'query_error/query_canceled', 'as a cancel');
        is($dbh->pg_ping, 3, "the host's transaction is healthy");
        eval { $dbh->do('INSERT INTO ic_l VALUES (2)') };
        ok(eval { $dbh->commit }, 'and commits');
        is(join(',', @{$admin->selectcol_arrayref('SELECT hit FROM ic_l ORDER BY hit')}), '1,2', "with all of the host's work");
        $dbh->disconnect;
    };
}

done_testing;
