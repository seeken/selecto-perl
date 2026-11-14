package Selecto::API::Explorer;

use 5.034;
use utf8;
use Mojo::Base -base, -signatures;
use B ();
use DateTime ();
use DateTime::TimeZone ();
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use List::Util qw(max);
use Math::BigFloat ();
use Scalar::Util qw(blessed);
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::API::RemoteQuery ();
use Selecto::API::ResultFormatter ();
use Selecto::DateShortcut ();
use Selecto::Error ();
use Selecto::Identifier ();
use Selecto::Limits ();
use Selecto::QueryLibrary ();

# remote_query.explorer.v1 and selecto.explorer-features v1: an HTTP-neutral
# host for explorer queries. Every query runs through
# Selecto::API::EngineHandler with its explorer extensions, so tenant
# boundaries, field visibility, field roles and execution are the canonical
# handler's; this module owns the wire profile: envelopes, the features
# document, the refusal order, translation, grouped ordering, rollup,
# drilldowns, bounded counts and export.

our $PROFILE = 'remote_query.explorer.v1';
my @GROUP_FORMATS = qw(day day_hour week month quarter year month_of_year day_of_month day_of_week hour);
my %GROUP_FORMAT = map { ($_ => 1) } @GROUP_FORMATS;
my @COMPARISONS = qw(eq ne gt gte lt lte between in not_in is_null not_null);
my @TEXT_OPS = qw(starts_with starts_with_ci text_contains text_contains_ci ends_with ends_with_ci);
my %TEXT_OP = map { ($_ => 1) } @TEXT_OPS;
my %TEMPORAL = map { ($_ => 1) } qw(date naive_datetime utc_datetime);
my %NUMERIC = map { ($_ => 1) } qw(integer decimal);
my @LIMIT_NAMES = qw(max_limit max_offset max_select max_filters max_filter_depth max_filter_values
    max_orders max_group_by max_aggregates max_groups max_result_cells max_buckets max_export_rows
    max_count_rows);
my %DEFAULT_LIMITS = (max_limit => 100, max_offset => 10_000, max_select => 20, max_filters => 20,
    max_filter_depth => 3, max_filter_values => 100, max_orders => 5, max_group_by => 3,
    max_aggregates => 10, max_groups => 1000, max_result_cells => 10_000, max_buckets => 20,
    max_export_rows => 10_000, max_count_rows => 100_000);
my @SUPPORT_FLAGS = qw(detail aggregate graph rollup grid nested recursive_filters group_formats
    buckets boolean_aggregates count_exact text_ops date_shortcuts);
my @EXPORT_FORMATS = qw(csv tsv json xlsx);
my %AGGREGATES = map { ($_ => 1) } qw(count count_distinct sum avg min max true_count false_count
    true_percentage bucket_count);
my %ERROR_STATUS = (malformed_request => 400, unsupported_protocol_version => 400,
    unsupported_media_type => 415, stale_domain_fingerprint => 409, stale_explorer_features => 409,
    operation_forbidden => 403, missing_tenant_scope => 403, operation_unsupported => 501, hidden_field => 403,
    invalid_field => 422, invalid_query => 422, result_limit_exceeded => 422,
    count_unavailable => 422, export_limit_exceeded => 422, response_format_not_acceptable => 406,
    query_timeout => 504);
my %ERROR_CODE = (field_not_public => 'hidden_field', unknown_field => 'invalid_field',
    unknown_association => 'invalid_field', invalid_api_query => 'invalid_query',
    invalid_query_library => 'invalid_query', unknown_query_library_definition => 'invalid_query',
    query_library_cycle => 'invalid_query', invalid_value_expression => 'invalid_query',
    query_rule_not_evaluable => 'invalid_query', unsupported_feature => 'operation_unsupported',
    tenant_scope_required => 'missing_tenant_scope',
    tenant_mismatch => 'operation_forbidden', related_collection_limit_exceeded => 'result_limit_exceeded',
    api_result_limit_exceeded => 'result_limit_exceeded');
my $ALIAS = qr/\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/;
my $JSON = JSON::PP->new->utf8->canonical;

