use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R65: bound values are sent as UTF-8. Under a session whose client_encoding is
# LATIN1 the server reads those bytes as LATIN1, so a tenant 'café' arrives as
# 'cafÃ©', which is another tenant's name: its rows were read and written. Every
# path refuses such a session, however it got that way.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $x = 'Selecto::Expression';
my @clean = ('DROP VIEW IF EXISTS r65_v', 'DROP TABLE IF EXISTS r65_t', 'DROP FUNCTION IF EXISTS public.r65_set()', 'DROP FUNCTION IF EXISTS public.r65_mid(int)');
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE r65_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT)',
    q{CREATE FUNCTION public.r65_set() RETURNS BOOLEAN LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.set_config('client_encoding', 'LATIN1', false); RETURN TRUE; END $$},
    q{CREATE FUNCTION public.r65_mid(i int) RETURNS int LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.set_config('client_encoding', 'LATIN1', false); RETURN i; END $$},
    'CREATE VIEW r65_v AS SELECT public.r65_mid(id) AS id, org, note FROM r65_t';
$admin->do('INSERT INTO r65_t VALUES (1, ?, ?), (2, ?, ?)', undef, 'café', 'mine', 'cafÃ©', 'theirs');
my $domain = sub {
    my ($table) = @_;
    my @f = qw(id org note);
    Selecto::Domain->parse({schema_version => 1, name => "D$table", source => {source_table => $table, primary_key => 'id', tenant_field => 'org', fields => \@f,
        columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
};
my ($dsn, @auth) = TestPostgreSQL->connection;
my %how = (
    'a host SET' => sub { $_[0]->do(q{SET client_encoding = 'LATIN1'}) },
    'set_config' => sub { $_[0]->selectrow_array(q{SELECT pg_catalog.set_config('client_encoding', 'LATIN1', false)}) },
    'a planted function' => sub { $_[0]->selectrow_array(q{SELECT public.r65_set()}) },
    'a connection default' => undef,
);
my $refused = sub {
    my ($work) = @_;
    my $ok = eval { $work->(); 1 };
    my $error = $@;
    return !$ok && blessed($error) && $error->can('details') && ref($error->details) eq 'HASH' && ($error->details->{reason} // '') eq 'client_encoding';
};
for my $name (sort keys %how) {
    for my $mode (qw(read stream bounded write)) {
        my $set = $how{$name};
        my $dbh = DBI->connect($dsn . ($set ? '' : q{;options='-c client_encoding=LATIN1'}), @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $set->($dbh) if $set;
        my $e = Selecto::Engine->new(domain => $domain->('r65_t'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 'café');
        my $q = $e->query->select('id', 'note')->order_by('id');
        ok($refused->(sub {
            if ($mode eq 'read') { $e->all($q) }
            elsif ($mode eq 'write') { $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r65_t', assignments => {note => 'W'},
                predicate => $x->gt('id', 0), expected_count => undef)) }
            else { my $s = $e->stream($q, $mode eq 'bounded' ? (bounded => 1, fetch_size => 1) : ()); 1 while $s->next }
        }), "$name: a $mode refuses");
        $dbh->disconnect;
    }
}
is($admin->selectrow_array(q{SELECT count(*) FROM r65_t WHERE note = 'W'}), 0, 'nothing was written');

# Every other encoding the server will take is refused, as the server reports
# it, whatever the driver believes. UNICODE and UTF-8 are UTF8's own names.
{
    my $names = $admin->selectcol_arrayref(q{SELECT DISTINCT pg_catalog.pg_encoding_to_char(g) FROM pg_catalog.generate_series(0, 63) AS g
        WHERE pg_catalog.pg_encoding_to_char(g) <> '' ORDER BY 1});
    my ($set, @missed) = (0);
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain->('r65_t'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 'cafe');
    for my $name (grep { $_ ne 'UTF8' } @$names) {
        next unless eval { $dbh->do("SET client_encoding = '$name'"); 1 };
        $set++;
        my $refuses = $refused->(sub { $e->all($e->query->select('id')) });
        my $stream = $refused->(sub { my $s = $e->stream($e->query->select('id'), bounded => 1); 1 while $s->next });
        push @missed, $name unless $refuses && $stream;
        $dbh->do(q{SET client_encoding = 'UTF8'});
    }
    is_deeply(\@missed, [], "all $set other encodings the server accepts refuse, read and bounded stream");
    cmp_ok($set, '>=', 30, 'and that covers the server-settable ones');
    for my $name (qw(UNICODE UTF8 utf8 UTF-8 utf-8)) {
        $dbh->do("SET client_encoding = '$name'");
        ok(eval { $e->all($e->query->select('id')); 1 }, "$name is UTF8");
    }
    $dbh->disconnect;
}

# The check comes first, before any savepoint: a ROLLBACK TO restoring a non-ASCII
# search_path in a non-UTF8 session makes PostgreSQL itself spin.
{
    $admin->do('CREATE SCHEMA IF NOT EXISTS "r65_é"');
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET statement_timeout = 5000');
    my $e = Selecto::Engine->new(domain => $domain->('r65_t'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 'cafe');
    my $q = $e->query->select('id');
    $dbh->do('SET search_path = "r65_é", public');
    $dbh->do(q{SET client_encoding = 'LATIN1'});
    ok($refused->(sub { $e->all($q) }), 'a read in autocommit refuses, typed');
    $dbh->begin_work;
    ok($refused->(sub { $e->all($q) }), 'a read in a host transaction refuses, typed');
    ok($refused->(sub { $e->stream($q, bounded => 1) }), 'a bounded stream too');
    ok($refused->(sub { $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r65_t', assignments => {note => 'W'},
        predicate => $x->gt('id', 0), expected_count => undef)) }), 'a write too');
    is(($dbh->selectrow_array('SELECT 1'))[0], 1, 'and the host transaction is untouched');
    $dbh->rollback;
    $dbh->disconnect;
    $admin->do('DROP SCHEMA "r65_é"');
}

# A change made during the statement is seen by the session check.
{
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain->('r65_v'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 'café');
    my $ok = eval { $e->all($e->query->select('id')); 1 };
    ok(!$ok, 'a view that changes client_encoding during a read is refused');
    is(($dbh->selectrow_array('SHOW client_encoding'))[0], 'UTF8', 'and the setting is restored');
}

# UTF8 is unchanged.
{
    my $dbh = DBI->connect($dsn, @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    my $e = Selecto::Engine->new(domain => $domain->('r65_t'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 'café');
    is(join(',', map { $_->[0] } @{$e->all($e->query->select('id'))->{rows}}), '1', 'a UTF8 session reads the tenant');
    my $s = $e->stream($e->query->select('id'), bounded => 1, fetch_size => 1);
    my @ids; while (my $row = $s->next) { push @ids, $row->[0] }
    is("@ids", '1', 'and streams it');
}

done_testing;
