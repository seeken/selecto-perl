use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R60, live: text_prefix buckets generate LEFT(...), the one keyword-named call
# Selecto emits. Its argument is text, so pg_catalog.left was an exact match and
# no plant could win; it must keep working, now qualified, beside a plant.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
local $ENV{SELECTO_PG_SQL_LINT} = 1;
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS r60_kw', 'DROP FUNCTION IF EXISTS public."left"(varchar, int)');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE r60_kw (id INT PRIMARY KEY, org TEXT NOT NULL, v VARCHAR(20))',
    q{INSERT INTO r60_kw VALUES (1, 't1', 'abc')},
    q{CREATE FUNCTION public."left"(varchar, int) RETURNS text LANGUAGE sql AS $$ SELECT 'forged' $$};
my @f = qw(id org v);
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'R60', source => {source_table => 'r60_kw', primary_key => 'id', tenant_field => 'org',
    fields => \@f, columns => {map { ($_ => {type => $_ eq 'id' ? 'integer' : 'string'}) } @f}, associations => {}}, schemas => {}, joins => {}});
my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => TestPostgreSQL->connect))->with_scope(tenant => 't1');
for my $spec ({kind => 'text_prefix', prefix_length => 2}, {kind => 'text_prefix', prefix_length => 2, exclude_articles => 1}) {
    my $rows = $e->all($e->query->select($x->bucket('v', $spec)->as('b')))->{rows};
    is $rows->[0][0], 'AB', 'a text_prefix bucket calls pg_catalog.left, under the lint';
}
my $statement = $e->compile($e->query->select($x->bucket('v', {kind => 'text_prefix', prefix_length => 2})->as('b')));
like $e->adapter->_statement_sql($statement->sql), qr/pg_catalog\.LEFT\(/, 'the call is qualified';
my $column = $admin->selectrow_array(q{SELECT v FROM r60_kw});
is $column, 'abc', 'the row is what it was';

done_testing;
