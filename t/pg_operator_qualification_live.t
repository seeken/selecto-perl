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
use Selecto::PostgreSQL::Qualify ();
use lib 't/lib';
use TestPostgreSQL ();

# R46 FINAL-2 / R47: PostgreSQL prefers an exact argument-type operator or
# function match anywhere on the search_path over pg_catalog's coercing one.
# Every statement the adapter executes passes through one qualifying emitter:
# operators become OPERATOR(pg_catalog.op) (the type's own extension schema
# for extension member types such as citext), pg_catalog functions are
# schema-qualified, and IN / BETWEEN / LIKE / IS DISTINCT FROM / NULLIF and a
# simple CASE are written with explicit operators. This test plants exact
# match user operators and functions in public for varchar, text, enum,
# array, domain and citext operands, runs a corpus of reads and writes (with
# SELECTO_PG_SQL_LINT on, so any bare operator or unqualified function in an
# executed statement dies), lints every statement the adapter prepared, and
# checks the answers against the native ones.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
local $ENV{SELECTO_PG_SQL_LINT} = 1;
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $outcome = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return 'applied' . (defined($value) && !ref($value) ? " $value" : '') unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code')
        ? $error->code . (ref($error->details) eq 'HASH' && $error->details->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
};
# citext in its own schema, off the search path, unless it is installed
# already (then it is left alone).
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
my $has_citext = $preinstalled
    || eval { $admin->do('CREATE SCHEMA IF NOT EXISTS r47ext'); $admin->do('CREATE EXTENSION citext SCHEMA r47ext'); 1 };
