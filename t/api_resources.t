use 5.034;
use strict;
use warnings;

use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::PostgreSQL ();

{
    package TestAPIResources::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;

    sub execute_query ($self, $statement) {
        $self->{last_statement} = $statement;
        return {columns => $statement->columns, rows => []} if $self->{empty};
        return {
            columns => $statement->columns,
            rows => [[map { $_ eq 'id' || /\A__selecto_version_\d+\z/ ? 7 : "value:$_" }
                @{$statement->columns}]],
        };
    }
}

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', name => 'Resource Test',
    domain_fingerprint => 'sha256:api-resources-test-v1',
    source => {
        source_table => 'records', primary_key => 'id',
        fields => [qw(id name occurred_at secret)],
        columns => {
            id => {type => 'integer'}, name => {type => 'string'},
            occurred_at => {type => 'utc_datetime'},
            secret => {type => 'string', internal => 1},
        },
        associations => {
            lines => {queryable => 'record_lines', owner_key => 'id',
                related_key => 'record_id', cardinality => 'many'},
        },
    },
    schemas => {
        record_lines => {
            source_table => 'record_lines', primary_key => 'id',
            fields => [qw(id record_id sku)],
            columns => {id => {type => 'integer'}, record_id => {type => 'integer'}, sku => {type => 'string'}},
            associations => {},
        },
    },
    joins => {lines => {type => 'left'}},
}, strict => 1);

my $adapter = TestAPIResources::Adapter->new(dbh => bless({}, 'TestAPIResources::DBH'));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

sub guard {
    my ($code) = @_;
    my $data = eval { $code->() };
    return ['ok', $data] unless $@;
    my $e = $@;
    die $e unless blessed($e) && $e->isa('Selecto::Error');
    return ['error', {status => Selecto::API::error_status($e->code), code => $e->code,
        message => $e->message, details => $e->details}];
}

sub call {
    my ($api, $handler, $method, $path, %request) = @_;
    my $response = $api->request({method => $method, path => $path, %request}, {
        query => sub { my ($body) = @_; guard(sub { $handler->query($engine, $body) }) },
        resource => sub { my (undef, $params) = @_; guard(sub { $handler->resource($engine, $params) }) },
    });
    return ($response, JSON::PP->new->decode($response->{body}));
}

# The route is opt-in.
my $plain = Selecto::API->new(domain => $domain, base_path => '/api');
ok !grep({ $_->{operation_id} eq 'getResource' } @{$plain->manifest->{routes}}),
    'resource GET is not advertised unless enabled';
my ($response, $body) = call($plain, Selecto::API::EngineHandler->new, GET => '/api/resources/7');
is $response->{status}, 404, 'resource GET is not routed unless enabled';
is $body->{error}{code}, 'route_not_found', 'a disabled resource route is an unknown route';

my $api = Selecto::API->new(domain => $domain, base_path => '/api', resources => 1);
is_deeply [grep { $_->{operation_id} eq 'getResource' } @{$api->manifest->{routes}}],
    [{method => 'GET', operation_id => 'getResource', path => '/api/resources/{id}'}],
    'an enabled API advertises resource GET';
is_deeply [map { $_->{name} } @{$api->openapi_document->{paths}{'/api/resources/{id}'}{get}{parameters}}],
    [qw(id fields)], 'OpenAPI documents the resource id and fields';

# Without a versioner: the primary key and requested fields.
my $handler = Selecto::API::EngineHandler->new;
($response, $body) = call($api, $handler, GET => '/api/resources/7');
is $response->{status}, 200, 'a resource GET succeeds';
is_deeply $body->{data}, {id => 7}, 'it returns the primary key';
ok !exists($response->{headers}{etag}), 'no ETag without an aggregate version';
like $adapter->{last_statement}->sql, qr/WHERE .*"s0"\."id" = \$1/s, 'it filters on the primary key';
is_deeply $adapter->{last_statement}->params, [7], 'the id is bound';

($response, $body) = call($api, $handler, GET => '/api/resources/7', fields => 'name, occurred_at');
is_deeply $body->{data}, {id => 7, name => 'value:name', occurred_at => 'value:occurred_at'},
    'requested fields are added';
