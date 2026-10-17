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
use DBI ();
use Selecto ();

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
    [qw(id fields date_format)], 'OpenAPI documents the resource id, fields and date_format';
is_deeply $api->openapi_document->{paths}{'/api/resources/{id}'}{get}{parameters}[2]{schema},
    {type => 'string', enum => [qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds)], default => 'iso8601'},
    'date_format is an enum defaulting to iso8601';
is_deeply(Selecto::API::EngineHandler->resource_date_formats,
    [qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds)], 'the handler lists the same values');

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

# date_format: one format for every temporal field, compiled into the SQL.
my $temporal_contract = {
    schema_version => 1, domain_version => '1.0.0', name => 'Resource Dates',
    domain_fingerprint => 'sha256:api-resources-dates-v1',
    source => {
        source_table => 'selecto_perl_test_resource_dates', primary_key => 'id',
        fields => [qw(id at local_at born epoch label)],
        columns => {
            id => {type => 'integer'}, at => {type => 'utc_datetime'},
            local_at => {type => 'naive_datetime'}, born => {type => 'date'},
            epoch => {type => 'epoch_datetime'}, label => {type => 'string'},
        },
        associations => {},
    },
    schemas => {}, joins => {},
};
my $dates = Selecto::Domain->parse($temporal_contract, strict => 1);
my $dates_adapter = TestAPIResources::Adapter->new(dbh => bless({}, 'TestAPIResources::DBH'));
my $dates_engine = Selecto::Engine->new(domain => $dates, adapter => $dates_adapter);
my $dates_api = Selecto::API->new(domain => $dates, base_path => '/api', resources => 1);
my $dates_call = sub {
    my (%request) = @_;
    my $response = $dates_api->request({method => 'GET', path => '/api/resources/7', %request}, {
        resource => sub { my (undef, $params) = @_; guard(sub { $handler->resource($dates_engine, $params) }) },
    });
    return ($response, JSON::PP->new->decode($response->{body}));
};
my $fields = 'at,local_at,born,epoch,label';
my %select_sql;
for my $format (undef, qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds)) {
    my ($response) = $dates_call->(fields => $fields, defined($format) ? (date_format => $format) : ());
    is $response->{status}, 200, 'date_format ' . ($format // '(absent)') . ' is accepted';
    my $sql = $dates_adapter->{last_statement}->sql;
    $select_sql{$format // 'default'} = substr($sql, 0, index($sql, ' FROM "selecto_perl_test_resource_dates"'));
}
is $select_sql{default}, $select_sql{iso8601}, 'the default is iso8601';
like $select_sql{iso8601}, qr/TO_CHAR\(\("s0"\."at" AT TIME ZONE 'UTC'\), 'YYYY-MM-DD"T"HH24:MI:SS'\) \|\| 'Z'/,
    'iso8601 keeps today\'s UTC instant SQL';
like $select_sql{iso8601}, qr/TO_CHAR\("s0"\."local_at", 'YYYY-MM-DD"T"HH24:MI:SS'\)/, 'and naive wall time';
like $select_sql{iso8601}, qr/"s0"\."born", /, 'a date keeps its plain value under iso8601';
unlike $select_sql{rfc3339_millis}, qr/"s0"\."born", /, 'but is formatted under the others';
like $select_sql{rfc3339_millis}, qr/HH24:MI:SS\.MS'\) \|\| 'Z'/, 'rfc3339_millis has milliseconds';
like $select_sql{rfc3339_millis}, qr/CAST\("s0"\."born" AS TIMESTAMP\) AT TIME ZONE 'UTC'/, 'a date is midnight UTC';
like $select_sql{epoch_seconds}, qr/CAST\(FLOOR\(EXTRACT\(EPOCH FROM .*"s0"\."at".*\)\) AS BIGINT\)/,
    'epoch_seconds floors the epoch';
like $select_sql{epoch_milliseconds}, qr/\* 1000\) AS BIGINT\)/, 'epoch_milliseconds scales it';
like $select_sql{epoch_seconds}, qr/TO_TIMESTAMP\("s0"\."epoch"\)/, 'an epoch field is read as an instant';
like $select_sql{epoch_seconds}, qr/"s0"\."label"/, 'other fields are unformatted';
for my $bad ('', 'raw', 'ISO8601', 'day', ['iso8601', 'epoch_seconds']) {
    my ($response, $body) = $dates_call->(fields => $fields, date_format => $bad);
    is $response->{status}, 422, 'date_format ' . (ref($bad) ? 'repeated' : "'$bad'") . ' is refused';
    is_deeply [$body->{error}{code}, $body->{error}{details}], ['invalid_api_query', {parameter => 'date_format'}],
        'as invalid_api_query naming the parameter';
}

