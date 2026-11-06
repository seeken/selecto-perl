use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Statement;
use lib 't/lib';
use TestPostgreSQL ();

# R60, R62 on a clean database: a call answers as PostgreSQL does. (Planted functions
# are a DBA's, out of scope since R67.)
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my %mine;
for my $extension (qw(citext hstore pg_trgm pgcrypto cube)) {
    next if ($admin->selectrow_array('SELECT count(*) FROM pg_extension WHERE extname = ?', undef, $extension))[0];
    plan skip_all => "$extension cannot be installed" unless eval { $admin->do(qq{CREATE EXTENSION "$extension"}); 1 };
    $mine{$extension} = 1;
}
my @clean = ('DROP TABLE IF EXISTS public.fr_t, public.fr_u CASCADE', 'DROP FUNCTION IF EXISTS public.fr_host(int)');
END { eval { $admin->do($_) for @clean; $admin->do(qq{DROP EXTENSION IF EXISTS "$_" CASCADE}) for keys %mine } }
$admin->do($_) for @clean, 'CREATE TABLE public.fr_t (id INT PRIMARY KEY, ci citext, tx TEXT, vc VARCHAR(10), h hstore, n INT)',
    q{INSERT INTO public.fr_t VALUES (1, 'Gold', 'Gold', 'a', 'a=>1, b=>2', 1), (2, 'GOLD', 'x', 'b', 'a=>3', 2)},
    'CREATE TABLE public.fr_u (id INT PRIMARY KEY, vc VARCHAR(10))', q{INSERT INTO public.fr_u VALUES (1, 'a'), (2, 'z')},
    q{CREATE FUNCTION public.fr_host(i int) RETURNS int LANGUAGE sql AS $$ SELECT i $$};
my $dbh = TestPostgreSQL->connect;
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
my $flat = sub { join '|', map { join ',', map { $_ // 'NULL' } @$_ } @{$_[0]} };
my $check = sub {
    my ($sql) = @_;
    my $statement = Selecto::Statement->new(sql => $sql, params => [], adapter_name => 'postgresql');
    $statement->{_selecto_relations} = ['public.fr_t', 'public.fr_u'];
    my $rows = eval { $adapter->execute_query($statement)->{rows} };
    return $flat->($rows) if $rows;
    my $error = $@;
    return blessed($error) && ref($error->details) eq 'HASH' ? 'refused ' . ($error->details->{reason} // $error->code) : "died: $error";
};
my $native = sub { $flat->($admin->selectall_arrayref($_[0])) };
for my $sql (
    q{SELECT id FROM public.fr_t WHERE similarity(tx, 'gold') > 0.5 ORDER BY 1},
    q{SELECT id FROM public.fr_t WHERE public.similarity(tx, 'gold') > 0.5 ORDER BY 1},
    q{SELECT pg_catalog.encode(digest(tx, 'sha1'), 'hex') FROM public.fr_t ORDER BY 1},
    q{SELECT id, delete(h, 'a') FROM public.fr_t ORDER BY 1},
    q{SELECT id, cube(n, n) FROM public.fr_t ORDER BY 1},
    q{SELECT id, cube_dim(cube(n, n)) FROM public.fr_t ORDER BY 1},
    q{SELECT "cube"(n) FROM public.fr_t ORDER BY 1},
    q{SELECT id, n, count(*) FROM public.fr_t GROUP BY CUBE (id, n) ORDER BY 1 NULLS FIRST, 2 NULLS FIRST},
    q{SELECT id, n, count(*) FROM public.fr_t GROUP BY ROLLUP (id, n) ORDER BY 1 NULLS FIRST, 2 NULLS FIRST},
    q{SELECT id, n, count(*) FROM public.fr_t GROUP BY GROUPING SETS (CUBE (id), (n)) ORDER BY 1 NULLS FIRST, 2 NULLS FIRST},
    q{SELECT id FROM public.fr_t WHERE strpos(ci, 'O') > 0 ORDER BY 1},
    q{SELECT id FROM public.fr_t WHERE replace(ci, 'O', 'x') = 'gxld' ORDER BY 1},
    q{SELECT min(DISTINCT ci) FROM public.fr_t},
    q{SELECT public.fr_host(1) FROM public.fr_t WHERE id = 1},
    q{SELECT fr_host(1) FROM public.fr_t WHERE id = 1},
    q{SELECT a.id FROM public.fr_t a JOIN public.fr_u b USING (vc) ORDER BY 1},
    q{SELECT a.id FROM public.fr_t a NATURAL JOIN public.fr_u b ORDER BY 1},
    q{SELECT U&"id" FROM public.fr_t ORDER BY 1},
    q{SELECT s.id FROM public.fr_t AS s WHERE s.U&"\0063\0069" = 'gold' ORDER BY 1},
    q{SELECT s.id FROM public.fr_t AS s WHERE s.U&"!0063!0069" UESCAPE '!' = 'gold' ORDER BY 1},
) {
    is($check->($sql), $native->($sql), "as PostgreSQL: $sql");
}
$dbh->disconnect;
$admin->do($_) for @clean;
done_testing;
