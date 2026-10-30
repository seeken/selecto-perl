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
use lib 't/lib';
use TestPostgreSQL ();

# Review of 96961bf (R49): operand types for extension operators.
# - M1: a computed member output whose type is known (lower(), a cast,
#   count()) is not refused, and a column's type is resolved through its own
#   relation, never by a namesake column of another relation.
# - M2: function rowsets (unnest of a citext[] column, a function returning
#   citext, a json rowset's declared columns) carry their column types.
# - M3 (R49c): citext's own max and min, which keep the citext type.
# - M4 (R49a): types read under a REPEATABLE READ snapshot are checked
#   against the current catalog; a column altered after the snapshot is
#   refused, typed.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
local $ENV{SELECTO_PG_SQL_LINT} = 1;
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
my $has = $preinstalled
    || eval { $admin->do('CREATE SCHEMA IF NOT EXISTS r50ext'); $admin->do('CREATE EXTENSION citext SCHEMA r50ext'); 1 };
plan skip_all => 'citext is not available' unless $has;
my ($schema) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'});
my $ci = qq{"$schema".citext};
# Natively, with the extension schema on the path.
$admin->do(qq{SET search_path = public, "$schema"});
my $outcome = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return 'applied' . (defined($value) && !ref($value) ? " $value" : '') unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code')
        ? $error->code . (ref($error->details) eq 'HASH' && $error->details->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
};
my $connect = sub { my $dbh = TestPostgreSQL->connect; $dbh->do('SET client_min_messages TO warning'); $dbh };
my $native = sub { my %seen; join ',', grep { !$seen{$_}++ } sort { $a <=> $b } @{$admin->selectcol_arrayref($_[0])} };
my $ids = sub { my ($e, $q) = @_; my %seen; join ',', grep { !$seen{$_}++ } sort { $a <=> $b } map { $_->[0] } @{$e->all($q)->{rows}} };

$admin->do($_) for 'DROP TABLE IF EXISTS r50_r, r50_m, r50_ma, r50_rr CASCADE', 'DROP FUNCTION IF EXISTS r50_ci_tags(text)',
    "CREATE TABLE r50_r (id INT PRIMARY KEY, org TEXT NOT NULL, k INT, email TEXT, tags $ci\[], doc JSONB)",
    q{INSERT INTO r50_r VALUES (1, 't1', 1, 'A@x.com', '{Gold,red}', '[{"code":"GOLD"}]'), (2, 't1', 2, 'b@x.com', '{GOLD}', '[{"code":"gold"}]'),
        (3, 't1', 3, 'c@x.com', '{silver}', '[{"code":"silver"}]'), (4, 't2', 1, 'd@x.com', '{gold}', '[]')},
    "CREATE TABLE r50_m (id INT PRIMARY KEY, org TEXT NOT NULL, k INT, tag $ci, email $ci, code $ci)",
    q{INSERT INTO r50_m VALUES (10, 't1', 1, 'Gold', 'A@X.COM', 'x'), (11, 't1', 2, 'GOLD', 'b@x.com', 'x'), (12, 't1', 3, 'silver', 'zz@x.com', 'x'),
        (13, 't2', 1, 'gold', 'd@x.com', 'x')},
    "CREATE FUNCTION r50_ci_tags(o text) RETURNS TABLE(t $ci) LANGUAGE sql STABLE AS \$\$ SELECT tag FROM r50_m WHERE org = o AND tag ILIKE 'gold' \$\$";
my $cols = sub { my %h = @_; +{map { ($_ => ref $h{$_} ? $h{$_} : {type => $h{$_}}) } keys %h} };
my $mem = {source_table => 'r50_m', primary_key => 'id', tenant_field => 'org', fields => [qw(id org k tag email)],
    columns => $cols->(id => 'integer', org => 'string', k => 'integer', tag => 'string', email => 'string'), associations => {}};
my $rc = $cols->(id => 'integer', org => 'string', k => 'integer', email => 'string', tags => {type => 'array', items => 'string'}, doc => 'jsonb');
$rc->{lemail} = {type => 'string', computed => {kind => 'expression', expression => ['lower', ['field', 'email']]}};
my $member = sub { my ($as, $item, @rest) = @_; ($as => {source => 'mem', query => {select => ['k', $item], @rest},
    join => {owner_key => 'k', related_key => 'k', type => 'inner'}}) };
