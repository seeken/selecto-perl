package Selecto::API::NestedDetail;

use Mojo::Base 'Selecto::API::RemoteQuery', -signatures;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode decode FB_CROAK);
use MIME::Base64 qw(decode_base64 encode_base64);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Math::BigInt ();
use Selecto::API::EngineHandler ();
use Selecto::API::ResponsePolicy ();
use Selecto::Limits ();

# Selected, complete typed collections on the existing governed query route.
# Hosts authenticate first, pass a fresh trusted engine, the original body
# bytes and Selecto-Nested-Detail-Context. No request member grants scope.
has [qw(id publication collection root_fields child_fields)];
my $JSON = JSON::PP->new->utf8->canonical->allow_nonref;
my $PROFILE = 'canonical_nested_detail.v1';
my @OPS = qw(eq ne gt gte lt lte is_null is_not_null);
my %LIMITS = (max_request_bytes => 1048576, max_header_ascii_bytes => 8192,
    max_context_token_utf8_bytes => 1024, max_field_id_path_label_utf8_bytes => 256,
    max_request_id_utf8_bytes => 128, default_parent_limit => 25, min_parent_limit => 1,
    max_parent_limit => 25, max_offset => 100000, max_root_fields => 20,
    max_child_fields => 20, max_filters => 20, max_orders => 10, max_collections => 1,
    max_children_per_parent => 20, max_returned_children => 500, max_scalar_utf8_bytes => 16384,
    max_preaggregate_projected_json_bytes => 1048576, max_response_entity_bytes => 262144);

