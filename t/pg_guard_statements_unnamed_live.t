use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R63: PREPARE and DEALLOCATE work from plpgsql and survive ROLLBACK, so a named
# statement can be swapped by code running in the session. Selecto's guard,
# snapshot and post-image statements are prepared afresh each time, and DBD::Pg
# names a statement only on the second execution of one handle
# (pg_switch_prepared), so they run unnamed. This pins that: if a guard ever
# moves to a reused handle, it fails here. (A pin: this held before it was written, so
# it passes with or without any later fix.)
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $x = 'Selecto::Expression';
my @clean = ('DROP TABLE IF EXISTS r63_t, r63_seen CASCADE', 'DROP FUNCTION IF EXISTS public.r63_look() CASCADE');
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE r63_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT)',
    q{INSERT INTO r63_t VALUES (1, 't1', 'n'), (2, 't2', 'n')}, 'CREATE TABLE r63_seen (name TEXT, stmt TEXT)',
    q{CREATE FUNCTION public.r63_look() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
        INSERT INTO public.r63_seen SELECT p.name, p.statement FROM pg_catalog.pg_prepared_statements p; RETURN NEW; END $$},
    'CREATE TRIGGER r63_look BEFORE UPDATE ON r63_t FOR EACH ROW EXECUTE FUNCTION public.r63_look()';
my @fields = qw(id org note);
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'R63', source => {source_table => 'r63_t', primary_key => 'id', tenant_field => 'org',
    fields => \@fields, columns => {map { ($_ => {type => $_ eq 'id' ? 'integer' : 'string'}) } @fields}, associations => {}}, schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
{
    $admin->do('DELETE FROM r63_seen');
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1');
    for my $i (1 .. 6) {
        $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r63_t', assignments => {note => "w$i"},
            predicate => $x->eq('id', 1), expected_count => undef));
        $e->all($e->query->select('id')->order_by('id'));
    }
    my @names = (@{$admin->selectcol_arrayref('SELECT DISTINCT stmt FROM r63_seen')},
        @{$dbh->selectcol_arrayref('SELECT statement FROM pg_catalog.pg_prepared_statements')});
    my @guards = grep { !/\A(?:UPDATE public\.r63_t|SELECT "s0"\."id")/ } @names;
    is_deeply(\@guards, [], 'no guard, snapshot or post-image statement is named');
    is(scalar(@names), 0, 'and nothing at all is');
}

done_testing;
