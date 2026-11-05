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
use lib 't/lib';
use TestPostgreSQL ();

# Guarded (tenant-scoped) inserts and upserts on uuid, citext and domain
# tenant columns (typed insert admission storage profile). The tenant value
# must equal the trusted scope exactly, or be omitted and filled from it; a
# case variant ('T1' for t1, an upper-case uuid) is refused with
# tenant_mismatch (as Python does), never admitted by native citext
# equality. The admission probe compares with the column's own semantics
# (citext's operators, cast to the member type per R50; a domain's CHECK
# constraints apply), and the post-image re-read still verifies the stored
# row. Modes: Selecto's own transaction, a host transaction (external) and a
# transaction_handler.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
local $ENV{SELECTO_PG_SQL_LINT} = 1;
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
my $has = $preinstalled
    || eval { $admin->do('CREATE SCHEMA IF NOT EXISTS r52ext'); $admin->do('CREATE EXTENSION citext SCHEMA r52ext'); 1 };
# Remove what this file installed even if it dies part-way, so a later
# run never mistakes a leftover for a preinstalled extension.
END { eval { $admin->do($_) for 'DROP EXTENSION IF EXISTS citext CASCADE', 'DROP SCHEMA IF EXISTS r52ext CASCADE' } if $has && !$preinstalled }
plan skip_all => 'citext is not available' unless $has;
my ($schema) = $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'});
my $ci = qq{"$schema".citext};
$admin->do($_) for 'DROP TABLE IF EXISTS r52_t', map({ "DROP DOMAIN IF EXISTS $_ CASCADE" } qw(r52_tdom r52_cidom r52_udom r52_short)),
    'CREATE DOMAIN r52_tdom AS text', "CREATE DOMAIN r52_cidom AS $ci", 'CREATE DOMAIN r52_udom AS uuid',
    'CREATE DOMAIN r52_short AS text CHECK (pg_catalog.length(VALUE) < 4)';