my $citext_schema = $has_citext ? ($admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'}))[0] : undef;
my $ci_type = $has_citext ? qq{"$citext_schema".citext} : 'text';
my @evil = (
    'DROP TABLE IF EXISTS r47_items, r47_links, r47_accs, r47_tags CASCADE', 'DROP TYPE IF EXISTS r47_en CASCADE', 'DROP DOMAIN IF EXISTS r47_dom CASCADE',
    q{CREATE TYPE r47_en AS ENUM ('a', 'b')}, 'CREATE DOMAIN r47_dom AS varchar(10)',
    "CREATE TABLE r47_items (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL, name TEXT, kind r47_en, tags INT[], code r47_dom, ci $ci_type, n INT)",
    q{INSERT INTO r47_items VALUES (1, 't1', 'alpha', 'a', '{1,2}', 'c1', 'MiXed', 5), (2, 't2', 'SECRET', 'b', '{3}', 'c2', 'other', 7),
        (3, 't1', 'mixed', 'b', '{2}', 'c3', 'mixed', 9), (5, 't1', 'MIXED', 'a', '{9}', 'c5', 'mixed', 11)},
    "CREATE TABLE r47_tags (code $ci_type PRIMARY KEY, label TEXT)", q{INSERT INTO r47_tags VALUES ('MIXED', 'tag-mixed'), ('other', 'tag-other')},
    'CREATE TABLE r47_accs (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL, label TEXT)',
    q{INSERT INTO r47_accs VALUES (10, 't1', 't1-acc'), (20, 't2', 't2-SECRET')},
    'CREATE TABLE r47_links (item_id INT, acc_id INT)', 'INSERT INTO r47_links VALUES (1, 10), (2, 20), (3, 10), (5, 10)',
);
$admin->do($_) for @evil;
# Exact-match user operators and functions that answer true / a decoy.
my @hijack;
for my $types (['varchar', 'varchar'], ['text', 'text'], ['r47_en', 'r47_en'], ['int4[]', 'int4[]'], ['r47_dom', 'r47_dom'],
    ($has_citext ? [$ci_type, $ci_type] : ())) {
    my ($l, $r) = @$types;
    (my $tag = "$l$r") =~ s/[^a-z0-9]//g;
    push @hijack, "CREATE FUNCTION public.r47_yes_$tag($l, $r) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true'",
        "CREATE OPERATOR public.= (LEFTARG = $l, RIGHTARG = $r, FUNCTION = public.r47_yes_$tag)",
        "CREATE OPERATOR public.<> (LEFTARG = $l, RIGHTARG = $r, FUNCTION = public.r47_yes_$tag)";
}
push @hijack, q{CREATE FUNCTION public.r47_zero(smallint, integer) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT 0'},
    'CREATE OPERATOR public.& (LEFTARG = smallint, RIGHTARG = integer, FUNCTION = public.r47_zero)',
    q{CREATE FUNCTION public.r47_zero2(smallint, smallint) RETURNS smallint LANGUAGE sql IMMUTABLE AS 'SELECT 0::smallint'},
    'CREATE OPERATOR public.& (LEFTARG = smallint, RIGHTARG = smallint, FUNCTION = public.r47_zero2)';
push @hijack, q{CREATE FUNCTION public.lower(varchar) RETURNS text LANGUAGE sql IMMUTABLE AS $$SELECT 'alpha'::text$$},
    q{CREATE FUNCTION public.count(varchar) RETURNS bigint LANGUAGE sql IMMUTABLE AS 'SELECT 42::bigint'};
my $drop_hijack = sub {
    for my $sql (@hijack) {
        next unless $sql =~ /\ACREATE (FUNCTION|OPERATOR) (public\.\S+?) ?\((?:LEFTARG = (\S+), RIGHTARG = (\S+?),|([^)]*)\))/;
        my ($kind, $name) = ($1, $2);
        my $args = $kind eq 'OPERATOR' ? "($3, $4)" : "($5)";
        eval { $admin->do("DROP $kind IF EXISTS $name $args CASCADE") };
    }
};
$drop_hijack->();

my $domain = Selecto::Domain->parse({schema_version => 1, name => 'R47',
    source => {source_table => 'r47_items', primary_key => 'id', tenant_field => 'org', fields => [qw(id org name kind tags code ci n)],
        columns => {id => {type => 'integer'}, org => {type => 'string'}, name => {type => 'string'}, kind => {type => 'string'},
            tags => {type => 'string'}, code => {type => 'string'}, ci => {type => 'string'}, n => {type => 'integer'}},
        associations => {accs => {queryable => 'acc', owner_key => 'id', related_key => 'id', cardinality => 'many',
            through => {table => 'r47_links', owner_key => 'item_id', related_key => 'acc_id'}},
            tag => {queryable => 'tag', owner_key => 'ci', related_key => 'code'}}},
    schemas => {acc => {source_table => 'r47_accs', primary_key => 'id', fields => [qw(id org label)],
        columns => {id => {type => 'integer'}, org => {type => 'string'}, label => {type => 'string'}}, associations => {}},
        tag => {source_table => 'r47_tags', primary_key => 'code', fields => [qw(code label)],
            columns => {code => {type => 'string'}, label => {type => 'string'}}, associations => {}}},
    joins => {accs => {type => 'left'}, tag => {type => 'left'}},
    writes => {operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
        delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {map { ($_ => {insertable => 1, updatable => ($_ eq 'name' ? 1 : 0)}) } qw(id org name n)}}});

my @prepared;
my $connect = sub {
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO warning');
    $dbh->{Callbacks} = {do => sub { push @prepared, $_[1]; return },
        ChildCallbacks => {execute => sub { push @prepared, $_[0]{Statement}; return }}};
    return $dbh;
};

my $run = sub {
    my ($label) = @_;
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)))
        ->with_scope(tenant => 't1');
    my $ids = sub { my ($q) = @_; join ',', map { $_->[0] } @{$engine->all($q->order_by('id'))->{rows}} };
    my $q = $engine->query->select('id');
    my %results = (
        'plain tenant read' => $outcome->(sub { $ids->($q) }),
        'eq varchar' => $outcome->(sub { $ids->($q->where($x->eq('name', 'alpha'))) }),
        'ne text' => $outcome->(sub { $ids->($q->where($x->ne('name', 'alpha'))) }),
        'in list' => $outcome->(sub { $ids->($q->where($x->in('n', [5, 7]))) }),
        'between' => $outcome->(sub { $ids->($q->where($x->between('n', 4, 6))) }),
        'starts_with' => $outcome->(sub { $ids->($q->where($x->starts_with('name', 'al'))) }),
        'starts_with_ci' => $outcome->(sub { $ids->($q->where($x->starts_with_ci('name', 'BE'))) }),
        'enum eq' => $outcome->(sub { $ids->($q->where($x->eq('kind', 'a'))) }),
        'domain eq' => $outcome->(sub { $ids->($q->where($x->eq('code', 'c3'))) }),
        'citext eq (case-insensitive natively)' => $outcome->(sub { $ids->($q->where($x->eq('ci', 'mixed'))) }),
        'citext ne' => $outcome->(sub { $ids->($q->where($x->ne('ci', 'mixed'))) }),
        'bridge read' => $outcome->(sub { join ',', map { $_->[1] // 'NULL' } @{$engine->all($engine->query->select('id', 'accs.label')->order_by('id'))->{rows}} }),
        'retarget' => $outcome->(sub { join ',', map { $_->[1] } @{$engine->all($engine->query->retarget('accs', strategy => 'in')->select('id', 'label')->order_by('id'))->{rows}} }),
        'group count' => $outcome->(sub { join ',', map { "$_->[0]:$_->[1]" } @{$engine->all($engine->query->select('kind', $x->count->as('c'))->group_by('kind')->order_by('kind'))->{rows}} }),
        'citext join keeps citext semantics' => $outcome->(sub { join ',', map { "$_->[0]:" . ($_->[1] // 'NULL') } @{$engine->all($engine->query->select('id', 'tag.label')->order_by('id'))->{rows}} }),
        'citext = text resolves to text' => $outcome->(sub { $ids->($q->where($x->eq('ci', $x->field('name')))) }),
        'text = citext resolves to text' => $outcome->(sub { $ids->($q->where($x->eq('name', $x->field('ci')))) }),
        'stream' => $outcome->(sub { my $s = $engine->stream($q->order_by('id')); my @r; while (my $row = $s->next) { push @r, $row->[0] } join ',', @r }),
    );
    # R48: Selecto's own guard SQL is qualified too: a statement-level
    # update trigger is still seen (and refused) when public holds an
    # exact-match &(smallint, integer) that would hide it.
    $admin->do($_) for 'CREATE OR REPLACE FUNCTION r47_stmt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$',
        'CREATE TRIGGER r47_stmt AFTER UPDATE ON r47_items FOR EACH STATEMENT EXECUTE FUNCTION r47_stmt()';
    $results{'statement trigger refused'} = $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'r47_items', assignments => {name => 'mixed'}, predicate => $x->eq('id', 3)))->affected_rows });
    $admin->do($_) for 'DROP TRIGGER r47_stmt ON r47_items', 'DROP FUNCTION r47_stmt()';
    $results{'tenant update of another tenant'} = $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'r47_items', assignments => {name => 'pwned'}, predicate => $x->eq('id', 2)))->affected_rows });
    $results{'tenant update of its own row'} = $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'r47_items', assignments => {name => 'mixed'}, predicate => $x->eq('id', 3)))->affected_rows });
    $results{'guarded insert'} = $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert',
        relation => 'r47_items', assignments => {id => 4, org => 't1', name => 'new', n => 1}))->affected_rows });
    $results{'tenant delete of another tenant'} = $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'delete',
        relation => 'r47_items', predicate => $x->eq('id', 2)))->affected_rows });
    $results{'cleanup delete'} = $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'delete',
        relation => 'r47_items', predicate => $x->eq('id', 4)))->affected_rows });
    $dbh->disconnect;
    return \%results;
};