my $copy = {source_table => 'r50_r', primary_key => 'id', tenant_field => 'org', fields => [qw(id org k email)],
    columns => {map { ($_ => $rc->{$_}) } qw(id org k email)}, associations => {}};
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'R50', source => {source_table => 'r50_r', primary_key => 'id',
    tenant_field => 'org', fields => [sort keys %$rc], columns => $rc, associations => {mm => {queryable => 'mem', owner_key => 'k', related_key => 'k'}}},
    schemas => {mem => $mem, rootcopy => $copy}, joins => {mm => {type => 'left'}},
    query_members => {ctes => {
        $member->('lw', {as => 'v', value => ['lower', ['field', 'tag']]}),
        $member->('ts', {as => 'v', value => ['cast', ['field', 'tag'], 'string']}),
        $member->('cn', {as => 'v', aggregate => 'count', field => 'tag'}, group_by => ['k']),
        $member->('mx', {as => 'v', aggregate => 'max', field => 'tag'}, group_by => ['k']),
        $member->('mn', {as => 'v', aggregate => 'min', field => 'tag'}, group_by => ['k']),
        re => {source => 'rootcopy', query => {select => ['k', {as => 'le', value => ['lower', ['field', 'email']]}]},
            join => {owner_key => 'k', related_key => 'k', type => 'inner'}}}}});
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
my $joined = q{SELECT r.id FROM r50_r r JOIN r50_m m ON r.k = m.k AND m.org = 't1' WHERE r.org = 't1'};
my @cases = (
    # M1
    ['member lower(citext) output <> gold', sub { $_[0]->with_member('lw')->select('id')->where($x->ne('lw.v', 'gold')) }, "$joined AND lower(m.tag) <> 'gold'"],
    ['member cast(citext as text) output <> gold', sub { $_[0]->with_member('ts')->select('id')->where($x->ne('ts.v', 'gold')) }, "$joined AND m.tag::text <> 'gold'"],
    ['member count(citext) output > 0', sub { $_[0]->with_member('cn')->select('id')->where($x->gt('cn.v', 0)) }, $joined],
    ['lower(text email) with a citext email relation joined', sub { $_[0]->select('id', 'mm.id')->where($x->ne('lemail', 'a@x.com')) },
        q{SELECT r.id FROM r50_r r LEFT JOIN r50_m m ON m.k = r.k AND m.org = 't1' WHERE r.org = 't1' AND lower(r.email) <> 'a@x.com'}],
    ['member lower(TEXT email) output with a citext email relation joined', sub { $_[0]->with_member('re')->select('id', 'mm.id')->where($x->ne('re.le', 'a@x.com')) },
        q{SELECT r.id FROM r50_r r LEFT JOIN r50_m m ON m.k = r.k AND m.org = 't1' WHERE r.org = 't1' AND lower(r.email) <> 'a@x.com'}],
    ['text email <> with a citext email relation joined', sub { $_[0]->select('id', 'mm.id')->where($x->ne('email', 'a@x.com')) },
        q{SELECT r.id FROM r50_r r LEFT JOIN r50_m m ON m.k = r.k AND m.org = 't1' WHERE r.org = 't1' AND r.email <> 'a@x.com'}],
    ['json_rowset text column = gold, a citext code relation joined',
        sub { $_[0]->json_rowset('doc', 'jr', {code => 'string'})->select('id', 'mm.id')->where($x->eq('jr.code', 'gold')) },
        q{SELECT r.id FROM r50_r r CROSS JOIN LATERAL jsonb_to_recordset(r.doc) AS jr(code text) WHERE r.org = 't1' AND jr.code = 'gold'}],
    # M2
    ['unnest(citext[]) value <> gold', sub { $_[0]->array_rowset('tags', 'tr')->select('id')->where($x->ne('tr.value', 'gold')) },
        q{SELECT r.id FROM r50_r r CROSS JOIN LATERAL unnest(r.tags) AS tr(value) WHERE r.org = 't1' AND tr.value <> 'gold'}],
    ['unnest(citext[]) value = GOLD', sub { $_[0]->array_rowset('tags', 'tr')->select('id')->where($x->eq('tr.value', 'GOLD')) },
        q{SELECT r.id FROM r50_r r CROSS JOIN LATERAL unnest(r.tags) AS tr(value) WHERE r.org = 't1' AND tr.value = 'GOLD'}],
    ['function returning citext: t <> gold', sub { $_[0]->function_lateral('r50_ci_tags', ['t1'], as => 'ft', columns => ['t'])->select('id')->where($x->ne('ft.t', 'gold')) },
        q{SELECT r.id FROM r50_r r JOIN LATERAL r50_ci_tags('t1') AS ft(t) ON TRUE WHERE r.org = 't1' AND ft.t <> 'gold'}],
    # M3
    ['member max(citext) output <> GOLD', sub { $_[0]->with_member('mx')->select('id')->where($x->ne('mx.v', 'GOLD')) },
        q{SELECT r.id FROM r50_r r JOIN (SELECT k, max(tag) v FROM r50_m WHERE org = 't1' GROUP BY k) x ON x.k = r.k WHERE r.org = 't1' AND x.v <> 'GOLD'}],
    ['member min(citext) output = gold', sub { $_[0]->with_member('mn')->select('id')->where($x->eq('mn.v', 'gold')) },
        q{SELECT r.id FROM r50_r r JOIN (SELECT k, min(tag) v FROM r50_m WHERE org = 't1' GROUP BY k) x ON x.k = r.k WHERE r.org = 't1' AND x.v = 'gold'}],
);
for my $case (@cases) {
    my ($label, $build, $sql) = @$case;
    my $want = $native->($sql);
    is($outcome->(sub { $ids->($engine, $build->($engine->query)) }), "applied $want", "$label: as natively [$want]");
}
# M3: citext's max and min order case-insensitively.
my $agg = Selecto::Domain->parse({schema_version => 1, name => 'R50M', source => {source_table => 'r50_ma', primary_key => 'id',
    tenant_field => 'org', fields => [qw(id org code)], columns => $cols->(id => 'integer', org => 'string', code => 'string'), associations => {}},
    schemas => {}, joins => {}});