# The values themselves, from a live PostgreSQL.
SKIP: {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    skip 'SELECTO_PERL_TEST_POSTGRES_URL is not configured', 1 unless defined($url) && $url ne '';
    skip 'DBD::Pg or Selecto::Certification is not installed', 1
        unless eval { require DBD::Pg; require Selecto::Certification; 1 };
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET TimeZone = ' . $dbh->quote('America/New_York'));
    $dbh->do('DROP TABLE IF EXISTS selecto_perl_test_resource_dates');
    $dbh->do('CREATE TABLE selecto_perl_test_resource_dates (id integer primary key, at timestamptz,
        local_at timestamp, born date, epoch bigint, label text)');
    $dbh->do(q{INSERT INTO selecto_perl_test_resource_dates VALUES
        (7, '2024-03-10 06:59:59.98765+00', '2024-03-10 01:02:03.4567', '2024-02-29', 1709999999, 'x'),
        (8, NULL, NULL, NULL, NULL, NULL),
        (9, '1969-12-31 23:59:59.5+00', '1969-12-31 23:59:59.5', '1969-12-31', -1, 'y')});
    my $live = Selecto::Engine->new(domain => $dates, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
    my $read = sub {
        my ($id, $format) = @_;
        return $handler->resource($live, {id => $id, fields => $fields,
            defined($format) ? (date_format => $format) : ()});
    };
    is_deeply $read->(7), {id => 7, at => '2024-03-10T06:59:59Z', local_at => '2024-03-10T01:02:03',
        born => '2024-02-29', epoch => '2024-03-09T15:59:59Z', label => 'x'}, 'iso8601 (default), in UTC whatever the session zone';
    is_deeply $read->(7, 'rfc3339_millis'), {id => 7, at => '2024-03-10T06:59:59.987Z',
        local_at => '2024-03-10T01:02:03.456Z', born => '2024-02-29T00:00:00.000Z',
        epoch => '2024-03-09T15:59:59.000Z', label => 'x'}, 'rfc3339_millis truncates to milliseconds';
    is_deeply $read->(7, 'epoch_seconds'), {id => 7, at => 1710053999, local_at => 1710032523,
        born => 1709164800, epoch => 1709999999, label => 'x'}, 'epoch_seconds';
    is_deeply $read->(7, 'epoch_milliseconds'), {id => 7, at => 1710053999987, local_at => 1710032523456,
        born => 1709164800000, epoch => 1709999999000, label => 'x'}, 'epoch_milliseconds';
    is_deeply $read->(9, 'epoch_seconds'), {id => 9, at => -1, local_at => -1, born => -86400,
        epoch => -1, label => 'y'}, 'epochs before 1970 round down';
    is_deeply $read->(9, 'epoch_milliseconds'), {id => 9, at => -500, local_at => -500, born => -86400000,
        epoch => -1000, label => 'y'}, 'in milliseconds too';
    for my $format (qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds)) {
        is_deeply $read->(8, $format), {id => 8, at => undef, local_at => undef, born => undef,
            epoch => undef, label => undef}, "a null field is null under $format";
    }
    my $json = JSON::PP->new->canonical;
    is $json->encode($read->(7, 'epoch_seconds')),
        '{"at":1710053999,"born":1709164800,"epoch":1709999999,"id":7,"label":"x","local_at":1710032523}',
        'epochs are JSON numbers';
    $dbh->do('DROP TABLE selecto_perl_test_resource_dates');
}

done_testing;