my $native = $run->('native');
$admin->do($_) for @hijack;
@prepared = ();
my $hijacked = $run->('hijacked');
$drop_hijack->();

is($native->{'plain tenant read'}, 'applied 1,3,5', 'native: the tenant read');
for my $case (sort keys %$native) {
    is($hijacked->{$case}, $native->{$case}, "with exact-match user operators and functions in public, $case: $native->{$case}");
}
is($native->{'tenant update of another tenant'}, $native->{'tenant update of another tenant'}, 'an update of another tenant never applies')
    if $native->{'tenant update of another tenant'} !~ /\Aapplied [1-9]/;
like($native->{'statement trigger refused'}, qr/\Awrite_capability_missing/, 'a statement-level update trigger refuses the bound update');
SKIP: {
    skip 'citext is not available', 2 unless $has_citext;
    is($native->{'citext eq (case-insensitive natively)'}, 'applied 1,3,5', 'citext keeps its case-insensitive equality');
    is($native->{'citext ne'}, 'applied ', 'and its inequality');
    is($native->{'citext join keeps citext semantics'}, 'applied 1:tag-mixed,3:tag-mixed,5:tag-mixed', 'a citext join matches case-insensitively');
    is($native->{'citext = text resolves to text'}, 'applied 3', 'citext against text compares as text (case-sensitive), as PostgreSQL resolves it');
    is($native->{'text = citext resolves to text'}, 'applied 3', 'whatever the operand order');
}
is($admin->selectrow_array('SELECT name FROM r47_items WHERE id = 2'), 'SECRET', "the other tenant's row is unchanged");

