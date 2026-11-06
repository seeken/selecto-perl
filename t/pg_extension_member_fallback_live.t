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
use Selecto::Write ();
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R51 amendments 1 and 2. Without a member operator, OPERATOR(pg_catalog.op)
# does not guarantee a server refusal: an implicit cast can make it resolve and
# compare the wrong thing (box3d by area, geography through bytea, geometry as
# text). The fallback is allowed only for a string-category extension type
# against a pg_catalog string type; everything else is refused here, typed.
# Members, cross-type ones included, keep working.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
local $ENV{SELECTO_PG_SQL_LINT} = 1;
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my %mine;
END { eval {
    $admin->do('DROP TABLE IF EXISTS r51_t, r51_dt, r51_g, r51_tb3 CASCADE');
    $admin->do('DROP DOMAIN IF EXISTS r51_txt');
    $admin->do(qq{DROP EXTENSION IF EXISTS "$_" CASCADE}) for grep { $mine{$_} } qw(postgis isn ltree hstore citext);
    $admin->do('DROP SCHEMA IF EXISTS r51ext CASCADE');
} }
$admin->do('CREATE SCHEMA IF NOT EXISTS r51ext');
my %schema;
for my $extension (qw(citext hstore ltree isn)) {
    my ($have) = $admin->selectrow_array('SELECT count(*) FROM pg_extension WHERE extname = ?', undef, $extension);
    if (!$have) {
        plan skip_all => "$extension is not available" unless eval { $admin->do(qq{CREATE EXTENSION "$extension" SCHEMA r51ext}); 1 };
        $mine{$extension} = 1;
    }
    ($schema{$extension}) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = ?}, undef, $extension);
}
my $path = join ', ', map { qq{"$_"} } 'public', sort keys %{{map { ($_ => 1) } values %schema}};
$admin->do("SET search_path = $path");
my @t = qw(id org note ci tx vc dt h l l2 i13 e13 ca ha);
$admin->do($_) for 'DROP TABLE IF EXISTS r51_t CASCADE', 'DROP DOMAIN IF EXISTS r51_txt',
    'CREATE DOMAIN r51_txt AS text',
    q{CREATE TABLE r51_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT, ci citext, tx TEXT, vc VARCHAR(20), dt r51_txt, h hstore, l ltree, l2 ltree, i13 isbn13, e13 ean13, ca citext[], ha hstore[])},
    q{INSERT INTO r51_t VALUES
      (1, 't1', 'n', 'Gold', 'Gold', 'Gold', 'Gold', 'a=>1', 'a.b', 'a.b', '978-0-393-04002-9', '978-0-393-04002-9', '{x}', ARRAY['a=>1'::hstore]),
      (2, 't1', 'n', 'GOLD', 'gold', 'gold', 'gold', 'a=>2', 'a.c', 'a.b', '978-0-393-04002-9', '978-1-56619-909-4', '{y}', ARRAY['b=>1'::hstore]),
      (3, 't2', 'n', 'gold', 'gold', 'gold', 'gold', 'a=>1', 'a.b', 'a.b', '978-0-393-04002-9', '978-0-393-04002-9', '{x}', ARRAY['a=>1'::hstore])};