sub features ($self, $engine) {
    my $domain = $engine->domain;
    _text($self->id, 1024); _text($self->publication, 1024);
    my $path = $self->collection;
    _reject('operation_unsupported') unless defined($path) && !ref($path) && $path =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    my $association = $domain->resolve_association($path)->{association};
    _reject('operation_unsupported') unless $association->cardinality eq 'many' && !$association->through;
    my @roots = @{$self->root_fields // [grep { $self->_eligible($domain, $_, 0) && _supported($domain->resolve($_)->{type}) }
        @{$domain->contract->{source}{fields}}]};
    my @children = @{$self->child_fields // [map { "$path.$_" } sort grep {
        $self->_eligible($domain, "$path.$_", 1) && _supported($domain->resolve("$path.$_")->{type})
    } keys %{$association->fields}]};
    _reject('operation_unsupported') unless @roots && @roots <= 20 && @children && @children <= 20;
    my @rf = map { $self->_field($domain, $_, 0) } @roots;
    my @cf = map { _reject('operation_unsupported') unless /^\Q$path\E\.[A-Za-z_][A-Za-z0-9_]*$/;
        $self->_field($domain, $_, 1) } @children;
    my $pk = $domain->primary_key;
    my $cpk = "$path." . ($association->target_primary_key // '');
    for my $pair ([$pk, \@rf], [$cpk, \@cf]) {
        my ($f) = grep { $_->{path} eq ($pair->[0] // '') } @{$pair->[1]};
        _reject('operation_unsupported') unless $f && $f->{type} eq 'integer' && !$f->{nullable};
    }
    my %seen;
    _reject('operation_unsupported') if grep { $seen{$_->{id}}++ || $_->{path} eq $path } (@rf, @cf);
    my $f = {format => 'selecto.nested-detail-features', format_version => 1,
        profile => $PROFILE, wire_profile => 'remote_query.v1', request_format_version => 1,
        result => {format => 'selecto.remote-query-result', format_version => 1},
        domain => {id => $self->id, fingerprint => _fingerprint($engine), publication => $self->publication},
        root_primary_key => $pk, root_fields => \@rf,
        collections => [{id => "collection/$path", path => $path, result_id => $path, label => $path,
            primary_key => $cpk, order_by => [{field => $cpk, direction => 'asc'}], fields => \@cf,
            default_select => [$cpk], limit => 20, complete => JSON::PP::true}],
        defaults => {select => [$pk, [$cpk]], limit => 25, offset => 0, row_format => 'arrays'},
        limits => {%LIMITS}, supports => {optional_domain_pin => JSON::PP::true, row_formats => [qw(arrays objects)], complete_children => JSON::PP::true,
            root_filters => 'flat-and', child_filtering => JSON::PP::false, child_ordering => 'fixed-public-pk-asc',
            root_required_order => JSON::PP::false, root_boolean => JSON::PP::false, partial_children => JSON::PP::false}};
    $f->{revision} = 'sha256:' . sha256_hex($JSON->encode($f));
    _text($_, 1024) for values %{$self->context($f)};
    return $f;
}

sub context ($self, $f) {
    return {profile => $PROFILE, fingerprint => $f->{domain}{fingerprint},
        publication => $f->{domain}{publication}, revision => $f->{revision}};
}

sub _eligible ($self, $domain, $path, $child) {
    return 0 unless $domain->field_is_public($path);
    my $m = $domain->field_metadata($path);
    return !grep { exists($m->{$_}) && !$m->{$_} } ($child ? ('selectable') : qw(selectable filterable sortable));
}

sub _field ($self, $domain, $path, $child) {
    _text($path, 256);
    _reject('operation_unsupported') unless $path =~ ($child ? qr/\A\w+\.\w+\z/ : qr/\A[A-Za-z_]\w*\z/)
        && $self->_eligible($domain, $path, $child);
    my $definition = $domain->resolve($path);
    my $type = $definition->{type};
    $type = 'string' if $type eq 'text'; $type = 'decimal' if $type eq 'numeric';
    _reject('operation_unsupported') unless _supported($type);
    my $m = $domain->field_metadata($path);
    my $label = $m->{label} // $path; _text($label, 256);
    my $encoding = exists($self->field_encodings->{$path}) ? 'decimal-string' : $m->{encoding}
        // ($type eq 'decimal' ? 'decimal-string' : $type eq 'integer' || $type eq 'boolean' ? 'json' : 'string');
    _reject('operation_unsupported') unless $type eq 'integer' ? $encoding =~ /\A(?:json|decimal-string)\z/
        : $encoding eq ($type eq 'decimal' ? 'decimal-string' : $type eq 'boolean' ? 'json' : 'string');
    return {id => $path, path => $path, label => $label, type => $type, encoding => $encoding,
        nullable => $m->{nullable} ? JSON::PP::true : JSON::PP::false,
        ($child ? () : (operators => $type eq 'boolean' ? [qw(eq ne is_null is_not_null)] : [@OPS]))};
}

sub request ($self, $engine, $request) {
    my ($result, $context);
    my $ok = eval {
        _reject('malformed_request') unless ref($request) eq 'HASH';
        my ($method, $path) = @{$request}{qw(method path)};
        my $base = $self->base_path;
        my $header = $request->{nested_detail_context};
        if (ref($request->{headers}) eq 'HASH') {
            my @headers = grep { lc($_) eq 'selecto-nested-detail-context' } keys %{$request->{headers}};
            _reject('malformed_request') if @headers > 1;
            _reject('malformed_request') if @headers && defined($header);
            $header = $request->{headers}{$headers[0]} if @headers;
        }
        if (($method // '') eq 'GET' && ($path // '') eq "$base/nested-detail-features") {
            $result = Selecto::API::RemoteQuery::_response(200, $self->features($engine));
        } elsif (($method // '') eq 'POST' && ($path // '') eq "$base/query" && defined($header)) {
            my $answer = $self->_nested_query($engine, $request, $header, \$context);
            $result = Selecto::API::RemoteQuery::_response(200, $answer);
        } else {
            $result = $self->SUPER::request($engine, $request);
            if (($method // '') eq 'GET' && (($path // '') eq $base || ($path // '') eq "$base/") && $result->{status} == 200) {
                $self->features($engine); # never promise an unusable sidecar
                my $m = $JSON->decode($result->{body});
                push @{$m->{profiles}}, $PROFILE;
                push @{$m->{routes}}, {method => 'GET', path => "$base/nested-detail-features", operation_id => 'getNestedDetailFeatures'};
                $result = Selecto::API::RemoteQuery::_response(200, $m);
            }
        }
        1;
    };
    return $result if $ok;
    my $error = $@;
    my $code = blessed($error) && $error->isa('Selecto::Error') ? $error->code : 'internal_failure';
    my %map = (field_not_public => 'hidden_field', unknown_field => 'invalid_query', unknown_association => 'invalid_query',
        invalid_api_query => 'invalid_query', unsupported_feature => 'operation_unsupported',
        related_collection_limit_exceeded => 'invalid_query', api_result_limit_exceeded => 'invalid_query',
        result_limit_exceeded => 'invalid_query', query_rule_not_evaluable => 'invalid_query',
        tenant_scope_required => 'missing_tenant_scope', tenant_mismatch => 'operation_forbidden');
    $code = $map{$code} // $code;
    my %status = (malformed_request => 400, unsupported_protocol_version => 400, unsupported_media_type => 415,
        stale_domain_fingerprint => 409, stale_nested_detail_context => 409, hidden_field => 403,
        missing_tenant_scope => 403, operation_forbidden => 403, invalid_query => 422, operation_unsupported => 501);
    $code = 'internal_failure' unless exists $status{$code};
    my $answer = {ok => JSON::PP::false, error => {code => $code, message => 'Query request could not be completed.', details => {}}};
    $answer->{meta} = {selecto_nested_detail => $context} if $context;
    return Selecto::API::RemoteQuery::_response($status{$code} // 500, $answer);
}

sub _nested_query ($self, $engine, $request, $header, $admitted) {
    _reject('unsupported_media_type') unless ($request->{content_type} // '') =~ m{\Aapplication/json\s*(?:;\s*charset="?utf-8"?\s*)?\z}i;
    Selecto::API::ResponsePolicy->check_json($request->{body}, $self->limits->tightened(max_response_bytes => 1048576))
        unless exists $request->{raw_body};
    my ($body, $tokens) = exists($request->{raw_body}) ? _parse($request->{raw_body}, 1048576) : ($request->{body}, {});
    _object($body, [qw(format format_version domain query request_id)], 'malformed_request');
    _reject('malformed_request') unless ($body->{format} // '') eq 'selecto.remote-query' && exists($body->{query});
    if (exists $body->{domain}) {
        _object($body->{domain}, ['fingerprint'], 'malformed_request');
        _text($body->{domain}{fingerprint}, 1024);
    }
    _text($body->{request_id}, 128) if exists $body->{request_id};
    _reject('malformed_request') if exists($body->{request_id}) && $body->{request_id} =~ /[\x00-\x1f\x7f]/;
    _reject('unsupported_protocol_version') unless _integer($body->{format_version}) && $body->{format_version} == 1
        && (!exists($tokens->{'/format_version'}) || $tokens->{'/format_version'} eq '1');
    _reject('stale_domain_fingerprint') if exists($body->{domain})
        && $body->{domain}{fingerprint} ne _fingerprint($engine);
    _reject('malformed_request') unless !ref($header) && length($header) <= 8192 && $header =~ /\A[A-Za-z0-9_-]+\z/;
    (my $b64 = $header) =~ tr/-_/+\//;
    my $bytes = decode_base64($b64);
    (my $roundtrip = encode_base64($bytes, '')) =~ tr!+/!-_!; $roundtrip =~ s/=+\z//;
    _reject('malformed_request') unless $header eq $roundtrip;
    my ($ctx) = _parse($bytes, 8192);
    _object($ctx, [qw(profile fingerprint publication revision)], 'malformed_request');
    _reject('malformed_request') unless keys(%$ctx) == 4;
    _text($_, 1024) for values %$ctx;
    my $features = $self->features($engine);
    my $current = $self->context($features);
    _reject('stale_nested_detail_context') if grep { $ctx->{$_} ne $current->{$_} } keys %$current;
    $$admitted = $current;
    $engine->assert_tenant_boundary(access => 'read');
    my $contract = $engine->domain->contract // {};
    _reject('operation_unsupported') if grep { @{$contract->{$_} // []} } qw(required_selected required_group_by required_order_by);
    my $q = $body->{query};
    _reject('invalid_query') unless ref($q) eq 'HASH';
    _reject('operation_unsupported') if grep { exists $q->{$_} } qw(where child_filters child_order_by group_by aggregates projection view segments parameters ordering);
    # Field pre-pass: resolve every reference before shape/limit validation.
    my @references;
    my $visit; $visit = sub ($v) {
        if (ref($v) eq 'ARRAY') { $visit->($_) for @$v }
        elsif (ref($v) eq 'HASH') { push @references, $v->{field} if exists $v->{field} }
        elsif (defined($v) && !ref($v)) { push @references, $v }
    };
    $visit->($q->{select});
    for my $part (qw(filters order_by)) {
        my $walk; $walk = sub ($v) {
            if (ref($v) eq 'ARRAY') { $walk->($_) for @$v }
            elsif (ref($v) eq 'HASH') { push @references, $v->{field} if exists $v->{field}; $walk->($v->{$_}) for grep { $_ eq 'any' || $_ eq 'all' } keys %$v }
        }; $walk->($q->{$part});
    }
    for my $field (@references) {
        next unless defined($field) && !ref($field);
        $engine->domain->resolve($field);
        _reject('hidden_field') unless $engine->domain->field_is_public($field);
    }
    _object($q, [qw(select filters order_by limit offset row_format timezone)], 'invalid_query');
    my %roots = map { ($_->{path} => $_) } @{$features->{root_fields}};
    my %children = map { ($_->{path} => $_) } @{$features->{collections}[0]{fields}};
    my ($nested, %selected, $root_count);
    _reject('invalid_query') unless ref($q->{select}) eq 'ARRAY';
    for my $s (@{$q->{select}}) {
        if (ref($s) eq 'ARRAY') {
            _reject('invalid_query') if $nested || !@$s || @$s > 20;
            $nested = $s; my %seen;
            _reject('invalid_query') if grep { ref($_) || !$children{$_} || $seen{$_}++ } @$s;
        } else {
            _reject('invalid_query') if !defined($s) || ref($s) || !$roots{$s} || $selected{$s}++;
            $root_count++;
        }
    }
    _reject('invalid_query') unless $nested && $root_count && $root_count <= 20;
    for my $part (qw(filters order_by)) {
        _reject('invalid_query') unless !exists($q->{$part}) || ref($q->{$part}) eq 'ARRAY';
        _reject('invalid_query') if @{$q->{$part} // []} > ($part eq 'filters' ? 20 : 10);
    }
    my @filters; my $fi = 0;
    for my $f (@{$q->{filters} // []}) {
        _object($f, [qw(field op value)], 'invalid_query');
        my $desc = !ref($f->{field}) && defined($f->{field}) ? $roots{$f->{field}} : undef;
        _reject('invalid_query') unless $desc && !ref($f->{op}) && grep { $_ eq ($f->{op} // '') } @{$desc->{operators}};
        my $null = $f->{op} =~ /null\z/;
        _reject('invalid_query') unless $null ? !exists($f->{value}) : exists($f->{value}) && defined($f->{value});
        _input_scalar($f->{value}, $desc, $tokens->{"/query/filters/$fi/value"}) unless $null;
        push @filters, {%$f, op => $f->{op} eq 'is_not_null' ? 'not_null' : $f->{op}}; $fi++;
    }
    my %ordered;
    for my $o (@{$q->{order_by} // []}) {
        _object($o, [qw(field direction)], 'invalid_query');
        _reject('invalid_query') unless defined($o->{field}) && !ref($o->{field}) && $roots{$o->{field}} && !$ordered{$o->{field}}++
            && ($o->{direction} // '') =~ /\A(?:asc|desc)\z/;
    }
    my ($limit, $offset) = (exists($q->{limit}) ? $q->{limit} : 25, exists($q->{offset}) ? $q->{offset} : 0);
    _reject('invalid_query') unless _integer($limit) && $limit >= 1 && $limit <= 25 && _integer($offset) && $offset <= 100000;
    for my $key (qw(limit offset)) {
        _reject('invalid_query') if exists($tokens->{"/query/$key"}) && $tokens->{"/query/$key"} !~ /\A(?:0|[1-9][0-9]*)\z/;
    }
    my $format = exists($q->{row_format}) ? $q->{row_format} : 'arrays';
    _reject('invalid_query') unless defined($format) && !ref($format);
    _reject('invalid_query') unless $format =~ /\A(?:arrays|objects)\z/;
    my $limits = Selecto::Limits->new(max_fields => 40, max_collection_rows => 20, max_total_collection_rows => 500,
        max_value_bytes => 16384, max_parameter_bytes => 1048576, max_response_bytes => 1048576,
        max_result_cell_bytes => 1048576)->intersect($self->limits)->intersect($engine->limits);
    # Smaller trusted caps are refusals, never falsely advertised truncation.
    _reject('operation_unsupported') if $limits->get('max_collection_rows') < 20;
    my @orders = @{$q->{order_by} // []};
    push @orders, {field => $features->{root_primary_key}, direction => 'asc'} unless $ordered{$features->{root_primary_key}};
    my $handler = Selecto::API::EngineHandler->new(limits => $limits, bounded_results => 1,
        collection_parent_lookahead => 1, collection_json_budget => $limits->get('max_response_bytes'), max_fields => 40, max_limit => 25, default_limit => 25, max_offset => 100000, max_orders => 11);
    my $r = $handler->query($engine, {%$q, filters => \@filters, order_by => \@orders, row_format => 'arrays', limit => $limit, offset => $offset});
    my $collection = $self->collection;
    my @cols = map { my $f = ref($_) eq 'ARRAY' ? {path => $collection, label => $collection, type => 'json', encoding => 'json', nullable => JSON::PP::false} : $roots{$_};
        +{id => $f->{path}, field => $f->{path}, map { ($_ => $f->{$_}) } qw(label type encoding nullable)} } @{$q->{select}};
    for my $row (@{$r->{rows}}) {
        for my $i (0 .. $#cols) {
            if (ref($q->{select}[$i]) eq 'ARRAY') {
                for my $child (@{$row->[$i]}) {
                    $child->[$_] = _output_scalar($child->[$_], $children{$nested->[$_]}) for 0 .. $#$nested;
                }
                $row->[$i] = [map { my %record; @record{@$nested} = @$_; \%record } @{$row->[$i]}] if $format eq 'objects';
            } else { $row->[$i] = _output_scalar($row->[$i], $roots{$q->{select}[$i]}) }
        }
    }
    my $rows = $r->{rows};
    $rows = [map { my %record; @record{map { $_->{id} } @cols} = @$_; \%record } @$rows] if $format eq 'objects';
    my $answer = {ok => JSON::PP::true, data => {format => 'selecto.remote-query-result', format_version => 1,
        domain => {fingerprint => _fingerprint($engine)}, columns => \@cols, rows => $rows, row_count => scalar(@$rows),
        row_format => $format, page => {limit => 0 + $limit, offset => 0 + $offset, has_more => $r->{has_more}},
        subtables => {$collection => {columns => [@$nested], limit => 20, complete => JSON::PP::true}}},
        meta => {selecto_nested_detail => $current, (exists($body->{request_id}) ? (request_id => $body->{request_id}) : ())}};
    _reject('invalid_query') if length($JSON->encode($answer)) > 262144;
    Selecto::API::ResponsePolicy->check_json($answer, $limits);
    return $answer;
}

sub _output_scalar ($v, $f) {
    _reject('internal_failure') if !defined($v) && !$f->{nullable};
    return undef unless defined $v;
    if ($f->{type} eq 'decimal') {
        my $s = "$v"; _reject('internal_failure') unless $s =~ /\A(-?)(0|[1-9][0-9]{0,31})(?:\.([0-9]+))?\z/;
        my ($sign, $whole, $frac) = ($1, $2, $3 // '');
        $frac =~ s/0+\z//;
        _reject('invalid_query') if length($frac) > 6;
        return $sign . $whole . '.' . $frac . ('0' x (6 - length($frac)));
    }
    if ($f->{type} eq 'integer') {
        _reject('internal_failure') unless !ref($v) && "$v" =~ /\A(?:0|[1-9][0-9]*|-[1-9][0-9]*)\z/;
        my $n = Math::BigInt->new("$v");
        _reject('invalid_query') if $n->bcmp('-9223372036854775808') < 0 || $n->bcmp('9223372036854775807') > 0
            || $f->{encoding} eq 'json' && $n->copy->babs->bcmp('9007199254740991') > 0;
    }
    _reject('invalid_query') if $f->{type} eq 'date' && "$v" =~ /\A0000-/;
    _reject('internal_failure') if !ref($v) && "$v" =~ /[\x{d800}-\x{dfff}]/;
    my $value = Selecto::API::RemoteQuery::_scalar($v, $f);
    _reject('invalid_query') if !ref($value) && length(encode('UTF-8', "$value")) > 16384;
    return $value;
}
sub _input_scalar ($v, $f, $token) {
    _reject('invalid_query') unless defined $v;
    my $type = $f->{type};
    if ($type eq 'boolean') { _reject('invalid_query') unless JSON::PP::is_bool($v); return }
    _reject('invalid_query') if ref($v);
    my $encoded = $JSON->encode($v);
    if ($encoded !~ /\A"/) {
        _reject('invalid_query') unless $type =~ /\A(?:integer|decimal)\z/ && $encoded =~ /\A-?(?:0|[1-9][0-9]*)\z/
            && (!defined($token) || $token =~ /\A-?(?:0|[1-9][0-9]*)\z/)
            && Math::BigInt->new("$v")->babs->bcmp('9007199254740991') <= 0;
    }
    _reject('invalid_query') if $type eq 'integer' && ("$v" !~ /\A(?:0|[1-9][0-9]*|-[1-9][0-9]*)\z/
        || Math::BigInt->new("$v")->bcmp('-9223372036854775808') < 0 || Math::BigInt->new("$v")->bcmp('9223372036854775807') > 0);
    _reject('invalid_query') if $type eq 'decimal' && "$v" !~ /\A-?(?:0|[1-9][0-9]{0,31})(?:\.[0-9]{1,6})?\z/;
    _reject('invalid_query') if $type eq 'date' && ("$v" =~ /\A0000-/ || !eval { Selecto::API::RemoteQuery::_scalar($v, $f); 1 });
    _reject('invalid_query') if length(encode('UTF-8', "$v")) > 16384;
}
sub _fingerprint ($engine) { $engine->domain->published_fingerprint // $engine->domain->fingerprint }
sub _supported ($type) { $type =~ /\A(?:integer|decimal|numeric|string|text|boolean|date)\z/ }
sub _integer ($v) { Selecto::API::RemoteQuery::_integer($v) }
sub _object ($v, $keys, $code) { Selecto::API::RemoteQuery::_object($v, $keys, $code) }
sub _reject ($code) { Selecto::API::RemoteQuery::_reject($code) }
sub _text ($v, $max) {
    _reject('malformed_request') unless defined($v) && !ref($v) && length($v) && $JSON->encode($v) =~ /\A"/
        && $v !~ /[\r\n\x{d800}-\x{dfff}]/ && length(encode('UTF-8', $v)) <= $max;
}

# Parse original bytes without losing duplicate decoded keys or numeric tokens.
# Decoded bodies remain usable by native callers, but a wire host MUST pass
# raw_body to enforce the lexical contract. This parser never loads code.
sub _parse ($bytes, $max) {
    _reject('malformed_request') if !defined($bytes) || ref($bytes) || length($bytes) > $max;
    my $s = eval { decode('UTF-8', $bytes, FB_CROAK) };
    _reject('malformed_request') if $@ || $s =~ /[\x{d800}-\x{dfff}]/;
    my ($pos, %tokens) = (0);
    my $ws = sub { $pos++ while substr($s, $pos, 1) =~ /[ \t\r\n]/ && $pos < length($s) };
    my $string = sub {
        my $tail = substr($s, $pos);
        _reject('malformed_request') unless $tail =~ /\A("(?:[^"\\\x00-\x1f]|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*")/;
        my $raw = $1; $pos += length($raw);
        my $v = eval { $JSON->decode(encode('UTF-8', $raw)) };
        _reject('malformed_request') if $@ || $v =~ /[\x{d800}-\x{dfff}]/;
        return $v;
    };
    my $value; $value = sub ($path, $depth) {
        _reject('malformed_request') if $depth > 32;
        $ws->(); my $c = substr($s, $pos, 1);
        if ($c eq '"') { return $string->() }
        if ($c eq '{') {
            $pos++; $ws->(); my %o;
            if (substr($s, $pos, 1) eq '}') { $pos++; return \%o }
            while (1) {
                $ws->(); my $k = $string->(); _reject('malformed_request') if exists $o{$k};
                $ws->(); _reject('malformed_request') unless substr($s, $pos++, 1) eq ':';
                $o{$k} = $value->("$path/$k", $depth + 1); $ws->();
                my $sep = substr($s, $pos++, 1); last if $sep eq '}'; _reject('malformed_request') unless $sep eq ',';
            } return \%o;
        }
        if ($c eq '[') {
            $pos++; $ws->(); my @a;
            if (substr($s, $pos, 1) eq ']') { $pos++; return \@a }
            while (1) {
                push @a, $value->("$path/" . scalar(@a), $depth + 1); $ws->();
                my $sep = substr($s, $pos++, 1); last if $sep eq ']'; _reject('malformed_request') unless $sep eq ',';
            } return \@a;
        }
        my $tail = substr($s, $pos);
        _reject('malformed_request') unless $tail =~ /\A(true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/;
        my $raw = $1; $pos += length($raw); $tokens{$path} = $raw if $raw =~ /\A[-0-9]/;
        my $v = eval { $JSON->decode($raw) }; _reject('malformed_request') if $@; return $v;
    };
    my $v = $value->('', 0); $ws->(); _reject('malformed_request') unless $pos == length($s);
    return ($v, \%tokens);
}
1;

__END__

=head1 NAME

Selecto::API::NestedDetail - selected complete typed collections over remote_query.v1

=head1 SYNOPSIS

  my $host = Selecto::API::NestedDetail->new(
      base_path => '/api/orders', id => 'orders', publication => $publication,
      collection => 'lines', publish_domain => $explicit_publication_policy,
  );
  my $response = $host->request($trusted_engine, {
      method => 'POST', path => '/api/orders/query', content_type => 'application/json',
      raw_body => $original_utf8_bytes,
      headers => {'Selecto-Nested-Detail-Context' => $header},
  });

=head1 DESCRIPTION

Publishes C<getNestedDetailFeatures> on C</nested-detail-features>, with one
configured direct to-many collection. The context header selects strict nested
validation on the existing query route. Without it, the inherited v1 host is
unchanged. L<Selecto::API::Explorer> can compose this publication with
C<nested_detail =E<gt> {collection =E<gt> 'lines'}>.

Hosts authenticate, pass a fresh governed engine and original body bytes, limit
body buffering to one MiB, and mount the discovery routes. Full domain
publication remains explicit. Optional C<root_fields> and C<child_fields> select
the published paths; otherwise eligible supported scalar fields are used.
Public nonnull integer primary keys are required in both scopes. Use
C<field_encodings> for declared int64 decimal-string fields; the authorized
canonical domain document must declare matching codecs.

Successful pages return at most 25 parents and 20 complete children per parent,
with stable codecs, six-place decimals and an echoed publication context.
Limits intersect trusted engine limits. No request value supplies tenant scope.
Unsupported policy, overflow and malformed requests refuse with sanitized errors.
The normative profile and portable cases live in the certification harness's
C<docs/canonical_nested_detail.md>.

=head2 Optional domain pin

Pinning protects against a field retaining its id while changing meaning. Use
C<domain =E<gt> {fingerprint =E<gt> ...}> for integrations that must never run
against a changed contract. Pinning is off unless the caller sends C<domain>;
omission runs against the current domain. When supplied, C<domain> must contain
exactly one C<fingerprint>, a non-empty string. Invalid pins are
C<malformed_request>; a different fingerprint is C<409 stale_domain_fingerprint>.
Responses still return the current fingerprint. Field publication and role
checks always apply.

The nested-detail-features document advertises
C<supports.optional_domain_pin>. The context still binds its own fingerprint,
publication and revision; a context from another fingerprint is refused even
without an envelope pin. The inherited canonical manifest advertises
C<query_capabilities.optional_domain_pin> for scalar remote reads.

=cut
