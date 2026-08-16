use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode_utf8);
use JSON::PP ();
use Selecto::API ();
use Selecto::Domain ();

my $domain = Selecto::Domain->parse({
    schema_version => 1,
    domain_version => '2.1.0',
    domain_fingerprint => 'sha256:certification-api-v1',
    name => 'Certification API',
    source => {
        source_table => 'selecto_cert_api',
        primary_key => 'id',
        fields => ['id', 'label'],
        columns => {
            id => { type => 'integer' },
            label => { type => 'string' },
        },
        associations => {},
    },
    schemas => {},
    joins => {},
    writes => { operations => { update => { enabled => JSON::PP::true } } },
    actions => { archive => { type => 'row_action', scope => 'row' } },
});

my $body = Selecto::API::canonical_json({
    z => 'Renée 東京',
    a => "line\nbreak",
    q => chr(31),
});
is(
    unpack('H*', $body),
    unpack('H*', encode_utf8(qq|{"a":"line\\nbreak","q":"\\u001f","z":"Renée 東京"}|)),
    'canonical JSON fixes order, escaping, and UTF-8 bytes',
);
eval { Selecto::API::canonical_json({ float => 1.25 }) };
is($@->code, 'non_canonical_value', 'canonical JSON rejects floats');

my $api = Selecto::API->new(domain => $domain, base_path => '/api/v1/certification');
is_deeply($api->manifest->{domain}, {
    fingerprint => 'sha256:certification-api-v1',
    name => 'Certification API',
    schema_version => 1,
    version => '2.1.0',
}, 'manifest binds the canonical domain identity');
is(
    $api->openapi->{paths}{'/api/v1/certification/query'}{post}{operationId},
    'queryDomain',
    'OpenAPI exposes the canonical query operation',
);

my $response = $api->request(
    { method => 'POST', path => '/api/v1/certification/query', body => {} },
    { query => sub { return ['ok', { rows => [[7, 'Renée 東京']] }]; } },
);
is($response->{status}, 200, 'query callback returns success');
is(
    unpack('H*', $response->{body}),
    unpack('H*', encode_utf8(qq|{"data":{"rows":[[7,"Renée 東京"]]},"ok":true}|)),
    'query callback response is byte stable',
);
is($response->{headers}{'content-length'}, length($response->{body}), 'byte length is exact');

my $missing = $api->request({
    method => 'DELETE',
    path => '/api/v1/certification/domain',
});
is($missing->{status}, 404, 'unknown method and route fail closed');
like($missing->{body}, qr/"code":"route_not_found"/, 'route error uses the canonical envelope');

done_testing;
