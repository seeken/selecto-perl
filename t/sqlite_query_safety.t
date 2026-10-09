use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use Storable qw(dclone);
use Selecto;
use Selecto::BoundedQuery;
use Selecto::Verification::QuerySafety;
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
$db->do('PRAGMA temp_store=MEMORY');
$db->do(q{ATTACH DATABASE ':memory:' AS tenant_a});
$db->do(q{ATTACH DATABASE ':memory:' AS tenant_b});
for my $schema (qw(main tenant_a tenant_b)) {
    $db->do(qq{CREATE TABLE $schema.accounts(id INTEGER PRIMARY KEY, name TEXT, active INTEGER, tenant_id TEXT)});
}
$db->do(q{INSERT INTO main.accounts VALUES(1,'Ada',1,'tenant-a'),(2,'Lin',1,'tenant-b'),(3,'Inactive',0,'tenant-a')});
$db->do(q{INSERT INTO tenant_a.accounts VALUES(10,'Tenant A',1,'tenant-a'),(11,'Other',1,'tenant-b'),(12,'Inactive A',0,'tenant-a')});
$db->do(q{INSERT INTO tenant_b.accounts VALUES(20,'Tenant B',1,'tenant-b')});
my $adapter = Selecto->adapter(sqlite => dbh => $db);
my $raw = {name => 'Accounts', tenant_required => JSON::PP::true,
    source => {source_table => 'accounts', primary_key => 'id', fields => [qw(id name active tenant_id)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, active => {type => 'boolean'}, tenant_id => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {}, required_filters => [['active', JSON::PP::true]],
    writes => {operations => {insert => {enabled => JSON::PP::true}}, fields => {name => {insertable => JSON::PP::true}, active => {insertable => JSON::PP::true}, tenant_id => {insertable => JSON::PP::true}}}};
sub engine { Selecto::Engine->new(domain => Selecto::Domain->parse(dclone($raw)), adapter => $adapter) }
sub query { $_[0]->query->select('id')->order_by('id') }
sub caught { my ($run) = @_; my $ok = eval { $run->(); 1 }; return $ok ? undef : $@; }
my $events = 0;
$db->sqlite_set_authorizer(sub { ++$events; return 0 });
sub refusal {
    my ($label, $code, $run) = @_;
    $events = 0;
    my $error = caught($run);
    is(ref($error) && UNIVERSAL::isa($error, 'Selecto::Error') ? $error->code : 'none', $code, $label);
    is($events, 0, "$label performs no native SQL");
    return $error;
}
my $e = engine();
ok(!$e->validate_tenant_scope->{valid}, 'required domain is initially unscoped');
refusal('required domain fails closed at native read', 'tenant_scope_missing', sub { $e->all(query($e)) });
refusal('ordinary user tenant equality cannot satisfy required context', 'tenant_scope_missing', sub {
    $e->all(query($e)->where(Selecto::Expression->eq('tenant_id', 'tenant-a')));
});
my $attached = $e->with_tenant({tenant_id => 'tenant-a'});
refusal('attached row context requires explicit application', 'tenant_scope_missing', sub { $attached->all(query($attached)) });
my $applied = $attached->apply_tenant_scope;
ok($applied->validate_tenant_scope->{valid}, 'applied attached row scope validates');
is_deeply($applied->all(query($applied))->{rows}, [[1]], 'applied row scope and base active filter execute');
my $compiled = $applied->compile(query($applied));
like($compiled->sql, qr/tenant_id/, 'row field reaches actual SQL');
unlike($compiled->sql, qr/tenant-a/, 'row value is not interpolated');
ok(grep(defined($_) && !ref($_) && $_ eq 'tenant-a', @{$compiled->params}), 'row value is a bound parameter');
my $copy = $applied->tenant_context;
$copy->{tenant_id} = 'tenant-b';
is_deeply($applied->all(query($applied))->{rows}, [[1]], 'context getter is isolated');
my $filters = $applied->required_filters;
$filters->[1][1] = 'tenant-b';
is_deeply($applied->all(query($applied))->{rows}, [[1]], 'required filters getter is isolated');
my $mismatch = $attached->require_tenant_filter('tenant_id', 'tenant-b');
refusal('contradictory trusted filter refuses read', 'tenant_scope_mismatch', sub { $mismatch->all(query($mismatch)) });
refusal('contradictory trusted filter refuses application', 'tenant_scope_mismatch', sub { $mismatch->apply_tenant_scope });
my $ambiguous = $applied->require_tenant_filter('tenant_id', 'tenant-b');
refusal('multiple trusted tenant values refuse read', 'tenant_scope_ambiguous', sub { $ambiguous->all(query($ambiguous)) });
refusal('attached identity cannot be replaced', 'tenant_context_mismatch', sub { $applied->with_tenant({tenant_id => 'tenant-b'}) });
refusal('legacy write scope cannot replace attached identity', 'tenant_context_mismatch', sub { $applied->with_scope(tenant => 'tenant-b') });
my $prefix = engine()->with_tenant({prefix => 'tenant_a'});
is_deeply($prefix->all(query($prefix))->{rows}, [[10], [11]], 'attached prefix selects separate native memory relation');
like($prefix->compile(query($prefix))->sql, qr/"tenant_a"\."accounts"/, 'prefix and table are separately quoted');
is_deeply($prefix->all(query($prefix), prefix => 'tenant_a')->{rows}, [[10], [11]], 'matching execution prefix is usable');
refusal('execution prefix substitution is refused', 'tenant_prefix_mismatch', sub { $prefix->all(query($prefix), prefix => 'tenant_b') });
refusal('stream prefix substitution is refused', 'tenant_prefix_mismatch', sub { $prefix->stream(query($prefix), prefix => 'tenant_b') });
refusal('prefix identifier injection is refused', 'invalid_identifier', sub { engine()->with_tenant({prefix => q{tenant_a"; DROP TABLE accounts;--}}) });
my $compound = engine()->with_tenant({prefix => 'tenant_a', tenant_id => 'tenant-a'})->apply_tenant_scope;
is_deeply($compound->all(query($compound))->{rows}, [[10]], 'compound context scopes actual attached relation rows');
is_deeply($compound->with_limits(Selecto::Limits->new(max_fields => 1))->all(query($compound))->{rows}, [[10]], 'approved limits transition keeps read authority');
refusal('read context does not grant ordinary writes', 'unsupported_feature', sub { $compound->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'accounts', assignments => {name => 'forbidden', active => 1, tenant_id => 'tenant-a'})) });
my $advanced = query($prefix)->_copy(ctes => [{name => 'x'}]);
refusal('prefix advanced sources are explicitly unsupported', 'unsupported_feature', sub { $prefix->all($advanced) });
for my $edit (
    ['context', sub { $_[0]{tenant_context}{tenant_id} = 'tenant-b' }],
    ['required filter', sub { $_[0]{tenant_required_filters}[0][1] = 'tenant-b' }],
    ['prefix', sub { $_[0]{tenant_context}{prefix} = 'tenant_b' }],
    ['required domain flag', sub { $_[0]{domain}{tenant_required} = 0 }],
) {
    my $target = engine()->with_tenant({prefix => 'tenant_a', tenant_id => 'tenant-a'})->apply_tenant_scope;
    $target->read_domain;
    $edit->[1]->($target);
    refusal("public $edit->[0] tamper fails sealed read", 'domain_modified_after_configuration', sub { $target->all(query($target)) });
}
my $prepared = Selecto::BoundedQuery->prepare($compound, query($compound));
is_deeply(Selecto::BoundedQuery->execute($compound, $prepared)->{rows}, [[10]], 'bound prepared read executes');
is_deeply(Selecto::BoundedQuery->execute($compound->with_limits(Selecto::Limits->new(max_fields => 1)), $prepared)->{rows}, [[10]], 'prepared read survives approved limits transition');
my $other = engine()->with_tenant({prefix => 'tenant_b', tenant_id => 'tenant-b'})->apply_tenant_scope;
refusal('prepared query cannot cross legitimate tenant contexts', 'domain_modified_after_configuration', sub { Selecto::BoundedQuery->execute($other, $prepared) });
my $unscoped_raw = dclone($raw); delete $unscoped_raw->{tenant_required};
my $unscoped = Selecto::Engine->new(domain => Selecto::Domain->parse($unscoped_raw), adapter => $adapter);
refusal('prepared tenant authority cannot be dropped by another engine', 'domain_modified_after_configuration', sub { Selecto::BoundedQuery->execute($unscoped, $prepared) });
refusal('raw compiled statement cannot bypass attached policy', 'domain_modified_after_configuration', sub { Selecto::BoundedQuery->execute($compound, $prepared->{statement}) });
$prepared->{statement}{params}[1] = 'tenant-b';
refusal('actual prepared parameter mutation is refused', 'domain_modified_after_configuration', sub { Selecto::BoundedQuery->execute($compound, $prepared) });
$prepared = Selecto::BoundedQuery->prepare($compound, query($compound));
$prepared->{collections} = [[0, 1000000]];
refusal('prepared transfer metadata mutation is refused', 'domain_modified_after_configuration', sub { Selecto::BoundedQuery->execute($compound, $prepared) });

my $hooks = 0;
{ package Local::TenantHooks; use overload '""' => sub { ++$hooks; 'tenant_a' }, fallback => 1;
  sub STORABLE_freeze { ++$hooks; '' } sub TO_JSON { ++$hooks; 'tenant_a' } }
for my $value (sub { ++$hooks }, bless({}, 'Local::TenantHooks')) {
    refusal('executable context input is refused callback-free', 'invalid_query_contract', sub { engine()->with_tenant({prefix => $value}) });
}
my $cycle = {}; $cycle->{prefix} = $cycle;
refusal('cyclic context input is refused', 'invalid_query_contract', sub { engine()->with_tenant($cycle) });
refusal('context breadth is bounded before normalization', 'invalid_query_contract', sub { engine()->with_tenant({required_filters => [map { ['tenant_id', 'tenant-a'] } 1 .. 4000]}) });
is($hooks, 0, 'context admission invokes no callbacks, overloads or cloning hooks');
{ package Local::TenantTied; sub TIEHASH { bless {}, shift } sub FIRSTKEY { ++$hooks; die 'unexpected tie callback' } sub FETCH { ++$hooks; die 'unexpected tie callback' } }
my %tied_context; tie %tied_context, 'Local::TenantTied';
refusal('tied context root is refused before callbacks', 'invalid_query_contract', sub { engine()->with_tenant(\%tied_context) });
is($hooks, 0, 'context admission does not enumerate a tied root');
my $domain_input = dclone($raw); $domain_input->{tenant_required} = bless({}, 'Local::TenantHooks');
refusal('domain required flag is admitted before canonical clone', 'invalid_query_contract', sub { Selecto::Domain->parse($domain_input) });
is($hooks, 0, 'domain flag admission invokes no hooks');
{ package Local::TenantTiedScalar; sub TIESCALAR { bless {}, shift } sub FETCH { ++$hooks; die 'unexpected flag FETCH' } }
for my $flag (qw(tenant_required require_tenant)) {
    my $input = dclone($raw);
    tie $input->{$flag}, 'Local::TenantTiedScalar';
    refusal("tied $flag slot refuses before fetching", 'invalid_query_contract', sub { Selecto::Domain->parse($input) });
}
is($hooks, 0, 'neither read-requirement alias fetches tied scalar metadata');
my $plain_without_flags = dclone($raw); delete $plain_without_flags->{tenant_required};
my $before_plain_parse = dclone($plain_without_flags);
Selecto::Domain->parse($plain_without_flags);
is_deeply($plain_without_flags, $before_plain_parse, 'absence checks do not add missing requirement keys to authored input');
my $optional = dclone($raw); delete $optional->{tenant_required}; $optional->{source}{tenant_field} = 'tenant_id';
$optional->{required_filters} = [['tenant_id', 'tenant-a']];
$optional->{writes}{scope} = {tenant => {required => JSON::PP::true, field => 'tenant_id', satisfied_by => ['trusted_context']}};
my $legacy = Selecto::Engine->new(domain => Selecto::Domain->parse($optional), adapter => $adapter)->with_scope(tenant => 'tenant-a');
is_deeply($legacy->all(query($legacy))->{rows}, [[1], [3]], 'existing trusted write/read scope still works');
my $insert = $legacy->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'accounts', assignments => {name => 'Legacy', active => 1}));
ok($insert, 'existing trusted scope still authorizes declared write');
is($db->selectrow_array(q{SELECT tenant_id FROM accounts WHERE name='Legacy'}), 'tenant-a', 'legacy write retains native tenant authority');

my $report = Selecto::Verification::QuerySafety->verify;
is_deeply($report, {proof_level => 'bounded_exhaustive', model => 'selecto.query_scope.v1', state_count => 48,
    check_count => 240, invariant_count => 5, counterexamples => []}, 'original D060 finite public/native model passes');
{
    no warnings 'redefine';
    local *Selecto::Engine::validate_tenant_scope = sub { {valid => JSON::PP::true} };
    my $fault = Selecto::Verification::QuerySafety->verify;
    ok(@{$fault->{counterexamples}} > 0, 'actual broken validator produces counterexamples');
    ok(grep($_->{invariant} eq 'required_scope_fails_closed', @{$fault->{counterexamples}}), 'counterexamples report the observed violated invariant');
    is($fault->{check_count}, 240, 'faulty model still performs every check');
}
is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP memory');
my $databases = $db->selectall_arrayref('PRAGMA database_list');
ok(@$databases >= 3 && !grep(length($_->[2]), @$databases), 'all main, TEMP and attached databases are memory');
$db->disconnect;
done_testing;
