package Selecto::API;

use 5.034;
use utf8;
use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);
use Selecto::API::ResultFormatter ();
use Selecto::API::ResponsePolicy ();
use Selecto::Limits ();
use Selecto::Domain ();
use Selecto::Error ();

our $CANONICAL_JSON = 'selecto.canonical-json.v1';
our $DEFAULT_PATH = '/api/v1/selecto';
our $JSON_CONTENT_TYPE = 'application/json; charset=utf-8';
our $OPENAPI_CONTENT_TYPE = 'application/vnd.oai.openapi+json;version=3.1';

has [qw(domain base_path manifest openapi)];
has limits => sub { Selecto::Limits->new };
has debug_sql => 0;
has publish_domain => 0;
has resources => 0;

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    Selecto::Error->throw('invalid_api_host', 'API limits must be a Selecto::Limits')
        unless blessed($self->limits) && $self->limits->isa('Selecto::Limits');
    for my $name (qw(debug_sql publish_domain)) {
        my $option = $self->$name;
        Selecto::Error->throw('invalid_api_host', "$name must be a trusted boolean or callback")
            unless ref($option) eq 'CODE' || (!ref($option) && defined($option) && "$option" =~ /\A[01]\z/);
    }
    Selecto::Error->throw('invalid_api_host', 'resources must be a boolean')
        unless !ref($self->resources) && defined($self->resources)
            && "@{[$self->resources]}" =~ /\A[01]\z/;
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
    $self->manifest(_manifest($identity, $base_path, $self->resources));
    $self->openapi(_openapi($identity, $base_path, $self->resources));
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
    if (ref($route) eq 'ARRAY' && $route->[0] eq 'resource') {
        $route->[1]{fields} = $request->{fields} if defined $request->{fields};
        $route->[1]{date_format} = $request->{date_format} if defined $request->{date_format};
    }
    if ($route eq 'domain') {
        return _error_response(403, 'domain_publication_denied',
            'Full domain publication is not enabled for this request')
            unless $self->_permits('publish_domain', $request);
        return _error_response(422, 'api_result_limit_exceeded', 'The response exceeds its resource limit')
            unless eval { Selecto::API::ResponsePolicy->check_json($self->domain, $self->limits); 1 };
        return $self->_bounded_response(_response(200, $self->domain, $JSON_CONTENT_TYPE), $self->limits);
    }
    return _response(200, $self->openapi, $OPENAPI_CONTENT_TYPE) if $route eq 'openapi';
    return $self->_dispatch($route->[0], $route->[1], $body, $request, $handlers)
        if ref($route) eq 'ARRAY';
    return _error_response(
        404,
        'route_not_found',
        'Canonical API route not found',
        { method => $method, path => $path },
    );
}

sub _permits ($self, $name, $request) {
    my $option = $self->$name;
    return $option ? 1 : 0 unless ref($option) eq 'CODE';
    my $granted = eval { $option->($request) };
    return !$@ && defined($granted) && !ref($granted) && "$granted" eq '1' ? 1 : 0;
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
    if ($self->resources && defined($method) && defined($path) && $method eq 'GET'
        && index($path, "$base/resources/") == 0) {
        my $id = substr($path, length("$base/resources/"));
        return ['resource', { id => $id }] if $id ne '' && index($id, '/') < 0;
    }
    my $prefix = "$base/actions/";
    if (defined($method) && defined($path) && $method eq 'POST'
        && index($path, $prefix) == 0) {
        my $action = substr($path, length($prefix));
        return ['action', { action => $action }]
            if $action ne '' && index($action, '/') < 0;
    }
    return 'not_found';
}

