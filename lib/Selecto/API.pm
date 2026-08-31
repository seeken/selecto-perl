package Selecto::API;

use 5.034;
use utf8;
use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);
use Selecto::Domain ();
use Selecto::Error ();

our $CANONICAL_JSON = 'selecto.canonical-json.v1';
our $DEFAULT_PATH = '/api/v1/selecto';
our $JSON_CONTENT_TYPE = 'application/json; charset=utf-8';
our $OPENAPI_CONTENT_TYPE = 'application/vnd.oai.openapi+json;version=3.1';

has [qw(domain base_path manifest openapi)];

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    my $domain = $self->domain;
    Selecto::Error->throw(
        'canonical_api_requires_domain_contract',
        'canonical API hosting requires a canonical domain contract',
    ) unless blessed($domain) && $domain->isa('Selecto::Domain');
    my $contract = $domain->contract;
    Selecto::Error->throw(
        'canonical_api_requires_domain_contract',
        'canonical API hosting requires a canonical domain contract',
    ) unless defined $contract;

    my $base_path = _normalize_base_path($self->base_path // $DEFAULT_PATH);
    my $identity = _domain_identity($contract);
    canonical_json($contract);
    $self->domain($contract);
    $self->base_path($base_path);
    $self->manifest(_manifest($identity, $base_path));
    $self->openapi(_openapi($identity, $base_path));
    return $self;
}

sub openapi_document ($self) { return $self->openapi; }

sub request ($self, $request, $handlers = {}) {
    Selecto::Error->throw('invalid_request', 'canonical API request must be an object')
        unless ref($request) eq 'HASH';
    Selecto::Error->throw('invalid_handlers', 'canonical API handlers must be an object')
        unless ref($handlers) eq 'HASH';

    my $method = $request->{method};
    my $path = $request->{path};
    my $body = $request->{body};
    my $route = $self->_route($method, $path);
    return _response(200, $self->domain, $JSON_CONTENT_TYPE) if $route eq 'domain';
    return _response(200, $self->openapi, $OPENAPI_CONTENT_TYPE) if $route eq 'openapi';
    return _dispatch($route->[0], $route->[1], $body, $handlers) if ref($route) eq 'ARRAY';
    return _error_response(
        404,
        'route_not_found',
        'Canonical API route not found',
        { method => $method, path => $path },
    );
}

sub _route ($self, $method, $path) {
    my $base = $self->base_path;
    return 'domain' if defined($method) && defined($path)
        && $method eq 'GET' && $path eq "$base/domain";
    return 'openapi' if defined($method) && defined($path)
        && $method eq 'GET' && $path eq "$base/openapi.json";
    return ['query', {}] if defined($method) && defined($path)
        && $method eq 'POST' && $path eq "$base/query";
    return ['write', {}] if defined($method) && defined($path)
        && $method eq 'POST' && $path eq "$base/write";
    my $prefix = "$base/actions/";
    if (defined($method) && defined($path) && $method eq 'POST'
        && index($path, $prefix) == 0) {
        my $action = substr($path, length($prefix));
        return ['action', { action => $action }]
            if $action ne '' && index($action, '/') < 0;
    }
    return 'not_found';
}

sub _dispatch ($operation, $params, $body, $handlers) {
    my $handler = $handlers->{$operation};
    return _error_response(
        501,
        'operation_not_implemented',
        'Canonical API operation is not implemented',
        { operation => $operation },
    ) unless ref($handler) eq 'CODE';

    my $result;
    my $ok = eval { $result = $handler->($body, $params); 1 };
    return _error_response(
        500,
        'handler_failed',
        'Canonical API handler failed',
        { operation => $operation },
    ) unless $ok;

    return _error_response(
        500,
        'invalid_handler_result',
        'Canonical API handler returned an invalid result',
    ) unless ref($result) eq 'ARRAY' && @$result == 2
        && ($result->[0] eq 'ok' || $result->[0] eq 'error');

    return _success($result->[1]) if $result->[0] eq 'ok';
    my $error = $result->[1];
    return _error_response(
        500,
        'invalid_handler_result',
        'Canonical API handler returned an invalid result',
    ) unless ref($error) eq 'HASH';

    return _error_response(
        _error_integer($error, 'status', 422),
        _error_string($error, 'code', 'operation_rejected'),
        _error_string($error, 'message', 'Canonical API operation rejected'),
        ref($error->{details}) eq 'HASH' ? $error->{details} : {},
    );
}

sub canonical_json ($value) {
    _validate_canonical_value($value, '$');
    return JSON::PP->new
        ->allow_nonref(1)
        ->ascii(0)
        ->canonical(1)
        ->utf8(1)
        ->encode($value);
}

sub _validate_canonical_value ($value, $path) {
    return unless defined $value;
    if (blessed($value)) {
        return if JSON::PP::is_bool($value);
        Selecto::Error->throw(
            'non_canonical_value',
            'blessed values are outside Selecto Canonical JSON v1',
            { path => $path, type => ref($value) },
        );
    }
    if (ref($value) eq 'HASH') {
        for my $key (keys %$value) {
            _validate_canonical_value($value->{$key}, "$path\[$key\]");
        }
        return;
    }
    if (ref($value) eq 'ARRAY') {
        for my $index (0 .. $#$value) {
            _validate_canonical_value($value->[$index], "$path\[$index\]");
        }
        return;
    }
    Selecto::Error->throw(
        'non_canonical_value',
        'references are outside Selecto Canonical JSON v1',
        { path => $path, type => ref($value) },
    ) if ref($value);
    # Perl scalars can be numeric-looking strings while still carrying an
    # intentional JSON string type (notably exact NUMERIC/DECIMAL values from
    # DBI adapters). Use JSON::PP's scalar typing decision before rejecting a
    # native non-integer number from Canonical JSON v1.
    my $encoded_scalar = JSON::PP->new->allow_nonref(1)->encode($value);
    if ($encoded_scalar !~ /\A"/
        && looks_like_number($value)
        && "$value" !~ /\A-?(?:0|[1-9][0-9]*)\z/) {
        Selecto::Error->throw(
            'non_canonical_value',
            'floats are outside Selecto Canonical JSON v1',
            { path => $path },
        );
    }
    return;
}