$admin->do($_) for "CREATE TABLE r50_ma (id INT PRIMARY KEY, org TEXT NOT NULL, code $ci)", q{INSERT INTO r50_ma VALUES (1, 't1', 'a'), (2, 't1', 'B'), (3, 't2', 'z')};
my ($max, $min) = $admin->selectrow_array(q{SELECT max(code), min(code) FROM r50_ma WHERE org = 't1'});
my $ea = Selecto::Engine->new(domain => $agg, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
is($outcome->(sub { join ',', @{$ea->all($ea->query->select($x->max('code')->as('mx'), $x->min('code')->as('mn')))->{rows}[0]} }),
    "applied $max,$min", "citext max and min as natively ($max,$min)");

# A function planted beside the extension's type (lower(citext) in the
# extension's schema, not a member of it) is never resolved: lower stays
# pg_catalog's, and the member output compares as pg_catalog.lower's text.
$admin->do(qq{CREATE FUNCTION "$schema".lower($ci) RETURNS text LANGUAGE sql IMMUTABLE AS \$\$SELECT 'planted'\$\$});
my $planted = $native->("$joined AND pg_catalog.lower(CAST(m.tag AS text)) <> 'gold'");
my $ep = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
my $lq = $ep->query->with_member('lw')->select('id')->where($x->ne('lw.v', 'gold'));
is($outcome->(sub { $ids->($ep, $lq) }), "applied $planted", "a planted lower(citext) is not used: as pg_catalog.lower [$planted]");
like($ep->adapter->_statement_sql($ep->compile($lq)->sql), qr/pg_catalog\.lower\(/i, 'the statement calls pg_catalog.lower');
$admin->do(qq{DROP FUNCTION "$schema".lower($ci)});

# R50 (review of 0ce754a, HIGH-1/HIGH-2): operators and aggregates in the
# extension's schema take operands cast to the member type, so exact-match
# objects planted there over a DOMAIN of citext are never chosen.
$admin->do($_) for 'DROP TABLE IF EXISTS r50_dm', 'DROP DOMAIN IF EXISTS r50_email CASCADE', "CREATE DOMAIN r50_email AS $ci",
    'CREATE TABLE r50_dm (id INT PRIMARY KEY, org TEXT NOT NULL, k INT, tag r50_email)',
    q{INSERT INTO r50_dm VALUES (10, 't1', 1, 'Gold'), (11, 't1', 2, 'GOLD'), (12, 't1', 3, 'silver'), (13, 't2', 1, 'gold')};
my %want = (eq => $native->(q{SELECT id FROM r50_dm WHERE org = 't1' AND tag = 'gold'}),
    max => join(',', $admin->selectrow_array(q{SELECT CAST(max(tag) AS text), CAST(min(tag) AS text) FROM r50_dm WHERE org = 't1'})));
$admin->do($_) for
    qq{CREATE FUNCTION "$schema".r50_yes(r50_email, r50_email) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true'},
    qq{CREATE OPERATOR "$schema".= (LEFTARG = r50_email, RIGHTARG = r50_email, FUNCTION = "$schema".r50_yes)},
    qq{CREATE OPERATOR "$schema".<> (LEFTARG = r50_email, RIGHTARG = r50_email, FUNCTION = "$schema".r50_yes)},
    qq{CREATE FUNCTION "$schema".r50_zzz(r50_email, r50_email) RETURNS r50_email LANGUAGE sql IMMUTABLE AS \$\$SELECT CAST('zzz' AS r50_email)\$\$},
    qq{CREATE AGGREGATE "$schema".max(r50_email) (SFUNC = "$schema".r50_zzz, STYPE = r50_email)},
    qq{CREATE AGGREGATE "$schema".min(r50_email) (SFUNC = "$schema".r50_zzz, STYPE = r50_email)};
my $dm = Selecto::Domain->parse({schema_version => 1, name => 'R50D', source => {source_table => 'r50_dm', primary_key => 'id',
    tenant_field => 'org', fields => [qw(id org k tag)], columns => $cols->(id => 'integer', org => 'string', k => 'integer', tag => 'string'),
    associations => {}}, schemas => {}, joins => {}});
my $host = Selecto::Engine->new(domain => $dm->with_required_predicate($x->eq('tag', 'gold')),
    adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
is($outcome->(sub { $ids->($host, $host->query->select('id')) }), "applied $want{eq}",
    "a host required tag = 'gold' on a citext domain ignores a planted =(domain, domain) [$want{eq}]");
like($host->adapter->_statement_sql($host->compile($host->query->select('id'))->sql), qr/CAST\(\("s0"\."tag"\) AS [^)]*citext\)\) OPERATOR\(/,
    'the extension operator takes operands cast to the member type');
my $de = Selecto::Engine->new(domain => $dm, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
is($outcome->(sub { join ',', @{$de->all($de->query->select($x->max('tag')->as('mx'), $x->min('tag')->as('mn')))->{rows}[0]} }),
    "applied $want{max}", "citext max and min over a domain ignore a planted max/min(domain) [$want{max}]");
$admin->do($_) for 'DROP TABLE r50_dm', 'DROP DOMAIN r50_email CASCADE';

# Review MEDIUM: a CASE whose WHEN compares a citext column but whose result
# is a text literal is not refused.
$admin->do($_) for 'CREATE TABLE r50_tier (id INT PRIMARY KEY, org TEXT NOT NULL, tier ' . $ci . ')',
    q{INSERT INTO r50_tier VALUES (1, 't1', 'Gold'), (2, 't1', 'silver'), (3, 't1', NULL)};
my %tc = (id => {type => 'integer'}, org => {type => 'string'}, tier => {type => 'string'},
    label => {type => 'string', computed => {kind => 'expression', expression => ['case', [['eq', 'tier', 'gold'], ['literal', 'G']], ['else', ['literal', 'O']]]}});
my $td = Selecto::Domain->parse({schema_version => 1, name => 'R50T', source => {source_table => 'r50_tier', primary_key => 'id', tenant_field => 'org',
    fields => [sort keys %tc], columns => \%tc, associations => {}}, schemas => {}, joins => {}});
my $te = Selecto::Engine->new(domain => $td, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
my $tw = $native->(q{SELECT id FROM r50_tier WHERE org = 't1' AND (CASE WHEN tier = 'gold' THEN 'G' ELSE 'O' END) = 'G'});
is($outcome->(sub { $ids->($te, $te->query->select('id')->where($x->eq('label', 'G'))) }), "applied $tw",
    "CASE WHEN tier = 'gold' THEN 'G' ELSE 'O' END = 'G' reads as natively [$tw]");
$admin->do('DROP TABLE r50_tier');

# Review LOW 7: a host function read from is schema-qualified.
like($engine->adapter->_statement_sql($engine->compile($engine->query->function_lateral('r50_ci_tags', ['t1'], as => 'ft', columns => ['t'])
    ->select('id'))->sql), qr/"public"\.r50_ci_tags\(|"[^"]+"\."?r50_ci_tags"?\(/, 'function_lateral names its function with its schema');

# M4: a column altered text -> citext after a REPEATABLE READ host
# transaction's snapshot: a host required note <> 'secret' is refused, typed
# (read committed reads the current types).
my $rr = Selecto::Domain->parse({schema_version => 1, name => 'R50R', source => {source_table => 'r50_rr', primary_key => 'id',
    tenant_field => 'org', fields => [qw(id org note)], columns => $cols->(id => 'integer', org => 'string', note => 'string'), associations => {}},
    schemas => {}, joins => {}})->with_required_predicate($x->ne('note', 'secret'));
for my $isolation ('REPEATABLE READ', 'READ COMMITTED') {
    $admin->do($_) for 'DROP TABLE IF EXISTS r50_rr', 'CREATE TABLE r50_rr (id INT PRIMARY KEY, org TEXT, note TEXT)',
        q{INSERT INTO r50_rr VALUES (1, 't1', 'ok'), (2, 't1', 'SECRET'), (3, 't2', 'c')};
    my $host = $connect->();
    my $e = Selecto::Engine->new(domain => $rr, adapter => Selecto->adapter(postgresql => (dbh => $host)))->with_scope(tenant => 't1');
    $host->begin_work;
    $host->do("SET TRANSACTION ISOLATION LEVEL $isolation");
    $host->selectall_arrayref('SELECT count(*) FROM r50_ma');
    $admin->do("ALTER TABLE r50_rr ALTER COLUMN note TYPE $ci");
    my $want = join ',', map { $_->[0] } @{$admin->selectall_arrayref(q{SELECT id FROM r50_rr WHERE org = 't1' AND note <> 'secret' ORDER BY 1})};
    my $got = $outcome->(sub { $ids->($e, $e->query->select('id')) });
    $host->rollback;
    $host->disconnect;
    is($got, $isolation eq 'READ COMMITTED' ? "applied $want" : 'query_rule_not_evaluable/catalog_changed',
        "$isolation: a column altered to citext after the snapshot " . ($isolation eq 'READ COMMITTED' ? 'reads as natively' : 'is refused, typed'));
}

# Review of b969df8, HIGH 1: guarded updates (single row and bulk) on a
# table whose tenant column is citext or a domain over citext: the tenant
# compare's citext casts never leak into the post-image re-read.
$admin->do($_) for 'DROP TABLE IF EXISTS r50_wt', 'DROP DOMAIN IF EXISTS r50_tenant CASCADE', "CREATE DOMAIN r50_tenant AS $ci";
for my $tenant ($ci, 'r50_tenant') {
    $admin->do($_) for 'DROP TABLE IF EXISTS r50_wt', "CREATE TABLE r50_wt (id INT PRIMARY KEY, org $tenant NOT NULL, note TEXT)",
        q{INSERT INTO r50_wt VALUES (1, 't1', 'a'), (2, 'T1', 'b'), (3, 't2', 'c')};
    my $wd = Selecto::Domain->parse({schema_version => 1, name => 'R50WT', source => {source_table => 'r50_wt', primary_key => 'id', tenant_field => 'org',
        fields => [qw(id org note)], columns => $cols->(id => 'integer', org => 'string', note => 'string'), associations => {}},
        schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {note => {updatable => 1}}}});
    my $we = Selecto::Engine->new(domain => $wd, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
    require Selecto::Write;
    is($outcome->(sub { $we->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r50_wt',
        assignments => {note => 'one'}, predicate => $x->eq('id', 1)))->affected_rows }), 'applied 1', "tenant $tenant: a guarded update applies");
    is($outcome->(sub { $we->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r50_wt',
        assignments => {note => 'bulk'}, predicate => $x->gt('id', 0), expected_count => 2))->affected_rows }), 'applied 2', "tenant $tenant: a bulk update applies to the tenant's rows (citext)");
    is(join(',', @{$admin->selectcol_arrayref('SELECT note FROM r50_wt ORDER BY id')}), 'bulk,bulk,c', "tenant $tenant: the other tenant's row is unchanged");
}
$admin->do($_) for 'DROP TABLE r50_wt', 'DROP DOMAIN r50_tenant CASCADE';

# Review of b969df8, MEDIUM 1: a function read from resolves to exactly one
# function among the pinned schemas (overloads included), qualified, with its
# arguments cast to their declared types; an ambiguous name is refused.
$admin->do($_) for 'DROP SCHEMA IF EXISTS r50_fn CASCADE', 'CREATE SCHEMA r50_fn', 'DROP FUNCTION IF EXISTS r50_rows(int)', 'DROP FUNCTION IF EXISTS r50_rows(text)',
    q{CREATE FUNCTION r50_rows(n int) RETURNS TABLE(v text) LANGUAGE sql STABLE AS $$ SELECT 'host:' || n $$};
my $fl = sub { my $e = Selecto::Engine->new(domain => $agg, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
    my $q = $e->query->function_lateral('r50_rows', [7], as => 'f', columns => ['v'])->select('id', 'f.v');
    ($outcome->(sub { join ',', map { $_->[1] } @{$e->all($q)->{rows}} }), eval { $e->adapter->_statement_sql($e->compile($q)->sql) } // '') };
my ($got, $sql) = $fl->();
is($got, 'applied host:7,host:7', 'the one r50_rows(int) is called');
like($sql, qr/"public"\."r50_rows"\(CAST\(\(\$\d+\) AS pg_catalog\.int4\)\)/, 'qualified, with its argument cast to the declared type');
$admin->do(q{CREATE FUNCTION r50_rows(n text) RETURNS TABLE(v text) LANGUAGE sql STABLE AS $$ SELECT 'PLANTED' $$});
is(($fl->())[0], 'query_rule_not_evaluable/function_ambiguous', 'a same-schema overload makes it ambiguous: refused');
$admin->do($_) for 'DROP FUNCTION r50_rows(text)', q{CREATE FUNCTION r50_fn.r50_rows(n int) RETURNS TABLE(v text) LANGUAGE sql STABLE AS $$ SELECT 'unpinned' $$};
is(($fl->())[0], 'applied host:7,host:7', 'a namesake in a schema outside the pin does not count');
$admin->do($_) for 'DROP FUNCTION r50_rows(int)', 'DROP SCHEMA r50_fn CASCADE';
# Review of 2e95065 (MEDIUM): pg_catalog set-returning functions (every
# pinned candidate pg_catalog's) are called pg_catalog-qualified, and a
# VARIADIC host function as VARIADIC, as a function_lateral and as a
# declared lateral member, with native results.
$admin->do($_) for 'DROP FUNCTION IF EXISTS r50_tags_of(text[])',
    q{CREATE FUNCTION r50_tags_of(VARIADIC xs text[]) RETURNS TABLE(v text) LANGUAGE sql STABLE AS $$ SELECT pg_catalog.unnest(xs) $$};
my $lm = Selecto::Domain->parse({schema_version => 1, name => 'R50L', source => {source_table => 'r50_ma', primary_key => 'id', tenant_field => 'org',
    fields => [qw(id org code)], columns => $cols->(id => 'integer', org => 'string', code => 'string'), associations => {}}, schemas => {}, joins => {},
    query_members => {laterals => {
        parts => {source => ['function', 'regexp_split_to_table', ['red,green', ',']], columns => ['v']},
        words => {source => ['function', 'string_to_table', ['a b', ' ']], columns => ['v']},
        tags => {source => ['function', 'r50_tags_of', ['x', 'y']], columns => ['v']},
        one => {source => ['function', 'r50_tags_of', ['{a,b}']], columns => ['v']},
        matches => {source => ['function', 'regexp_matches', ['abcb', 'b', 'g']], columns => ['v']}}}});
my $le = Selecto::Engine->new(domain => $lm, adapter => Selecto->adapter(postgresql => (dbh => $connect->())))->with_scope(tenant => 't1');
my $vals = sub { my ($q) = @_; join ',', sort map { $_->[1] } grep { $_->[0] == 1 } @{$le->all($q)->{rows}} };
for my $case (['parts', 'green,red'], ['words', 'a,b'], ['tags', 'x,y'], ['one', '{a,b}']) {
    my ($member, $want) = @$case;
    is($outcome->(sub { $vals->($le->query->with_lateral($member)->select('id', "$member.v")) }), "applied $want", "declared lateral member $member: $want");
}
for my $case (['regexp_split_to_table', ['red,green', ','], 'green,red'], ['string_to_table', ['a b', ' '], 'a,b'],
    ['r50_tags_of', ['x', 'y'], 'x,y'], ['r50_tags_of', ['{a,b}'], '{a,b}']) {
    my ($fn, $args, $want) = @$case;
    is($outcome->(sub { $vals->($le->query->function_lateral($fn, $args, as => 'f', columns => ['v'])->select('id', 'f.v')) }), "applied $want",
        "function_lateral $fn(@$args): $want");
}
like($le->adapter->_statement_sql($le->compile($le->query->function_lateral('r50_tags_of', ['x', 'y'], as => 'f', columns => ['v'])->select('id'))->sql),
    qr/"r50_tags_of"\(VARIADIC ARRAY\[CAST\(\(\$\d+\) AS pg_catalog\.text\), CAST/, 'a VARIADIC host function is called as VARIADIC with cast elements');
# Review of 07d36d8 (MEDIUM): citext's own overloads (regexp_split_to_table,
# regexp_matches over citext) do not make the pg_catalog functions ambiguous,
# with citext's schema on the reset path, and with citext in public.
my $srf = sub {
    my (%options) = @_;
    my ($dsn, @auth) = TestPostgreSQL->connection;
    $dsn .= ";options='$options{options}'" if $options{options};
    my $dbh = DBI->connect($dsn, @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
    my $e = Selecto::Engine->new(domain => $lm, adapter => Selecto->adapter(postgresql => (dbh => $dbh)))->with_scope(tenant => 't1');
    my $count = sub { my ($q) = @_; scalar grep { $_->[0] == 1 } @{$e->all($q)->{rows}} };
    my $splits = sub { my ($q) = @_; join ',', sort map { $_->[1] } grep { $_->[0] == 1 } @{$e->all($q)->{rows}} };
    return (
        $outcome->(sub { $splits->($e->query->function_lateral('regexp_split_to_table', ['red,green', ','], as => 'f', columns => ['v'])->select('id', 'f.v')) }),
        $outcome->(sub { $count->($e->query->function_lateral('regexp_matches', ['abcb', 'b', 'g'], as => 'f', columns => ['v'])->select('id', 'f.v')) }),
        $outcome->(sub { $splits->($e->query->with_lateral('parts')->select('id', 'parts.v')) }),
        $outcome->(sub { $count->($e->query->with_lateral('matches')->select('id', 'matches.v')) }));
};
my @want = ('applied green,red', 'applied 2', 'applied green,red', 'applied 2');
is_deeply([$srf->(options => qq{-c search_path=public,"$schema"})], \@want,
    "citext's own regexp overloads on the reset path: pg_catalog's set-returning functions as function_lateral and lateral members");
SKIP: {
    skip 'citext was preinstalled; not moved', 1 if $preinstalled || $schema eq 'public';
    $admin->do('ALTER EXTENSION citext SET SCHEMA public');
    my @got = $srf->();
    $admin->do(qq{ALTER EXTENSION citext SET SCHEMA "$schema"});
    is_deeply(\@got, \@want, 'and with citext in public');
}
# Review of c2d1554: an extension's own function that is the only
# candidate (hstore's skeys, each; ltree's subpath by argument count) is
# called, schema-qualified with its argument cast to its type; a name with
# no candidate is refused as not found.
SKIP: {
    my $had = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'hstore'}))[0];
    my $made = !$had && eval { $admin->do('CREATE SCHEMA IF NOT EXISTS r51hs'); $admin->do('CREATE EXTENSION hstore SCHEMA r51hs'); 1 };
    skip 'hstore is not available', 3 unless $had || $made;
    my ($hs) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'hstore'});
    my ($dsn, @auth) = TestPostgreSQL->connection;
    my $dbh = DBI->connect($dsn . qq{;options='-c search_path=public,"$hs"'}, @auth, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    my $he = Selecto::Engine->new(domain => $lm, adapter => Selecto->adapter(postgresql => (dbh => $dbh)))->with_scope(tenant => 't1');
    is($outcome->(sub { join ',', sort map { $_->[1] } grep { $_->[0] == 1 }
        @{$he->all($he->query->function_lateral('skeys', ['a=>1,b=>2'], as => 'f', columns => ['v'])->select('id', 'f.v'))->{rows}} }),
        'applied a,b', "hstore's skeys, the only candidate, is called");
    like($he->adapter->_statement_sql($he->compile($he->query->function_lateral('skeys', ['a=>1'], as => 'f', columns => ['v'])->select('id'))->sql),
        qr/"\Q$hs\E"\."skeys"\(CAST\(\(\$\d+\) AS [^)]*hstore\)\)/, 'qualified, its argument cast to hstore');
    is($outcome->(sub { $he->all($he->query->function_lateral('r51_no_such_rows', ['x'], as => 'f', columns => ['v'])->select('id')) }),
        'query_rule_not_evaluable/function_not_found', 'a function with no candidate is refused as not found');
    $dbh->disconnect;
    $admin->do($_) for $made ? ('DROP EXTENSION hstore', 'DROP SCHEMA r51hs') : ();
}
$admin->do('DROP FUNCTION r50_tags_of(text[])');

require Selecto::PostgreSQL::Qualify;
like(join('; ', Selecto::PostgreSQL::Qualify::lint(q{SELECT "s0"."id" FROM public.t AS "s0", "r50_rows"($1) AS "f"("v")}, {})),
    qr/unqualified function rowset/, 'the lint flags an unqualified function rowset in a FROM list');
like(join('; ', Selecto::PostgreSQL::Qualify::lint(q{SELECT "s0"."id" FROM public.t AS "s0" JOIN LATERAL "r50_rows"($1) AS "f"("v") ON TRUE}, {})),
    qr/unqualified function rowset/, 'the lint flags an unqualified function rowset');

# Review LOW 8: a row trigger that switches the session's role with
# set_config('role', ..., false) refuses the write (CURRENT_USER is part of
# the session snapshot).
SKIP: {
    my ($can) = $admin->selectrow_array(q{SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = CURRENT_USER});
    skip 'roles cannot be created', 2 unless $can;
    $admin->do($_) for 'DROP TABLE IF EXISTS r50_rw', q{DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'r50_switch') THEN CREATE ROLE r50_switch; END IF; END $$},
        'GRANT r50_switch TO CURRENT_USER', 'CREATE TABLE r50_rw (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)',
        q{INSERT INTO r50_rw VALUES (1, 't1', 'a')}, 'GRANT SELECT, UPDATE ON r50_rw TO r50_switch',
        q{CREATE OR REPLACE FUNCTION r50_rw_sw() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.set_config('role', 'r50_switch', false); RETURN NEW; END $$},
        'CREATE TRIGGER r50_rw_tr AFTER UPDATE ON r50_rw FOR EACH ROW EXECUTE FUNCTION r50_rw_sw()';
    my $rw = Selecto::Domain->parse({schema_version => 1, name => 'R50W', source => {source_table => 'r50_rw', primary_key => 'id', tenant_field => 'org_key',
        fields => [qw(id org_key note)], columns => $cols->(id => 'integer', org_key => 'string', note => 'string'), associations => {}},
        schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}}}});
    my $wh = $connect->();
    my $we = Selecto::Engine->new(domain => $rw, adapter => Selecto->adapter(postgresql => (dbh => $wh)))->with_scope(tenant => 't1');
    require Selecto::Write;
    is($outcome->(sub { $we->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r50_rw',
        assignments => {note => 'b'}, predicate => $x->eq('id', 1)))->affected_rows }), 'query_rule_violation/session_state_changed',
        "a trigger's role switch refuses the write");
    is(($wh->selectrow_array('SELECT CURRENT_USER'))[0], ($admin->selectrow_array('SELECT CURRENT_USER'))[0], 'and the role switch was rolled back');
    $wh->disconnect;
    $admin->do($_) for 'DROP TABLE r50_rw', 'DROP FUNCTION r50_rw_sw()';
    $admin->do('DROP ROLE r50_switch') if eval { $admin->do('REVOKE r50_switch FROM CURRENT_USER'); 1 };
}

$admin->do($_) for 'DROP TABLE r50_r, r50_m, r50_ma, r50_rr CASCADE', 'DROP FUNCTION r50_ci_tags(text)';
$admin->do($_) for $preinstalled ? () : ('DROP EXTENSION IF EXISTS citext CASCADE', 'DROP SCHEMA IF EXISTS r50ext CASCADE');
done_testing;