my $outcome = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return 'applied' . (defined($value) && !ref($value) ? " $value" : '') unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code')
        ? $error->code . (ref($error->details) eq 'HASH' && $error->details->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
};
my $U1 = '0000000a-0000-0000-0000-000000000001';
my $U2 = '0000000a-0000-0000-0000-000000000002';
# (column type, domain type, tenant, other tenant, case variant or undef)
my @types = (
    ['uuid', 'string', $U1, $U2, uc $U1], ['uuid', 'uuid', $U1, $U2, uc $U1], [$ci, 'string', 't1', 't2', 'T1'],
    ['r52_tdom', 'string', 't1', 't2', undef], ['r52_cidom', 'string', 't1', 't2', 'T1'], ['r52_udom', 'string', $U1, $U2, uc $U1],
);
my $domain = sub {
    my ($type) = @_;
    Selecto::Domain->parse({schema_version => 1, name => 'R52', source => {source_table => 'r52_t', primary_key => 'id',
        tenant_field => 'org', fields => [qw(id org note)],
        columns => {id => {type => 'integer'}, org => {type => $type}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}, writes => {operations => {insert => {enabled => 1}, upsert => {enabled => 1, conflict_targets => [[qw(org id)]]}},
            fields => {id => {insertable => 1}, org => {insertable => 1}, note => {insertable => 1, updatable => 1}}}});
};
my @sql;
my $run = sub {
    my ($column, $type, $tenant, $mode, $operation, $assignments) = @_;
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO warning');
    $dbh->{Callbacks} = {prepare => sub { push @sql, $_[1]; return }};
    my %options = $mode eq 'host' ? (transaction_mode => 'external')
        : $mode eq 'handler' ? (transaction_handler => sub { my ($work) = @_; $dbh->begin_work; my $r = eval { $work->() };
            my $e = $@; $e ? $dbh->rollback : $dbh->commit; die $e if $e; $r }) : ();
    my $e = Selecto::Engine->new(domain => $domain->($type), adapter => Selecto->adapter(postgresql => (dbh => $dbh, %options)))
        ->with_scope(tenant => $tenant);
    $dbh->begin_work if $mode eq 'host';
    my $result = $outcome->(sub { $e->execute_write(Selecto::Write::Command->new(operation => $operation, relation => 'r52_t',
        assignments => $assignments, $operation eq 'upsert' ? (metadata => {conflict_target => [qw(org id)], upsert_update_fields => ['note']}) : ()))
        ->affected_rows });
    if ($mode eq 'host') { $result =~ /\Aapplied/ ? $dbh->commit : $dbh->rollback }
    $dbh->disconnect;
    return $result;
};
my $stored = sub { join ',', map { join '/', @$_ } @{$admin->selectall_arrayref('SELECT id, CAST(org AS text), note FROM r52_t ORDER BY id')} };
for my $case (@types) {
    my ($column, $type, $tenant, $other, $variant) = @$case;
    for my $mode (qw(own host handler)) {
        my $label = "$column (declared $type), $mode";
        my $reset = sub { $admin->do($_) for 'DROP TABLE IF EXISTS r52_t', "CREATE TABLE r52_t (id INT PRIMARY KEY, org $column NOT NULL, note TEXT, UNIQUE (org, id))" };
        $reset->();
        is($run->($column, $type, $tenant, $mode, 'insert', {id => 9, note => 'n'}), 'applied 1', "$label: an insert filled from the scope is admitted");
        is($stored->(), "9/$tenant/n", "$label: and stored for the tenant");
        $reset->();
        is($run->($column, $type, $tenant, $mode, 'insert', {id => 9, org => $tenant, note => 'n'}), 'applied 1', "$label: an explicit own tenant is admitted");
        $reset->();
        is($run->($column, $type, $tenant, $mode, 'insert', {id => 9, org => $other, note => 'n'}), 'tenant_mismatch', "$label: another tenant is refused");
        is($stored->(), '', "$label: and nothing is stored");
        if (defined $variant) {
            is($run->($column, $type, $tenant, $mode, 'insert', {id => 9, org => $variant, note => 'n'}), 'tenant_mismatch',
                "$label: a case variant of the tenant is refused (tenant_mismatch), not admitted by native equality");
        }
        is($run->($column, $type, $tenant, $mode, 'upsert', {id => 9, note => 'n'}), 'applied 1', "$label: an upsert inserting is admitted");
        is($run->($column, $type, $tenant, $mode, 'upsert', {id => 9, note => 'new'}), 'applied 1', "$label: an upsert updating its row is admitted");
        is($stored->(), "9/$tenant/new", "$label: the upserted row is the tenant's");
    }
}
# The citext admission probe compares with citext's own operator, its
# operands cast to the member type (R50).
my ($probe) = grep { /__selecto_candidate/ && /citext/ } @sql;
like($probe // '', qr/OPERATOR\("\Q$schema\E"\.=\)/, "the citext admission compares with citext's own operator");
like($probe // '', qr/CAST\(\(.*?\) AS "?\Q$schema\E"?\.citext\)\) OPERATOR/, 'its operands cast to the member type');
# A domain's CHECK constraint: a typed refusal.
$admin->do($_) for 'DROP TABLE IF EXISTS r52_t', 'CREATE TABLE r52_t (id INT PRIMARY KEY, org r52_short NOT NULL, note TEXT, UNIQUE (org, id))';
is($run->('r52_short', 'string', 'toolong', 'own', 'insert', {id => 9, note => 'n'}), 'database_check_violation',
    "a tenant violating the domain's CHECK is a typed refusal");
# uuid: an invalid or non-canonical tenant value is a typed refusal.
$admin->do($_) for 'DROP TABLE IF EXISTS r52_t', 'CREATE TABLE r52_t (id INT PRIMARY KEY, org uuid NOT NULL, note TEXT, UNIQUE (org, id))';
is($run->('uuid', 'string', 'not-a-uuid', 'own', 'insert', {id => 9, note => 'n'}), 'query_rule_not_evaluable', 'an invalid uuid tenant is refused, typed');
is($run->('uuid', 'string', uc $U1, 'own', 'insert', {id => 9, note => 'n'}), 'query_rule_not_evaluable', 'a non-canonical uuid tenant is refused, typed');
is($stored->(), '', 'and nothing is stored');
$admin->do($_) for 'DROP TABLE r52_t', map({ "DROP DOMAIN $_" } qw(r52_tdom r52_cidom r52_udom r52_short));
done_testing;
