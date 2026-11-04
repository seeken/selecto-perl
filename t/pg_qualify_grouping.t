use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::PostgreSQL::Qualify ();

# GROUPING(...) is a call whose integer result is compared, not a keyword
# before a parenthesized group: the comparison stays outside its parentheses.
my $q = \&Selecto::PostgreSQL::Qualify::qualify;

my $sql = $q->(q{SELECT CASE WHEN GROUPING("s0"."status") = 1 THEN NULL ELSE MIN("s0"."status") END}
    . q{ FROM "public"."trailer" AS "s0" GROUP BY ROLLUP("s0"."status")});
like $sql, qr/CASE WHEN \(\(GROUPING\("s0"\."status"\)\) OPERATOR\(pg_catalog\.=\) \(1\)\) THEN/,
    'GROUPING(...) = 1 compares the GROUPING result';
unlike $sql, qr/GROUPING \(/, 'GROUPING keeps its own argument list';

$sql = $q->(q{SELECT GROUPING("s0"."a", "s0"."b") FROM "public"."t" AS "s0" GROUP BY ROLLUP("s0"."a", "s0"."b")});
like $sql, qr/\ASELECT GROUPING\("s0"\."a" , "s0"\."b"\) FROM/,
    'GROUPING with several operands is left a call';

$sql = $q->(q{SELECT "s0"."a" FROM "public"."t" AS "s0" GROUP BY GROUPING SETS (("s0"."a"), ())});
like $sql, qr/GROUPING SETS \(/, 'GROUPING SETS is still a clause';

done_testing;
