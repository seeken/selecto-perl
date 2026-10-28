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

# Push-gate review of R48 (H1, H2, M1):
# - a DOMAIN over an extension type (citext) compares with the extension's
#   operators, as PostgreSQL resolves it (H1);
# - a read with a declared schema (a tenant prefix) resolves its relations
#   under the pin pg_catalog, <declared>, <reset>, pg_temp, and is not
#   refused as ambiguous when the prefix is not first on the reset path (H2);
# - the extension-operator choice follows the column's source in scope, so
#   an alias reused for another relation, or a CTE or member output, gets
#   its own relation's type (M1).
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
my $connect = sub {
    my (%options) = @_;
    my ($dsn, @auth) = TestPostgreSQL->connection;
    $dsn .= ";options='$options{options}'" if $options{options};
    my $dbh = DBI->connect($dsn, @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
};
my $engine = sub {
    my ($domain, %options) = @_;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $connect->(%options)));
    $e = $e->with_scope(tenant => $options{tenant}) if $options{tenant};
    $e = $e->with_read_context({prefix => $options{prefix}}) if $options{prefix};
    return $e;
};
my $ids = sub { my ($e, $q) = @_; join ',', map { $_->[0] } @{$e->all($q->order_by('id'))->{rows}} };

$admin->do($_) for 'DROP SCHEMA IF EXISTS r49_a CASCADE', 'DROP SCHEMA IF EXISTS r49_b CASCADE',
    'DROP TABLE IF EXISTS r49_acct, r49_root, r49_mem CASCADE', 'DROP DOMAIN IF EXISTS r49_email CASCADE';

# H2: schema-per-tenant prefix reads.
$admin->do($_) for 'CREATE SCHEMA r49_a', 'CREATE SCHEMA r49_b',
    'CREATE TABLE r49_a.r49_items (id INT PRIMARY KEY, note TEXT)', 'CREATE TABLE r49_b.r49_items (id INT PRIMARY KEY, note TEXT)',
    q{INSERT INTO r49_a.r49_items VALUES (1, 'a1'), (2, 'a2')}, q{INSERT INTO r49_b.r49_items VALUES (1, 'b1')};
