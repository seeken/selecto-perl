use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R51 amendment 3: what an expression's type is, for choosing an operator.
# A CASE takes its type from its results, never its conditions; a column tested
# by IS [NOT] NULL gives nothing its type; an expression of strings alone is a
# string; a function that can only return a non-extension type is plain. So
# none of these is refused for reading an extension column, and each answers
# as PostgreSQL does. An expression that can have the extension type stays
# refused where the choice of operator depends on it.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
local $ENV{SELECTO_PG_SQL_LINT} = 1;
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my %mine;
END { eval {
    $admin->do('DROP TABLE IF EXISTS public.a3_t CASCADE');
    $admin->do(qq{DROP EXTENSION IF EXISTS "$_" CASCADE}) for grep { $mine{$_} } qw(postgis lo pg_trgm ltree hstore citext);
    $admin->do('DROP SCHEMA IF EXISTS a3ext CASCADE');
} }
$admin->do('CREATE SCHEMA IF NOT EXISTS a3ext');
my %schema;
for my $extension (qw(citext hstore ltree pg_trgm lo)) {
    my ($have) = $admin->selectrow_array('SELECT count(*) FROM pg_extension WHERE extname = ?', undef, $extension);
    if (!$have) {
        plan skip_all => "$extension is not available" unless eval { $admin->do(qq{CREATE EXTENSION "$extension" SCHEMA a3ext}); 1 };
        $mine{$extension} = 1;
    }
    ($schema{$extension}) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = ?}, undef, $extension);
}
my %distinct = map { ($_ => 1) } 'public', values %schema;
my $path = join ',', sort keys %distinct;
my ($dsn, @auth) = TestPostgreSQL->connection;
my $dbh = DBI->connect("$dsn;options='-c search_path=" . ($path =~ s/,/\\,/gr) . "'", @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
$dbh->do('SET client_min_messages TO warning');
$dbh->do($_) for 'DROP TABLE IF EXISTS public.a3_t CASCADE',
    q{CREATE TABLE public.a3_t (id INT PRIMARY KEY, org TEXT NOT NULL, ci citext, ci2 citext, tx TEXT, n INT, h hstore, l ltree, loo lo, ta TEXT[], cat TEXT)},
    q{INSERT INTO public.a3_t VALUES (1, 't1', 'a@x', 'A@X', 'gold', 1, 'a=>1', 'a.b', 101, '{a@x,A@X}', 'a@x'), (2, 't1', NULL, NULL, 'GOLD', 2, NULL, NULL, 102, '{x}', 'A@X'),
      (3, 't2', 'b@x', 'b@x', 'gold', 3, 'b=>1', 'b.c', 103, '{b@x}', 'b@x')};
my $case_null = sub { ['case', [['is_null', $_[0]], ['literal', 1]], ['else', ['literal', 0]]] };
my %computed = (
    missing_ci => {type => 'integer', expression => $case_null->('ci')},
    missing_h => {type => 'integer', expression => $case_null->('h')},
    missing_l => {type => 'integer', expression => $case_null->('l')},
    weight => {type => 'integer', expression => ['add', ['field', 'n'], $case_null->('ci')]},
    label => {type => 'string', expression => ['case', [['eq', 'tx', 'gold'], ['literal', 'a@x']], ['else', ['literal', 'other']]]},
    by_ci => {type => 'string', expression => ['case', [['eq', 'ci', 'A@X'], ['literal', 'A@X']], ['else', ['literal', 'other']]]},
    ci_case => {type => 'string', expression => ['case', [['eq', 'id', 1], ['field', 'ci']], ['else', ['field', 'ci2']]]},
    ci_text => {type => 'string', expression => ['case', [['eq', 'id', 1], ['field', 'ci']], ['else', ['literal', 'x']]]},
    ci_coalesce => {type => 'string', expression => ['coalesce', ['field', 'ci'], ['literal', 'x']]},
);
my @fields = qw(id org ci ci2 tx n h l loo ta cat);
my %columns = map { ($_ => {type => /\A(?:id|n)\z/ ? 'integer' : 'string'}) } @fields;
$columns{ta} = {type => 'array', items => 'string'};
$columns{$_} = {type => $computed{$_}{type}, computed => {kind => 'expression', expression => $computed{$_}{expression}}} for keys %computed;
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'A3', source => {source_table => 'a3_t', primary_key => 'id', tenant_field => 'org',
    fields => [@fields, sort keys %computed], columns => \%columns, associations => {}}, schemas => {}, joins => {}});
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $e = Selecto::Engine->new(domain => $domain, adapter => $adapter)->with_scope(tenant => 't1');
my $attempt = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return $value unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code')
        ? $error->code . (ref($error->details) eq 'HASH' && $error->details->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
};
my $rows = sub { my ($q) = @_; $attempt->(sub { join ';', map { join ',', map { $_ // 'NULL' } @$_ } @{$e->all($q)->{rows}} }) };
my $where = sub { $rows->($e->query->select('id')->where($_[0])->order_by('id')) };
my $f = sub { $x->field($_[0]) };

# F1: a column tested for NULL gives the CASE no type.
is($rows->($e->query->select('id', 'weight')->order_by('id')), '1,1;2,3', 'an integer CASE over IS NULL of citext selects');
is($rows->($e->query->select('id')->order_by('weight')->order_by('id')), '1;2', 'and orders');
is($rows->($e->query->select('weight', $x->count->as('c'))->group_by('weight')->order_by('weight')), '1,1;3,1', 'and groups');
is($where->($x->gt('weight', 1)), '2', 'and filters');
is($where->($x->eq('missing_ci', $f->('n'))), '', 'and compares with an integer');
is($where->($x->eq('missing_h', 1)), '2', 'over hstore');
is($where->($x->eq('missing_l', 1)), '2', 'over ltree');

# F2: strings alone against citext compare as text, like PostgreSQL.
is($where->($x->eq('ci', $f->('label'))), '1', 'citext = a text-only CASE compares as text');
is($where->($x->ne('label', $f->('ci'))), '', 'a text-only CASE <> citext compares as text');
is($where->($x->eq('ci2', $f->('label'))), '', 'and is case-sensitive, as native');
is($where->($x->eq('ci2', $f->('by_ci'))), '1', 'conditions on citext do not type a CASE of strings');
my $member = sub {
    my ($field, $predicate, %join) = @_;
    $rows->($e->query->with_cte('m', $domain, $e->query->select('id', $field), columns => ['id', 'v'],
        join => {owner_key => 'id', related_key => 'id', type => 'inner', %join})->select('id')->where($predicate // $x->gt('id', 0))->order_by('id'));
};
is($member->('label', $x->eq('ci2', $f->('m.v'))), '', 'a member output of strings against citext compares as text');
is($member->('label', undef, owner_key => 'ci', related_key => 'v'), '1', 'and joins as text');

# Text results compare as text against citext, through every public shape: an
# aggregate, an array rowset and a subquery join, not only a plain column.
my $one = {owner_key => 'id', related_key => 'id', type => 'inner'};
my $maximum = sub { $e->query->select('id', $x->max($_[0])->as('v'))->group_by('id') };
is($rows->($e->query->with_cte('m', $domain, $maximum->('cat'), columns => ['id', 'v'], join => {owner_key => 'ci', related_key => 'v', type => 'inner'})->select('id')->order_by('id')),
    '1', 'a member of max(text) joined to citext');
is($rows->($e->query->with_cte('m', $domain, $maximum->('cat'), columns => ['id', 'v'], join => $one)->select('id')->where($x->eq('ci2', $f->('m.v')))->order_by('id')),
    '', 'max(text) = citext compares as text');
is($rows->($e->query->array_rowset('ta', 'r')->select('id')->where($x->eq('ci2', $f->('r.value')))->order_by('id')), '1', 'an array rowset of text against citext');
is($rows->($e->query->subquery_join('m', $domain, $maximum->('cat'), on => [{left => 'ci', right => 'v'}])->select('id')->order_by('id')), '1;2', 'a subquery join of max(text) to citext, left join');

# Set operations in a member, through the public API, against what PostgreSQL
# answers for the same text. The right-nested form compiles to SELECT *.
{
    my $branch = sub { $e->query->select('id', $_[0]) };
    my $native = TestPostgreSQL->connect;
    $native->do("SET search_path = " . join(', ', map { qq{"$_"} } split(/,/, $path)));
    for my $case (['tx union ci', sub { $branch->('tx')->union($branch->('ci')) }], ['ci union (ci union tx)', sub { $branch->('ci')->union($branch->('ci')->union($branch->('tx'))) }],
        ['(ci union ci) union tx', sub { $branch->('ci')->union($branch->('ci'))->union($branch->('tx')) }], ['ci union ci2', sub { $branch->('ci')->union($branch->('ci2')) }]) {
        my ($name, $set) = @$case;
        for my $predicate ([eq => $x->eq('m.v', 'A@X')], [ne => $x->ne('m.v', 'A@X')]) {
            my $q = $e->query->with_cte('m', $domain, $set->(), columns => ['id', 'v'], join => $one)->select('id', 'm.v')->where($predicate->[1])->order_by('id');
            my $statement = $e->compile($q);
            my $want = join ';', sort map { join ',', map { $_ // 'NULL' } @$_ } @{$native->selectall_arrayref($statement->sql, undef, @{$statement->params})};
            is($attempt->(sub { join ';', sort map { join ',', map { $_ // 'NULL' } @$_ } @{$e->all($q)->{rows}} }), $want, "$name, $predicate->[0]: as natively");
        }
    }
}

# An output that is no string against text is PostgreSQL's error, and no
# operand cast left over from typing the member (a citext cast here once made
# bigint = text answer).
is($member->('weight', $x->eq('tx', $f->('m.v'))), 'query_error', 'integer against text stays an error');
my $text = sub { my ($sql) = @_; local $ENV{SELECTO_PG_SQL_LINT} = 0; $attempt->(sub { $adapter->_statement_sql($sql) }) };
unlike($text->(q{WITH m AS (SELECT id, CASE WHEN ci LIKE 'a%' THEN 1 ELSE 0 END AS v FROM public.a3_t) SELECT a.id FROM public.a3_t AS a JOIN m ON a.id = m.id WHERE a.tx = m.v}),
    qr/\(\(CAST\(\("?a"?\."?tx/, 'no operator inherits a cast from typing its operand');

# Hand-built forms, each against citext and answered natively.
my %string = ("NULLIF(a.tx, 'x')" => 'NULLIF', 'a.tx || a.tx' => 'a || b', "'a' || 'b'" => 'lit || lit', "(SELECT 'x')" => 'a scalar subquery of a literal',
    q{(SELECT b.tx FROM public.a3_t AS b WHERE b.id = 1)} => 'a scalar subquery of a text column', q{CASE a.id WHEN 1 THEN 'x' ELSE 'y' END} => 'a simple CASE of strings');
for my $sql (sort keys %string) {
    my $out = $text->("SELECT a.id FROM public.a3_t AS a WHERE a.ci = ($sql)");
    like($out, qr/OPERATOR\(pg_catalog\.=\)/, "citext = $string{$sql} is text's operator");
    is(eval { scalar @{$dbh->selectall_arrayref($out)} } // "died: $@", scalar @{$dbh->selectall_arrayref("SELECT a.id FROM public.a3_t AS a WHERE a.ci = ($sql)")},
        "and answers as PostgreSQL does");
}
for my $sql (q{similarity(a.ci, 'a') > 0.1}, q{nlevel(a.l) > 1}, q{exist(a.h, 'a') = TRUE}) {
    unlike($text->("SELECT a.id FROM public.a3_t AS a WHERE $sql"), qr/\Aquery_rule/, "$sql: a function of a plain type is plain");
}

# R51 amendment 3: the two exact cases that answer.
is($where->($x->eq('loo', 101)), '1', 'lo = 101 compares as oid');
is($where->($x->gte('loo', 102)), '2', 'lo >= 102 compares as oid');
like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE (a.ci || a.ci2) = a.tx}), qr/OPERATOR\(pg_catalog\.\|\|\)/, 'citext || citext is the text operator');
like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE a.ci ^@ a.ci2}), qr/OPERATOR\(pg_catalog\.\^@\)/, 'citext ^@ citext is the text operator');
is($text->(q{SELECT a.id FROM public.a3_t AS a WHERE a.loo || a.tx = a.tx}), 'query_rule_not_evaluable/operator_not_member', 'lo has no exact ||');

like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE a.ci = ('A')}), qr/\.=\)\s*\(CAST/, 'a parenthesised literal is still untyped');
like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE a.ci = (($1))}), qr/\.=\)\s*\(CAST/, 'and a parenthesised parameter');

# Still refused: an expression that can have the extension type, where that
# decides the operator.
is($where->($x->eq('ci_case', 'A@X')), '1', "a CASE of citext alone is citext: its own operator");
is($where->($x->eq('ci_case', $f->('ci'))), '1', 'against citext too');
is($where->($x->eq('ci_case', $f->('tx'))), '', 'against text it compares as text');

# PostgreSQL's common type: citext beside a pg_catalog string is text, and a
# Selecto literal is CAST AS TEXT. So these are text, and answer as natively.
is($where->($x->eq('ci_text', 'a@x')), '1', 'citext beside a literal is text: exact match');
is($where->($x->eq('ci_text', 'A@X')), '', 'and case-sensitive');
is($rows->($e->query->select($x->max('ci_coalesce')->as('m'))), 'x', "max over citext beside a literal is pg_catalog's, as native");
like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE (CASE WHEN a.id = 1 THEN a.ci ELSE a.ci END) ~ LEFT(a.tx, 4)}), qr/"\w+"\.~\)/,
    'citext ~ text is a cross-type member: a CASE of citext takes it (L2)');
like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE (CASE WHEN a.id = 1 THEN a.ci ELSE a.ci END) ~~ a.tx}), qr/"\w+"\.~~\)/, 'and ~~');
unlike($text->(q{SELECT a.id FROM public.a3_t AS a WHERE a.tx ~ (CASE WHEN a.id = 1 THEN a.ci ELSE a.ci END)}), qr/\Aquery_rule/, 'text ~ citext has no member, and is text');

