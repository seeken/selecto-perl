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