sub _dispatch ($self, $operation, $params, $body, $request, $handlers) {
    my $format;
    my $format_ok = eval {
        $format = Selecto::API::ResultFormatter->negotiate(
            $request->{response_format}, $request->{accept},
        );
        1;
    };
    unless ($format_ok) {
        my $error = $@;
        return _error_response(
            blessed($error) && $error->isa('Selecto::Error')
                && $error->code eq 'response_format_not_acceptable' ? 406 : 400,
            blessed($error) && $error->isa('Selecto::Error')
                ? $error->code : 'invalid_response_format',
            blessed($error) && $error->isa('Selecto::Error')
                ? $error->message : 'Response format is invalid',
            blessed($error) && $error->isa('Selecto::Error')
                ? $error->details : {},
        );
    }
    if ($operation ne 'query' && $format ne 'json') {
        return _error_response(
            406, 'response_format_not_acceptable',
            'CSV, TSV, and XLSX responses are available only for queries',
            {operation => $operation, format => $format},
        );
    }
    my $download_filename;
    if (defined $request->{download_filename} && "$request->{download_filename}" ne '') {
        my $filename_ok = eval {
            $download_filename = _validate_download_filename(
                $request->{download_filename}, $format,
            );
            1;
        };
        unless ($filename_ok) {
            my $error = $@;
            return _error_response(
                400,
                blessed($error) && $error->isa('Selecto::Error')
                    ? $error->code : 'invalid_response_filename',
                blessed($error) && $error->isa('Selecto::Error')
                    ? $error->message : 'Response filename is invalid',
                blessed($error) && $error->isa('Selecto::Error')
                    ? $error->details : {},
            );
        }
    }
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

    if ($result->[0] eq 'ok') {
        my $limits = Selecto::API::ResponsePolicy->limits_for($result->[1], $self->limits);
        my $data;
        my $safe = eval {
            $data = Selecto::API::ResponsePolicy->public_data(
                $result->[1], $self->_permits('debug_sql', $request), $limits);
            1;
        };
        return _error_response(422, 'api_result_limit_exceeded',
            'The response exceeds its resource limit') unless $safe;
        return _query_success($self, $data, $format, $download_filename, $limits)
            if $operation eq 'query';
        my $response = $self->_bounded_success($data, $limits);
        # A resource's aggregate version doubles as its entity tag.
        $response->{headers}{etag} = qq{"$data->{aggregate_version}"}
            if $operation eq 'resource' && $response->{status} == 200 && ref($data) eq 'HASH'
                && defined($data->{aggregate_version}) && !ref($data->{aggregate_version})
                && $data->{aggregate_version} =~ /\A[\x21\x23-\x7e]+\z/;
        return $response;
    }
    my $error = $result->[1];
    return _error_response(
        500,
        'invalid_handler_result',
        'Canonical API handler returned an invalid result',
    ) unless ref($error) eq 'HASH';

    my $debug = $self->_permits('debug_sql', $request);
    my $details = eval { Selecto::API::ResponsePolicy->error_details(
        $error->{details}, $debug, $self->limits) } // {};
    my $code = _error_string($error, 'code', 'operation_rejected');
    $code = 'operation_rejected' unless $code =~ /\A[a-z][a-z0-9_]{0,127}\z/;
    my $response = {
        error => {
            code => $code, details => $details,
            message => $debug ? _error_string($error, 'message', 'Canonical API operation rejected')
                : 'Canonical API operation rejected',
        }, ok => JSON::PP::false,
    };
    return _error_response(422, 'api_result_limit_exceeded', 'The response exceeds its resource limit')
        unless eval { Selecto::API::ResponsePolicy->check_json($response, $self->limits); 1 };
    return _error_response(
        _error_integer($error, 'status', error_status($code)),
        $code,
        $debug ? _error_string($error, 'message', 'Canonical API operation rejected')
            : 'Canonical API operation rejected',
        $details,
    );
}

sub _bounded_success ($self, $data, $limits) {
    return _error_response(422, 'api_result_limit_exceeded', 'The response exceeds its resource limit')
        unless eval { Selecto::API::ResponsePolicy->check_json({data => $data, ok => JSON::PP::true}, $limits); 1 };
    return $self->_bounded_response(_success($data), $limits);
}

sub _bounded_response ($self, $response, $limits) {
    return _error_response(422, 'api_result_limit_exceeded',
        'The response exceeds its resource limit')
        if length($response->{body}) > $limits->get('max_response_bytes');
    return $response;
}