sub _success ($data, $status = 200) {
    return _response($status, { data => $data, ok => JSON::PP::true }, $JSON_CONTENT_TYPE);
}

sub _error_response ($status, $code, $message, $details = {}) {
    return _response($status, {
        error => { code => $code, details => $details, message => $message },
        ok => JSON::PP::false,
    }, $JSON_CONTENT_TYPE);
}

sub _response ($status, $value, $content_type) {
    my $body;
    my $ok = eval { $body = canonical_json($value); 1 };
    unless ($ok) {
        $status = 500;
        $content_type = $JSON_CONTENT_TYPE;
        $body = '{"error":{"code":"non_canonical_value","details":{},'
            . '"message":"Response contains a value outside Selecto Canonical JSON v1"},'
            . '"ok":false}';
    }
    return {
        status => $status,
        headers => {
            'content-length' => '' . length($body),
            'content-type' => $content_type,
        },
        body => $body,
    };
}

sub _domain_identity ($domain) {
    my $identity = {
        fingerprint => $domain->{domain_fingerprint},
        name => $domain->{name},
        schema_version => $domain->{schema_version},
        version => $domain->{domain_version},
    };
    Selecto::Error->throw(
        'canonical_api_requires_domain_identity',
        'canonical API hosting requires complete domain identity',
    ) unless defined($identity->{fingerprint}) && !ref($identity->{fingerprint})
        && $identity->{fingerprint} ne ''
        && defined($identity->{name}) && !ref($identity->{name}) && $identity->{name} ne ''
        && defined($identity->{schema_version}) && !ref($identity->{schema_version})
        && "$identity->{schema_version}" =~ /\A[1-9][0-9]*\z/
        && defined($identity->{version}) && !ref($identity->{version})
        && $identity->{version} ne '';
    $identity->{schema_version} = int($identity->{schema_version});
    return $identity;
}

sub _normalize_base_path ($path) {
    Selecto::Error->throw('invalid_canonical_api_path', 'canonical API path must be a string')
        if !defined($path) || ref($path);
    $path =~ s{/+\z}{};
    Selecto::Error->throw('invalid_canonical_api_path', 'canonical API path is invalid')
        if $path eq '' || index($path, '/') != 0
        || index($path, '?') >= 0 || index($path, '#') >= 0 || index($path, '//') >= 0;
    return $path;
}

sub _routes ($base_path) {
    return [
        { method => 'GET', operation_id => 'getDomain', path => "$base_path/domain" },
        { method => 'GET', operation_id => 'getOpenApi', path => "$base_path/openapi.json" },
        { method => 'POST', operation_id => 'queryDomain', path => "$base_path/query" },
        { method => 'POST', operation_id => 'writeDomain', path => "$base_path/write" },
        {
            method => 'POST',
            operation_id => 'executeAction',
            path => "$base_path/actions/{action}",
        },
    ];
}

sub _manifest ($identity, $base_path) {
    return {
        canonical_json => $CANONICAL_JSON,
        domain => $identity,
        format => 'selecto.canonical-domain-api',
        format_version => 1,
        routes => _routes($base_path),
    };
}

sub _openapi ($identity, $base_path) {
    my %paths;
    for my $route (@{_routes($base_path)}) {
        my $operation = {
            operationId => $route->{operation_id},
            responses => {
                200 => { description => _response_description($route->{operation_id}) },
            },
        };
        if ($route->{operation_id} eq 'executeAction') {
            $operation->{parameters} = [{
                in => 'path',
                name => 'action',
                required => JSON::PP::true,
                schema => { type => 'string' },
            }];
        }
        $paths{$route->{path}} = { lc($route->{method}) => $operation };
    }
    return {
        info => { title => $identity->{name}, version => $identity->{version} },
        jsonSchemaDialect => 'https://json-schema.org/draft/2020-12/schema',
        openapi => '3.1.0',
        paths => \%paths,
        'x-selecto' => {
            canonicalJson => $CANONICAL_JSON,
            domainFingerprint => $identity->{fingerprint},
            domainSchemaVersion => $identity->{schema_version},
            domainVersion => $identity->{version},
        },
    };
}

sub _response_description ($operation_id) {
    return 'Canonical domain' if $operation_id eq 'getDomain';
    return 'OpenAPI document' if $operation_id eq 'getOpenApi';
    return 'Canonical response';
}

sub _error_integer ($value, $key, $default) {
    my $candidate = $value->{$key};
    return $default if !defined($candidate) || ref($candidate)
        || "$candidate" !~ /\A[1-9][0-9]*\z/;
    return int($candidate);
}

sub _error_string ($value, $key, $default) {
    my $candidate = $value->{$key};
    return defined($candidate) && !ref($candidate) && $candidate ne '' ? "$candidate" : $default;
}

1;
