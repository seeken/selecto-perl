use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto::PostgreSQL::Qualify ();

# R60: a function whose name is an SQL keyword is still a function. PostgreSQL
# resolves delete(h, v) or left(v, 2) through the session like any other call,
# so it is pg_catalog-qualified, or refused, and the lint sees it. The comma
# forms of SUBSTRING and OVERLAY are plain calls too; their keyword forms and
# NORMALIZE and TRIM are pg_catalog's by grammar.
my %functions = map { ($_ => 'string') } qw(left right substring overlay upper);
$functions{mode} = 1;
my $q = sub { Selecto::PostgreSQL::Qualify::qualify($_[0], \%functions) };
my $lint = sub { join ',', Selecto::PostgreSQL::Qualify::lint($_[0], \%functions) };

for my $case (['left', q{SELECT left(v, 2) FROM public.kw}, qr/SELECT pg_catalog\.left\(v , 2\) FROM/],
    ['LEFT', q{SELECT LEFT(v, 2) FROM public.kw}, qr/SELECT pg_catalog\.LEFT\(v , 2\) FROM/],
    ['right', q{SELECT right(v, 2) FROM public.kw}, qr/pg_catalog\.right\(v , 2\)/],
    ['mode', q{SELECT mode() WITHIN GROUP (ORDER BY v) FROM public.kw}, qr/pg_catalog\.mode\(\) WITHIN GROUP/],
    ['substring', q{SELECT substring(v, 1, 2) FROM public.kw}, qr/pg_catalog\.substring\(v , 1 , 2\)/],
    ['overlay', q{SELECT overlay(v, v, 1) FROM public.kw}, qr/pg_catalog\.overlay\(v , v , 1\)/]) {
    my ($name, $sql, $want) = @$case;
    like $q->($sql), $want, "$name is qualified";
    is $lint->($q->($sql)), '', "$name lints clean once qualified";
    like $lint->($sql), qr/unqualified function/, "the lint sees a bare $name";
}

for my $name (qw(delete last key update first next range share lock)) {
    my $sql = "SELECT $name(h, v) FROM public.kw";
    my $ok = eval { $q->($sql); 1 };
    my $error = $@;
    ok !$ok && blessed($error) && $error->code eq 'query_rule_not_evaluable' && $error->details->{reason} eq 'function_keyword',
        "$name, in no pinned catalog, is refused";
    like $lint->($sql), qr/unqualified function $name/, "the lint sees $name";
}

# THEN insert(...) in a CASE is a call, THEN INSERT (...) in a MERGE is not.
like $lint->(q{SELECT CASE WHEN id OPERATOR(pg_catalog.=) 1 THEN insert(v) END FROM public.kw}), qr/unqualified function insert/, 'insert in a CASE is a call';

is $lint->($q->($_)), '', "syntax, not a call: $_" for
    q{SELECT substring(v FROM 1 FOR 2) FROM public.kw},
    q{SELECT overlay(v PLACING v FROM 1) FROM public.kw},
    q{SELECT a.id FROM public.kw AS a LEFT JOIN (SELECT id FROM public.kw) AS b ON a.id OPERATOR(pg_catalog.=) b.id},
    q{SELECT a.id FROM public.kw AS a RIGHT JOIN public.kw AS b ON a.id OPERATOR(pg_catalog.=) b.id},
    q{SELECT id FROM public.kw ORDER BY id DESC NULLS LAST FETCH FIRST (1) ROWS ONLY},
    q{SELECT id FROM public.kw FETCH NEXT (1) ROWS ONLY},
    q{SELECT id FROM public.kw FOR UPDATE},
    q{SELECT SUM(id) OVER (ORDER BY id RANGE (1) PRECEDING) FROM public.kw},
    q{INSERT INTO public.kw (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET id = 2},
    q{DELETE FROM public.kw},
    q{WITH key(a) AS (SELECT 1) SELECT a FROM key},
    q{WITH c AS (SELECT 1), first(a) AS (SELECT 1) SELECT a FROM first},
    q{SELECT b.a FROM (SELECT 1) AS first(a)},
    q{INSERT INTO range (a) VALUES (1)},
    q{MERGE INTO public.kw AS t USING public.kw AS s ON t.id OPERATOR(pg_catalog.=) s.id WHEN NOT MATCHED THEN INSERT (id) VALUES (1)};

done_testing;
