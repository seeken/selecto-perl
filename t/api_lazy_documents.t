use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::API ();
use Selecto::Domain ();

# Selecto::API builds its manifest and OpenAPI document when first asked for
# them: a query does not pay for documents it does not serve.

sub contract {
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {
            source_table => 'orders', primary_key => 'id', fields => [qw(id total)],
            columns => {id => {type => 'integer'}, total => {type => 'decimal', label => 'Total'}},
            associations => {},
        },
        schemas => {}, joins => {},
    };
}
my $raw = contract();
$raw->{domain_fingerprint} = Selecto::Domain->parse(contract(), strict => 1)->fingerprint;
my $domain = Selecto::Domain->parse($raw, strict => 1);
is $domain->published_fingerprint, $raw->{domain_fingerprint}, 'the domain_fingerprint the contract publishes';
is(Selecto::Domain->parse(contract(), strict => 1)->published_fingerprint, undef, 'undef when it publishes none');

my $api = Selecto::API->new(domain => $domain, base_path => '/api');
ok !exists($api->{openapi}) && !exists($api->{manifest}), 'construction builds neither document';
my $response = $api->request({method => 'POST', path => '/api/query', body => {select => ['id']}},
    {query => sub { ['ok', {columns => ['id'], rows => [], returned => 0}] }});
is $response->{status}, 200, 'a query is served';
ok !exists($api->{openapi}) && !exists($api->{manifest}), 'without building them';

my $eager = Selecto::API->new(domain => $domain, base_path => '/api');
my %paths = map { $_->{path} => 1 } @{$eager->openapi_document->{'x-selecto'}{fields}};
is_deeply \%paths, {id => 1, total => 1}, 'the document lists the public fields when asked for';
is $eager->manifest->{domain}{fingerprint}, $raw->{domain_fingerprint}, 'and the manifest names the domain';
ok((grep { $_->{path} eq '/api/query' } @{$eager->manifest->{routes}}), 'with its routes');
$eager->openapi_document->{externalDocs} = {url => '/console'};
is $eager->openapi_document->{externalDocs}{url}, '/console', "a host's additions stay";
my $served = $eager->request({method => 'GET', path => '/api/openapi.json'});
is(JSON::PP->new->decode($served->{body})->{externalDocs}{url}, '/console', 'in the document served');

done_testing;
