package Selecto::API::RemoteQuery;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Math::BigInt ();
use DateTime ();
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::API::ResponsePolicy ();
use Selecto::Error ();
use Selecto::Identifier ();
use Selecto::Limits ();

# HTTP-neutral adapter: the host authenticates the request and supplies a fresh
# trusted engine. HTML/HTMX and this adapter share Selecto::BoundedQuery; neither
# a fingerprint nor any client-supplied value grants tenant authority.
has base_path => '/api/v1/selecto';
has publish_domain => 0;
has limits => sub { Selecto::Limits->new };
has max_limit => 1000;
has default_limit => 100;
has field_encodings => sub { {} };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    _reject('internal_failure') unless ref($self->field_encodings) eq 'HASH'
        && !grep { !defined($_) || ref($_) || $_ ne 'decimal-string' }
            values %{$self->field_encodings};
    $self->{handler} = Selecto::API::EngineHandler->new(
        limits => $self->limits, max_limit => $self->max_limit,
        default_limit => $self->default_limit, bounded_results => 1,
    );
    _reject('internal_failure') unless $self->max_limit >= 1 && $self->default_limit >= 1;
    return $self;
}

sub request ($self, $engine, $request) {
    my $response;
    my $ok = eval {
        _reject('internal_failure') unless blessed($engine) && $engine->isa('Selecto::Engine');
        _reject('malformed_request') unless ref($request) eq 'HASH';
        my $api = Selecto::API->new(domain => $engine->domain,
            base_path => $self->base_path, limits => $self->limits->intersect($engine->limits),
            publish_domain => $self->publish_domain);
        my ($method, $path) = @{$request}{qw(method path)};
        if (defined($method) && defined($path) && $method eq 'GET'
            && ($path eq $self->base_path || $path eq $self->base_path . '/')) {
            $response = _response(200, {%{$api->manifest}, profiles => ['remote_query.v1'],
                routes => [grep { $_->{operation_id} =~ /\A(?:getDomain|getOpenApi|queryDomain)\z/ }
                    @{$api->manifest->{routes}}],
                query_capabilities => {explicit_root_select => JSON::PP::true,
                    filters => [qw(eq ne gt gte lt lte is_null is_not_null)],
                    nested => JSON::PP::false, aggregates => JSON::PP::false,
                    recursive_filters => JSON::PP::false}});
        } elsif (defined($method) && defined($path) && $method eq 'POST'
            && $path eq $self->base_path . '/query') {
            my $type = $request->{content_type} // '';
            _reject('unsupported_media_type') unless !ref($type)
                && $type =~ m{\Aapplication/json(?:\s*;[^\r\n]*)?\z}i;
            $response = _response(200, $self->query($engine, $request->{body}));
        } else {
            $response = $api->request($request);
        }
        1;
    };
    return $response if $ok;
    my $error = $@;
    my $code = blessed($error) && $error->isa('Selecto::Error') ? $error->code : 'internal_failure';
    my %map = (field_not_public => 'hidden_field', unknown_field => 'invalid_field',
        invalid_field => 'invalid_field', invalid_api_query => 'invalid_query',
        invalid_query => 'invalid_query', unsupported_feature => 'operation_unsupported',
        tenant_scope_required => 'operation_forbidden', missing_tenant_scope => 'operation_forbidden',
        tenant_mismatch => 'operation_forbidden',
        query_timeout => 'query_timeout', result_limit_exceeded => 'invalid_query',
        api_result_limit_exceeded => 'invalid_query');
    $code = $map{$code} // $code;
    my %status = (malformed_request => 400, unsupported_protocol_version => 400,
        unsupported_media_type => 415, stale_domain_fingerprint => 409,
        hidden_field => 403, operation_forbidden => 403, invalid_field => 422,
        invalid_query => 422, operation_unsupported => 501, query_timeout => 504);
    $code = 'internal_failure' unless exists($status{$code});
    my $body = {ok => JSON::PP::false,
        error => {code => $code, message => 'Query request could not be completed.', details => {}}};
    my $id = ref($request) eq 'HASH' && ref($request->{body}) eq 'HASH'
        ? $request->{body}{request_id} : undef;
    $body->{meta} = {request_id => $id} if _request_id($id);
    return _response($status{$code} // 500, $body);
}

sub query ($self, $engine, $body) {
    _object($body, [qw(format format_version domain query request_id)], 'malformed_request');
    _reject('malformed_request') unless ($body->{format} // '') eq 'selecto.remote-query';
    _reject('unsupported_protocol_version') unless _integer($body->{format_version})
        && $body->{format_version} == 1;
    _object($body->{domain}, ['fingerprint'], 'malformed_request');
    _reject('malformed_request') unless defined($body->{domain}{fingerprint})
        && !ref($body->{domain}{fingerprint}) && length($body->{domain}{fingerprint});
    _reject('malformed_request') if exists($body->{request_id}) && !_request_id($body->{request_id});
    _reject('stale_domain_fingerprint') unless $body->{domain}{fingerprint} eq $engine->domain->fingerprint;
    my $contract = $engine->domain->contract // {};
    # This first wire subset cannot faithfully describe mandatory extra output,
    # grouping or order. Refuse before SQL rather than discard domain policy or
    # discover a different result shape after execution.
    _reject('operation_unsupported') if grep { @{$contract->{$_} // []} }
        qw(required_selected required_group_by required_order_by);
    my $query = $body->{query};
    _object($query, [qw(select projection view segments parameters filters ordering order_by
        group_by limit offset timezone row_format)], 'invalid_query');
    # Rich native HTMX modes retain their public native contracts. This wire
    # adapter advertises only these explicit scalar reads, rather than silently
    # dropping intent that has not acquired a remote-profile admission.
    _reject('operation_unsupported') if grep { exists $query->{$_} }
        qw(projection view segments parameters ordering group_by);
    _reject('invalid_query') unless ref($query->{select}) eq 'ARRAY' && @{$query->{select}};
    my $limits = $self->limits->intersect($engine->limits);
    Selecto::API::ResponsePolicy->check_json($body, $limits);
    my $limit = exists($query->{limit}) ? $query->{limit} : $self->default_limit;
    my $offset = exists($query->{offset}) ? $query->{offset} : 0;
    _reject('invalid_query') unless _integer($limit) && $limit >= 1 && $limit <= $self->max_limit
        && _integer($offset) && $offset <= $self->{handler}->max_offset;
    my $row_format = $query->{row_format} // 'arrays';
    _reject('invalid_query') unless !ref($row_format) && $row_format =~ /\A(?:arrays|objects)\z/;
    my (@columns, %ids);
    for my $selection (@{$query->{select}}) {
        _reject('operation_unsupported') if ref($selection) eq 'ARRAY';
        my ($field, $alias);
        if (ref($selection) eq 'HASH') {
            _object($selection, [qw(field alias format)], 'invalid_query');
            _reject('operation_unsupported') if exists $selection->{format};
            ($field, $alias) = @{$selection}{qw(field alias)};
        } else { $field = $selection; }
        _reject('invalid_query') unless defined($field) && !ref($field) && length($field);
        my $definition = $engine->domain->resolve($field);
        _reject('hidden_field') unless $engine->domain->field_is_public($field);
        my $id = defined($alias) ? $alias : Selecto::Identifier::result_name($field);
        _reject('invalid_query') unless !ref($id) && Selecto::Identifier::valid($id) && !$ids{$id}++;
        my $type = $definition->{type};
        $type = 'string' if $type eq 'text';
        $type = 'decimal' if $type eq 'numeric';
        _reject('operation_unsupported') unless $type =~ /\A(?:integer|decimal|string|boolean|date)\z/;
        my $encoding = $type eq 'decimal' ? 'decimal-string'
            : $type eq 'integer' || $type eq 'boolean' ? 'json' : 'string';
        $encoding = 'decimal-string' if $type eq 'integer' && exists $self->field_encodings->{$field};
        my $metadata = $engine->domain->field_metadata($field);
        push @columns, {id => $id, field => $field, label => $id, type => $type,
            encoding => $encoding, nullable => exists($metadata->{nullable}) && !$metadata->{nullable}
                ? JSON::PP::false : JSON::PP::true};
    }
    my @filters;
    _reject('invalid_query') if exists($query->{filters}) && ref($query->{filters}) ne 'ARRAY';
    for my $filter (@{$query->{filters} // []}) {
        _object($filter, [qw(field op value end)], 'invalid_query');
        my $op = $filter->{op};
        _reject('invalid_query') unless defined($op) && !ref($op);
        _reject('operation_unsupported') unless $op =~ /\A(?:eq|ne|gt|gte|lt|lte|is_null|is_not_null)\z/;
        _reject('invalid_query') if exists($filter->{end})
            || ($op =~ /null\z/ ? exists($filter->{value}) : !exists($filter->{value}));
        push @filters, {%$filter, op => $op eq 'is_not_null' ? 'not_null' : $op};
    }
    # The shared handler establishes has_more with one bounded lookahead row.
    my $handler = Selecto::API::EngineHandler->new(limits => $limits,
        bounded_results => 1, max_limit => $self->max_limit,
        default_limit => $self->default_limit, max_orders => $self->{handler}->max_orders + 1);
    _reject('invalid_query') if exists($query->{order_by}) && ref($query->{order_by}) ne 'ARRAY';
    my @orders = @{$query->{order_by} // []};
    _reject('invalid_query') if @orders > $self->{handler}->max_orders;
    my $key = $engine->domain->primary_key;
    _reject('operation_unsupported') unless defined($key) && $engine->domain->field_is_public($key);
    # Preserve caller order, including an explicit descending PK, and finish
    # nonunique sorts with the public root key for stable offset pages.
    push @orders, {field => $key, direction => 'asc'} unless grep {
        ref($_) eq 'HASH' && defined($_->{field}) && !ref($_->{field}) && $_->{field} eq $key
    } @orders;
    my $result = $handler->query($engine, {%$query, filters => \@filters, order_by => \@orders,
        row_format => 'arrays', limit => $limit, offset => $offset});
    _reject('internal_failure') unless @{$result->{columns}} == @columns
        && !grep { $result->{columns}[$_] ne $columns[$_]{id} } 0 .. $#columns;
    my @rows = @{$result->{rows}};
    my $more = $result->{has_more};
    for my $i (0 .. $#columns) {
        my $column = $columns[$i];
        if ($column->{type} eq 'integer' && grep { defined($_->[$i])
            && Math::BigInt->new('' . $_->[$i])->babs->bcmp('9007199254740991') > 0 } @rows) {
            $column->{encoding} = 'decimal-string';
        }
        for my $row (@rows) { $row->[$i] = _scalar($row->[$i], $column); }
    }
    if ($row_format eq 'objects') {
        @rows = map { my %row; @row{map { $_->{id} } @columns} = @$_; \%row } @rows;
    }
    my $answer = {ok => JSON::PP::true, data => {
        format => 'selecto.remote-query-result', format_version => 1,
        domain => {fingerprint => $engine->domain->fingerprint}, columns => \@columns,
        rows => \@rows, row_count => scalar(@rows), row_format => $row_format,
        page => {limit => 0 + $limit, offset => 0 + $offset,
            has_more => $more ? JSON::PP::true : JSON::PP::false},
    }};
    $answer->{meta} = {request_id => $body->{request_id}} if exists $body->{request_id};
    Selecto::API::ResponsePolicy->check_json($answer, $limits);
    return $answer;
}

sub explorer_metadata ($self, $engine, %options) {
    my ($id, $publication, $fields) = @options{qw(id publication fields)};
    _reject('internal_failure') unless defined($id) && !ref($id) && length($id)
        && defined($publication) && !ref($publication) && length($publication)
        && ref($fields) eq 'ARRAY' && @$fields;
    my @fields;
    for my $field (@$fields) {
        _reject('hidden_field') unless $engine->domain->field_is_public($field);
        my $definition = $engine->domain->resolve($field);
        my $metadata = $engine->domain->field_metadata($field);
        my $type = $definition->{type};
        $type = 'string' if $type eq 'text';
        $type = 'decimal' if $type eq 'numeric';
        _reject('operation_unsupported') unless $type =~ /\A(?:integer|decimal|string|boolean|date)\z/;
        push @fields, {id => 'source.' . $field, path => $field,
            label => $metadata->{label} // $field, type => $type,
            encoding => $type eq 'decimal' || exists($self->field_encodings->{$field}) ? 'decimal-string'
                : $type eq 'integer' || $type eq 'boolean' ? 'json' : 'string',
            nullable => exists($metadata->{nullable}) && !$metadata->{nullable} ? JSON::PP::false : JSON::PP::true};
    }
    return {format => 'selecto.explorer-metadata', format_version => 1,
        domain => {id => $id, fingerprint => $engine->domain->fingerprint, publication => $publication},
        label => $options{label} // $id, fields => \@fields,
        default_select => [map { $_->{id} } @fields],
        query => {profile => 'remote_query.v1', operators => [qw(eq ne gt gte lt lte is_null is_not_null)],
            limits => {max_limit => 0 + $self->max_limit, max_offset => 0 + $self->{handler}->max_offset,
                max_filters => 0 + $self->{handler}->max_filters},
            supports => {detail => JSON::PP::true, nested => JSON::PP::false,
                recursive_filters => JSON::PP::false, aggregates => JSON::PP::false}}, services => {}};
}

sub _scalar ($value, $column) {
    unless (defined $value) {
        _reject('internal_failure') unless $column->{nullable};
        return undef;
    }
    _reject('internal_failure') if ref($value) && !JSON::PP::is_bool($value);
    my $type = $column->{type};
    if ($type eq 'integer') {
        _reject('internal_failure') unless !ref($value) && "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/;
        return "$value" if $column->{encoding} eq 'decimal-string';
        return 0 + $value;
    }
    if ($type eq 'decimal') {
        _reject('internal_failure') unless !ref($value) && "$value" =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/;
        return "$value";
    }
    if ($type eq 'boolean') {
        return $value ? JSON::PP::true : JSON::PP::false if JSON::PP::is_bool($value);
        _reject('internal_failure') unless "$value" =~ /\A[01]\z/;
        return $value ? JSON::PP::true : JSON::PP::false;
    }
    if ($type eq 'date') {
        _reject('internal_failure') unless "$value" =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/;
        my $valid = eval { DateTime->new(year => $1, month => $2, day => $3); 1 };
        _reject('internal_failure') unless $valid;
    }
    return "$value";
}

sub _integer ($value) {
    return 0 if !defined($value) || ref($value);
    return JSON::PP->new->allow_nonref->encode($value) =~ /\A(?:0|[1-9][0-9]*)\z/;
}
sub _request_id ($value) {
    return defined($value) && !ref($value) && length($value) >= 1 && length($value) <= 128;
}
sub _object ($value, $allowed, $code) {
    _reject($code) unless ref($value) eq 'HASH';
    my %allowed = map { $_ => 1 } @$allowed;
    _reject($code) if grep { !$allowed{$_} } keys %$value;
}
sub _reject ($code) { Selecto::Error->throw($code, 'Query request could not be completed.'); }
sub _response ($status, $body) {
    return {status => $status, content_type => 'application/json; charset=utf-8',
        body => JSON::PP->new->utf8->canonical->encode($body)};
}

1;

=head1 NAME

Selecto::API::RemoteQuery - fingerprint-bound bounded scalar query transport

=head1 DESCRIPTION

Hosts authenticate requests before calling C<request($engine, $request)> with
a fresh trusted engine. The request has C<method>, C<path>, C<content_type> and
decoded C<body>. Root scalar selections, flat comparisons/null predicates,
ordering and positive offset pages use the same bounded native execution as
HTMX explorers. Unsupported richer wire intent is refused before execution.
Full domain publication is disabled by default. The existing bare API remains
available for its existing clients. No profile certification is implied.

=cut
