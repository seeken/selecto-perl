use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();

# A public query or write on a tenant_field domain whose engine has no trusted
# tenant boundary is refused as missing_tenant_scope, 403 through Selecto::API,
# as in the other runtimes (Elixir, Go, Rust, TypeScript).

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

sub relation {
    my ($table, %cols) = @_;
    return {
        source_table => $table, primary_key => 'id', fields => [sort keys %cols],
        columns => {map { ($_ => {type => $cols{$_}}) } keys %cols},
        associations => {},
    };
}

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Work Orders', domain_version => '1',
    domain_fingerprint => 'sha256:api-missing-tenant-scope',
    source => {%{relation('work_orders', id => 'integer', site_id => 'integer', title => 'string')},
        tenant_field => 'site_id'},
    schemas => {}, joins => {},
    writes => {
        operations => {update => {enabled => 1}},
        fields => {title => {updatable => 1}},
        scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
    },
});

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE work_orders (id integer primary key, site_id integer not null, title text not null)');
$dbh->do(q{INSERT INTO work_orders VALUES (1, 10, 'mine'), (2, 20, 'theirs')});
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $scoped = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 10});

my $handler = Selecto::API::EngineHandler->new;
my $api = Selecto::API->new(domain => $domain, base_path => '/api');
my $update = {operation => 'update', assignments => {title => 'changed'},
    filters => [{field => 'id', op => 'eq', value => 1}]};

# The documented host guard: Selecto::Errors become ['error', ...], with or
# without an explicit status from error_status.
sub guarded {
    my ($run, $with_status) = @_;
    my $data = eval { $run->() };
    return ['ok', $data] unless $@;
    my $e = $@;
    die $e unless blessed($e) && $e->isa('Selecto::Error');
    return ['error', {
        ($with_status ? (status => Selecto::API::error_status($e->code)) : ()),
        code => $e->code, message => $e->message, details => $e->details,
    }];
}

sub request {
    my ($engine, $route, $body, $with_status) = @_;
    my $response = $api->request({method => 'POST', path => "/api/$route", body => $body}, {
        query => sub { my ($intent) = @_; guarded(sub { $handler->query($engine, $intent) }, $with_status) },
        write => sub { my ($intent) = @_; guarded(sub { $handler->write($engine, $intent) }, $with_status) },
    });
    return ($response->{status}, JSON::PP->new->decode($response->{body}));
}

my $refused = {ok => JSON::PP::false, error => {code => 'missing_tenant_scope', details => {},
    message => 'Canonical API operation rejected'}};

is(Selecto::API::error_status('missing_tenant_scope'), 403, 'missing_tenant_scope maps to 403');

for my $with_status (0, 1) {
    my $label = $with_status ? 'a guard using error_status' : 'a handler error without a status';

    subtest "$label: queries" => sub {
        my ($status, $body) = request($unscoped, 'query', {select => ['id']}, $with_status);
        is($status, 403, 'an engine without a tenant boundary is 403');
        is_deeply($body, $refused, 'the body names the code only (the tenant field is withheld)');
        ($status, $body) = request($scoped, 'query', {select => ['id', 'site_id']}, $with_status);
        is($status, 200, 'an engine tenant still reads');
        is_deeply($body->{data}{rows}, [[1, 10]], 'only the trusted tenant is read');
        ($status, $body) = request($unscoped, 'query', {select => ['nope']}, $with_status);
        is($status, 403, 'the tenant boundary is checked before the body');
        is($body->{error}{code}, 'missing_tenant_scope', 'and reports missing_tenant_scope');
    };

    subtest "$label: writes" => sub {
        my ($status, $body) = request($unscoped, 'write', $update, $with_status);
        is($status, 403, 'an engine without a tenant boundary is 403');
        is_deeply($body, $refused, 'the body names the code only (the tenant field is withheld)');
        is($dbh->selectrow_array('SELECT title FROM work_orders WHERE id = 1'), 'mine', 'nothing was written');
        ($status, $body) = request($scoped, 'write',
            {%$update, filters => [{field => 'id', op => 'eq', value => 2}]}, $with_status);
        is($status, 422, 'another tenant\'s row stays a 422 refusal');
        is($body->{error}{code}, 'cardinality_mismatch', 'as cardinality_mismatch');
    };
}

my $explicit = $api->request({method => 'POST', path => '/api/query', body => {}}, {query => sub {
    ['error', {status => 422, code => 'missing_tenant_scope'}];
}});
is($explicit->{status}, 422, 'a handler-chosen status still wins');

done_testing;