# A CASE of citext results gets citext's own operator and aggregate, operands
# cast, never pg_catalog's: native 'A@X' matches case-insensitively, and text's =
# would narrow the rows silently.
{
    my $citext_case = q{(CASE WHEN a.id > 0 THEN a.ci END)};
    my $member = qr/"\w+"\.=\)\s*\(CAST/;
    for my $case (["$citext_case = 'A\@X'", 'CASE of citext = a literal'], ["'A\@X' = $citext_case", 'a literal = CASE of citext'],
        [q{CASE WHEN a.id > 0 THEN a.ci END = $1}, 'CASE of citext = a parameter'], ["$citext_case = a.ci2", 'CASE of citext = citext'],
        ["$citext_case IN ('A\@X')", 'CASE of citext in a list'], ["NULLIF(a.ci, 'x') = 'A\@X'", 'NULLIF of citext'], ["COALESCE(a.ci, a.ci2) = 'A\@X'", 'COALESCE of citext']) {
        like($text->("SELECT a.id FROM public.a3_t AS a WHERE $case->[0]"), $member, "$case->[1] uses the member");
    }
    like($text->("SELECT max$citext_case FROM public.a3_t AS a"), qr/"\w+"\.max\(CAST/, "max over a CASE of citext is citext's");
    like($text->("SELECT min(COALESCE(a.ci, a.ci2)) FROM public.a3_t AS a"), qr/"\w+"\.min\(CAST/, "min over a COALESCE of citext is citext's");
    like($text->("WITH m AS (SELECT a.id, $citext_case AS v FROM public.a3_t AS a) SELECT m.id FROM m WHERE m.v = 'A\@X'"), $member, 'a member output of a CASE of citext');
    is($rows->($e->query->select($x->max('ci')->as('m'))), 'a@x', "max over the column itself is citext's");
    is($where->($x->eq('ci_case', 'A@X')), '1', 'and through the public API');
    my $unknown = 'query_rule_not_evaluable/operand_type_unknown';
    is($text->("SELECT a.id FROM public.a3_t AS a WHERE citext(a.tx) = 'A'"), $unknown, 'a function that may return citext is refused against a value');
    like($text->(q{SELECT a.id FROM public.a3_t AS a WHERE a.ci IN (SELECT 'A')}), qr/pg_catalog\.=/, 'IN a subquery of a literal is text, as natively');
}

# A set operation's output is what its branches resolve to together, not its
# first branch's type: a literal beside citext is citext, citext beside text is
# text. Each of these answered wrongly when only the first branch was read.
{
    my $unknown = 'query_rule_not_evaluable/operand_type_unknown';
    like($text->(q{SELECT 1 FROM (SELECT 'a' AS x UNION ALL SELECT s.ci FROM public.a3_t AS s) AS d WHERE d.x = 'A'}), qr/\.=\)\s*\(CAST/, 'an untyped literal beside citext is citext');
    like($text->(q{SELECT 1 FROM (SELECT s.ci AS x FROM public.a3_t AS s UNION ALL SELECT s.tx FROM public.a3_t AS s) AS d WHERE d.x = 'A'}), qr/pg_catalog\.=/, 'citext beside text is text');
    like($text->(q{SELECT 1 FROM (SELECT s.ci AS x FROM public.a3_t AS s UNION SELECT * FROM (SELECT t.ci AS x FROM public.a3_t AS t UNION SELECT t.tx FROM public.a3_t AS t) AS r) AS d WHERE d.x = 'A'}),
        qr/pg_catalog\.=/, 'a SELECT * branch is expanded, not dropped');
    is($text->(q{SELECT 1 FROM (SELECT s.ci AS x FROM public.a3_t AS s UNION SELECT * FROM public.a3_t) AS d WHERE d.x = 'A'}), $unknown, 'a SELECT * of a relation is unknown, not dropped');
    like($text->(q{SELECT 1 FROM (SELECT s.ci AS x FROM public.a3_t AS s UNION SELECT t.ci2 FROM public.a3_t AS t) AS d WHERE d.x = 'A'}), qr/OPERATOR\("?\w+"?\.=\)\s*\(CAST/,
        'citext beside citext stays citext');
    like($text->(q{WITH RECURSIVE m(id, v) AS (SELECT s.id, s.ci FROM public.a3_t AS s UNION ALL SELECT m.id + 1, m.v FROM m WHERE m.id < 2) SELECT m.id FROM m WHERE m.v = 'A'}),
        qr/\.=\)\s*\(CAST/, "a recursive step's own reference adds nothing");
    like($text->(q{SELECT 1 FROM (SELECT s.tx AS x FROM public.a3_t AS s UNION SELECT 'y') AS d WHERE d.x = 'A'}), qr/pg_catalog\.=/, 'text beside a literal is text');
}

# A refusal says what it refused.
my $refused = eval { $e->all($e->query->select('id')->where($x->lt('h', 'a=>1'))); 1 } ? undef : $@;
is($refused->details->{column}, 'h', 'the refusal names the column');
like($refused->details->{type}, qr/hstore/, 'and the type');
unlike($refused->message, qr/hstore|column h/, 'but its message is fixed: hosts pass messages on to clients');

SKIP: {
    my ($available) = $admin->selectrow_array(q{SELECT count(*) FROM pg_available_extensions WHERE name = 'postgis'});
    my ($installed) = $admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'postgis'});
    skip 'postgis is not available', 4 unless $available || $installed;
    if (!$installed) { $admin->do('CREATE EXTENSION postgis SCHEMA a3ext'); $mine{postgis} = 1 }
    my ($gis) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'postgis'});
    $dbh->do(qq{ALTER TABLE public.a3_t ADD COLUMN g "$gis".geometry});
    unlike($text->("SELECT a.id FROM public.a3_t AS a WHERE $_"), qr/\Aquery_rule/, "$_: a function of a plain type is plain")
        for q{ST_Area(a.g)=0}, q{ST_X(a.g)>0}, q{ST_Distance(a.g,a.g)<1};
    is($text->(q{SELECT a.id FROM public.a3_t AS a WHERE ST_Centroid(a.g) = a.tx}), 'query_rule_not_evaluable/operand_type_unknown', 'a function returning geometry is not plain');
}

done_testing;
