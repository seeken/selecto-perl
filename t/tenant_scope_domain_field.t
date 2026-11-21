use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;

# A tenant_required domain whose tenant column is not tenant_id (site_id
# here): the scope check reads the domain's tenant_field. It used to look for
# a tenant_id filter, so with_tenant reads refused with tenant_scope_missing.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE sites_items (id INTEGER PRIMARY KEY, site_id INTEGER NOT NULL, name TEXT)');
$dbh->do(q{INSERT INTO sites_items VALUES (1, 5, 'a'), (2, 6, 'b'), (3, 5, 'c')});
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'SiteItems', tenant_required => JSON::PP::true,
    source => {source_table => 'sites_items', primary_key => 'id', fields => [qw(id site_id name)], tenant_field => 'site_id',
        columns => {id => {type => 'integer'}, site_id => {type => 'integer'}, name => {type => 'string'}}},
    schemas => {}, joins => {}});
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
sub ids { my ($e) = @_; return [map { $_->[0] } @{$e->all($e->query->select('id')->order_by('id'))->{rows}}] }
sub code { my ($run) = @_; return eval { $run->(); 1 } ? undef : $@->code }

my $site = $engine->with_tenant(5);
ok(${$site->validate_tenant_scope->{valid}}, 'with_tenant satisfies the scope through site_id');
is_deeply(ids($site), [1, 3], 'with_tenant reads only that site');

is(code(sub { ids($engine) }), 'tenant_scope_missing', 'a read with no tenant still refuses');
my $report = $engine->validate_tenant_scope;
is($report->{error}{tenant_field}, 'site_id', 'the missing-scope report names the domain tenant field');

my $attached = $engine->with_read_context({tenant_id => 6});
is($attached->tenant_context->{tenant_field}, 'site_id', 'a read context defaults to the domain tenant field');
is(code(sub { ids($attached) }), 'tenant_scope_missing', 'an attached context still needs apply_tenant_scope');
is_deeply(ids($attached->apply_tenant_scope), [2], 'the applied read context scopes site_id');

my $explicit = $engine->with_read_context({tenant_id => 5, tenant_field => 'site_id'})->apply_tenant_scope;
is_deeply(ids($explicit), [1, 3], 'an explicit tenant_field still works');
is(code(sub { $engine->with_read_context({tenant_id => 5, tenant_field => 'tenant_id'}) }), 'unknown_field',
    'a context naming a field the domain lacks refuses');

done_testing;