like $adapter->{last_statement}->sql, qr/occurred_at/, 'timestamps are selected';
($response, $body) = call($api, $handler, GET => '/api/resources/7', fields => ['name']);
is $body->{data}{name}, 'value:name', 'fields may be an array';

($response, $body) = call($api, $handler, GET => '/api/resources/7', fields => 'secret');
is $response->{status}, 403, 'an internal field is refused';
is $body->{error}{code}, 'hidden_field', 'as a hidden field, like queries';
($response, $body) = call($api, $handler, GET => '/api/resources/7', fields => 'lines.sku');
is $response->{status}, 422, 'a to-many field is refused';
is $body->{error}{code}, 'invalid_api_query', 'with the query route as the alternative';
($response, $body) = call($api, $handler, GET => '/api/resources/abc');
is $body->{error}{code}, 'invalid_api_query', 'a non-integer id for an integer key is refused';
$adapter->{empty} = 1;
($response, $body) = call($api, $handler, GET => '/api/resources/8');
is $response->{status}, 404, 'a missing resource is 404';
is $body->{error}{code}, 'resource_not_found', 'with resource_not_found';
$adapter->{empty} = 0;

($response, $body) = call($api, $handler, POST => '/api/query',
    body => {select => ['aggregate_version']});
isnt $response->{status}, 200, 'aggregate_version is not a field without a versioner';
($response, $body) = call($api, $handler, GET => '/api/resources/7', fields => 'aggregate_version');
is $body->{error}{code}, 'invalid_api_query', 'nor a resource field';

# With a versioner: the virtual aggregate_version.
my @asked;
my $versioned = $handler->with_versioner(sub {
    my ($versioned_engine, $keys) = @_;
    push @asked, [@$keys];
    return {map { ($_ => "v$_") } @$keys};
});
ok !$handler->versioner, 'with_versioner leaves the original handler unchanged';
($response, $body) = call($api, $versioned, GET => '/api/resources/7');
is_deeply $body->{data}, {id => 7}, 'the version is opt-in';
ok !exists($response->{headers}{etag}), 'so is the ETag';
ok !@asked, 'the versioner is not asked unless the version is requested';
($response, $body) = call($api, $versioned, GET => '/api/resources/7', fields => 'name,aggregate_version');
is_deeply $body->{data}, {id => 7, name => 'value:name', aggregate_version => 'v7'},
    'a requested version is returned with the other fields';
is $response->{headers}{etag}, '"v7"', 'the version is the ETag';
is_deeply $asked[-1], [7], 'the versioner receives the row keys';

($response, $body) = call($api, $versioned, POST => '/api/query',
    body => {select => ['name', 'aggregate_version', {field => 'aggregate_version', alias => 'v'}]});
is $response->{status}, 200, 'a query may select aggregate_version';
is_deeply $body->{data}{columns}, [qw(name aggregate_version v)], 'versions take the selected names';
is_deeply $body->{data}{rows}, [['value:name', 'v7', 'v7']], 'and the host versions';
($response, $body) = call($api, $versioned, POST => '/api/query',
    body => {select => ['name', 'aggregate_version'], row_format => 'objects'});
is_deeply $body->{data}{rows}, [{name => 'value:name', aggregate_version => 'v7'}],
    'object rows carry versions too';
($response, $body) = call($api, $versioned, POST => '/api/query',
    body => {select => [{field => 'aggregate_version', format => 'day'}]});
is $body->{error}{code}, 'invalid_api_query', 'aggregate_version takes only an alias';

my $described = Selecto::API->new(domain => $domain, base_path => '/api', resources => 1);
$versioned->describe_openapi($described);
is $described->domain->{source}{columns}{aggregate_version}{read_only}, JSON::PP::true,
    'the published domain lists aggregate_version as read-only';
is $described->domain->{source}{columns}{aggregate_version}{filterable}, JSON::PP::false,
    'and not filterable';
my $undescribed = Selecto::API->new(domain => $domain, base_path => '/api');
$handler->describe_openapi($undescribed);
ok !exists($undescribed->domain->{source}{columns}{aggregate_version}),
    'without a versioner the column is not published';

is Selecto::API::error_status('resource_not_found'), 404, 'resource_not_found maps to 404';

done_testing;