my $domain = sub {
    my ($table, $fields) = @_;
    Selecto::Domain->parse({schema_version => 1, name => "D$table", source => {source_table => $table, primary_key => 'id', tenant_field => 'org',
        fields => $fields, columns => {map { ($_ => {type => $_ eq 'id' ? 'integer' : 'string'}) } @$fields}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
};
my $dsn_options = "-c search_path=" . ($path =~ s/"//gr =~ s/, /\\,/gr);
my ($dsn, @auth) = TestPostgreSQL->connection;
my $dbh = DBI->connect("$dsn;options='$dsn_options'", @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
$dbh->do('SET client_min_messages TO warning');
my $engine = sub { my ($d, $tenant) = @_; Selecto::Engine->new(domain => $d, adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => $tenant // 't1') };
my $attempt = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return $value unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code')
        ? $error->code . (ref($error->details) eq 'HASH' && $error->details->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
};
my $read = sub { my ($e, $p) = @_; $attempt->(sub { join ',', map { $_->[0] } @{$e->all($e->query->select('id')->where($p)->order_by('id'))->{rows}} }) };
my $update = sub { my ($e, $table, $p) = @_;
    my $done = $attempt->(sub { $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => $table,
        assignments => {note => 'HIT'}, predicate => $p, expected_count => undef))->affected_rows });
    my $hit = $admin->selectcol_arrayref("SELECT id FROM $table WHERE note = 'HIT' ORDER BY id");
    $admin->do("UPDATE $table SET note = 'n'");
    return join ',', "$done", @$hit };
my $f = sub { $x->field($_[0]) };
my $refused = 'query_rule_not_evaluable/operator_not_member';
my $e = $engine->($domain->('r51_t', \@t));

# The allowed fallback: citext against a pg_catalog string compares as text,
# in either order, like PostgreSQL.
for my $other (qw(tx vc dt)) {
    is($read->($e, $x->eq('ci', $f->($other))), '1', "citext = $other compares as text");
    is($read->($e, $x->eq($other, $f->('ci'))), '1', "$other = citext compares as text");
    is($read->($e, $x->ne('ci', $f->($other))), '2', "citext <> $other compares as text");
}
is($read->($e, $x->eq('ci', 'gold')), '1,2', "citext = a value is citext's own operator");
is($read->($e, $x->in('ci', ['gold'])), '1,2', "citext in a value is citext's own operator");

# Members: same-type and cross-type, either order.
is($read->($e, $x->eq('h', 'a=>1')), '1', "hstore = a value is hstore's own");
is($read->($e, $x->eq('l', $f->('l2'))), '1', "ltree = ltree is ltree's own");
is($read->($e, $x->eq('i13', $f->('e13'))), '1', 'isbn13 = ean13 is a cross-type member');
is($read->($e, $x->eq('e13', $f->('i13'))), '1', 'ean13 = isbn13 is a cross-type member');
is($read->($e, $x->ne('i13', $f->('e13'))), '2', 'isbn13 <> ean13 is a cross-type member');

# An array of an extension type uses pg_catalog's array operators, which go
# through the element type's own comparison, as natively (R47).
is($read->($e, $x->eq('ca', '{x}')), '1', "citext[] = a value uses pg_catalog's array operator");
is($read->($e, $x->eq('ha', '{"a=>1"}')), '1', "hstore[] = a value uses pg_catalog's array operator");
is($read->($e, $x->eq('ca', $f->('ca'))), '1,2', "citext[] = citext[] uses pg_catalog's array operator");

# Refused, typed, on reads and on writes.
for my $case (['hstore <', $x->lt('h', 'a=>1')], ['hstore > hstore', $x->gt('h', $f->('h'))], ['hstore = text', $x->eq('h', $f->('tx'))],
    ['text = hstore', $x->eq('tx', $f->('h'))], ['ltree = text', $x->eq('l', $f->('tx'))], ['text = ltree', $x->eq('tx', $f->('l'))],
    ['citext = hstore', $x->eq('ci', $f->('h'))], ['hstore = citext', $x->eq('h', $f->('ci'))], ['citext = ltree', $x->eq('ci', $f->('l'))],
    ['citext = integer', $x->eq('ci', $f->('id'))], ['integer = citext', $x->eq('id', $f->('ci'))],
    ['hstore = integer', $x->eq('h', $f->('id'))]) {
    my ($name, $predicate) = @$case;
    is($read->($e, $predicate), $refused, "$name is refused on a read");
    like($update->($e, 'r51_t', $predicate), qr/\Aquery_rule_[a-z_\/]+\z/, "$name is refused on a write, and writes nothing");
}
is($read->($e, $x->starts_with('h', 'a')), $refused, 'a pattern on hstore is refused');
is($read->($e, $x->starts_with('l', 'a')), $refused, 'a pattern on ltree is refused');

# Operands the qualifier cannot type. An expression over an extension column is
# refused, unless it can only be a string against a string; a rowset output of
# no known type keeps pg_catalog's operator against a plain operand (the
# pg_catalog SRFs: an over-refusal here would break unnest over a parameter).
{
    my $adapter = $e->adapter;
    my $qualified = sub { my ($sql) = @_; local $ENV{SELECTO_PG_SQL_LINT} = 0; $attempt->(sub { $adapter->_statement_sql($sql) }) };
    is($qualified->(q{SELECT a.id FROM public.r51_t AS a WHERE COALESCE(a.h, a.h) = a.tx}), 'query_rule_not_evaluable/operator_not_member',
        'an expression over hstore against text is refused');
    is($qualified->(q{SELECT a.id FROM public.r51_t AS a WHERE COALESCE(a.h, a.h) = a.id}), 'query_rule_not_evaluable/operator_not_member',
        'an expression over hstore against an integer is refused');
    unlike($qualified->(q{SELECT a.id FROM public.r51_t AS a WHERE COALESCE(a.ci, a.ci) = a.tx}), qr/\Aquery_rule/,
        'an expression over citext against text falls back, as natively');
    is($qualified->(q{SELECT a.id FROM public.r51_t AS a WHERE COALESCE(a.ci, a.ci) = a.id}), 'query_rule_not_evaluable/operator_not_member',
        'an expression over citext against an integer is refused');
    unlike($qualified->(q{SELECT a.id FROM public.r51_t AS a JOIN LATERAL unnest(CAST($1 AS integer[])) AS u(x) ON u.x = a.id}), qr/\Aquery_rule/,
        'unnest over a parameter against a plain column still qualifies');
    is($attempt->(sub { join ',', map { $_->[0] } @{$e->all($e->query->select('id')->where($x->eq('tx', 'Gold')))->{rows}} }), '1',
        'a plain text column is untouched beside extension columns');
}

# PostGIS: the implicit casts that made the fallback compare the wrong thing.
SKIP: {
    my ($available) = $admin->selectrow_array(q{SELECT count(*) FROM pg_available_extensions WHERE name = 'postgis'});
    my ($installed) = $admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'postgis'});
    skip 'postgis is not available', 16 unless $available || $installed;
    if (!$installed) { $admin->do('CREATE EXTENSION postgis SCHEMA r51ext'); $mine{postgis} = 1 }
    my ($gis) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'postgis'});
    $admin->do($_) for 'DROP TABLE IF EXISTS r51_g, r51_tb3 CASCADE',
        qq{CREATE TABLE r51_g (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT, b3 "$gis".box3d, bx box, g "$gis".geometry, gg "$gis".geography, tx TEXT)},
        qq{INSERT INTO r51_g VALUES (1, 't1', 'n', 'BOX3D(0 0 0,2 2 0)', '(2,2),(0,0)', 'POINT(1 1)', 'POINT(1 1)', 'POINT(1 1)'),
          (2, 't1', 'n', 'BOX3D(5 5 0,7 7 0)', '(2,2),(0,0)', 'POINT(2 2)', 'POINT(2 2)', 'x')},
        qq{CREATE TABLE r51_tb3 (id INT PRIMARY KEY, org "$gis".box3d NOT NULL, note TEXT)},
        q{INSERT INTO r51_tb3 VALUES (1, 'BOX3D(0 0 0,2 2 0)', 'n'), (2, 'BOX3D(5 5 0,7 7 0)', 'n')};
    my $g = $engine->($domain->('r51_g', [qw(id org note b3 bx g gg tx)]));
    for my $case (['box3d =', $x->eq('b3', '(2,2),(0,0)')], ['box3d = box', $x->eq('b3', $f->('bx'))], ['box = box3d', $x->eq('bx', $f->('b3'))],
        ['geometry = text', $x->eq('g', $f->('tx'))], ['text = geometry', $x->eq('tx', $f->('g'))], ['geography <>', $x->ne('gg', 'POINT(1 1)')],
        ['geometry = geography', $x->eq('g', $f->('gg'))], ['geography = geometry', $x->eq('gg', $f->('g'))]) {
        my ($name, $predicate) = @$case;
        is($read->($g, $predicate), $refused, "$name is refused on a read");
        like($update->($g, 'r51_g', $predicate), qr/\Aquery_rule_[a-z_\/]+\z/, "$name is refused on a write, and writes nothing");
    }
    # Tenants that compare by area: a box3d tenant column must not cross.
    my $t = $engine->($domain->('r51_tb3', [qw(id org note)]), '(2,2),(0,0)');
    is($attempt->(sub { join ',', map { $_->[0] } @{$t->all($t->query->select('id'))->{rows}} }), $refused, 'a box3d tenant column is refused on a read');
    is($update->($t, 'r51_tb3', $x->gt('id', 0)), $refused, 'a box3d tenant column is refused on a write, and writes nothing');
}

done_testing;
