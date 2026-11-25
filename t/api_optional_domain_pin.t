use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Mojo::URL;
use Selecto;
use Selecto::API::Explorer;
use Selecto::API::RemoteQuery;
use Selecto::API::NestedDetail;

my $json = JSON::PP->new->utf8->canonical;
sub context_header {
    my $header = encode_base64($json->encode($_[0]), '');
    $header =~ tr!+/!-_!;
    $header =~ s/=+\z//;
    return $header;
}
sub exercise {
    my ($backend, $dbh) = @_;
    $dbh->do('CREATE TEMP TABLE pin_orders (id INTEGER, tenant_id INTEGER, title TEXT)');
    $dbh->do('CREATE TEMP TABLE pin_lines (id INTEGER, tenant_id INTEGER, order_id INTEGER)');
    $dbh->do("INSERT INTO pin_orders VALUES (1, 7, 'Amber'), (2, 8, 'Violet')");
    $dbh->do('INSERT INTO pin_lines VALUES (11, 7, 1), (12, 8, 1)');
    my $integer = {type => 'integer', nullable => JSON::PP::false};
    my $internal = {%$integer, internal => JSON::PP::true};
    my $domain = Selecto::Domain->parse({schema_version => 1, domain_version => '1',
        domain_fingerprint => 'sha256:optional-pin-orders-v1', name => 'Pin orders',
        source => {source_table => 'pin_orders', primary_key => 'id', tenant_field => 'tenant_id',
            fields => [qw(id tenant_id title)], columns => {id => $integer, tenant_id => $internal,
                title => {type => 'string', nullable => JSON::PP::false}},
            associations => {lines => {queryable => 'lines', owner_key => 'id', related_key => 'order_id', cardinality => 'many'}}},
        schemas => {lines => {source_table => 'pin_lines', primary_key => 'id', tenant_field => 'tenant_id',
            fields => [qw(id tenant_id order_id)], columns => {id => $integer, tenant_id => $internal, order_id => $internal},
            associations => {}}}, joins => {lines => {type => 'left'}}}, strict => 1);
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter($backend => dbh => $dbh, temporary_relations => 1), scope => {tenant => 7});
    my $explorer = Selecto::API::Explorer->new(base_path => '/orders', id => 'orders', publication => 'pub-1', clock => '2026-11-25T00:00:00Z');
    my $remote = Selecto::API::RemoteQuery->new(base_path => '/orders');
    my $nested = Selecto::API::NestedDetail->new(base_path => '/orders', id => 'orders', publication => 'pub-1', collection => 'lines');
    my $features = $explorer->features($engine);
    my $nested_features = $nested->features($engine);
    my $context = $nested->context($nested_features);
    for my $surface (
        ['explorer', $explorer, 'explorer-query', 'selecto.explorer-query', $features->{domain}{fingerprint}],
        ['remote', $remote, 'query', 'selecto.remote-query', $domain->fingerprint],
        ['nested', $nested, 'query', 'selecto.remote-query', $nested_features->{domain}{fingerprint}],
    ) {
        my ($name, $host, $route, $format, $fingerprint) = @$surface;
        subtest $name => sub {
            my $envelope = sub { +{format => $format, format_version => 1,
                query => {select => $name eq 'nested' ? ['id', ['lines.id']] : ['id']}} };
            my $call = sub {
                my ($body, $ctx) = @_;
                my $response = $host->request($engine, {method => 'POST', path => "/orders/$route",
                    content_type => 'application/json', body => $body, raw_body => $json->encode($body),
                    ($name eq 'nested' ? (headers => {'Selecto-Nested-Detail-Context' => context_header($ctx // $context)}) : ())});
                return ($response->{status}, $json->decode($response->{body}));
            };
            for my $pinned (0, 1) {
                my $body = $envelope->();
                $body->{domain} = {fingerprint => $fingerprint} if $pinned;
                my ($status, $result) = $call->($body);
                is $status, 200, $pinned ? 'matching pin runs' : 'absent pin runs';
                is $result->{data}{domain}{fingerprint}, $fingerprint, 'response carries current fingerprint';
                is_deeply $result->{data}{rows}, $name eq 'nested' ? [[1, [[11]]]] : [[1]], 'governed data is returned';
                is $result->{data}{features}{revision}, $features->{revision}, 'current features revision returned' if $name eq 'explorer';
            }
            for my $case (
                ['stale', {fingerprint => 'sha256:old'}, 409, 'stale_domain_fingerprint'],
                ['empty object', {}, 400, 'malformed_request'],
                ['empty string', {fingerprint => ''}, 400, 'malformed_request'],
                ['number', {fingerprint => 42}, 400, 'malformed_request'],
                ['boolean', {fingerprint => JSON::PP::true}, 400, 'malformed_request'],
                ['null fingerprint', {fingerprint => undef}, 400, 'malformed_request'],
                ['array fingerprint', {fingerprint => []}, 400, 'malformed_request'],
                ['extra key', {fingerprint => $fingerprint, extra => 1}, 400, 'malformed_request'],
                ['null domain', undef, 400, 'malformed_request'],
                ['array domain', [], 400, 'malformed_request'],
                ['string domain', 'old', 400, 'malformed_request'],
            ) {
                my ($label, $pin, $want_status, $code) = @$case;
                my ($status, $result) = $call->({%{$envelope->()}, domain => $pin});
                is $status, $want_status, "$label status";
                is $result->{error}{code}, $code, "$label code";
            }
            if ($name eq 'explorer') {
                for my $revision ($features->{revision}, 'old') {
                    my ($status, $result) = $call->({%{$envelope->()}, features => {revision => $revision}});
                    is $status, $revision eq 'old' ? 409 : 200, 'features pin checked without domain';
                    is $result->{error}{code}, 'stale_explorer_features', 'stale revision code' if $revision eq 'old';
                }
            }
            if ($name eq 'nested') {
                my ($status, $result) = $call->($envelope->(), {%$context, fingerprint => 'sha256:old'});
                is $status, 409, 'context still binds fingerprint without envelope pin';
                is $result->{error}{code}, 'stale_nested_detail_context', 'stale context code';
            }
            my $openapi = $json->decode($host->request($engine, {method => 'GET', path => '/orders/openapi.json'})->{body});
            my $schema = $openapi->{paths}{"/orders/$route"}{post}{requestBody}{content}{'application/json'}{schema};
            ok $schema, 'OpenAPI describes request envelope';
            ok !grep({ $_ eq 'domain' || $_ eq 'features' } @{$schema->{required}}), 'domain and features are optional in OpenAPI';
            like $schema->{properties}{domain}{description}, qr/Optional.*pin/, 'OpenAPI describes domain pin';
            is_deeply $schema->{properties}{domain}{required}, ['fingerprint'], 'supplied domain requires fingerprint';
            is $schema->{properties}{domain}{properties}{fingerprint}{minLength}, 1, 'pin must be non-empty';
        };
    }
    is $features->{supports}{optional_domain_pin}, JSON::PP::true, 'Explorer features advertise optional_domain_pin';
    is $nested_features->{supports}{optional_domain_pin}, JSON::PP::true, 'nested features advertise optional_domain_pin';
    my $manifest = $json->decode($remote->request($engine, {method => 'GET', path => '/orders'})->{body});
    is $manifest->{query_capabilities}{optional_domain_pin}, JSON::PP::true, 'remote manifest advertises optional_domain_pin';
    my $openapi = $json->decode($explorer->request($engine, {method => 'GET', path => '/orders/openapi.json'})->{body});
    is $openapi->{'x-selecto-explorer-supports'}{optional_domain_pin}, JSON::PP::true, 'OpenAPI mirrors Explorer capability';
    $dbh->disconnect;
}
subtest SQLite => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    exercise('sqlite', DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0}));
};
subtest PostgreSQL => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL not configured' unless $url;
    my $u = Mojo::URL->new($url);
    my $db = $u->path->to_string; $db =~ s{^/}{};
    exercise('postgresql', DBI->connect('dbi:Pg:dbname=' . $db . ';host=' . $u->host . ';port=' . $u->port,
        $u->username, $u->password, {RaiseError => 1, PrintError => 0, pg_enable_utf8 => 1}));
};
done_testing;
