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

# R56: column-keyed catalog facts use the exact column name, following
# PostgreSQL's folding (an unquoted identifier is lower case, a quoted one
# exact). With org text and "ORG" citext in one table, folding gave org
# citext's operators: tenant t1 read and wrote the row of tenant T1, and the
# post-write guard folded the same way. Native answers below are PostgreSQL's
# own for the same comparison.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $drop_ext;
END { eval { $admin->do($_) for 'DROP TABLE IF EXISTS r56_cv, r56_cw, r56_rt, "R56_RT" CASCADE'; $admin->do('DROP EXTENSION citext CASCADE') if $drop_ext } }
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
my $has = $preinstalled || eval { $admin->do('CREATE EXTENSION citext'); 1 };
plan skip_all => 'citext is not available' unless $has;
$drop_ext = !$preinstalled;
my ($schema) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'});
my $citext = qq{"$schema".citext};

my $seed = sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r56_cv, r56_cw, r56_rt, "R56_RT" CASCADE',
        qq{CREATE TABLE r56_cv (id INT PRIMARY KEY, org TEXT NOT NULL, "ORG" $citext, note TEXT)},
        q{INSERT INTO r56_cv VALUES (1, 't1', 'x', 'a'), (2, 'T1', 'x', 'b'), (3, 't2', 'x', 'c')},
        qq{CREATE TABLE r56_cw (id INT PRIMARY KEY, "ORG" TEXT NOT NULL, org $citext, note TEXT)},
        q{INSERT INTO r56_cw VALUES (1, 't1', 'x', 'a'), (2, 'T1', 'x', 'b'), (3, 't2', 'x', 'c')},
        'CREATE TABLE r56_rt (id INT PRIMARY KEY, org TEXT NOT NULL)',
        qq{CREATE TABLE "R56_RT" (id INT PRIMARY KEY, org $citext NOT NULL)};
};
my $domain = sub {
    my ($table, $tenant, $fields, %more) = @_;
    Selecto::Domain->parse({schema_version => 1, name => "T$table", source => {source_table => $table, primary_key => 'id',
        tenant_field => $tenant, fields => $fields, columns => {map { ($_ => {type => $_ eq 'id' ? 'integer' : 'string'}) } @$fields},
        associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
            delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}, %more});
};
my $dbh = TestPostgreSQL->connect;
$dbh->do('SET client_min_messages TO warning');
my $engine = sub { my ($d, $tenant) = @_; Selecto::Engine->new(domain => $d, adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => $tenant) };
my $attempt = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return $value unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code') ? $error->code : "died: $error";
};
my $read = sub { my ($e, $predicate) = @_;
    $seed->();
    my $q = $e->query->select('id')->order_by('id');
    $q = $q->where($predicate) if $predicate;
    $attempt->(sub { join ',', map { $_->[0] } @{$e->all($q)->{rows}} }) };
# What a write touched: the ids it changed or removed, read back by the admin.
my $write = sub {
    my ($e, $table, $kind, $predicate) = @_;
    $seed->();
    my %command = (operation => $kind, relation => $table, predicate => $predicate, expected_count => undef);
    $command{assignments} = {note => 'HIT'} if $kind eq 'update';
    my $outcome = $attempt->(sub { $e->execute_write(Selecto::Write::Command->new(%command))->affected_rows; undef });
    return $outcome if defined $outcome;
    return join ',', @{$admin->selectcol_arrayref($kind eq 'update' ? "SELECT id FROM $table WHERE note = 'HIT' ORDER BY id"
        : "SELECT i FROM generate_series(1, 3) AS i WHERE NOT EXISTS (SELECT 1 FROM $table t WHERE t.id = i) ORDER BY i")};
};
my @both = qw(id org ORG note);
my $any = $x->gt('id', 0);
$seed->();

# The tenant is the text twin; the citext twin beside it, declared or not.
for my $case (['r56_cv', 'org', 'declared', \@both, 'the citext twin ORG'], ['r56_cv', 'org', 'undeclared', [qw(id org note)], 'the citext twin ORG'],
    ['r56_cw', 'ORG', 'declared', \@both, 'the citext twin org'], ['r56_cw', 'ORG', 'undeclared', [qw(id ORG note)], 'the citext twin org']) {
    my ($table, $tenant, $declared, $fields, $twin) = @$case;
    my $e = $engine->($domain->($table, $tenant, $fields), 't1');
    is($read->($e), '1', "$table tenant $tenant, $declared twin: a read sees t1 only");
    is($read->($e, $x->eq($tenant, 'T1')), '', "$table tenant $tenant, $declared twin: a filter on the tenant is exact");
    is($write->($e, $table, 'update', $any), '1', "$table tenant $tenant, $declared twin: an update writes t1 only");
    is($write->($e, $table, 'delete', $any), '1', "$table tenant $tenant, $declared twin: a delete removes t1 only");
}

# The tenant is the citext twin; the text twin is filtered, required, compared.
for my $case (['r56_cv', 'ORG', 'org'], ['r56_cw', 'org', 'ORG']) {
    my ($table, $tenant, $text) = @$case;
    my $d = $domain->($table, $tenant, \@both);
    my $e = $engine->($d, 'x');
    is($read->($engine->($d, 'X')), '1,2,3', "$table: the citext tenant keeps citext's operator");
    is($read->($e, $x->eq($text, 't1')), '1', "$table: eq on the text twin is exact");
    is($read->($e, $x->ne($text, 't1')), '2,3', "$table: ne on the text twin is exact");
    is($read->($e, $x->in($text, ['t1'])), '1', "$table: in on the text twin is exact");
    is($read->($e, $x->starts_with($text, 'T')), '2', "$table: a prefix on the text twin is exact");
    is($write->($e, $table, 'update', $x->eq($text, 't1')), '1', "$table: an update filtered on the text twin");
    is($write->($e, $table, 'delete', $x->eq($text, 't1')), '1', "$table: a delete filtered on the text twin");
    my $required = $engine->($d->with_required_predicate($x->eq($text, 't1')), 'x');
    is($read->($required), '1', "$table: a required predicate on the text twin is exact");
    is($write->($required, $table, 'update', $any), '1', "$table: an update under that required predicate");
    is($write->($required, $table, 'delete', $any), '1', "$table: a delete under that required predicate");
}

# A CTE member projecting the text twin keeps the text twin's operator.
{
    my @fields = @both;
    my $rel = {source_table => 'r56_cv', primary_key => 'id', tenant_field => 'org', fields => \@fields,
        columns => {map { ($_ => {type => $_ eq 'id' ? 'integer' : 'string'}) } @fields}, associations => {}};
    my $join = {owner_key => 'id', related_key => 'id', type => 'inner'};
    my $d = Selecto::Domain->parse({schema_version => 1, name => 'R56M', source => $rel, schemas => {c2 => $rel}, joins => {},
        query_members => {ctes => {m => {source => 'c2', query => {select => ['id', 'org']}, join => $join},
            r => {source => 'c2', query => {select => ['id', {as => 'o', value => ['field', 'org']}]}, join => $join}}}});
    my $e = $engine->($d, 't1');
    my $member = sub { my ($name, $predicate) = @_;
        $attempt->(sub { join ',', map { $_->[0] } @{$e->all($e->query->with_member($name)->select('id')->where($predicate)->order_by('id'))->{rows}} }) };
    $seed->();
    is($member->('m', $x->eq('m.org', 't1')), '1', 'a member projecting the text twin compares as text');
    is($member->('r', $x->eq('r.o', 'T1')), '', 'a renamed member output of the text twin compares as text');
}


done_testing;
