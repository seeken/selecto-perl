use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(decode_utf8 encode_utf8);
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
is(
    Selecto::API::canonical_json({ exact_decimal => "1.2500" }),
    '{"exact_decimal":"1.2500"}',
    'canonical JSON preserves an exact numeric-looking string as a string',
);

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
is $response->{headers}{vary}, 'Accept',
    'query responses declare Accept-based content negotiation';

my $csv_response = $api->request(
    {
        method => 'POST', path => '/api/v1/certification/query', body => {},
        accept => 'text/csv',
    },
    {query => sub { return ['ok', {
        columns => [qw(id label)], rows => [[7, 'Renée 東京']],
    }]; }},
);
is $csv_response->{status}, 200, 'CSV query response succeeds';
is $csv_response->{headers}{'content-type'}, 'text/csv; charset=utf-8',
    'CSV query response has its standard media type';
is $csv_response->{headers}{'content-disposition'},
    'attachment; filename="certification-api-query.csv"',
    'CSV query response has a safe domain-derived filename';
is decode_utf8($csv_response->{body}), "id,label\r\n7,\"Renée 東京\"\r\n",
    'CSV query response contains headings and UTF-8 row data';

my $named_csv_response = $api->request(
    {
        method => 'POST', path => '/api/v1/certification/query', body => {},
        accept => 'text/csv', download_filename => 'September Certifications.csv',
    },
    {query => sub { return ['ok', {
        columns => [qw(id label)], rows => [[7, 'Approved']],
    }]; }},
);
is $named_csv_response->{headers}{'content-disposition'},
    'attachment; filename="September Certifications.csv"',
    'a caller may choose a safe download filename with the required extension';

my $bad_filename_response = $api->request(
    {
        method => 'POST', path => '/api/v1/certification/query', body => {},
        accept => 'text/csv', download_filename => 'certifications.xlsx',
    },
    {query => sub { die 'an invalid filename must not execute the query' }},
);
is $bad_filename_response->{status}, 400,
    'a download filename with the wrong extension is rejected before execution';
like $bad_filename_response->{body}, qr/"code":"invalid_response_filename"/,
    'invalid download filenames use a stable machine-readable code';
like $bad_filename_response->{body}, qr/"expected_extension":"\.csv"/,
    'the filename error reports the required extension';

my $tsv_response = $api->request(
    {
        method => 'POST', path => '/api/v1/certification/query', body => {},
        response_format => 'tsv', accept => 'application/json',
    },
    {query => sub { return ['ok', {
        columns => [qw(id label)], rows => [{id => 7, label => "tab\tvalue"}],
    }]; }},
);
is $tsv_response->{headers}{'content-type'},
    'text/tab-separated-values; charset=utf-8',
    'explicit response format takes precedence over Accept';
is decode_utf8($tsv_response->{body}), "id\tlabel\r\n7\t\"tab\tvalue\"\r\n",
    'TSV query response supports object rows and quotes embedded tabs';

my $not_acceptable = $api->request(
    {
        method => 'POST', path => '/api/v1/certification/query', body => {},
        accept => 'application/pdf',
    },
    {query => sub { die 'unsupported formats must not execute the query' }},
);
is $not_acceptable->{status}, 406,
    'an unsupported Accept media type is rejected before query execution';
like $not_acceptable->{body}, qr/"code":"response_format_not_acceptable"/,
    'not-acceptable responses use a stable machine-readable code';

my $missing = $api->request({
    method => 'DELETE',
    path => '/api/v1/certification/domain',
});
is($missing->{status}, 404, 'unknown method and route fail closed');
like($missing->{body}, qr/"code":"route_not_found"/, 'route error uses the canonical envelope');

done_testing;