has base_path => '/api/v1/selecto';
has [qw(id label publication clock)];
has default_limit => 30;
has count_exact => 0;
has limits => sub { +{} };
has collection_limit => 20;
has supports => sub { +{} };
has services => sub { +{} };
has links => sub { +{} };
has publish_domain => 0;
# Trusted engine limits (Selecto::Limits) for the handler and the
# remote_query.v1 routes.
has engine_limits => sub { Selecto::Limits->new };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    _host_error('base_path must be an absolute path')
        unless _string($self->base_path) && $self->base_path =~ m{\A/[^?#]*\z} && $self->base_path !~ m{//};
    (my $base = $self->base_path) =~ s{/+\z}{};
    _host_error('base_path must be an absolute path') unless length $base;
    $self->base_path($base);
    _host_error("$_ must be a non-empty string") for grep { !_string($self->$_) || $self->$_ eq '' } qw(id publication);
    $self->label($self->id) unless _string($self->label);
    _host_error('clock must be an RFC 3339 instant') unless defined _instant_epoch($self->clock);
    _host_error('limits must be an object') unless ref($self->limits) eq 'HASH';
    my %limits = (%DEFAULT_LIMITS, %{$self->limits});
    for my $name (keys %limits) {
        _host_error("unknown limit $name") unless exists $DEFAULT_LIMITS{$name};
        _host_error("limit $name must be a non-negative integer")
            unless defined($limits{$name}) && !ref($limits{$name}) && "$limits{$name}" =~ /\A[0-9]{1,9}\z/;
        $limits{$name} = 0 + $limits{$name};
    }
    _host_error("limit $_ must be positive") for grep { !$limits{$_} }
        qw(max_limit max_select max_filters max_filter_values max_groups max_buckets max_group_by max_aggregates);
    $self->limits(\%limits);
    for my $name (qw(default_limit collection_limit)) {
        _host_error("$name must be a positive integer")
            unless defined($self->$name) && !ref($self->$name) && $self->$name =~ /\A[1-9][0-9]{0,8}\z/;
    }
    _host_error('default_limit cannot exceed max_limit') if $self->default_limit > $limits{max_limit};
    _host_error('count_exact must be a boolean') unless !ref($self->count_exact) || JSON::PP::is_bool($self->count_exact);
    _host_error('supports must be an object') unless ref($self->supports) eq 'HASH';
    for my $name (keys %{$self->supports}) {
        my $value = $self->supports->{$name};
        if ($name eq 'export') {
            _host_error('supports.export must list export formats')
                unless ref($value) eq 'ARRAY' && !grep { my $format = $_; !_string($format) || !grep { $_ eq $format } @EXPORT_FORMATS } @$value;
        } elsif ($name eq 'timezones') {
            _host_error('supports.timezones must be utc or iana') unless _string($value) && $value =~ /\A(?:utc|iana)\z/;
        } else {
            _host_error("unknown supports flag $name") unless grep { $_ eq $name } @SUPPORT_FLAGS;
        }
    }
    _host_error('services must be an object') unless ref($self->services) eq 'HASH';
    _host_error('links must be an object') unless ref($self->links) eq 'HASH';
    _host_error('engine_limits must be a Selecto::Limits')
        unless blessed($self->engine_limits) && $self->engine_limits->isa('Selecto::Limits');
    $self->{remote} = Selecto::API::RemoteQuery->new(base_path => $base,
        publish_domain => $self->publish_domain, limits => $self->engine_limits,
        max_limit => $limits{max_limit}, default_limit => $self->default_limit);
    return $self;
}

# {method, path, content_type, accept, body (decoded JSON)} =>
# {status, content_type, headers, body (bytes)}.
sub request ($self, $engine, $request) {
    my $base = $self->base_path;
    my ($method, $path) = ref($request) eq 'HASH' ? @{$request}{qw(method path)} : ();
    $method //= '';
    $path //= '';
    my $response = eval {
        _reject('internal_failure') unless blessed($engine) && $engine->isa('Selecto::Engine');
        if ($method eq 'GET' && ($path eq $base || $path eq "$base/")) {
            $self->manifest_response($engine);
        } elsif ($method eq 'GET' && $path eq "$base/explorer-features") {
            _json_response(200, $self->features($engine));
        } elsif ($method eq 'POST' && $path eq "$base/explorer-query") {
            $self->_query_response($engine, $request);
        } else {
            _normalize_response($self->{remote}->request($engine, $request));
        }
    };
    return $response if $response;
    return $self->_error_response($@, $request);
}

sub manifest_response ($self, $engine) {
    my $response = _normalize_response($self->{remote}->request($engine,
        {method => 'GET', path => $self->base_path}));
    return $response unless $response->{status} == 200;
    my $manifest = $JSON->decode($response->{body});
    $manifest->{profiles} = [@{$manifest->{profiles} // []}, $PROFILE];
    my $base = $self->base_path;
    push @{$manifest->{routes}},
        {method => 'GET', operation_id => 'getExplorerFeatures', path => "$base/explorer-features"},
        {method => 'POST', operation_id => 'queryExplorer', path => "$base/explorer-query"};
    return _json_response(200, $manifest);
}

# The selecto.explorer-features v1 document for this engine.
sub features ($self, $engine) {
    my $supports = $self->_supports($engine);
    my $catalogue = $self->_catalogue($engine->domain, $supports);
    my $domain = $engine->domain;
    my $key = $domain->primary_key;
    my %limits = %{$self->limits};
    delete $limits{max_count_rows} unless $supports->{count_exact};
    my $library = eval { Selecto::QueryLibrary->definitions($domain, 'segments') } // {};
    my @segments = map {
        my $parameters = ref($library->{$_}) eq 'HASH' && ref($library->{$_}{parameters}) eq 'HASH'
            ? $library->{$_}{parameters} : {};
        {name => $_, parameters => [map {
            my $spec = ref($parameters->{$_}) eq 'HASH' ? $parameters->{$_} : {};
            {name => $_, type => $spec->{type} // 'string', required => _bool($spec->{required})};
        } sort keys %$parameters]};
    } sort keys %$library;
    my $contract = $domain->contract // {};
    my @default = grep { $catalogue->{by_path}{$_} && $catalogue->{by_path}{$_}{kind} ne 'many' }
        @{ref($contract->{default_selected}) eq 'ARRAY' ? $contract->{default_selected} : []};
    @default = ($key) if !@default && defined($key) && !ref($key) && $catalogue->{by_path}{$key};
    my $document = {
        format => 'selecto.explorer-features', format_version => 1, profile => $PROFILE,
        domain => {id => $self->id, fingerprint => _fingerprint($engine), publication => $self->publication},
        label => $self->label,
        fields => [map { _public_field($_) } @{$catalogue->{list}}],
        collections => $catalogue->{collections},
        default => {select => \@default, order_by => [], group_by => [], aggregates => [],
            rollup => JSON::PP::false},
        query_library => {segments => \@segments},
        limits => \%limits,
        supports => {%$supports, map { ($_ => _bool($supports->{$_})) } @SUPPORT_FLAGS},
        services => $self->services, links => $self->links,
    };
    $document->{revision} = 'sha256:' . sha256_hex($JSON->encode($document));
    return $document;
}

sub _supports ($self, $engine) {
    my %supports = map { ($_ => 1) } @SUPPORT_FLAGS;
    $supports{count_exact} = $self->count_exact ? 1 : 0;
    # Only adapters that convert instants to any zone advertise iana.
    $supports{timezones} = $engine->adapter->name eq 'postgresql' ? 'iana' : 'utc';
    $supports{export} = [@EXPORT_FORMATS];
    my $overrides = $self->supports;
    for my $name (keys %$overrides) {
        if ($name eq 'export') { $supports{export} = [grep { my $f = $_; grep { $_ eq $f } @{$overrides->{export}} } @EXPORT_FORMATS] }
        elsif ($name eq 'timezones') { $supports{timezones} = 'utc' if $overrides->{timezones} eq 'utc' }
        else { $supports{$name} = $overrides->{$name} ? 1 : 0 }
    }
    return \%supports;
}

# The public fields a query may name: root fields, fields of to-one
# associations one hop away, then fields of direct to-many associations.
sub _catalogue ($self, $domain, $supports) {
    my (@root, @one, @many, %by_path, @collections);
    my $fields = $domain->fields;
    my $associations = $domain->associations;
    my @candidates = map { [$_, 'root', undef, $fields->{$_}] } sort keys %$fields;
    for my $name (sort keys %$associations) {
        my $association = $associations->{$name};
        my $kind = $association->cardinality eq 'many' ? 'many' : 'one';
        my $related = $association->fields;
        push @candidates, map { ["$name.$_", $kind, $name, $related->{$_}] } sort keys %$related;
    }
    for my $candidate (@candidates) {
        my ($path, $kind, $association, $declared) = @$candidate;
        next unless $domain->field_is_public($path);
        my $type = _canonical_type($declared);
        next unless defined $type;
        my $metadata = $domain->field_metadata($path);
        my %role = map {
            my $flag = $_;
            my ($key) = grep { exists $metadata->{$_} } ($flag, "$flag?");
            ($flag => defined($key) ? ($metadata->{$key} ? 1 : 0) : 1);
        } qw(selectable sortable filterable groupable);
        if ($kind eq 'many') {
            # A to-many field is read only inside a collection selection: it
            # neither sorts, groups nor filters (a filter would multiply
            # root rows).
            @role{qw(sortable groupable filterable)} = (0, 0, 0);
        }
        my $entry = {
            path => $path, kind => $kind, association => $association, type => $type,
            label => _string($metadata->{label}) ? $metadata->{label} : $path,
            description => $domain->field_description($path),
            nullable => $kind eq 'one' ? 1 : exists($metadata->{nullable}) ? ($metadata->{nullable} ? 1 : 0) : 1,
            %role,
        };
        $entry->{operators} = !$role{filterable} ? [] : [@COMPARISONS,
            ($type eq 'string' && $supports->{text_ops} ? @TEXT_OPS : ()),
            ($TEMPORAL{$type} && $supports->{date_shortcuts} ? ('date_shortcut') : ())];
        $entry->{operators} = [grep { /\A(?:eq|ne|is_null|not_null)\z/ } @{$entry->{operators}}]
            if $type eq 'boolean';
        $entry->{aggregates} = $kind eq 'many' ? []
            : $NUMERIC{$type} ? [qw(count count_distinct sum avg min max)]
            : $type eq 'boolean' ? [qw(count count_distinct), ($supports->{boolean_aggregates}
                ? qw(true_count false_count true_percentage) : ())]
            : [qw(count count_distinct min max)];
        my $grouping = $role{groupable} && $kind ne 'many';
        $entry->{group_formats} = $grouping && $TEMPORAL{$type} && $supports->{group_formats} ? [@GROUP_FORMATS] : [];
        $entry->{buckets} = !$grouping || !$supports->{buckets} ? []
            : $NUMERIC{$type} ? ['numeric'] : $TEMPORAL{$type} ? [qw(year elapsed_days relative_days)] : [];
        $entry->{date_shortcuts} = $TEMPORAL{$type} && $supports->{date_shortcuts}
            ? [map { $_->{id} } @{Selecto::DateShortcut->choices}] : [];
        $entry->{collection} = $kind eq 'many' ? $association : undef;
        $by_path{$path} = $entry;
        push @{$kind eq 'root' ? \@root : $kind eq 'one' ? \@one : \@many}, $entry;
    }
    my %seen;
    for my $entry (@many) {
        next if $seen{$entry->{association}}++;
        push @collections, {id => $entry->{association}, path => $entry->{association},
            label => $entry->{association}, limit => 0 + $self->collection_limit};
    }
    return {list => [@root, @one, @many], by_path => \%by_path, collections => \@collections};
}

sub _public_field ($entry) {
    return {
        id => $entry->{path}, path => $entry->{path}, label => $entry->{label}, type => $entry->{type},
        encoding => _encoding($entry->{type}), nullable => _bool($entry->{nullable}),
        description => $entry->{description},
        (map { ($_ => _bool($entry->{$_})) } qw(selectable sortable filterable groupable)),
        (map { ($_ => [@{$entry->{$_}}]) } qw(operators aggregates group_formats buckets date_shortcuts)),
        collection => $entry->{collection},
    };
}

sub _query_response ($self, $engine, $request) {
    my $body = $request->{body};
    # 1. Media type, before the body is read: application/json, with at most
    # a utf-8 charset parameter.
    my $type = $request->{content_type};
    _reject('unsupported_media_type') unless _string($type)
        && $type =~ m{\A\s*application/json\s*(?:;\s*charset\s*=\s*"?utf-8"?\s*)?\z}i;
    # 2. Envelope.
    _reject('malformed_request') unless ref($body) eq 'HASH';
    my %envelope = map { ($_ => 1) } qw(format format_version domain features request_id query);
    _reject('malformed_request') if grep { !$envelope{$_} } keys %$body;
    _reject('malformed_request') unless _string($body->{format}) && $body->{format} eq 'selecto.explorer-query';
    _reject('malformed_request') unless ref($body->{domain}) eq 'HASH' && keys(%{$body->{domain}}) == 1
        && _string($body->{domain}{fingerprint}) && length($body->{domain}{fingerprint});
    _reject('malformed_request') if exists($body->{features}) && !(ref($body->{features}) eq 'HASH'
        && !grep { $_ ne 'revision' } keys %{$body->{features}});
    _reject('malformed_request') if ref($body->{features}) eq 'HASH' && exists($body->{features}{revision})
        && !_string($body->{features}{revision});
    _reject('malformed_request') if exists($body->{request_id}) && !_request_id($body->{request_id});
    _reject('malformed_request') unless exists $body->{query};
    _reject('unsupported_protocol_version') unless _integer($body->{format_version}) && $body->{format_version} == 1;
    # 3-4. Bindings.
    _reject('stale_domain_fingerprint') unless $body->{domain}{fingerprint} eq _fingerprint($engine);
    my $features = $self->features($engine);
    _reject('stale_explorer_features') if ref($body->{features}) eq 'HASH' && exists($body->{features}{revision})
        && $body->{features}{revision} ne $features->{revision};
    # 5. Tenant scope.
    $engine->assert_tenant_boundary(access => 'read');
    my $contract = $engine->domain->contract // {};
    _reject('operation_unsupported') if grep { @{$contract->{$_} // []} }
        qw(required_selected required_group_by required_order_by);
    my $query = $body->{query};
    _reject('invalid_query') unless ref($query) eq 'HASH';
    my $context = {engine => $engine, supports => $self->_supports($engine), features => $features,
        catalogue => $self->_catalogue($engine->domain, $self->_supports($engine)), limits => $self->limits};
    # 6. Member supports, 7. the field pre-pass, 8. instant conversions on a
    # UTC-only host (they need the field types), then shape and limits.
    $self->_check_supports($context, $query);
    $self->_field_prepass($context, $query);
    $self->_check_conversions($context, $query);
    my $plan = $self->_plan($context, $query);
    my $format;
    if ($plan->{export}) {
        $format = eval { Selecto::API::ResultFormatter->negotiate(undef, $request->{accept}) };
        _reject('response_format_not_acceptable') unless defined $format;
        _reject('operation_unsupported') unless grep { $_ eq $format } @{$context->{supports}{export}};
    }
    my $result = $self->_execute($context, $plan);
    my $meta = exists($body->{request_id}) ? {request_id => $body->{request_id}} : undef;
    return $self->_export_response($plan, $result, $format) if $plan->{export};
    my $data = {
        format => 'selecto.explorer-query-result', format_version => 1,
        domain => {fingerprint => _fingerprint($engine)}, features => {revision => $features->{revision}},
        columns => [map { _public_column($_) } @{$plan->{columns}}],
        rows => $result->{rows}, row_count => scalar(@{$result->{rows}}), row_format => $plan->{row_format},
        subtables => $result->{subtables} // {},
        page => {limit => 0 + $plan->{limit}, offset => 0 + $plan->{offset},
            has_more => _bool($result->{has_more})},
        (defined($result->{total_count}) ? (total_count => 0 + $result->{total_count}) : ()),
        ($result->{row_meta} ? (row_meta => $result->{row_meta}) : ()),
        ($plan->{complete} ? (complete => JSON::PP::true) : ()),
    };
    return _json_response(200, {ok => JSON::PP::true, data => $data, ($meta ? (meta => $meta) : ())});
}

# ---- supports (501) ----

sub _check_supports ($self, $context, $query) {
    my $supports = $context->{supports};
    my $unsupported = sub ($flag) { _reject('operation_unsupported') unless $supports->{$flag} };
    $unsupported->('count_exact') if _string($query->{count}) && $query->{count} eq 'exact';
    $unsupported->('rollup') if JSON::PP::is_bool($query->{rollup}) && $query->{rollup};
    $unsupported->('grid') if JSON::PP::is_bool($query->{complete}) && $query->{complete};
    my $select = ref($query->{select}) eq 'ARRAY' ? $query->{select} : [];
    my $groups = ref($query->{group_by}) eq 'ARRAY' ? $query->{group_by} : [];
    $unsupported->('aggregate') if exists($query->{group_by})
        || grep { ref($_) eq 'HASH' && exists $_->{aggregate} } @$select;
    for my $entry (@$select) {
        $unsupported->('nested') if ref($entry) eq 'ARRAY';
        next unless ref($entry) eq 'HASH';
        $unsupported->('group_formats') if exists($entry->{format}) && !exists($entry->{aggregate});
        my $aggregate = _string($entry->{aggregate}) ? $entry->{aggregate} : '';
        $unsupported->('boolean_aggregates') if $aggregate =~ /\A(?:true_count|false_count|true_percentage)\z/;
        $unsupported->('buckets') if $aggregate eq 'bucket_count';
    }
    for my $entry (@$groups) {
        next unless ref($entry) eq 'HASH';
        $unsupported->('group_formats') if exists $entry->{format};
        $unsupported->('buckets') if exists $entry->{buckets};
    }
    my @nodes = ref($query->{filters}) eq 'ARRAY' ? @{$query->{filters}} : ();
    while (@nodes) {
        my $node = shift @nodes;
        next unless ref($node) eq 'HASH';
        if (_is_group($node)) {
            $unsupported->('recursive_filters');
            push @nodes, @{$node->{any} // $node->{all}} if ref($node->{any} // $node->{all}) eq 'ARRAY';
            next;
        }
        my $op = _string($node->{op}) ? $node->{op} : '';
        $unsupported->('text_ops') if $TEXT_OP{$op};
        $unsupported->('date_shortcuts') if $op eq 'date_shortcut';
        $unsupported->('group_formats') if exists $node->{format};
    }
    if (ref($query->{export}) eq 'HASH') {
        _reject('operation_unsupported') unless @{$supports->{export}};
    }
    return;
}

# ---- field pre-pass (unknown 422 invalid_field, withheld 403 hidden_field) ----

sub _field_prepass ($self, $context, $query) {
    my $catalogue = $context->{catalogue};
    my $domain = $context->{engine}->domain;
    my $visit = sub ($path) {
        return unless _string($path);
        return if $catalogue->{by_path}{$path};
        my $exists = eval { $domain->resolve($path); 1 };
        _reject($exists && !$domain->field_is_public($path) ? 'hidden_field' : 'invalid_field');
    };
    my %aliases;
    my $select = ref($query->{select}) eq 'ARRAY' ? $query->{select} : [];
    for my $entry (@$select) {
        if (ref($entry) eq 'ARRAY') {
            $visit->(ref($_) eq 'HASH' ? $_->{field} : $_) for @$entry;
        } elsif (ref($entry) eq 'HASH') {
            $visit->($entry->{field}) if exists $entry->{field};
            $aliases{$entry->{alias}} = 1 if _string($entry->{alias});
            if (_string($entry->{alias}) && _string($entry->{aggregate}) && $entry->{aggregate} eq 'bucket_count'
                && ref($entry->{buckets}) eq 'HASH' && ref($entry->{buckets}{ranges}) eq 'ARRAY') {
                $aliases{"$entry->{alias}__bucket_$_"} = 1 for 1 .. @{$entry->{buckets}{ranges}};
            }
        } else {
            $visit->($entry);
        }
    }
    my $groups = ref($query->{group_by}) eq 'ARRAY' ? $query->{group_by} : [];
    for my $entry (@$groups) {
        $visit->(ref($entry) eq 'HASH' ? $entry->{field} : $entry);
        $aliases{$entry->{alias}} = 1 if ref($entry) eq 'HASH' && _string($entry->{alias});
    }
    my @nodes = ref($query->{filters}) eq 'ARRAY' ? @{$query->{filters}} : ();
    while (@nodes) {
        my $node = shift @nodes;
        next unless ref($node) eq 'HASH';
        if (_is_group($node)) {
            unshift @nodes, @{$node->{any} // $node->{all}} if ref($node->{any} // $node->{all}) eq 'ARRAY';
            next;
        }
        $visit->($node->{field});
    }
    for my $order (ref($query->{order_by}) eq 'ARRAY' ? @{$query->{order_by}} : ()) {
        next unless ref($order) eq 'HASH' && _string($order->{field});
        $visit->($order->{field}) unless $aliases{$order->{field}};
    }
    return;
}

# ---- instant conversions on a UTC-only host (501) ----

sub _check_conversions ($self, $context, $query) {
    return unless $context->{supports}{timezones} eq 'utc';
    my $zone = exists($query->{timezone}) ? $query->{timezone} : 'UTC';
    return unless _string($zone) && $zone ne 'UTC' && DateTime::TimeZone->is_valid_name($zone);
    my $catalogue = $context->{catalogue}{by_path};
    my $instant = sub ($path) { _string($path) && $catalogue->{$path} && $catalogue->{$path}{type} eq 'utc_datetime' };
    my $refuse = sub ($path) { _reject('operation_unsupported') if $instant->($path) };
    for my $entry (ref($query->{select}) eq 'ARRAY' ? @{$query->{select}} : ()) {
        next unless ref($entry) eq 'HASH';
        $refuse->($entry->{field}) if exists($entry->{format}) && !exists($entry->{aggregate});
        $refuse->($entry->{field}) if _string($entry->{aggregate}) && $entry->{aggregate} eq 'bucket_count'
            && ref($entry->{buckets}) eq 'HASH' && ($entry->{buckets}{kind} // '') ne 'numeric';
    }
    for my $entry (ref($query->{group_by}) eq 'ARRAY' ? @{$query->{group_by}} : ()) {
        next unless ref($entry) eq 'HASH';
        $refuse->($entry->{field}) if exists($entry->{format})
            || (ref($entry->{buckets}) eq 'HASH' && ($entry->{buckets}{kind} // '') ne 'numeric');
    }
    my @nodes = ref($query->{filters}) eq 'ARRAY' ? @{$query->{filters}} : ();
    while (@nodes) {
        my $node = shift @nodes;
        next unless ref($node) eq 'HASH';
        if (_is_group($node)) {
            push @nodes, @{$node->{any} // $node->{all}} if ref($node->{any} // $node->{all}) eq 'ARRAY';
            next;
        }
        $refuse->($node->{field}) if exists($node->{format})
            || (_string($node->{op}) && $node->{op} eq 'date_shortcut');
    }
    return;
}

# ---- shape and limits (422) ----

sub _plan ($self, $context, $query) {
    my $limits = $context->{limits};
    my $catalogue = $context->{catalogue}{by_path};
    my %members = map { ($_ => 1) } qw(select filters group_by order_by segments parameters limit offset
        timezone row_format rollup complete count export);
    _invalid() if grep { !$members{$_} } keys %$query;
    my $zone = exists($query->{timezone}) ? $query->{timezone} : 'UTC';
    _invalid() unless _string($zone) && DateTime::TimeZone->is_valid_name($zone);
    my $today = DateTime->from_epoch(epoch => _instant_epoch($self->clock), time_zone => $zone)->ymd('-');
    my $plan = {zone => $zone, today => $today, columns => [], selections => [], groups => [],
        utc_host => $context->{supports}{timezones} eq 'utc'};
    my $boolean = sub ($name, $default) {
        return $default unless exists $query->{$name};
        _invalid() unless JSON::PP::is_bool($query->{$name});
        return $query->{$name} ? 1 : 0;
    };
    $plan->{rollup} = $boolean->('rollup', 0);
    $plan->{complete} = $boolean->('complete', 0);
    $plan->{row_format} = $query->{row_format} // 'arrays';
    _invalid() unless _string($plan->{row_format}) && $plan->{row_format} =~ /\A(?:arrays|objects)\z/;
    $plan->{count} = $query->{count} // 'none';
    _invalid() unless _string($plan->{count}) && $plan->{count} =~ /\A(?:none|exact)\z/;
    $plan->{limit} = exists($query->{limit}) ? $query->{limit} : $self->default_limit;
    _invalid() unless _integer($plan->{limit}) && $plan->{limit} <= $limits->{max_limit};
    $plan->{offset} = exists($query->{offset}) ? $query->{offset} : 0;
    _invalid() unless _integer($plan->{offset}) && $plan->{offset} <= $limits->{max_offset};
    $plan->{limit} += 0;
    $plan->{offset} += 0;

    # Group entries.
    my %group_alias;
    if (exists $query->{group_by}) {
        my $groups = $query->{group_by};
        _invalid() unless ref($groups) eq 'ARRAY' && @$groups >= 1 && @$groups <= $limits->{max_group_by};
        my %ids;
        for my $index (0 .. $#$groups) {
            my $entry = $groups->[$index];
            my $group = {index => $index};
            if (ref($entry) eq 'HASH') {
                _invalid() if grep { !/\A(?:field|alias|format|buckets)\z/ } keys %$entry;
                _invalid() unless _string($entry->{alias}) && $entry->{alias} =~ $ALIAS;
                _invalid() unless (exists($entry->{format}) xor exists($entry->{buckets}));
                @$group{qw(id path)} = ($entry->{alias}, $entry->{field});
                _invalid() unless _string($group->{path});
                my $field = $catalogue->{$group->{path}};
                _invalid() if $field->{kind} eq 'many';
                _reject('invalid_field') unless $field->{groupable};
                if (exists $entry->{format}) {
                    _invalid() unless _string($entry->{format}) && $GROUP_FORMAT{$entry->{format}} && $TEMPORAL{$field->{type}};
                    @$group{qw(kind format)} = ('format', $entry->{format});
                    $self->_instant_use($plan, $field);
                } else {
                    $group->{kind} = 'bucket';
                    $group->{bucket} = $self->_bucket_spec($plan, $field, $entry->{buckets}, 1);
                }
                $group->{type} = 'string';
                $group_alias{$group->{id}} = $group;
            } else {
                _invalid() unless _string($entry);
                my $field = $catalogue->{$entry};
                _invalid() if $field->{kind} eq 'many';
                _reject('invalid_field') unless $field->{groupable};
                @$group{qw(id path kind type)} = ($entry, $entry, 'plain', $field->{type});
            }
            $group->{field} = $catalogue->{$group->{path}};
            _invalid() if $ids{$group->{id}}++;
            push @{$plan->{groups}}, $group;
        }
    }
    my $grouped = @{$plan->{groups}} ? 1 : 0;

    # Selections.
    my $select = $query->{select};
    _invalid() unless ref($select) eq 'ARRAY' && @$select >= 1 && @$select <= $limits->{max_select};
    my (%column_ids, %selected_groups, $aggregates, $collections, $plain_fields);
    my $add_column = sub ($column) {
        _invalid() if $column_ids{$column->{id}}++;
        push @{$plan->{columns}}, $column;
    };
    for my $entry (@$select) {
        if (ref($entry) eq 'ARRAY') {
            $collections++;
            my $selection = $self->_collection_selection($context, $entry);
            $add_column->({id => $selection->{association}, label => $selection->{association},
                type => 'collection', role => 'field', field => $selection->{association},
                nullable => 0, children => $selection->{children}});
            push @{$plan->{selections}}, $selection;
            next;
        }
        if (ref($entry) eq 'HASH' && exists $entry->{group}) {
            _invalid() if keys(%$entry) != 1 || !_string($entry->{group});
            my $group = $group_alias{$entry->{group}};
            _invalid() unless $group;
            _invalid() if $selected_groups{$group->{index}}++;
            $add_column->(_group_column($group, $plan));
            push @{$plan->{selections}}, {kind => 'group', group => $group};
            next;
        }
        if (ref($entry) eq 'HASH' && exists $entry->{aggregate}) {
            $aggregates++;
            my $selection = $self->_aggregate_selection($context, $plan, $entry);
            $add_column->($_) for @{$selection->{columns}};
            push @{$plan->{selections}}, $selection;
            next;
        }
        my ($path, $alias, $format);
        if (ref($entry) eq 'HASH') {
            _invalid() if grep { !/\A(?:field|alias|format)\z/ } keys %$entry;
            ($path, $alias, $format) = @$entry{qw(field alias format)};
            _invalid() if exists($entry->{alias}) && !(_string($alias) && $alias =~ $ALIAS);
            _invalid() if exists($entry->{format}) && !exists($entry->{alias});
        } else {
            $path = $entry;
        }
        _invalid() unless _string($path);
        my $field = $catalogue->{$path};
        _invalid() if $field->{kind} eq 'many' || !$field->{selectable};
        if (defined $format) {
            _invalid() unless _string($format) && $GROUP_FORMAT{$format} && $TEMPORAL{$field->{type}};
            $self->_instant_use($plan, $field);
        }
        my $id = $alias // $path;
        if ($grouped) {
            # A grouped plain path, selected once.
            my ($group) = grep { $_->{kind} eq 'plain' && $_->{path} eq $path } @{$plan->{groups}};
            _invalid() unless $group && !defined($alias) && !defined($format);
            _invalid() if $selected_groups{$group->{index}}++;
            $add_column->(_group_column($group, $plan));
            push @{$plan->{selections}}, {kind => 'group', group => $group};
            next;
        }
        $plain_fields++;
        $add_column->({id => $id, label => $alias // $field->{label}, role => 'field', field => $path,
            type => defined($format) ? 'string' : $field->{type},
            nullable => $field->{nullable}, (defined($format) ? (format => $format) : ())});
        push @{$plan->{selections}}, {kind => 'field', path => $path, format => $format, field => $field};
    }
    _invalid() if ($aggregates // 0) > $limits->{max_aggregates};
    if ($grouped) {
        _invalid() unless keys(%selected_groups) == @{$plan->{groups}};
        _invalid() if $collections;
        $plan->{mode} = 'grouped';
    } elsif ($aggregates) {
        _invalid() if $plain_fields || $collections;
        $plan->{mode} = 'summary';
    } else {
        $plan->{mode} = 'detail';
    }

    # Filters.
    my $filters = exists($query->{filters}) ? $query->{filters} : [];
    _invalid() unless ref($filters) eq 'ARRAY';
    my $leaves = 0;
    $plan->{filters} = [map { $self->_filter_node($context, $plan, $_, 0, \$leaves) } @$filters];

    # Segments and parameters (expanded and governed by the handler).
    my $segments = exists($query->{segments}) ? $query->{segments} : [];
    _invalid() unless ref($segments) eq 'ARRAY' && !grep { !_string($_) || !length } @$segments;
    $plan->{segments} = [@$segments];
    my $parameters = exists($query->{parameters}) ? $query->{parameters} : {};
    _invalid() unless ref($parameters) eq 'HASH';
    $plan->{parameters} = $parameters;

    # Ordering.
    my $orders = exists($query->{order_by}) ? $query->{order_by} : [];
    _invalid() unless ref($orders) eq 'ARRAY' && @$orders <= $limits->{max_orders};
    my %aggregate_columns = map { ($_->{id} => $_) } grep { $_->{role} eq 'aggregate' } @{$plan->{columns}};
    for my $order (@$orders) {
        _invalid() unless ref($order) eq 'HASH' && !grep { !/\A(?:field|direction)\z/ } keys %$order;
        my $direction = exists($order->{direction}) ? $order->{direction} : 'asc';
        _invalid() unless _string($direction) && $direction =~ /\A(?:asc|desc)\z/;
        my $id = $order->{field};
        _invalid() unless _string($id);
        if ($plan->{mode} eq 'grouped') {
            my ($group) = grep { $_->{id} eq $id } @{$plan->{groups}};
            if ($group) {
                _reject('invalid_field') if $group->{kind} eq 'plain' && !$group->{field}{sortable};
                push @{$plan->{orders}}, {group => $group, direction => $direction};
            } elsif ($aggregate_columns{$id}) {
                push @{$plan->{orders}}, {column => $aggregate_columns{$id}, direction => $direction};
            } else {
                _invalid();
            }
        } elsif ($plan->{mode} eq 'detail') {
            my $field = $catalogue->{$id};
            _invalid() unless $field && $field->{kind} ne 'many';
            _reject('invalid_field') unless $field->{sortable};
            push @{$plan->{orders}}, {path => $id, direction => $direction};
        } else {
            _invalid();
        }
    }
    $plan->{orders} //= [];

    # Result-shape rules.
    _invalid() if $plan->{rollup} && ($plan->{mode} ne 'grouped' || @$orders);
    _invalid() if $plan->{complete} && ($plan->{mode} ne 'grouped' || $plan->{rollup} || $plan->{offset});
    if (exists($query->{export}) && defined($query->{export})) {
        my $export = $query->{export};
        _invalid() unless ref($export) eq 'HASH' && !grep { !/\A(?:all_rows|shape)\z/ } keys %$export;
        _invalid() unless JSON::PP::is_bool($export->{all_rows}) && $export->{all_rows};
        my $shape = exists($export->{shape}) ? $export->{shape} : 'rows';
        _invalid() unless _string($shape) && $shape =~ /\A(?:rows|grid)\z/;
        if ($shape eq 'grid') {
            my @measures = grep { $_->{role} eq 'aggregate' } @{$plan->{columns}};
            _invalid() unless $plan->{mode} eq 'grouped' && @{$plan->{groups}} == 2 && @measures == 1
                && !$plan->{rollup} && @{$plan->{columns}} == 3;
        }
        $plan->{export} = {shape => $shape};
    }
    return $plan;
}

sub _group_column ($group, $plan) {
    return {id => $group->{id}, label => $group->{kind} eq 'plain' ? $group->{field}{label} : $group->{id},
        role => 'group', field => $group->{path}, type => $group->{type},
        nullable => $plan->{rollup} || ($group->{kind} ne 'bucket' && $group->{field}{nullable}) ? 1 : 0,
        ($group->{kind} eq 'format' ? (format => $group->{format}) : ()), group => $group};
}

sub _collection_selection ($self, $context, $entry) {
    my $catalogue = $context->{catalogue}{by_path};
    _invalid() unless @$entry;
    my ($association, @children, %ids);
    for my $child (@$entry) {
        my ($path, $alias);
        if (ref($child) eq 'HASH') {
            _invalid() if grep { !/\A(?:field|alias)\z/ } keys %$child;
            ($path, $alias) = @$child{qw(field alias)};
            _invalid() if exists($child->{alias}) && !(_string($alias) && $alias =~ $ALIAS);
        } else {
            $path = $child;
        }
        _invalid() unless _string($path);
        my $field = $catalogue->{$path};
        _invalid() unless $field->{kind} eq 'many' && $field->{selectable};
        $association //= $field->{association};
        _invalid() unless $field->{association} eq $association;
        my $id = $alias // $path;
        _invalid() if $ids{$id}++;
        push @children, {id => $id, path => $path, type => $field->{type}};
    }
    return {kind => 'collection', association => $association, children => \@children};
}

sub _aggregate_selection ($self, $context, $plan, $entry) {
    my $catalogue = $context->{catalogue}{by_path};
    my $function = $entry->{aggregate};
    _invalid() unless _string($function) && $AGGREGATES{$function};
    my @allowed = qw(aggregate field alias);
    push @allowed, 'ignore_nulls' if $function eq 'sum';
    push @allowed, 'buckets' if $function eq 'bucket_count';
    my %allowed = map { ($_ => 1) } @allowed;
    _invalid() if grep { !$allowed{$_} } keys %$entry;
    _invalid() unless _string($entry->{alias}) && $entry->{alias} =~ $ALIAS;
    my $alias = $entry->{alias};
    my $field;
    if (exists $entry->{field}) {
        _invalid() unless _string($entry->{field});
        $field = $catalogue->{$entry->{field}};
        _invalid() if $field->{kind} eq 'many';
    } else {
        _invalid() unless $function eq 'count';
    }
    if ($function eq 'bucket_count') {
        _invalid() unless $field;
        my $bucket = $self->_bucket_spec($plan, $field, $entry->{buckets}, 0);
        my @columns = map {
            {id => "${alias}__bucket_" . ($_ + 1), label => $bucket->{ranges}[$_]{label}, role => 'aggregate',
                aggregate => 'bucket_count', field => $field->{path}, type => 'integer', nullable => 0,
                bucket => $bucket->{ranges}[$_]{label}}
        } 0 .. $#{$bucket->{ranges}};
        return {kind => 'bucket_count', field => $field, bucket => $bucket, columns => \@columns};
    }
    if ($field) {
        _invalid() unless grep { $_ eq $function } @{$field->{aggregates}};
    }
    my $auto = 0;
    if (exists $entry->{ignore_nulls}) {
        _invalid() unless _string($entry->{ignore_nulls}) && $entry->{ignore_nulls} eq 'auto';
        $auto = 1;
    }
    my $type = $function =~ /\A(?:count|count_distinct|true_count|false_count)\z/ ? 'integer'
        : $function =~ /\A(?:avg|true_percentage)\z/ ? 'decimal' : $field->{type};
    my $nullable = $function =~ /\A(?:count|count_distinct|true_count|false_count)\z/ || $auto ? 0 : 1;
    return {kind => 'aggregate', aggregate => $function, field => $field, auto => $auto,
        columns => [{id => $alias, label => $alias, role => 'aggregate', aggregate => $function,
            ($field ? (field => $field->{path}) : ()), type => $type, nullable => $nullable}]};
}

# A bucket spec (5.3), validated and resolved to ranges with literal bounds
# from the trusted clock in the request zone.
sub _bucket_spec ($self, $plan, $field, $spec, $allow_step) {
    my $limits = $self->limits;
    _invalid() unless ref($spec) eq 'HASH' && _string($spec->{kind});
    my $kind = $spec->{kind};
    _invalid() unless $kind =~ /\A(?:numeric|year|elapsed_days|relative_days)\z/;
    _invalid() unless $kind eq 'numeric' ? $NUMERIC{$field->{type}} : $TEMPORAL{$field->{type}};
    $self->_instant_use($plan, $field) unless $kind eq 'numeric';
    if (exists $spec->{step}) {
        _invalid() unless $allow_step && !exists($spec->{ranges}) && keys(%$spec) == 2;
        _invalid() unless $kind eq 'numeric' || $kind eq 'year';
        _invalid() unless _integer($spec->{step}) && $spec->{step} >= 1 && $spec->{step} <= 1_000_000_000;
        return {kind => $kind, step => 0 + $spec->{step}};
    }
    _invalid() if grep { !/\A(?:kind|ranges)\z/ } keys %$spec;
    my $ranges = $spec->{ranges};
    _invalid() unless ref($ranges) eq 'ARRAY' && @$ranges >= 1 && @$ranges <= $limits->{max_buckets};
    my (%labels, @resolved);
    for my $range (@$ranges) {
        _invalid() unless ref($range) eq 'HASH' && !grep { !/\A(?:min|max|label)\z/ } keys %$range;
        my ($min, $max, $label) = @$range{qw(min max label)};
        _invalid() unless defined($min) || defined($max);
        _invalid() if grep { defined($_) && !_json_integer($_) } $min, $max;
        _invalid() if defined($min) && defined($max) && $min > $max;
        _invalid() unless _string($label) && length($label) >= 1 && length($label) <= 80
            && $label !~ /[\x00-\x1f\x7f-\x9f]/ && $label ne 'Other' && !$labels{$label}++;
        push @resolved, {label => $label, min => $min, max => $max,
            where => $self->_range_bounds($plan, $field, $kind, $min, $max)};
    }
    return {kind => $kind, ranges => \@resolved};
}

# [[operator, literal], ...] bounds for one inclusive range of a bucket kind.
sub _range_bounds ($self, $plan, $field, $kind, $min, $max) {
    if ($kind eq 'numeric') {
        return [(defined($min) ? (['gte', 0 + $min]) : ()), (defined($max) ? (['lte', 0 + $max]) : ())];
    }
    my ($low, $high);    # day offsets or years, as inclusive bounds on the date
    my $instant = $field->{type} eq 'utc_datetime';
    my $day = sub ($date) { $instant ? Selecto::DateShortcut->day_start_instant($date, $plan->{zone}) : $date };
    if ($kind eq 'year') {
        my @bounds;
        push @bounds, $min <= 1 ? () : $min > 9999 ? (['gte', $day->('9999-12-31')], ['lt', $day->('0001-01-01')])
            : (['gte', $day->(sprintf('%04d-01-01', $min))]) if defined $min;
        push @bounds, $max >= 9999 ? () : $max < 1 ? (['lt', $day->('0001-01-01')])
            : (['lt', $day->(sprintf('%04d-01-01', $max + 1))]) if defined $max;
        return @bounds ? \@bounds : [['gte', $day->('0001-01-01')]];
    }
    # elapsed_days: today - date in [min, max]; relative_days: date - today.
    my ($from, $to) = $kind eq 'elapsed_days'
        ? ((defined($max) ? -$max : undef), (defined($min) ? -$min : undef))
        : ($min, $max);
    my @bounds;
    if (defined $from) {
        my $date = _offset_date($plan->{today}, $from);
        push @bounds, !defined($date) ? ($from < 0 ? () : (['gte', $day->('9999-12-31')], ['lt', $day->('0001-01-01')]))
            : (['gte', $day->($date)]);
    }
    if (defined $to) {
        my $date = _offset_date($plan->{today}, $to + 1);
        push @bounds, !defined($date) ? ($to > 0 ? () : (['lt', $day->('0001-01-01')]))
            : (['lt', $day->($date)]);
    }
    return @bounds ? \@bounds : [['gte', $day->('0001-01-01')]];
}

sub _offset_date ($today, $days) {
    return undef if abs($days) > 3_000_000;
    my ($y, $m, $d) = split /-/, $today;
    my $date = DateTime->new(year => $y, month => $m, day => $d, time_zone => 'UTC')->add(days => $days);
    return undef if $date->year < 1 || $date->year > 9999;
    return $date->ymd('-');
}

# An instant converted to a non-UTC zone needs supports.timezones "iana".
sub _instant_use ($self, $plan, $field) {
    _reject('operation_unsupported')
        if $field->{type} eq 'utc_datetime' && $plan->{utc_host} && $plan->{zone} ne 'UTC';
}

sub _filter_node ($self, $context, $plan, $node, $depth, $leaves) {
    _invalid() unless ref($node) eq 'HASH';
    if (_is_group($node)) {
        _invalid() if keys(%$node) != 1;
        my ($conjunction) = keys %$node;
        my $members = $node->{$conjunction};
        _invalid() unless ref($members) eq 'ARRAY' && @$members;
        _invalid() if $depth + 1 > $self->limits->{max_filter_depth};
        my @translated = map { $self->_filter_node($context, $plan, $_, $depth + 1, $leaves) } @$members;
        return @translated == 1 ? $translated[0] : {$conjunction => \@translated};
    }
    _invalid() if ++$$leaves > $self->limits->{max_filters};
    my $catalogue = $context->{catalogue}{by_path};
    _invalid() unless _string($node->{field}) && _string($node->{op});
    my $field = $catalogue->{$node->{field}};
    _reject('invalid_field') unless $field->{filterable};
    my $op = $node->{op};
    if (exists $node->{format}) {
        _invalid() if grep { !/\A(?:field|format|op|value)\z/ } keys %$node;
        _invalid() unless _string($node->{format}) && $GROUP_FORMAT{$node->{format}} && $TEMPORAL{$field->{type}};
        $self->_instant_use($plan, $field);
        if ($op eq 'is_null') {
            _invalid() if exists $node->{value};
            return {field => $field->{path}, format => $node->{format}, op => 'is_null'};
        }
        _invalid() unless $op eq 'eq' && _string($node->{value});
        return {field => $field->{path}, format => $node->{format}, op => 'eq', value => $node->{value}};
    }
    _invalid() if grep { !/\A(?:field|op|value|end)\z/ } keys %$node;
    _invalid() unless grep { $_ eq $op } @{$field->{operators}};
    my %leaf = (field => $field->{path}, op => $op);
    if ($op eq 'is_null' || $op eq 'not_null') {
        _invalid() if exists($node->{value}) || exists($node->{end});
    } elsif ($op eq 'in' || $op eq 'not_in') {
        _invalid() if exists $node->{end};
        my $values = $node->{value};
        _invalid() unless ref($values) eq 'ARRAY' && @$values >= 1 && @$values <= $self->limits->{max_filter_values};
        $leaf{value} = [map { _filter_value($field, $_) } @$values];
    } elsif ($op eq 'between') {
        _invalid() unless exists($node->{value}) && exists($node->{end});
        $leaf{value} = _filter_value($field, $node->{value});
        $leaf{end} = _filter_value($field, $node->{end});
    } elsif ($TEXT_OP{$op}) {
        _invalid() if exists $node->{end};
        _invalid() unless _string($node->{value});
        $leaf{value} = $node->{value};
    } elsif ($op eq 'date_shortcut') {
        _invalid() if exists $node->{end};
        _invalid() unless Selecto::DateShortcut->valid($node->{value});
        $self->_instant_use($plan, $field);
        $leaf{value} = $node->{value};
    } else {
        _invalid() if exists $node->{end};
        $leaf{value} = _filter_value($field, $node->{value});
    }
    return \%leaf;
}

# A JSON scalar of the field's type, as the handler binds it.
sub _filter_value ($field, $value) {
    my $type = $field->{type};
    if ($type eq 'boolean') {
        _invalid() unless JSON::PP::is_bool($value);
        return $value ? JSON::PP::true : JSON::PP::false;
    }
    _invalid() if !defined($value) || ref($value);
    if ($type eq 'integer') {
        _invalid() unless _json_integer($value);
        return 0 + $value;
    }
    if ($type eq 'decimal') {
        return "$value" if _string($value) && $value =~ /\A-?[0-9]{1,30}(?:\.[0-9]{1,30})?\z/;
        _invalid() if _string($value);
        return 0 + $value;
    }
    _invalid() unless _string($value);
    if ($type eq 'date') {
        _invalid() unless Selecto::DateShortcut->valid_date($value);
        return "$value";
    }
    if ($type eq 'naive_datetime') {
        my ($date, $time) = $value =~ /\A(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d{1,9})?\z/;
        _invalid() unless defined($date) && Selecto::DateShortcut->valid_date($date);
        return "$date $time";
    }
    if ($type eq 'utc_datetime') {
        my $epoch = _instant_epoch($value);
        _invalid() unless defined $epoch;
        return DateTime->from_epoch(epoch => $epoch)->strftime('%Y-%m-%dT%H:%M:%SZ');
    }
    return "$value";
}

# ---- execution ----

sub _handler ($self, $plan) {
    my $limits = $self->limits;
    my $rows = max($limits->{max_limit}, $limits->{max_groups} + 1, $limits->{max_count_rows} + 1,
        $limits->{max_export_rows} + 1, 10_000);
    my $engine_limits = $self->engine_limits->tightened(max_collection_rows => 0 + $self->collection_limit);
    return Selecto::API::EngineHandler->new(
        filter_groups => 1, aggregate_selections => 1, explorer_extensions => 1,
        today => $plan->{today}, explorer_timezone => $plan->{zone},
        limits => $engine_limits,
        max_filters => $limits->{max_filters}, max_filter_values => $limits->{max_filter_values},
        max_filter_depth => $limits->{max_filter_depth}, max_orders => $limits->{max_orders} + 1,
        max_fields => $limits->{max_select} * $limits->{max_buckets} + $limits->{max_group_by} + 1,
        max_limit => $rows, default_limit => 1, max_offset => $limits->{max_offset},
    );
}

sub _base_body ($self, $plan, $extra_filters = []) {
    my @filters = (@{$plan->{filters}}, @$extra_filters);
    return (
        (@filters ? (filters => \@filters) : ()),
        (@{$plan->{segments}} ? (segments => $plan->{segments}) : ()),
        (keys(%{$plan->{parameters}}) || @{$plan->{segments}} ? (parameters => $plan->{parameters}) : ()),
    );
}

sub _execute ($self, $context, $plan) {
    my $handler = $self->_handler($plan);
    my $engine = $context->{engine};
    $self->_resolve_instant_steps($handler, $engine, $plan);
    return $self->_execute_grouped($handler, $engine, $plan) if $plan->{mode} eq 'grouped';
    return $self->_execute_summary($handler, $engine, $plan) if $plan->{mode} eq 'summary';
    return $self->_execute_detail($handler, $engine, $plan);
}

sub _execute_detail ($self, $handler, $engine, $plan) {
    my $key = $engine->domain->primary_key;
    my (@select, $index);
    for my $selection (@{$plan->{selections}}) {
        $index++;
        if ($selection->{kind} eq 'collection') {
            my $child = 0;
            push @select, [map { {field => $_->{path}, alias => 'k' . $child++} } @{$selection->{children}}];
        } else {
            push @select, {field => $selection->{path}, alias => "c$index",
                (defined($selection->{format}) ? (format => $selection->{format}) : ())};
        }
    }
    my @orders = map { {field => $_->{path}, direction => $_->{direction}} } @{$plan->{orders}};
    push @orders, {field => $key, direction => 'asc'}
        if defined($key) && !ref($key) && !grep { $_->{field} eq $key } @orders;
    my $export = $plan->{export};
    my $limit = $export ? $self->limits->{max_export_rows} + 1 : $plan->{limit};
    my $total;
    if ($plan->{count} eq 'exact' && !$export) {
        my $budget = $self->limits->{max_count_rows};
        my $counted = $handler->query($engine, {select => [{field => $key, alias => 'k'}],
            $self->_base_body($plan), limit => $budget + 1});
        _reject('count_unavailable') if @{$counted->{rows}} > $budget;
        $total = scalar @{$counted->{rows}};
    }
    # A zero page still validates the query without reading rows.
    my $result = $handler->query($engine, {select => \@select, $self->_base_body($plan), order_by => \@orders,
        limit => $limit, ($export ? () : (offset => $plan->{offset}))});
    _reject('export_limit_exceeded') if $export && @{$result->{rows}} > $self->limits->{max_export_rows};
    my @rows = map { $self->_detail_row($plan, $_) } @{$result->{rows}};
    my %subtables = map {
        ($_->{id} => {columns => [map { $_->{id} } @{$_->{children}}], limit => 0 + $self->collection_limit,
            complete => JSON::PP::true})
    } grep { $_->{type} eq 'collection' } @{$plan->{columns}};
    return {rows => \@rows, has_more => !$export && $result->{has_more} ? 1 : 0,
        subtables => \%subtables, total_count => $total};
}

sub _detail_row ($self, $plan, $raw) {
    my @values;
    for my $index (0 .. $#{$plan->{columns}}) {
        my $column = $plan->{columns}[$index];
        my $value = $raw->[$index];
        if ($column->{type} eq 'collection') {
            my @children = map {
                my $child = $_;
                my @cells = map { _wire($child->[$_], $column->{children}[$_]{type}) } 0 .. $#{$column->{children}};
                $plan->{row_format} eq 'objects'
                    ? +{map { ($column->{children}[$_]{id} => $cells[$_]) } 0 .. $#cells} : \@cells;
            } @{$value // []};
            push @values, \@children;
        } else {
            push @values, _wire($value, $column->{type});
        }
    }
    return $self->_shape_row($plan, \@values);
}

sub _shape_row ($self, $plan, $values) {
    return $values unless $plan->{row_format} eq 'objects';
    return +{map { ($plan->{columns}[$_]{id} => $values->[$_]) } 0 .. $#{$plan->{columns}}};
}

# Handler aggregate entries for the plan's aggregate selections, in column
# order, with their column ids.
sub _aggregate_entries ($self, $plan) {
    my @entries;
    my $index = 0;
    for my $selection (grep { $_->{kind} eq 'aggregate' || $_->{kind} eq 'bucket_count' } @{$plan->{selections}}) {
        if ($selection->{kind} eq 'bucket_count') {
            for my $range_index (0 .. $#{$selection->{bucket}{ranges}}) {
                my $range = $selection->{bucket}{ranges}[$range_index];
                push @entries, [$selection->{columns}[$range_index], {aggregate => 'count_where',
                    field => $selection->{field}{path}, alias => 'a' . $index++, where => $range->{where}}];
            }
            next;
        }
        push @entries, [$selection->{columns}[0], {aggregate => $selection->{aggregate},
            ($selection->{field} ? (field => $selection->{field}{path}) : ()),
            ($selection->{auto} ? (ignore_nulls => 'auto') : ()), alias => 'a' . $index++}];
    }
    return \@entries;
}

sub _execute_summary ($self, $handler, $engine, $plan) {
    my $entries = $self->_aggregate_entries($plan);
    my $result = $handler->query($engine, {select => [map { $_->[1] } @$entries], $self->_base_body($plan), limit => 1});
    my $raw = $result->{rows}[0] // [];
    my %values = map { ($entries->[$_][0]{id} => _wire($raw->[$_], $entries->[$_][0]{type})) } 0 .. $#$entries;
    my @all = ($self->_shape_row($plan, [map { $values{$_->{id}} } @{$plan->{columns}}]));
    my @rows = $plan->{export} ? @all : grep { defined } @all[$plan->{offset} .. $plan->{offset} + $plan->{limit} - 1];
    return {rows => \@rows, has_more => !$plan->{export} && @all > $plan->{offset} + $plan->{limit} ? 1 : 0,
        total_count => $plan->{count} eq 'exact' ? 1 : undef};
}

# Year steps over instants become ranges, one per non-empty step: the
# distinct years (in the request zone) of the matching rows, at most 9999,
# give the step starts, so a wide sparse span costs nothing.
sub _resolve_instant_steps ($self, $handler, $engine, $plan) {
    for my $group (grep { $_->{kind} eq 'bucket' && $_->{bucket}{step} && $_->{bucket}{kind} eq 'year'
            && $_->{field}{type} eq 'utc_datetime' } @{$plan->{groups}}) {
        my $path = $group->{field}{path};
        my $result = $handler->query($engine, {select => [{group => 'y'}],
            group_by => [{field => $path, alias => 'y', format => 'year'}],
            $self->_base_body($plan), limit => 10_000});
        my $step = $group->{bucket}{step};
        my %starts;
        for my $row (@{$result->{rows}}) {
            next unless defined($row->[0]) && $row->[0] =~ /\A[0-9]{1,4}\z/;
            $starts{_floor_div(0 + $row->[0], $step) * $step} = 1;
        }
        _reject('result_limit_exceeded') if keys(%starts) > $self->limits->{max_groups};
        my @ranges = map {
            {label => $_ . '-' . ($_ + $step - 1), start => $_,
                where => $self->_range_bounds($plan, $group->{field}, 'year', $_, $_ + $step - 1)}
        } sort { $a <=> $b } keys %starts;
        @ranges = ({label => 'Other', start => 0, where => [['lt', '0001-01-01T00:00:00Z']]}) unless @ranges;
        $group->{bucket} = {kind => 'year', step => $step, ranges => \@ranges, instant_steps => 1};
    }
}

sub _group_entry ($group) {
    return $group->{path} if $group->{kind} eq 'plain';
    return {field => $group->{path}, alias => 'g' . $group->{index}, format => $group->{format}}
        if $group->{kind} eq 'format';
    my $bucket = $group->{bucket};
    return {field => $group->{path}, alias => 'g' . $group->{index}, step => $bucket->{step}, kind => $bucket->{kind}}
        if $bucket->{step} && !$bucket->{ranges};
    return {field => $group->{path}, alias => 'g' . $group->{index},
        ranges => [map { {where => $_->{where}, label => $_->{label}} } @{$bucket->{ranges}}]};
}

sub _execute_grouped ($self, $handler, $engine, $plan) {
    my @groups = @{$plan->{groups}};
    my $entries = $self->_aggregate_entries($plan);
    my $max_groups = $self->limits->{max_groups};
    my @levels = $plan->{rollup} ? reverse(0 .. @groups) : (scalar @groups);
    my @merged;
    for my $level (@levels) {
        my @present = @groups[0 .. $level - 1];
        my @select = ((map { $_->{kind} eq 'plain' ? {field => $_->{path}, alias => 'g' . $_->{index}}
                : {group => 'g' . $_->{index}} } @present), map { $_->[1] } @$entries);
        my $rows;
        if (!@select) {
            $rows = [[]];
        } else {
            my $result = $handler->query($engine, {select => \@select, $self->_base_body($plan),
                (@present ? (group_by => [map { _group_entry($_) } @present]) : ()),
                limit => $max_groups + 1});
            $rows = $result->{rows};
        }
        _reject('result_limit_exceeded') if @merged + @$rows > $max_groups;
        for my $raw (@$rows) {
            my @keys = map { $_ < $level ? _wire($raw->[$_], $groups[$_]{type}) : undef } 0 .. $#groups;
            my %aggregates = map {
                ($entries->[$_][0]{id} => _wire($raw->[$level + $_], $entries->[$_][0]{type}))
            } 0 .. $#$entries;
            push @merged, {level => $level, keys => \@keys, aggregates => \%aggregates};
        }
    }
    my $total = grep { $_->{level} == @groups } @merged;
    if ($plan->{count} eq 'exact' && !$plan->{export}) {
        _reject('count_unavailable') if $total > $self->limits->{max_count_rows};
    }
    my $compare = sub ($a, $b) {
        my $c = 0;
        unless ($plan->{rollup}) {
            for my $order (@{$plan->{orders}}) {
                $c = $order->{group}
                    ? _compare_key($order->{group}, $a->{keys}[$order->{group}{index}], $b->{keys}[$order->{group}{index}])
                    : _compare_value($a->{aggregates}{$order->{column}{id}}, $b->{aggregates}{$order->{column}{id}},
                        $order->{column}{type});
                if ($c) { $c = -$c if $order->{direction} eq 'desc'; return $c }
            }
        }
        for my $group (@groups) {
            my $i = $group->{index};
            my ($ra, $rb) = ($i < $a->{level} ? 0 : 1, $i < $b->{level} ? 0 : 1);
            $c = $ra <=> $rb || ($ra ? 0 : _compare_key($group, $a->{keys}[$i], $b->{keys}[$i]));
            return $c if $c;
        }
        return 0;
    };
    @merged = sort { $compare->($a, $b) } @merged;
    my $cells = @merged * @{$plan->{columns}};
    my @page;
    my $has_more = 0;
    if ($plan->{export}) {
        @page = @merged;
        _reject('export_limit_exceeded') if @page > $self->limits->{max_export_rows} && $plan->{export}{shape} eq 'rows';
    } elsif ($plan->{complete}) {
        _reject('result_limit_exceeded') if @merged > $plan->{limit} || $cells > $self->limits->{max_result_cells};
        @page = @merged;
    } else {
        @page = grep { defined } @merged[$plan->{offset} .. $plan->{offset} + $plan->{limit} - 1];
        $has_more = @merged > $plan->{offset} + $plan->{limit} ? 1 : 0;
    }
    my @rows = map {
        my $item = $_;
        $self->_shape_row($plan, [map {
            $_->{role} eq 'group' ? $item->{keys}[$_->{group}{index}] : $item->{aggregates}{$_->{id}}
        } @{$plan->{columns}}]);
    } @page;
    my @row_meta = map { _row_meta($plan, $_) } @page;
    return {rows => \@rows, has_more => $has_more, row_meta => \@row_meta, merged => \@page,
        total_count => $plan->{count} eq 'exact' ? $total : undef};
}

sub _row_meta ($plan, $item) {
    my @groups = @{$plan->{groups}};
    my $level = $item->{level};
    return {level => 0, kind => 'total', drilldown => undef} if $level == 0;
    my $kind = $level == @groups ? 'detail' : 'subtotal';
    my @present = @groups[0 .. $level - 1];
    my $drilldown;
    unless (grep { $_->{kind} eq 'bucket' } @present) {
        $drilldown = {column => $present[-1]{id}, filters => [map {
            my $value = $item->{keys}[$_->{index}];
            {field => $_->{path}, ($_->{kind} eq 'format' ? (format => $_->{format}) : ()),
                (defined($value) ? (op => 'eq', value => _copy_scalar($value, $_->{type})) : (op => 'is_null'))};
        } @present]};
    }
    return {level => $level, kind => $kind, drilldown => $drilldown};
}

# Grouped keys order by type: nulls first, numbers numerically, text by code
# point, booleans false first; bucket labels by range position (steps by
# their start), Other last.
sub _compare_key ($group, $x, $y) {
    return _compare_value($x, $y, $group->{type}) unless $group->{kind} eq 'bucket';
    return _bucket_rank($group, $x) <=> _bucket_rank($group, $y);
}

sub _bucket_rank ($group, $label) {
    return 9**99 if !defined($label) || $label eq 'Other';
    my $bucket = $group->{bucket};
    if ($bucket->{ranges}) {
        for my $index (0 .. $#{$bucket->{ranges}}) {
            return $bucket->{instant_steps} ? $bucket->{ranges}[$index]{start} : $index
                if $bucket->{ranges}[$index]{label} eq $label;
        }
        return 9**98;
    }
    my ($start) = $label =~ /\A(-?[0-9]+)-/;
    return defined($start) ? 0 + $start : 9**98;
}

sub _compare_value ($x, $y, $type) {
    return defined($x) ? 1 : defined($y) ? -1 : 0 unless defined($x) && defined($y);
    return ($x ? 1 : 0) <=> ($y ? 1 : 0) if $type eq 'boolean';
    if ($NUMERIC{$type}) {
        return Math::BigFloat->new("$x")->bcmp(Math::BigFloat->new("$y"));
    }
    return "$x" cmp "$y";
}

# ---- export ----

sub _export_response ($self, $plan, $result, $format) {
    my ($columns, $rows) = ([map { $_->{id} } @{$plan->{columns}}], $result->{rows});
    $rows = [map { ref($_) eq 'HASH' ? [my @r = @$_{@$columns}] : $_ } @$rows];
    ($columns, $rows) = _grid($plan, $result) if $plan->{export}{shape} eq 'grid';
    _reject('export_limit_exceeded') if @$rows > $self->limits->{max_export_rows};
    my $specification = Selecto::API::ResultFormatter->specification($format);
    my $body = $format eq 'json'
        ? Selecto::API::canonical_json({data => {columns => $columns, rows => _numify_rows($plan, $rows, $columns)},
            ok => JSON::PP::true})
        : Selecto::API::ResultFormatter->encode_result($format, {columns => $columns,
            rows => _numify_rows($plan, $rows, $columns)}, limits => $self->engine_limits);
    my $filename = ($self->id =~ s/[^A-Za-z0-9_.-]+/_/gr) . '.' . $specification->{extension};
    return {status => 200, content_type => $specification->{content_type},
        headers => {'content-type' => $specification->{content_type},
            'content-disposition' => qq{attachment; filename="$filename"},
            'content-length' => '' . length($body), 'x-content-type-options' => 'nosniff'},
        body => $body};
}

# One row per first-key value, one column per second-key value (in group
# order), each cell the aggregate or null.
sub _grid ($plan, $result) {
    my ($first, $second) = @{$plan->{groups}};
    my ($measure) = grep { $_->{role} eq 'aggregate' } @{$plan->{columns}};
    my (@firsts, %first_seen, @seconds, %cells);
    my $text = sub ($value) { !defined($value) ? '' : JSON::PP::is_bool($value) ? ($value ? 'true' : 'false') : "$value" };
    for my $item (@{$result->{merged}}) {
        my ($x, $y) = map { $item->{keys}[$_->{index}] } $first, $second;
        push @firsts, $x unless $first_seen{$text->($x) . (defined($x) ? 'v' : 'n')}++;
        push @seconds, $y unless grep { _compare_key($second, $_, $y) == 0 && defined($_) == defined($y) } @seconds;
        $cells{$text->($x) . (defined($x) ? 'v' : 'n')}{$text->($y) . (defined($y) ? 'v' : 'n')} = $item->{aggregates}{$measure->{id}};
    }
    @seconds = sort { _compare_key($second, $a, $b) } @seconds;
    my @columns = ($first->{id}, map { $text->($_) } @seconds);
    my @rows = map {
        my $x = $_;
        my $row = $cells{$text->($x) . (defined($x) ? 'v' : 'n')};
        [$x, map { $row->{$text->($_) . (defined($_) ? 'v' : 'n')} } @seconds];
    } @firsts;
    return (\@columns, \@rows);
}

sub _numify_rows ($plan, $rows, $columns) {
    return $rows;
}

# ---- encoding ----

sub _public_column ($column) {
    return {id => $column->{id}, label => $column->{label}, type => $column->{type},
        encoding => $column->{type} eq 'collection' ? 'json' : _encoding($column->{type}),
        nullable => _bool($column->{nullable}), role => $column->{role},
        (map { defined($column->{$_}) ? ($_ => $column->{$_}) : () } qw(field aggregate format bucket))};
}

sub _canonical_type ($declared) {
    my $type = lc($declared // '');
    return 'string' if $type =~ /\A(?:string|text|varchar|char|citext|uuid)\z/;
    return 'integer' if $type =~ /\A(?:integer|int|bigint|smallint|serial|bigserial)\z/;
    return 'decimal' if $type =~ /\A(?:decimal|numeric|number|float|double|real)\z/;
    return 'boolean' if $type eq 'boolean';
    return 'date' if $type eq 'date';
    return 'naive_datetime' if $type =~ /\A(?:naive_datetime|datetime|timestamp)\z/;
    return 'utc_datetime' if $type =~ /\A(?:utc_datetime|timestamptz)\z/;
    return undef;
}

sub _encoding ($type) {
    return 'decimal-string' if $type eq 'decimal';
    return 'json' if $type eq 'integer' || $type eq 'boolean';
    return 'string';
}

# A database value as its canonical wire scalar.
sub _wire ($value, $type) {
    return undef unless defined $value;
    if ($type eq 'integer') {
        my $text = "$value";
        $text =~ s/\.0+\z//;
        return $text if $text =~ /\A-?[0-9]+\z/ && length($text =~ s/-//r) > 15
            && Math::BigInt->new($text)->babs->bcmp('9007199254740991') > 0;
        return 0 + $text;
    }
    if ($type eq 'decimal') {
        my $text = "$value";
        $text = Math::BigFloat->new($text)->bstr if $text =~ /e/i;
        return $text;
    }
    if ($type eq 'boolean') {
        return $value ? JSON::PP::true : JSON::PP::false if JSON::PP::is_bool($value);
        return $value =~ /\A(?:1|t|true)\z/i ? JSON::PP::true : JSON::PP::false;
    }
    my $text = "$value";
    if ($type eq 'date') {
        $text = $1 if $text =~ /\A(\d{4}-\d{2}-\d{2})/;
        return $text;
    }
    if ($type eq 'naive_datetime') {
        return "$1T$2" if $text =~ /\A(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})/;
        return $text;
    }
    if ($type eq 'utc_datetime') {
        # Database text: an offset of +HH, +HHMM or +HH:MM (PostgreSQL in the
        # session zone), Z, or none (UTC text).
        my ($date, $time, $sign, $hours, $minutes) = $text
            =~ /\A(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2})(?::?(\d{2}))?)?\z/i;
        return $text unless defined $date;
        my $epoch = _instant_epoch("${date}T$time" . (defined($sign) ? sprintf('%s%s:%s', $sign, $hours, $minutes // '00') : 'Z'));
        return defined($epoch) ? DateTime->from_epoch(epoch => $epoch)->strftime('%Y-%m-%dT%H:%M:%SZ') : $text;
    }
    return $text;
}

# A fresh copy of a wire scalar (numbers stay JSON numbers).
sub _copy_scalar ($value, $type) {
    return $value if ref($value);
    return 0 + $value if $type eq 'integer' && $value =~ /\A-?[0-9]+\z/ && length($value) <= 15;
    return "$value";
}

# ---- envelopes and errors ----

sub _error_response ($self, $error, $request) {
    my $code = blessed($error) && $error->isa('Selecto::Error') ? $error->code : 'internal_failure';
    warn 'Selecto::API::Explorer: ' . (blessed($error) && $error->isa('Selecto::Error') ? $error->code . ': ' . $error->message : $error) . "\n"
        if $ENV{SELECTO_EXPLORER_DEBUG};
    $code = $ERROR_CODE{$code} // $code;
    $code = 'internal_failure' unless exists $ERROR_STATUS{$code};
    my $body = {ok => JSON::PP::false,
        error => {code => $code, message => 'Explorer request could not be completed.', details => {}}};
    my $id = ref($request) eq 'HASH' && ref($request->{body}) eq 'HASH' ? $request->{body}{request_id} : undef;
    $body->{meta} = {request_id => $id} if _request_id($id);
    return _json_response($ERROR_STATUS{$code} // 500, $body);
}

sub _json_response ($status, $value) {
    my $body = $JSON->encode($value);
    my $type = 'application/json; charset=utf-8';
    return {status => $status, content_type => $type,
        headers => {'content-type' => $type, 'content-length' => '' . length($body)}, body => $body};
}

sub _normalize_response ($response) {
    my $type = $response->{content_type} // ($response->{headers} // {})->{'content-type'};
    return {%$response, content_type => $type, headers => {%{$response->{headers} // {}}, 'content-type' => $type}};
}

sub _fingerprint ($engine) {
    my $contract = $engine->domain->contract // {};
    return $contract->{domain_fingerprint} // $engine->domain->fingerprint;
}

sub _is_group ($node) {
    return ref($node) eq 'HASH' && (exists($node->{any}) xor exists($node->{all})) && !exists($node->{field}) ? 1 : 0;
}

sub _instant_epoch ($value) {
    return undef unless _string($value);
    my ($y, $mo, $d, $h, $mi, $s, $fraction, $zone) = $value
        =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/i;
    return undef unless defined $y;
    my $instant = eval { DateTime->new(year => $y, month => $mo, day => $d, hour => $h, minute => $mi,
        second => $s, time_zone => uc($zone) eq 'Z' ? 'UTC' : $zone) };
    return $instant ? $instant->epoch : undef;
}

sub _floor_div ($x, $y) { my $q = int($x / $y); $q-- if $q * $y > $x; return $q }
sub _bool ($value) { return $value ? JSON::PP::true : JSON::PP::false }
sub _string ($value) { return defined($value) && !ref($value) && (B::svref_2object(\$value)->FLAGS & B::SVf_POK) ? 1 : 0 }
sub _json_integer ($value) {
    return defined($value) && !ref($value) && !_string($value) && $value =~ /\A-?[0-9]{1,15}\z/ ? 1 : 0;
}
sub _integer ($value) { return _json_integer($value) && $value >= 0 ? 1 : 0 }
sub _request_id ($value) { return _string($value) && length($value) >= 1 && length($value) <= 128 ? 1 : 0 }
sub _reject ($code) { Selecto::Error->throw($code, 'Explorer request could not be completed.') }
sub _invalid () { _reject('invalid_query') }
sub _host_error ($message) { Selecto::Error->throw('invalid_api_host', $message) }

1;

__END__

=head1 NAME

Selecto::API::Explorer - remote_query.explorer.v1 over the canonical query handler

=head1 SYNOPSIS

  my $explorer = Selecto::API::Explorer->new(
      base_path => '/api/v1/orders', id => 'orders', label => 'Orders',
      publication => $publication, clock => '2026-03-15T03:30:00Z',
      default_limit => 30, count_exact => 1, collection_limit => 20,
      limits => {max_limit => 100, max_groups => 1000},
  );
  # In a route, after authentication, with a fresh trusted engine:
  my $response = $explorer->request($engine, {method => 'POST',
      path => '/api/v1/orders/explorer-query', content_type => 'application/json',
      accept => 'application/json', body => $decoded_json});
  # {status, content_type, headers, body (bytes)}

=head1 DESCRIPTION

An HTTP-neutral host for the explorer wire profile
(C<docs/remote_query_explorer.md> in selecto_backend_certification):

=over 4

=item C<GET base_path>

The C<remote_query.v1> manifest of L<Selecto::API::RemoteQuery>, with
C<remote_query.explorer.v1> in C<profiles> and the C<getExplorerFeatures> and
C<queryExplorer> routes.

=item C<GET base_path/explorer-features>

The C<selecto.explorer-features> v1 document: the public fields a query may
name with their type-derived operators, aggregates, group formats, buckets
and date shortcuts, collections, limits, query-library segments and the
C<supports> flags. Its revision is C<sha256:> and the hex SHA-256 of its
canonical JSON without the revision.

=item C<POST base_path/explorer-query>

A C<selecto.explorer-query> v1 request. Refusals follow the profile's order,
all before SQL: media type (415, also for no Content-Type), envelope (400
C<malformed_request>, then C<unsupported_protocol_version>), domain
fingerprint and features revision (409), trusted tenant scope (403
C<missing_tenant_scope>), member C<supports> (501), the field pre-pass (403
C<hidden_field> or 422 C<invalid_field>, first reference first), a UTC-only
host's instant conversions (501), then shape and limits (422). Detail rows
sort nulls first ascending and last descending; rollup rows are paged
together; step buckets are bounded only by C<max_groups>. Results carry typed columns,
C<row_meta> drilldowns for grouped rows, bounded exact counts and C<complete>
grids; C<export> returns CSV, TSV, JSON or XLSX of the whole result.

=back

Anything else is passed to L<Selecto::API::RemoteQuery>.

Every query runs through L<Selecto::API::EngineHandler> with
C<filter_groups>, C<aggregate_selections> and C<explorer_extensions>, the
trusted C<today> (the calendar date of C<clock> in the request's time zone)
and C<explorer_timezone>, so tenant boundaries, field visibility, roles and
execution are the canonical handler's. Grouped rows (at most C<max_groups>)
are ordered and paged here; rollup runs one grouped query per prefix of the
group keys. Range buckets are compiled with literal bounds from the trusted
clock, never the database's current time. PostgreSQL hosts advertise
C<supports.timezones> C<iana>; other adapters C<utc>, and refuse (501) a
request that would convert an instant to another zone.

=head1 CONSTRUCTOR

C<base_path>, C<id>, C<publication> and C<clock> (an RFC 3339 instant) are
required. C<label>, C<default_limit>, C<count_exact>, C<collection_limit>,
C<limits> (the profile's fourteen limits), C<supports> (flag overrides and
C<export>), C<services>, C<links>, C<publish_domain> and C<engine_limits> (a
L<Selecto::Limits>) are optional. Invalid configuration throws
C<invalid_api_host>.

=head1 SEE ALSO

L<Selecto::API::EngineHandler>, L<Selecto::API::RemoteQuery>, L<Selecto::API::Spa>

=cut