sub _query_success ($self, $data, $format, $download_filename = undef, $limits = undef) {
    $limits //= $self->limits;
    my $response;
    if ($format eq 'json') {
        $response = $self->_bounded_success($data, $limits);
    } else {
        my $body;
        my $ok = eval {
            $body = Selecto::API::ResultFormatter->encode_result($format, $data, limits => $limits);
            1;
        };
        unless ($ok) {
            my $error = $@;
            return _error_response(422, 'api_result_limit_exceeded',
                'The response exceeds its resource limit')
                if blessed($error) && $error->isa('Selecto::Error')
                    && $error->code eq 'api_result_limit_exceeded';
            return _error_response(
                500, 'response_encoding_failed',
                'The query succeeded but its requested response could not be encoded',
            );
        }
        my $specification = Selecto::API::ResultFormatter->specification($format);
        my $filename = $download_filename
            // _download_filename($self->domain->{name}, $specification->{extension});
        $response = {
            status => 200,
            headers => {
                'content-disposition' => qq{attachment; filename="$filename"},
                'content-length' => '' . length($body),
                'content-type' => $specification->{content_type},
                'x-content-type-options' => 'nosniff',
            },
            body => $body,
        };
    }
    $response->{headers}{vary} = 'Accept';
    return $self->_bounded_response($response, $limits);
}

sub _validate_download_filename ($filename, $format) {
    Selecto::Error->throw(
        'invalid_response_filename',
        'download filename is available only for CSV, TSV, and XLSX responses',
        {format => $format},
    ) if $format eq 'json';
    my $extension = Selecto::API::ResultFormatter->specification($format)->{extension};
    Selecto::Error->throw(
        'invalid_response_filename',
        "download filename must be a safe filename ending in .$extension",
        {expected_extension => ".$extension"},
    ) if ref($filename)
        || length("$filename") > 160
        || "$filename" !~ /\A[A-Za-z0-9][A-Za-z0-9._ ()-]*\.\Q$extension\E\z/i
        || "$filename" =~ /\.\./;
    return "$filename";
}