my $items = Selecto::Domain->parse({schema_version => 1, name => 'R49I', source => {source_table => 'r49_items', primary_key => 'id',
    fields => [qw(id note)], columns => {id => {type => 'integer'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}});
my $notes = sub { my ($e) = @_; join ',', map { $_->[1] } @{$e->all($e->query->select('id', 'note')->order_by('id'))->{rows}} };
my $streamed = sub {
    my ($e) = @_;
    my $s = $e->stream($e->query->select('id', 'note')->order_by('id'));
    my @r; while (my $row = $s->next) { push @r, $row->[1] } join ',', @r;
};
for my $case (['r49_a', 'a1,a2'], ['r49_b', 'b1']) {
    my ($prefix, $want) = @$case;
    is($outcome->(sub { $notes->($engine->($items, prefix => $prefix)) }), "applied $want", "prefix $prefix read");
    is($outcome->(sub { $streamed->($engine->($items, prefix => $prefix)) }), "applied $want", "prefix $prefix stream");
    # The reset path names the other tenant's schema first.
    my $other = $prefix eq 'r49_a' ? 'r49_b' : 'r49_a';
    is($outcome->(sub { $notes->($engine->($items, prefix => $prefix, options => "-c search_path=$other,public")) }), "applied $want",
        "prefix $prefix read with $other first on the reset path");
    is($outcome->(sub { $notes->($engine->($items, prefix => $prefix, options => "-c search_path=$prefix,public")) }), "applied $want",
        "prefix $prefix read with $prefix first on the reset path");
    my $e = $engine->($items, prefix => $prefix);
    $e->adapter->dbh->do("SET search_path = $other, public");
    is($outcome->(sub { $notes->($e) }), "applied $want", "prefix $prefix read with $other first on the host's current path");
}

SKIP: {
    my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
    my $has = $preinstalled
        || eval { $admin->do('CREATE SCHEMA IF NOT EXISTS r49ext'); $admin->do('CREATE EXTENSION citext SCHEMA r49ext'); 1 };
    skip 'citext is not available', 8 unless $has;
    my ($schema) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'});
    my $citext = qq{"$schema".citext};
    # Natively, with the extension schema on the path.
    $admin->do(qq{SET search_path = public, "$schema"});

    # H1: a domain over citext, as a required filter on a read and a bulk write.
    $admin->do($_) for "CREATE DOMAIN r49_email AS $citext CHECK (VALUE LIKE '%\@%')",
        'CREATE TABLE r49_acct (id INT PRIMARY KEY, org TEXT NOT NULL, owner r49_email, note TEXT)',
        q{INSERT INTO r49_acct VALUES (1, 't1', 'alice@x', 'a'), (2, 't1', 'BLOCKED@x', 'b'), (3, 't1', 'blocked@x', 'c'), (4, 't2', 'bob@x', 'd')};
    my $acct = Selecto::Domain->parse({schema_version => 1, name => 'R49A', source => {source_table => 'r49_acct', primary_key => 'id',
        tenant_field => 'org', fields => [qw(id org owner note)],
        columns => {id => {type => 'integer'}, org => {type => 'string'}, owner => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {note => {updatable => 1}}}})->with_required_predicate($x->ne('owner', 'blocked@x'));
    my $native = join ',', @{$admin->selectcol_arrayref(q{SELECT id FROM r49_acct WHERE org = 't1' AND owner <> 'blocked@x' ORDER BY id})};
    is($native, '1', 'natively the domain over citext compares case-insensitively');
    my $e = $engine->($acct, tenant => 't1');
    is($outcome->(sub { $ids->($e, $e->query->select('id')) }), "applied $native", 'a required <> on a domain over citext reads as natively');
    is($outcome->(sub { $ids->($e, $e->query->select('id')->where($x->eq('owner', 'ALICE@X'))) }), 'applied 1', 'and = on it');
    is($outcome->(sub { $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r49_acct',
        assignments => {note => 'upd'}, predicate => $x->gt('id', 0)))->affected_rows }), 'applied 1', 'a bulk update under it writes the admitted row only');
    is(join(',', @{$admin->selectcol_arrayref('SELECT note FROM r49_acct ORDER BY id')}), 'upd,b,c,d', 'no excluded or other tenant row changed');

    # M1: the alias s0 names a text-org root and, in the member CTE, a citext-org relation.
    $admin->do($_) for 'CREATE TABLE r49_root (id INT PRIMARY KEY, org TEXT NOT NULL, k INT)',
        q{INSERT INTO r49_root VALUES (1, 't1', 1), (2, 'T1', 1), (3, 't2', 2)},
        "CREATE TABLE r49_mem (id INT PRIMARY KEY, org $citext NOT NULL, k INT, amount INT)",
        q{INSERT INTO r49_mem VALUES (10, 't1', 1, 5), (11, 'T1', 1, 7), (12, 't2', 2, 100)};
    my $rel = sub { my ($t, @f) = @_; +{source_table => $t, primary_key => 'id', tenant_field => 'org', fields => [map { $_->[0] } @f],
        columns => {map { ($_->[0] => {type => $_->[1]}) } @f}, associations => {}} };
    my $root = Selecto::Domain->parse({schema_version => 1, name => 'R49R', source => $rel->('r49_root', [id => 'integer'], [org => 'string'], [k => 'integer']),
        schemas => {mem => $rel->('r49_mem', [id => 'integer'], [org => 'string'], [k => 'integer'], [amount => 'integer'])}, joins => {},
        query_members => {ctes => {tot => {source => 'mem', query => {select => ['k', {as => 'total', aggregate => 'sum', field => 'amount'}],
            group_by => ['k']}, join => {owner_key => 'k', related_key => 'k', type => 'left'}}}}});
    my ($total) = $admin->selectrow_array(q{SELECT sum(amount) FROM r49_mem WHERE org = 't1'});
    my $er = $engine->($root, tenant => 't1');
    is($outcome->(sub { join ',', map { "$_->[0]:$_->[1]" } @{$er->all($er->query->with_member('tot')->select('id', 'tot.total')->order_by('id'))->{rows}} }),
        "applied 1:$total", 'a member CTE over a citext-org relation, under an alias the text-org root also uses, reads as natively');

    # M1: a CTE output and a member column carry the citext type.
    $admin->do($_) for "ALTER TABLE r49_root ADD COLUMN ci $citext", q{UPDATE r49_root SET ci = CASE id WHEN 1 THEN 'abc' WHEN 2 THEN 'ABC' ELSE 'x' END},
        q{UPDATE r49_root SET org = 't1'};
    my $root2 = Selecto::Domain->parse({schema_version => 1, name => 'R49R2', source => $rel->('r49_root', [id => 'integer'], [org => 'string'], [k => 'integer'], [ci => 'string']),
        schemas => {}, joins => {}});
    my $e2 = $engine->($root2, tenant => 't1');
    is($outcome->(sub { $ids->($e2, $e2->query->with_cte('m', $root2, $e2->query->select('id', 'ci')->where($x->eq('id', 1)),
        join => {type => 'inner', owner_key => 'ci', related_key => 'ci'})->select('id')) }), 'applied 1,2', 'a CTE join on a citext output matches as natively');
    is($outcome->(sub { $ids->($e2, $e2->query->with_cte('m', $root2, $e2->query->select('id', 'ci'),
        join => {type => 'inner', owner_key => 'id', related_key => 'id'})->select('id')->where($x->ne('m.ci', 'ABC'))) }), 'applied 3',
        'a filter on a CTE citext output compares as natively');

    $admin->do($_) for 'DROP TABLE r49_acct, r49_root, r49_mem CASCADE', 'DROP DOMAIN r49_email';
    $admin->do($_) for $preinstalled ? () : ('DROP EXTENSION IF EXISTS citext CASCADE', 'DROP SCHEMA IF EXISTS r49ext CASCADE');
}
$admin->do($_) for 'DROP SCHEMA r49_a CASCADE', 'DROP SCHEMA r49_b CASCADE';
done_testing;