# Every statement the adapter prepared (business SQL and its guard SQL)
# resolves no operator or pg_catalog function through the session.
my %functions = map { (lc($_) => 1) } @{$admin->selectcol_arrayref(
    q{SELECT DISTINCT proname::text FROM pg_catalog.pg_proc WHERE pronamespace = 'pg_catalog'::regnamespace})};
my %bad;
for my $sql (@prepared) {
    next if $sql =~ /\A\s*(?:SAVEPOINT|RELEASE|ROLLBACK|BEGIN|COMMIT|SET |LOCK |DECLARE|FETCH|CLOSE|DEALLOCATE)/i && $sql !~ /\bFOR\s+SELECT\b/i;
    my @problems = eval { Selecto::PostgreSQL::Qualify::lint($sql, \%functions) };
    @problems = ("unparsable: $@") if $@;
    $bad{$sql} = join('; ', @problems) if @problems;
}
ok((grep { /r47_items/ && /\bOPERATOR\(/ } @prepared), 'the corpus holds the business statements as executed');
ok(!%bad, 'no executed statement resolves an operator or function through the session')
    or diag join "\n", map { "$bad{$_}: $_" } sort keys %bad;

# The lint covers Selecto's own guard SQL (review M2): a bare operator in a
# guard statement fails it.
{
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)))
        ->with_scope(tenant => 't1');
    no warnings 'redefine';
    my $original = \&Selecto::PostgreSQL::_pg_reset_schemas;
    local *Selecto::PostgreSQL::_pg_reset_schemas = sub {
        my ($self) = @_;
        $self->{dbh}->selectrow_array(q{SELECT 1 WHERE (2 & 3) <> 0});
        return $original->(@_);
    };
    like($outcome->(sub { scalar @{$engine->all($engine->query->select('id'))->{rows}} }), qr/SELECTO_PG_SQL_LINT: bare operator/,
        'a bare operator in guard SQL fails the lint');
    $dbh->disconnect;
}

$admin->do($_) for 'DROP TABLE r47_items, r47_links, r47_accs, r47_tags CASCADE', 'DROP TYPE r47_en', 'DROP DOMAIN r47_dom';
$admin->do($_) for $preinstalled ? () : ('DROP EXTENSION IF EXISTS citext CASCADE', 'DROP SCHEMA IF EXISTS r47ext CASCADE');
done_testing;