sub _download_filename ($name, $extension) {
    $name = lc($name // 'selecto');
    $name =~ s/[^a-z0-9]+/-/g;
    $name =~ s/\A-+|-+\z//g;
    $name = 'selecto' unless length $name;
    return "$name-query.$extension";
}

# The HTTP status for a handler error that names none: a query naming a hidden
# (internal or redacted) field and a request without a trusted tenant scope
# are forbidden, as in the other runtimes; every other refusal is 422.
my %FORBIDDEN_CODES = map { $_ => 1 } qw(hidden_field missing_tenant_scope);

sub error_status ($code) {
    return 404 if defined($code) && !ref($code) && $code eq 'resource_not_found';
    return defined($code) && !ref($code) && $FORBIDDEN_CODES{$code} ? 403 : 422;
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
    # The affected-row count of a rolled-back write tells a client how many
    # rows matched a predicate it could not otherwise run, so it stays
    # server-side.
    if ($code eq 'cardinality_mismatch' && ref($details) eq 'HASH' && exists $details->{actual}) {
        $details = { %$details };
        delete $details->{actual};
    }
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

sub _routes ($base_path, $resources = 0) {
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
        ($resources
            ? { method => 'GET', operation_id => 'getResource', path => "$base_path/resources/{id}" }
            : ()),
    ];
}

sub _manifest ($identity, $base_path, $resources = 0) {
    return {
        canonical_json => $CANONICAL_JSON,
        domain => $identity,
        format => 'selecto.canonical-domain-api',
        format_version => 1,
        routes => _routes($base_path, $resources),
    };
}

sub _openapi ($identity, $base_path, $resources = 0) {
    my %paths;
    for my $route (@{_routes($base_path, $resources)}) {
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
        if ($route->{operation_id} eq 'getResource') {
            $operation->{summary} = 'Read one resource by primary key';
            $operation->{parameters} = [
                { in => 'path', name => 'id', required => JSON::PP::true, schema => { type => 'string' } },
                {
                    in => 'query', name => 'fields', required => JSON::PP::false,
                    description => 'Comma-separated public scalar or to-one field paths. The primary '
                        . 'key is always returned. Request aggregate_version, when the domain '
                        . 'publishes it, for the resource version and its ETag. Temporal fields '
                        . 'are returned in the date_format.',
                    style => 'form', explode => JSON::PP::false,
                    schema => { type => 'array', items => { type => 'string' } },
                },
                {
                    in => 'query', name => 'date_format', required => JSON::PP::false,
                    description => 'Format of every temporal field, in UTC. iso8601 (default): '
                        . 'YYYY-MM-DDTHH:MM:SSZ for instants, YYYY-MM-DDTHH:MM:SS for naive '
                        . 'datetimes, YYYY-MM-DD for dates. rfc3339_millis: '
                        . 'YYYY-MM-DDTHH:MM:SS.sssZ. epoch_seconds, epoch_milliseconds: integers '
                        . 'since 1970-01-01T00:00:00Z, rounded down. Except under iso8601, a naive '
                        . 'datetime is read as UTC and a date as midnight UTC. Null stays null.',
                    schema => { type => 'string', enum => [qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds)],
                        default => 'iso8601' },
                },
            ];
            $operation->{responses}{200}{headers} = {
                ETag => { description => 'The aggregate version, when requested', schema => { type => 'string' } },
            };
            $operation->{responses}{404} = { description => 'Resource unavailable' };
        }
        if ($route->{operation_id} eq 'queryDomain') {
            $operation->{parameters} = Selecto::API::ResultFormatter->openapi_parameters;
            $operation->{responses}{200}{content} =
                Selecto::API::ResultFormatter->openapi_content;
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
    return 'Resource' if $operation_id eq 'getResource';
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

__END__

=head1 NAME

Selecto::API - HTTP-neutral host for the canonical Selecto API

=head1 SYNOPSIS

  use Selecto::API;
  use Selecto::API::EngineHandler;

  my $api = Selecto::API->new(domain => $domain, base_path => '/api/v1/orders');
  my $handler = Selecto::API::EngineHandler->new;
  $handler->describe_openapi($api);

  # In your framework's route for "$base_path/*":
  my $response = $api->request(
      {
          method            => $request_method,          # 'GET' or 'POST'
          path              => $request_path,
          body              => $decoded_json_body,        # hash or undef
          accept            => $accept_header,            # optional
          response_format   => $query_param_format,       # optional: json csv tsv xlsx
          download_filename => $query_param_filename,     # optional
      },
      {
          query => sub { my ($body) = @_; ... return ['ok', $data] },
          write => sub { my ($body) = @_; ... return ['ok', $data] },
          action => sub { my ($body, $params) = @_; ... },  # $params->{action}
      },
  );
  # $response = {status => 200, headers => {...}, body => $bytes}

=head1 DESCRIPTION

C<Selecto::API> implements the routing, content negotiation and byte-stable
encoding of the canonical Selecto HTTP contract without depending on any web
framework. It is a pure function from a request hash to a response hash;
your framework supplies the method, path and decoded body and sends back the
status, headers and body it returns.

The object never touches a database. Query and write work is delegated to
the handler callbacks you pass to L</request>, normally thin wrappers around
L<Selecto::API::EngineHandler> using an engine built from the authenticated
request.

=head1 ROUTES

Relative to C<base_path> (default C</api/v1/selecto>):

  GET  /domain          the canonical domain contract (JSON)
  GET  /openapi.json    the OpenAPI 3.1 document
  POST /query           handlers->{query}
  POST /write           handlers->{write}
  POST /actions/NAME    handlers->{action}, with {action => NAME}
  GET  /resources/ID    handlers->{resource}, with {id => ID, fields => ...,
                        date_format => ...}
                        (only when constructed with resources => 1)

Unknown routes return 404 C<route_not_found>; a route without a handler
returns 501 C<operation_not_implemented>.

=head1 METHODS

=head2 new

  my $api = Selecto::API->new(domain => $domain, base_path => '/api/v1/orders');

C<domain> must be a canonical L<Selecto::Domain> whose contract includes
C<name>, C<schema_version>, C<domain_version> and C<domain_fingerprint>
(C<canonical_api_requires_domain_contract>,
C<canonical_api_requires_domain_identity>). After construction C<domain>
holds the contract hash, and C<manifest> and C<openapi> hold the generated
documents.

C<< resources => 1 >> adds the C<getResource> route, C<GET .../resources/{id}>.
Pass the request's C<fields> query parameter (a comma-separated string or an
array) as C<fields>, and its C<date_format> query parameter as C<date_format>,
in L</request>; the handler receives them with the C<id>. C<date_format>
(C<iso8601>, the default, C<rfc3339_millis>, C<epoch_seconds> or
C<epoch_milliseconds>) formats every temporal field in UTC; see
L<Selecto::API::EngineHandler/resource>.
L<Selecto::API::EngineHandler/resource> implements the handler. When the
resource's data has a scalar C<aggregate_version>, the response carries it,
quoted, as its C<ETag>.

=head2 request

  my $response = $api->request(\%request, \%handlers);

Routes the request and returns C<< {status => ..., headers => {...}, body => $bytes} >>.
The body is UTF-8 encoded bytes; C<content-length> is exact.

A handler returns C<['ok', $data]> or C<['error', \%error]>, where
C<%error> may contain C<status> (default L</error_status> of the code: 403
for C<hidden_field> and C<missing_tenant_scope>, otherwise 422), C<code>,
C<message> and C<details>.
If a handler dies, the response is a 500 C<handler_failed> without the
exception text, so convert expected L<Selecto::Error>s into
C<['error', ...]> yourself:

  my $guard = sub {
      my ($code) = @_;
      my $data = eval { $code->() };
      return ['ok', $data] unless $@;
      my $e = $@;
      die $e unless blessed($e) && $e->isa('Selecto::Error');
      return ['error', {status => Selecto::API::error_status($e->code), code => $e->code,
          message => $e->message, details => $e->details}];
  };

Successful JSON responses are C<< {"ok": true, "data": ...} >> and errors
C<< {"ok": false, "error": {"code", "message", "details"}} >>, encoded as
canonical JSON (sorted keys, fixed escaping). Canonical JSON has no floating
point numbers: exact decimals must be strings, and a float anywhere in a
handler result produces a 500 C<non_canonical_value>.

=head2 Response formats

Query responses default to JSON. Pass the C<Accept> header as C<accept>, or
an explicit C<?format=> value as C<response_format> (which wins), to get
C<csv>, C<tsv> or C<xlsx>. CSV and TSV start with a header row, end every
row with CRLF and encode nested values as canonical JSON cells. A cell that
starts with a tab, CR or LF, or with C<=>, C<+>, C<-> or C<@> after any
leading whitespace, gets a leading C<'>; a cell is quoted when it contains
the separator, a quote, a tab, CR, LF or any non-ASCII character (never for
a space alone). These are the certified C<api_export_rules>. For decimals at
their column scale, have the query handler pass C<< export_scalars => 1 >> to
L<Selecto::API::EngineHandler/query>. XLSX writes text as strings, never
formulas. Other routes answer only JSON (406
C<response_format_not_acceptable>). C<download_filename> must be a safe
basename of at most 160 characters ending in the format's extension.

=head2 openapi_document, manifest

The generated OpenAPI document and the API manifest (domain identity and
route list).

=head2 error_status

  my $status = Selecto::API::error_status($code);

A function (not a method) that returns the HTTP status for a refusal code:
403 for C<hidden_field> (a query names a field the domain withholds) and
C<missing_tenant_scope> (the engine has no trusted tenant boundary for a
C<tenant_field> domain), 404 for C<resource_not_found>, 422 for every
other code. L</request> uses it when
a handler error has no C<status>.

=head2 canonical_json

  my $bytes = Selecto::API::canonical_json($value);

A function (not a method) that encodes a value as Selecto Canonical JSON v1
bytes, throwing C<non_canonical_value> for floats and other values it cannot
represent exactly.

=head2 Host privacy and resource policy

C<debug_sql> and C<publish_domain> default to C<0>. Each accepts a trusted
C<0>/C<1> flag or a callback receiving the host request and returning exactly
C<1> to authorize it. Request parameters do not modify either setting. Callback
exceptions deny access. Default responses omit diagnostic SQL and parameter
metadata and suppress arbitrary handler-error messages and causes. Business rows
and returning values are application data and must not contain host diagnostics.

C<GET .../domain> requires publication authorization and then returns the full
canonical contract. C<limits> accepts a trusted L<Selecto::Limits>; all successful
representations obey C<max_response_bytes>, and XLSX generation additionally
reserves C<max_response_temp_bytes>. Small constant error envelopes may exceed
an unusually tiny successful-response limit.

=head1 SEE ALSO

L<Selecto>, L<Selecto::API::EngineHandler>, L<Selecto::API::ResultFormatter>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
