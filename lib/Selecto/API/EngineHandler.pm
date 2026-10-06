package Selecto::API::EngineHandler;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::API::ResultFormatter ();
use Selecto::API::ResponsePolicy ();
use Selecto::OperationBudget ();
use Selecto::Engine ();
use Selecto::Error ();
use Selecto::DateShortcut ();
use Selecto::DateFormat ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::QueryLibrary ();
use Selecto::Limits ();
use Selecto::Write ();

has max_fields        => 100;
has max_filters       => 20;
has max_filter_values => 100;
has max_orders        => 10;
has max_segments      => 20;
has max_limit         => 1000;
# Deep offsets make the database scan and discard every earlier row.
has max_offset        => 100_000;
has default_limit     => 100;
has max_write_count   => 1000;
has limits => sub { Selecto::Limits->new };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    Selecto::Error->throw('invalid_api_handler', 'limits must be a Selecto::Limits')
        unless blessed($self->limits) && $self->limits->isa('Selecto::Limits');
    for my $name (qw(
        max_fields max_filters max_filter_values max_orders max_segments
        max_limit max_offset default_limit max_write_count
    )) {
        my $value = $self->$name;
        Selecto::Error->throw(
            'invalid_api_handler', "$name must be a non-negative integer",
        ) unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/;
        $self->$name(0 + $value);
    }
    Selecto::Error->throw(
        'invalid_api_handler', 'default_limit cannot exceed max_limit',
    ) if $self->default_limit > $self->max_limit;
    Selecto::Error->throw(
        'invalid_api_handler', 'max_write_count must be positive',
    ) if $self->max_write_count < 1;
    $self->max_filter_values($self->limits->get('max_filter_values'))
        if $self->max_filter_values > $self->limits->get('max_filter_values');
    $self->max_fields($self->limits->get('max_fields'))
        if $self->max_fields > $self->limits->get('max_fields');
    $self->limits($self->limits->tightened(
        max_filter_values => $self->max_filter_values, max_fields => $self->max_fields,
    ));
    return $self;
}

sub write ($self, $engine, $body) {
    my $command = $self->write_command($engine, $body);
    $engine = $self->_engine_with_limits($engine);
    return Selecto::API::ResponsePolicy->bind_limits(
        $engine->execute_write($command)->to_hash, $self->limits->intersect($engine->limits));
}

sub write_command ($self, $engine, $body) {
    Selecto::Error->throw(
        'invalid_api_host', 'API write handler requires a Selecto engine',
    ) unless blessed($engine) && $engine->isa('Selecto::Engine');
    $self = $self->_for_engine($engine);
    $engine = $self->_engine_with_limits($engine);
    _write_object($body, 'write body');
    $self->_admit_body($body, 'invalid_api_write');
    _write_reject_unknown($body, [qw(
        operation assignments filters expected_count returning
        conflict_target upsert_update_fields
    )], 'write body');

    my $operation = lc _write_required_string($body->{operation}, 'write operation');
    Selecto::Error->throw(
        'invalid_api_write', 'write operation must be insert, update, upsert, or delete',
        {operation => $operation},
    ) unless $operation =~ /\A(?:insert|update|upsert|delete)\z/;

    my $domain = $engine->domain;
    my $writes = $domain->writes;
    my $operation_spec = ref($writes->{operations}) eq 'HASH'
        ? $writes->{operations}{$operation} : undef;
    Selecto::Error->throw(
        'write_operation_not_enabled',
        "operation $operation is not published by the API write contract",
    ) unless ref($operation_spec) eq 'HASH' && $operation_spec->{enabled};

    my $assignments = $body->{assignments} // {};
    _write_object($assignments, 'assignments');
    if ($operation eq 'insert' || $operation eq 'upsert') {
        my $field_specs = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : {};
        my @missing = sort grep {
            my $spec = $field_specs->{$_};
            ref($spec) eq 'HASH' && $spec->{required}
                && _required_write_value_missing($assignments, $_)
        } keys %$field_specs;
        Selecto::Error->throw(
            'missing_required_write_fields',
            "$operation is missing required fields: " . join(', ', @missing),
            {operation => $operation, fields => \@missing, missing_fields => \@missing},
        ) if @missing;
    }
    Selecto::Error->throw(
        'invalid_api_write', "$operation requires at least one assignment",
    ) if $operation ne 'delete' && !keys %$assignments;
    Selecto::Error->throw(
        'invalid_api_write', 'delete does not accept assignments',
    ) if $operation eq 'delete' && keys %$assignments;
    my %normalized_assignments = map {
        my $field = "$_";
        Selecto::Error->throw(
            'invalid_api_write', 'write assignments must use root domain fields',
            {field => $field},
        ) if $field =~ /\./;
        my $definition = _public_field_definition($domain, $field);
        ($field => _write_assignment_value(
            $assignments->{$field}, $field, $definition,
        ));
    } keys %$assignments;

    my @filters = $self->_write_filters($domain, $body->{filters} // []);
    if ($operation eq 'update' || $operation eq 'delete') {
        Selecto::Error->throw(
            'invalid_api_write', "$operation requires at least one explicit filter",
        ) unless @filters;
        unless ($operation_spec->{bulk}) {
            my $key = $domain->primary_key;
            my $targeted = defined($key) && grep {
                ref($_) eq 'HASH' && ($_->{field} // '') eq $key
                    && lc($_->{op} // '') eq 'eq'
                    && defined($_->{value}) && !ref($_->{value})
            } @{$body->{filters} // []};
            Selecto::Error->throw('invalid_api_write',
                'non-bulk writes require a concrete primary-key equality target') unless $targeted;
        }
    } elsif (@filters) {
        Selecto::Error->throw(
            'invalid_api_write', "$operation does not accept filters",
        );
    }
    my $predicate = @filters == 1 ? $filters[0]
        : @filters ? Selecto::Expression->all(\@filters) : undef;

    my $expected_count = exists($body->{expected_count})
        ? _write_bounded_integer(
            $body->{expected_count}, 'expected_count', 1, $self->max_write_count,
        ) : 1;
    Selecto::Error->throw(
        'invalid_api_write', 'this write operation does not permit bulk changes',
        {expected_count => $expected_count},
    ) if $expected_count > 1 && !$operation_spec->{bulk};
    Selecto::Error->throw(
        'invalid_api_write', 'insert and upsert expect exactly one affected row',
    ) if ($operation eq 'insert' || $operation eq 'upsert') && $expected_count != 1;

    my %metadata;
    for my $key (qw(returning conflict_target upsert_update_fields)) {
        next unless exists $body->{$key};
        my @fields = _write_string_array(
            $body->{$key}, $key, $self->max_fields,
            $key eq 'returning' ? 0 : 1,
        );
        for my $field (@fields) {
            Selecto::Error->throw(
                'invalid_api_write', "$key must use root domain fields",
                {field => $field},
            ) if $field =~ /\./;
            _public_field_definition($domain, $field);
        }
        $metadata{$key} = \@fields;
    }
    if ($operation eq 'upsert') {
        Selecto::Error->throw(
            'invalid_api_write', 'upsert requires conflict_target and upsert_update_fields',
        ) unless @{$metadata{conflict_target} // []}
            && @{$metadata{upsert_update_fields} // []};
    } elsif (exists($metadata{conflict_target}) || exists($metadata{upsert_update_fields})) {
        Selecto::Error->throw(
            'invalid_api_write',
            'conflict_target and upsert_update_fields are only valid for upsert',
        );
    }

    # The engine guards every write with the domain's required predicate
    # (Selecto::Engine::required_write_guard): it refuses upserts and domains
    # whose predicate reaches into an association, and ANDs the predicate
    # into the command when it is governed. Checking here only reports those
    # refusals before the tenant boundary; the command stays unguarded so the
    # predicate is applied exactly once, by the engine.
    # Tenant upserts go through an engine tenant and writes.scope.tenant.
    $engine->required_write_guard($operation);
    $engine->assert_tenant_boundary(access => 'write');
    my $command = Selecto::Write::Command->new(
        operation => $operation,
        relation => $domain->table,
        assignments => \%normalized_assignments,
        predicate => $predicate,
        expected_count => $expected_count,
        metadata => \%metadata,
    );
    # Validate public construction through the same contract as direct/action
    # writes. Return the original so tenant guards are attached exactly once.
    $engine->governed_write($command);
    return $command;
}

sub query ($self, $engine, $body, %options) {
    Selecto::Error->throw(
        'invalid_api_host', 'API query handler requires a Selecto engine',
    ) unless blessed($engine) && $engine->isa('Selecto::Engine');
    $self = $self->_for_engine($engine);
    $engine = $self->_engine_with_limits($engine);
    $engine->assert_tenant_boundary(access => 'read');
    _object($body, 'query body');
    $self->_admit_body($body, 'invalid_api_query');
    _reject_unknown($body, [qw(
        select projection view segments parameters filters ordering order_by limit offset timezone row_format
    )], 'query body');

    my $has_select = exists $body->{select};
    my $has_projection = exists $body->{projection};
    my $has_view = exists $body->{view};
    Selecto::Error->throw(
        'invalid_api_query', 'Use exactly one of select, projection, or view',
    ) unless ($has_select + $has_projection + $has_view) == 1;
    Selecto::Error->throw(
        'invalid_api_query', 'Use either ordering or order_by, not both',
    ) if exists($body->{ordering}) && exists($body->{order_by});

    my $domain = $engine->domain;
    my $query = $engine->query;
    my @segments = _string_array(
        $body->{segments} // [], 'segments', $self->max_segments,
    );
    my $parameters = $body->{parameters} // {};
    _object($parameters, 'parameters');
    my $named_ordering = $body->{ordering};
    my $timezone = exists($body->{timezone})
        ? _required_string($body->{timezone}, 'timezone') : undef;
    my $row_format = lc(exists($body->{row_format})
        ? _required_string($body->{row_format}, 'row_format') : 'arrays');
    Selecto::Error->throw(
        'invalid_api_query', 'row_format must be arrays or objects',
        {row_format => $row_format},
    ) unless $row_format eq 'arrays' || $row_format eq 'objects';
    my @subtables;

    if ($has_select) {
        # Validate caller intent before composing host-mandated output fields.
        _api_selections($domain, $body->{select}, $self->max_fields, $self->limits, $engine->adapter->name);
        my @required = @{($domain->contract // {})->{required_selected} // []};
        my %required = map { $_ => 1 } @required;
        my $field_identity = sub {
            my ($entry) = @_;
            return $entry unless ref($entry);
            return $entry->{field} if ref($entry) eq 'HASH'
                && ($entry->{alias} // $entry->{field}) eq $entry->{field};
            return undef;
        };
        my %authored = map {
            my $field = $field_identity->($_);
            defined($field) ? ($field => $_) : ()
        } @{$body->{select}};
        my @selections = (
            (map { exists($authored{$_}) ? $authored{$_} : $_ } @required),
            (grep { my $field = $field_identity->($_); !defined($field) || !$required{$field} } @{$body->{select}}),
        );
        my $selection_plan = _api_selections(
            $domain, \@selections, $self->max_fields, $self->limits, $engine->adapter->name,
        );
        $query = $query->select($selection_plan->{expressions});
        @subtables = @{$selection_plan->{subtables}};
    } elsif ($has_projection) {
        my @projections = ref($body->{projection}) eq 'ARRAY'
            ? _string_array(
                $body->{projection}, 'projection', $self->max_fields, 1,
            )
            : (_required_string($body->{projection}, 'projection'));
        $query = $engine->apply_projection($query, \@projections);
    } else {
        my $view_id = _required_string($body->{view}, 'view');
        my $view = Selecto::QueryLibrary->definition($domain, 'views', $view_id);
        my $projection = $view->{projection};
        Selecto::Error->throw(
            'invalid_api_query', 'The selected view does not define a projection',
            {view => $view_id},
        ) unless defined($projection) && !ref($projection) && length($projection);
        push @segments, map { _required_string($_, 'view segment') }
            @{$view->{segments} // []};
        Selecto::Error->throw(
            'invalid_api_query', 'Too many combined query-library segments',
        ) if @segments > $self->max_segments;
        $query = $engine->apply_projection($query, $projection);
        $named_ordering = $view->{ordering}
            unless defined($named_ordering) || exists($body->{order_by});
        my $applied = $query->applied_query_library;
        push @{$applied->{views}}, $view_id
            unless grep { $_ eq $view_id } @{$applied->{views}};
        $query = $query->with_applied_query_library($applied);
    }

    if (!$has_select) {
        # Named library definitions are not permission to expose internal fields.
        my @fields = map { $_->arguments->[0] } @{$query->selections};
        my $selection_plan = _api_selections($domain, \@fields, $self->max_fields, $self->limits, $engine->adapter->name);
        $query = $query->replace_selections($selection_plan->{expressions});
    }

    if (@segments) {
        my %seen;
        @segments = grep { !$seen{$_}++ } @segments;
        $query = Selecto::QueryLibrary->apply_segments($domain, $query, \@segments, $parameters, $self->limits);
        # Segments are not permission to filter on an internal field either:
        # with a parameter, a caller could probe its value. They are the only
        # predicate so far (the required predicate is added when compiling).
        _public_field_definition($domain, $_) for Selecto::Expression->field_references($query->predicate);
    } elsif (keys %$parameters) {
        Selecto::Error->throw(
            'invalid_api_query',
            'parameters require a query-library segment or view',
        );
    }

    my @filters = $self->_filters($domain, $body->{filters} // []);
    if (@filters) {
        my $filter = @filters == 1
            ? $filters[0]
            : Selecto::Expression->all(\@filters);
        my $existing = $query->predicate;
        $query = $query->where($existing
            ? Selecto::Expression->all([$existing, $filter])
            : $filter);
    }

    if (defined $named_ordering) {
        my $ordering = _required_string($named_ordering, 'ordering');
        # Sorting by an internal field would reveal its order.
        _public_field_definition($domain, $_->[0])
            for @{Selecto::QueryLibrary->ordering_entries($domain, $ordering)};
        $query = $engine->apply_ordering($query, $ordering);
    } elsif (exists $body->{order_by}) {
        my $orders = $body->{order_by};
        Selecto::Error->throw('invalid_api_query', 'order_by must be an array')
            unless ref($orders) eq 'ARRAY';
        Selecto::Error->throw('invalid_api_query', 'Too many order_by entries')
            if @$orders > $self->max_orders;
        for my $order (@$orders) {
            _object($order, 'order_by entry');
            _reject_unknown($order, [qw(field direction)], 'order_by entry');
            my $field = _required_string($order->{field}, 'order_by field');
            my $direction = lc _required_string(
                $order->{direction} // 'asc', 'order_by direction',
            );
            Selecto::Error->throw(
                'invalid_api_query', 'order_by direction must be asc or desc',
            ) unless $direction eq 'asc' || $direction eq 'desc';
            _public_field_definition($domain, $field);
            $query = $query->order_by($field, $direction);
        }
    }

    my $limit = exists($body->{limit})
        ? _bounded_integer($body->{limit}, 'limit', 0, $self->max_limit)
        : $self->default_limit;
    my $offset = exists($body->{offset})
        ? _bounded_integer($body->{offset}, 'offset', 0, $self->max_offset)
        : 0;
    my $children_per_root = 0;
    $children_per_root += $_->{limit} for @subtables;
    $self->limits->check_count('max_total_collection_rows', $limit * $children_per_root,
        'invalid_api_query', 'requested related collection rows');
    $query = $query->limit($limit)->offset($offset);
    if (defined $timezone) {
        my $ok = eval { $query = $query->use_timezone($timezone); 1 };
        if (!$ok) {
            Selecto::Error->throw(
                'invalid_api_query', 'timezone must be a valid IANA timezone name',
                {timezone => $timezone},
            );
        }
    }

    # A zero-sized page still validates the compiled query, but does not fetch
    # data. SQL Server cannot execute FETCH NEXT 0, so compile with one solely
    # to obtain validated column metadata; never execute that statement.
    my $result = $limit == 0
        ? {columns => $engine->compile($query->limit(1))->columns, rows => []}
        : $engine->all($query, $options{export_scalars} ? (export_scalars => 1) : ());
    Selecto::Error->throw(
        'invalid_api_host', 'Selecto adapter returned an invalid result',
    ) unless ref($result) eq 'HASH'
        && ref($result->{columns}) eq 'ARRAY'
        && ref($result->{rows}) eq 'ARRAY';
    _shape_result_rows($result, \@subtables, $row_format, $self->limits);
    my %subtable_metadata = map {
        $_->{column} => {columns => [@{$_->{columns}}], limit => $_->{limit}, complete => JSON::PP::true}
    } @subtables;
    my $response = {
        columns => $result->{columns},
        rows => $result->{rows},
        returned => scalar(@{$result->{rows}}),
        row_format => $row_format,
        subtables => \%subtable_metadata,
        limit => $limit,
        offset => $offset,
        query_library => $query->applied_query_library,
    };
    # Raw-cell checks precede child decoding; this exact JSON-envelope check
    # also counts escaping, keys and metadata in the eventual public response.
    Selecto::API::ResponsePolicy->check_json({data => $response, ok => JSON::PP::true}, $self->limits);
    return Selecto::API::ResponsePolicy->bind_limits($response, $self->limits);
}

# One input budget includes all scalar filters, both range endpoints, membership
# lists, segment parameters and assignments before normalization or callbacks.
# The compiler separately counts actual emitted occurrences after composition.
sub _admit_body ($self, $body, $code) {
    my $budget = Selecto::OperationBudget->new(limits => $self->limits, code => $code);
    $budget->check_tree($body, label => 'API request');
    my @values;
    push @values, values %{$body->{assignments}} if ref($body->{assignments}) eq 'HASH';
    push @values, values %{$body->{parameters}} if ref($body->{parameters}) eq 'HASH';
    if (ref($body->{filters}) eq 'ARRAY') {
        for my $filter (@{$body->{filters}}) {
            next unless ref($filter) eq 'HASH';
            push @values, $filter->{$_} for grep { exists $filter->{$_} } qw(value end);
        }
    }
    # Parameter maps may group segment parameters. Tree admission has already
    # checked depth, breadth and cycles, so iterating their leaves is bounded.
    while (@values) {
        my $value = pop @values;
        if (ref($value) eq 'ARRAY') { push @values, @$value }
        elsif (ref($value) eq 'HASH') { push @values, values %$value }
        else { $budget->consume_value($value, label => 'API parameter') }
    }
}

sub _for_engine ($self, $engine) {
    my $limits = $self->limits->intersect($engine->limits);
    # Request-local copy: an engine's tighter trusted policy cannot be widened
    # by a handler, and serving it must not mutate a shared handler instance.
    return bless {%$self, limits => $limits,
        max_filter_values => $limits->get('max_filter_values'),
        max_fields => $limits->get('max_fields'),
    }, ref($self);
}

# The generated statement must obey the handler's ceiling as well as the
# original engine's. Copy request-local state; never mutate a shared engine's
# policy while a callback or adapter can re-enter it.
sub _engine_with_limits ($self, $engine) {
    return bless {%$engine, limits => $self->limits->intersect($engine->limits)}, ref($engine);
}

sub describe_openapi ($self, $api) {
    Selecto::Error->throw(
        'invalid_api_host', 'OpenAPI description requires a Selecto API object',
    ) unless blessed($api) && $api->isa('Selecto::API');
    my $openapi = $api->openapi_document;
    my $query_path = $api->base_path . '/query';
    $openapi->{paths}{$query_path}{post}{summary} = 'Run a domain read query';
    $openapi->{paths}{$query_path}{post}{parameters} =
        Selecto::API::ResultFormatter->openapi_parameters;
    $openapi->{paths}{$query_path}{post}{responses}{200}{content} =
        Selecto::API::ResultFormatter->openapi_content;
    $openapi->{paths}{$query_path}{post}{responses}{200}{content}{'application/json'} = {
        schema => {'$ref' => '#/components/schemas/SelectoQueryResponse'},
    };
    $openapi->{components}{schemas}{SelectoSubtableMetadata} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => [qw(columns limit complete)],
        properties => {
            columns => {type => 'array', items => {type => 'string'}},
            limit => {type => 'integer', minimum => 0},
            complete => {type => 'boolean', const => JSON::PP::true},
        },
        description => 'Complete bounded collection in stable primary-key order; oversized collections refuse the query.',
    };
    $openapi->{components}{schemas}{SelectoQueryResponse} = {
        type => 'object', required => [qw(ok data)],
        properties => {
            ok => {type => 'boolean', const => JSON::PP::true},
            data => {
                type => 'object', required => [qw(columns rows subtables)],
                properties => {
                    columns => {type => 'array', items => {type => 'string'}},
                    rows => {type => 'array', items => {oneOf => [{type => 'array'}, {type => 'object'}]}},
                    subtables => {type => 'object', additionalProperties => {
                        '$ref' => '#/components/schemas/SelectoSubtableMetadata',
                    }},
                },
            },
        },
    };
    $openapi->{paths}{$query_path}{post}{requestBody} = {
        required => JSON::PP::true,
        content => {
            'application/json' => {
                schema => {'$ref' => '#/components/schemas/SelectoQuery'},
            },
        },
    };
    $openapi->{components}{schemas}{SelectoQuery} = {
        type => 'object',
        additionalProperties => JSON::PP::false,
        description => 'Choose exactly one of select, projection, or view.',
        properties => {
            select => {
                type => 'array',
                items => {
                    oneOf => [
                        {type => 'string'},
                        {'$ref' => '#/components/schemas/SelectoSelection'},
                        {'$ref' => '#/components/schemas/SelectoSubtableSelection'},
                    ],
                },
                maxItems => $self->max_fields,
            },
            projection => {
                oneOf => [
                    {type => 'string'},
                    {
                        type => 'array', items => {type => 'string'},
                        maxItems => $self->max_fields,
                    },
                ],
            },
            view => {type => 'string'},
            segments => {
                type => 'array', items => {type => 'string'},
                maxItems => $self->max_segments,
            },
            parameters => {type => 'object'},
            filters => {
                type => 'array', maxItems => $self->max_filters,
                items => {'$ref' => '#/components/schemas/SelectoFilter'},
            },
            ordering => {type => 'string'},
            order_by => {
                type => 'array', maxItems => $self->max_orders,
                items => {'$ref' => '#/components/schemas/SelectoOrder'},
            },
            limit => {
                type => 'integer', minimum => 0, maximum => $self->max_limit,
                default => $self->default_limit,
            },
            offset => {type => 'integer', minimum => 0, maximum => $self->max_offset, default => 0},
            timezone => {
                type => 'string',
                description => 'IANA timezone applied to UTC and epoch datetime fields and filters.',
                example => 'America/New_York',
            },
            row_format => {
                type => 'string', enum => [qw(arrays objects)], default => 'arrays',
                description => 'Shape used for root rows and nested subtable rows.',
            },
        },
    };
    $openapi->{components}{schemas}{SelectoSelection} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => ['field'],
        properties => {
            field => {type => 'string'},
            alias => {
                type => 'string', pattern => '^[A-Za-z_][A-Za-z0-9_]*$',
            },
            format => {
                type => 'string',
                enum => [map { $_->{id} } @{Selecto::DateFormat->choices}],
            },
        },
    };
    $openapi->{components}{schemas}{SelectoSubtableSelection} = {
        type => 'array', minItems => 1, maxItems => $self->max_fields,
        description => 'PostgreSQL only. Stable primary-key order; each collection must fit the configured per-parent limit or the request is refused. Successful subtable metadata includes limit and complete=true.',
        'x-selecto-max-rows-per-parent' => $self->limits->get('max_collection_rows'),
        items => {
            oneOf => [
                {type => 'string'},
                {'$ref' => '#/components/schemas/SelectoSelection'},
            ],
        },
    };
    $openapi->{components}{schemas}{SelectoFilter} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => [qw(field op)],
        'x-selecto-date-shortcuts' => Selecto::DateShortcut->choices,
        properties => {
            field => {type => 'string'},
            op => {
                type => 'string',
                enum => [qw(eq ne gt gte lt lte between date_shortcut in not_in is_null not_null
                    starts_with starts_with_ci text_contains text_contains_ci ends_with ends_with_ci)],
            },
            value => {}, end => {},
        },
    };
    $openapi->{components}{schemas}{SelectoOrder} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => ['field'],
        properties => {
            field => {type => 'string'},
            direction => {
                type => 'string', enum => [qw(asc desc)], default => 'asc',
            },
        },
    };
    my $write_path = $api->base_path . '/write';
    $openapi->{paths}{$write_path}{post}{summary} = 'Run a governed domain write';
    $openapi->{paths}{$write_path}{post}{requestBody} = {
        required => JSON::PP::true,
        content => {'application/json' => {
            schema => {'$ref' => '#/components/schemas/SelectoWrite'},
        }},
    };
    $openapi->{components}{schemas}{SelectoWrite} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => ['operation'],
        properties => {
            operation => {type => 'string', enum => [qw(insert update upsert delete)]},
            assignments => {
                type => 'object',
                description => 'Root fields and values permitted by writes.fields.',
            },
            filters => {
                type => 'array', maxItems => $self->max_filters,
                items => {'$ref' => '#/components/schemas/SelectoWriteFilter'},
            },
            expected_count => {
                type => 'integer', minimum => 1, maximum => $self->max_write_count,
                default => 1,
            },
            returning => {type => 'array', items => {type => 'string'}},
            conflict_target => {type => 'array', minItems => 1, items => {type => 'string'}},
            upsert_update_fields => {type => 'array', minItems => 1, items => {type => 'string'}},
        },
    };
    $openapi->{components}{schemas}{SelectoWriteFilter} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => [qw(field op)],
        properties => {
            field => {type => 'string'},
            op => {type => 'string', enum => [qw(eq ne gt gte lt lte in is_null not_null)]},
            value => {},
        },
    };
    return $api;
}

sub _write_filters ($self, $domain, $filters) {
    Selecto::Error->throw('invalid_api_write', 'filters must be an array')
        unless ref($filters) eq 'ARRAY';
    Selecto::Error->throw('invalid_api_write', 'Too many filters')
        if @$filters > $self->max_filters;
    my @expressions;
    for my $filter (@$filters) {
        _write_object($filter, 'write filter');
        _write_reject_unknown($filter, [qw(field op value)], 'write filter');
        my $field = _write_required_string($filter->{field}, 'write filter field');
        Selecto::Error->throw(
            'invalid_api_write', 'write filters must use root domain fields',
            {field => $field},
        ) if $field =~ /\./;
        _public_field_definition($domain, $field);
        my $operator = lc _write_required_string($filter->{op}, 'write filter operator');
        my $operand = Selecto::Expression->field($field);
        if ($operator eq 'is_null' || $operator eq 'not_null') {
            push @expressions, Selecto::Expression->can($operator)->(
                'Selecto::Expression', $operand,
            );
            next;
        }
        if ($operator eq 'in') {
            my $values = $filter->{value};
            Selecto::Error->throw(
                'invalid_api_write', 'in filter value must be a non-empty array',
            ) unless ref($values) eq 'ARRAY' && @$values;
            Selecto::Error->throw('invalid_api_write', 'Too many in filter values')
                if @$values > $self->max_filter_values;
            my $total = 0;
            for my $value (@$values) {
                $total += $self->limits->check_bytes('max_value_bytes', _write_value($value, 'in filter item'), 'invalid_api_write', 'in filter item');
                $self->limits->check_count('max_parameter_bytes', $total, 'invalid_api_write', 'in filter bytes');
            }
            push @expressions, Selecto::Expression->in(
                $operand,
                [map { _write_value($_, 'in filter value') } @$values],
            );
            next;
        }
        Selecto::Error->throw(
            'invalid_api_write', "Unsupported write filter operator $operator",
        ) unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/;
        push @expressions, Selecto::Expression->can($operator)->(
            'Selecto::Expression', $operand,
            _write_value($filter->{value}, 'write filter value'),
        );
    }
    return @expressions;
}

sub _write_value ($value, $label) {
    return $value ? 1 : 0 if blessed($value) && JSON::PP::is_bool($value);
    Selecto::Error->throw('invalid_api_write', "$label must be a JSON scalar")
        if ref($value);
    return $value;
}

sub _required_write_value_missing ($assignments, $field) {
    return 1 unless exists $assignments->{$field};
    my $value = $assignments->{$field};
    return 1 unless defined $value;
    return 1 if !ref($value) && "$value" =~ /\A\s*\z/;
    return 0;
}

sub _write_assignment_value ($value, $field, $definition) {
    my $normalized = _write_value($value, "assignment $field");
    return $normalized unless defined $normalized;
    my $type = lc($definition->{type} // 'string');
    if ($type eq 'date') {
        my ($year, $month, $day) = "$normalized" =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
        my @days = (0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
        $days[2] = 29 if defined($year)
            && ($year % 400 == 0 || ($year % 4 == 0 && $year % 100 != 0));
        Selecto::Error->throw(
            'invalid_api_write',
            "assignment $field must be an ISO date (YYYY-MM-DD) or null",
            {field => $field, type => $type, expected => 'YYYY-MM-DD or null'},
        ) unless defined($year) && $month >= 1 && $month <= 12
            && $day >= 1 && $day <= $days[$month];
    }
    return $normalized;
}

sub _write_object ($value, $label) {
    Selecto::Error->throw('invalid_api_write', "$label must be an object")
        unless ref($value) eq 'HASH';
    return $value;
}

sub _write_reject_unknown ($value, $allowed, $label) {
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$value;
    Selecto::Error->throw(
        'invalid_api_write', "$label contains unsupported properties",
        {properties => \@unknown},
    ) if @unknown;
}

sub _write_required_string ($value, $label) {
    Selecto::Error->throw('invalid_api_write', "$label must be a non-empty string")
        if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

sub _write_string_array ($value, $label, $maximum, $required = 0) {
    Selecto::Error->throw('invalid_api_write', "$label must be an array")
        unless ref($value) eq 'ARRAY';
    Selecto::Error->throw('invalid_api_write', "$label must not be empty")
        if $required && !@$value;
    Selecto::Error->throw('invalid_api_write', "Too many $label entries")
        if @$value > $maximum;
    my @fields = map { _write_required_string($_, "$label entry") } @$value;
    # Conflict targets have an exact ordered identity. Preserve duplicates so
    # the common governed-write validator refuses them instead of silently
    # turning the request into a different, declared target.
    return @fields if $label eq 'conflict_target';
    my %seen;
    return grep { !$seen{$_}++ } @fields;
}

sub _write_bounded_integer ($value, $label, $minimum, $maximum) {
    Selecto::Error->throw('invalid_api_write', "$label must be an integer")
        unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/;
    my $integer = int($value);
    Selecto::Error->throw('invalid_api_write', "$label is below its minimum")
        if $integer < $minimum;
    Selecto::Error->throw('invalid_api_write', "$label exceeds its maximum")
        if defined($maximum) && $integer > $maximum;
    return $integer;
}

sub _filters ($self, $domain, $filters) {
    Selecto::Error->throw('invalid_api_query', 'filters must be an array')
        unless ref($filters) eq 'ARRAY';
    Selecto::Error->throw('invalid_api_query', 'Too many filters')
        if @$filters > $self->max_filters;
    my @expressions;
    for my $filter (@$filters) {
        _object($filter, 'filter');
        _reject_unknown($filter, [qw(field op value end)], 'filter');
        my $field = _required_string($filter->{field}, 'filter field');
        my $operator = lc _required_string($filter->{op}, 'filter operator');
        my $choice = $domain->components->{filter_choices}{$field};
        my $conditional = ref($choice) eq 'HASH' ? $choice->{conditional} : undef;
        if (ref($conditional) eq 'HASH') {
            Selecto::Error->throw('invalid_api_query',
                "Unsupported filter operator $operator")
                unless $operator =~ /\A(?:eq|ne|in|not_in|is_null|not_null)\z/;
            my $definition = $domain->resolve($conditional->{present_field});
            my $present = $self->_query_filter_expression(
                $filter, $operator, $definition,
                Selecto::Expression->field($conditional->{present_field}),
            );
            my $absent = $self->_query_filter_expression(
                $filter, $operator, $definition,
                Selecto::Expression->field($conditional->{absent_field}),
            );
            # A choice filter may read internal fields, but only through the
            # choices the domain declares: any other value, or a null test,
            # would probe their values.
            if (grep { !$domain->field_is_public($conditional->{$_}) }
                qw(when_field present_field absent_field)) {
                my %declared = map { ("$_->{value}" => 1) } @{$choice->{choices} // []};
                my @values = $operator =~ /\A(?:in|not_in)\z/
                    ? @{$filter->{value}} : ($filter->{value});
                Selecto::Error->throw(
                    'field_not_public', 'Filter value is not a declared choice',
                    {field => "$field"},
                ) if $operator =~ /\A(?:is_null|not_null)\z/
                    || grep { !defined($_) || ref($_) || !$declared{"$_"} } @values;
            }
            my $when = Selecto::Expression->field($conditional->{when_field});
            push @expressions, Selecto::Expression->any([
                Selecto::Expression->all([
                    Selecto::Expression->not_null($when), $present,
                ]),
                Selecto::Expression->all([
                    Selecto::Expression->is_null($when), $absent,
                ]),
            ]);
            next;
        }
        my $definition = _public_field_definition($domain, $field);
        my $operand = $definition->{type} eq 'epoch_datetime'
            ? Selecto::Expression->epoch_datetime($field)
            : Selecto::Expression->field($field);
        push @expressions, $self->_query_filter_expression(
            $filter, $operator, $definition, $operand,
        );
    }
    return @expressions;
}

sub _query_filter_expression ($self, $filter, $operator, $definition, $operand) {
    if ($operator =~ /\A(?:starts_with|text_contains|ends_with)(?:_ci)?\z/) {
        Selecto::Error->throw('invalid_api_query', "$operator requires a text field")
            unless ($definition->{type} // '') =~ /\A(?:string|text)\z/;
        return Selecto::Expression->can($operator)->(
            'Selecto::Expression', $operand, _literal_value($filter->{value}, 'text filter value'),
        );
    }
    if ($operator eq 'is_null' || $operator eq 'not_null') {
        return Selecto::Expression->can($operator)->(
            'Selecto::Expression', $operand,
        );
    }
    if ($operator eq 'in' || $operator eq 'not_in') {
        my $values = $filter->{value};
        Selecto::Error->throw('invalid_api_query',
            "$operator filter value must be a non-empty array")
            unless ref($values) eq 'ARRAY' && @$values;
        Selecto::Error->throw('invalid_api_query', 'Too many in filter values')
            if @$values > $self->max_filter_values;
        my $total = 0;
        for my $value (@$values) {
            $total += $self->limits->check_bytes('max_value_bytes', _literal_value($value, 'in filter item'), 'invalid_api_query', 'in filter item');
            $self->limits->check_count('max_parameter_bytes', $total, 'invalid_api_query', 'in filter bytes');
        }
        my @values = map { _literal_value($_, 'in filter value') } @$values;
        my $expression = Selecto::Expression->in($operand, \@values);
        return $operator eq 'not_in' ? Selecto::Expression->not($expression) : $expression;
    }
    if ($operator eq 'between') {
        return Selecto::Expression->between(
            $operand,
            _literal_value($filter->{value}, 'between start'),
            _literal_value($filter->{end}, 'between end'),
        );
    }
    if ($operator eq 'date_shortcut') {
        Selecto::Error->throw('invalid_api_query',
            'date_shortcut requires a temporal field')
            unless ($definition->{type} // '')
                =~ /\A(?:date|datetime|naive_datetime|utc_datetime|epoch_datetime)\z/;
        my $shortcut = _required_string($filter->{value}, 'date shortcut value');
        Selecto::Error->throw('invalid_api_query', 'Date shortcut is not available',
            {value => $shortcut}) unless Selecto::DateShortcut->valid($shortcut);
        return Selecto::DateShortcut->expression($operand, $shortcut);
    }
    Selecto::Error->throw('invalid_api_query',
        "Unsupported filter operator $operator")
        unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/;
    return Selecto::Expression->can($operator)->(
        'Selecto::Expression', $operand,
        _literal_value($filter->{value}, 'filter value'),
    );
}

sub _literal_value ($value, $label) {
    return $value ? 1 : 0 if blessed($value) && JSON::PP::is_bool($value);
    Selecto::Error->throw('invalid_api_query', "$label must be a JSON scalar")
        if !defined($value) || ref($value);
    return $value;
}

sub _public_field_definition ($domain, $field) {
    my $definition = $domain->resolve($field);
    Selecto::Error->throw(
        'field_not_public', 'Field is an internal domain dependency',
        {field => "$field"},
    ) unless $domain->field_is_public($field);
    return $definition;
}

sub _object ($value, $label) {
    Selecto::Error->throw('invalid_api_query', "$label must be an object")
        unless ref($value) eq 'HASH';
    return $value;
}

sub _reject_unknown ($value, $allowed, $label) {
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$value;
    Selecto::Error->throw(
        'invalid_api_query', "$label contains unsupported properties",
        {properties => \@unknown},
    ) if @unknown;
}

sub _required_string ($value, $label) {
    Selecto::Error->throw(
        'invalid_api_query', "$label must be a non-empty string",
    ) if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

sub _api_selections ($domain, $value, $maximum, $limits, $adapter_name) {
    Selecto::Error->throw('invalid_api_query', 'select must be an array')
        unless ref($value) eq 'ARRAY';
    Selecto::Error->throw('invalid_api_query', 'select must not be empty')
        unless @$value;
    my (@expressions, @subtables, %column_names);
    my $field_count = 0;
    for my $entry (@$value) {
        if (ref($entry) ne 'ARRAY') {
            my $selection = _api_selection_entry($domain, $entry, 'select entry');
            $field_count++;
            Selecto::Error->throw(
                'invalid_api_query',
                'select entries produce duplicate result column names; provide distinct aliases',
                {column => $selection->{result_name}},
            ) if $column_names{$selection->{result_name}}++;
            push @expressions, $selection->{flat_expression};
            next;
        }
        Selecto::Error->throw('invalid_api_query', 'subtable selection must not be empty')
            unless @$entry;
        Selecto::Error->throw('unsupported_feature', 'bounded API collections require PostgreSQL')
            unless $adapter_name eq 'postgresql';
        my (@fields, %nested_names, $association);
        for my $nested_entry (@$entry) {
            Selecto::Error->throw(
                'invalid_api_query', 'subtable selections cannot contain another array',
            ) if ref($nested_entry) eq 'ARRAY';
            my $selection = _api_selection_entry(
                $domain, $nested_entry, 'subtable select entry',
            );
            $field_count++;
            my $definition = $selection->{definition};
            Selecto::Error->throw(
                'invalid_api_query',
                'subtable fields must belong to a direct to-many association',
                {field => $selection->{field}},
            ) unless $definition->{association}
                && @{$definition->{associations}} == 1
                && $definition->{association}->cardinality eq 'many';
            $association //= $definition->{association_path};
            Selecto::Error->throw(
                'invalid_api_query',
                'all fields in a subtable must belong to the same association',
                {association => $association, field => $selection->{field}},
            ) unless $definition->{association_path} eq $association;
            Selecto::Error->throw(
                'invalid_api_query',
                'subtable fields produce duplicate names; provide distinct aliases',
                {column => $selection->{result_name}},
            ) if $nested_names{$selection->{result_name}}++;
            push @fields, {
                key => $selection->{result_name}, expression => $selection->{expression},
                # JSON decoders turn numeric literals into inexact native floats.
                # Preserve the database's decimal text before JSON aggregation.
                ($definition->{type} =~ /\A(?:decimal|numeric|number|float|double|real)\z/i
                    ? (stringify => 1) : ()),
            };
        }
        Selecto::Error->throw(
            'invalid_api_query',
            'a subtable association collides with another result column',
            {column => $association},
        ) if $column_names{$association}++;
        my $related = $domain->resolve_association($association)->{association};
        my $primary_key = $related->target_primary_key;
        Selecto::Error->throw('invalid_api_query', 'bounded collection requires a public target primary key')
            unless defined($primary_key) && $domain->field_is_public("$association.$primary_key");
        my $child_limit = $limits->get('max_collection_rows');
        push @subtables, {
            limit => $child_limit,
            column => $association,
            columns => [map { $_->{key} } @fields],
        };
        push @expressions, Selecto::Expression->related_collection(
            $association, \@fields, limit => $child_limit + 1,
            order_by => [[$primary_key, 'asc']],
        )->as($association);
    }
    Selecto::Error->throw('invalid_api_query', 'Too many select entries')
        if $field_count > $maximum;
    return {
        expressions => \@expressions,
        subtables => \@subtables,
    };
}

sub _api_selection_entry ($domain, $entry, $label) {
    my ($field, $alias, $format);
    if (ref($entry) eq 'HASH') {
        _reject_unknown($entry, [qw(field alias format)], $label);
        $field = _required_string($entry->{field}, "$label field");
        if (exists $entry->{alias}) {
            $alias = _required_string($entry->{alias}, "$label alias");
            Selecto::Error->throw(
                'invalid_api_query', 'select alias must be a valid identifier',
                {alias => $alias},
            ) unless Selecto::Identifier::valid($alias);
        }
        if (exists $entry->{format}) {
            $format = _required_string($entry->{format}, "$label format");
            Selecto::Error->throw(
                'invalid_api_query', 'select format is not available',
                {format => $format},
            ) unless Selecto::DateFormat::valid($format);
        }
    } else {
        $field = _required_string($entry, $label);
    }
    my $definition = _public_field_definition($domain, $field);
    Selecto::Error->throw(
        'invalid_api_query', 'select format requires a date or time field',
        {field => $field, format => $format},
    ) if defined($format) && $definition->{type} !~ /(?:date|time)/i;
    my $result_name = defined($alias)
        ? $alias : Selecto::Identifier::result_name($field);
    my $expression = Selecto::Expression->field($field);
    if (defined $format) {
        $expression = Selecto::Expression->epoch_datetime($expression)
            if $definition->{type} eq 'epoch_datetime';
        $expression = Selecto::Expression->datetime_format($expression, $format);
    }
    return {
        field => $field, definition => $definition,
        result_name => $result_name, expression => $expression,
        flat_expression => defined($alias) || defined($format)
            ? $expression->as($result_name) : $expression,
    };
}

sub _shape_result_rows ($result, $subtables, $row_format, $limits) {
    Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')->check_tree(
        $result, label => 'adapter result', bytes_limit => 'max_response_bytes');
    my ($total_bytes, $total_children) = (0, 0);
    for my $row (@{$result->{rows}}) {
        for my $value (@$row) {
            $total_bytes += ref($value)
                ? Selecto::API::ResponsePolicy->check_json($value, $limits)
                : $limits->check_bytes('max_response_bytes', $value, 'api_result_limit_exceeded', 'result cell');
            $limits->check_count('max_response_bytes', $total_bytes, 'api_result_limit_exceeded', 'result bytes');
        }
    }
    my %subtable = map { $_->{column} => $_ } @$subtables;
    for my $index (0 .. $#{$result->{columns}}) {
        my $specification = $subtable{$result->{columns}[$index]};
        next unless $specification;
        for my $row (@{$result->{rows}}) {
            Selecto::Error->throw(
                'invalid_api_host', 'Selecto adapter returned an invalid row',
            ) unless ref($row) eq 'ARRAY';
            my $decoded = $row->[$index];
            my $ok = ref($decoded) eq 'ARRAY';
            $ok = defined($decoded) && !ref($decoded)
                && eval { $decoded = JSON::PP->new->max_depth($limits->get('max_response_depth'))->decode($decoded); 1 }
                unless $ok;
            Selecto::Error->throw(
                'invalid_api_host', 'Selecto adapter returned an invalid related collection',
                {column => $result->{columns}[$index]},
            ) unless $ok && ref($decoded) eq 'ARRAY'
                && !grep { ref($_) ne 'HASH' } @$decoded;
            Selecto::Error->throw('related_collection_limit_exceeded',
                'related collection exceeds its per-parent limit; use a separately paged child query',
                {maximum => $specification->{limit}}) if @$decoded > $specification->{limit};
            $total_children += @$decoded;
            $limits->check_count('max_total_collection_rows', $total_children,
                'api_result_limit_exceeded', 'related collection rows');
            Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')->check_tree(
                $decoded, label => 'decoded collection', bytes_limit => 'max_response_bytes');
            $decoded = _collection_json_value($decoded);
            $row->[$index] = $row_format eq 'objects' ? $decoded : [map {
                my $record = $_;
                [map { $record->{$_} } @{$specification->{columns}}]
            } @$decoded];
        }
    }
    return if $row_format eq 'arrays';
    my @columns = @{$result->{columns}};
    $result->{rows} = [map {
        my $row = $_;
        Selecto::Error->throw(
            'invalid_api_host', 'Selecto adapter returned an invalid row',
        ) unless ref($row) eq 'ARRAY' && @$row == @columns;
        my %record;
        @record{@columns} = @$row;
        \%record;
    } @{$result->{rows}}];
}

sub _collection_json_value ($value) {
    return [map { _collection_json_value($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _collection_json_value($value->{$_}) } keys %$value}
        if ref($value) eq 'HASH';
    return $value unless defined($value) && !ref($value);
    # Preserve strings and safe numeric JSON types. Comparing decimal digits
    # avoids routing exact 64-bit IDs through floating-point arithmetic.
    my $wire = JSON::PP->new->allow_nonref(1)->encode($value);
    if ($wire =~ /\A-?([0-9]+)\z/) {
        my $digits = $1;
        return substr($wire, 0) if length($digits) > 16
            || (length($digits) == 16 && $digits gt '9007199254740991');
    }
    return $value;
}

sub _string_array ($value, $label, $maximum, $required = 0) {
    Selecto::Error->throw('invalid_api_query', "$label must be an array")
        unless ref($value) eq 'ARRAY';
    Selecto::Error->throw('invalid_api_query', "$label must not be empty")
        if $required && !@$value;
    Selecto::Error->throw('invalid_api_query', "Too many $label entries")
        if @$value > $maximum;
    my %seen;
    return grep { !$seen{$_}++ }
        map { _required_string($_, "$label entry") } @$value;
}

sub _bounded_integer ($value, $label, $minimum, $maximum) {
    Selecto::Error->throw('invalid_api_query', "$label must be an integer")
        unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/;
    my $integer = int($value);
    Selecto::Error->throw('invalid_api_query', "$label is below its minimum")
        if $integer < $minimum;
    Selecto::Error->throw('invalid_api_query', "$label exceeds its maximum")
        if defined($maximum) && $integer > $maximum;
    return $integer;
}

1;

__END__

=head1 NAME

Selecto::API::EngineHandler - governed query and write handler for the canonical API

=head1 SYNOPSIS

  use Selecto::API::EngineHandler;

  my $handler = Selecto::API::EngineHandler->new(
      default_limit => 100,
      max_limit     => 1000,
      max_offset    => 100_000,
  );

  # $engine is built per request from trusted context (tenant, required predicate).
  my $data = $handler->query($engine, {
      select   => ['id', 'name', {field => 'created_on', alias => 'month', format => 'month'}],
      filters  => [{field => 'stock', op => 'gte', value => 1}],
      order_by => [{field => 'name', direction => 'asc'}],
      limit    => 50,
  });
  # {columns => [...], rows => [[...]], returned => 3, limit => 50, offset => 0,
  #  row_format => 'arrays', subtables => {}, query_library => {...}}

  my $written = $handler->write($engine, {
      operation      => 'update',
      assignments    => {status => 'closed'},
      filters        => [{field => 'id', op => 'eq', value => 17}],
      expected_count => 1,
      returning      => ['id', 'status'],
  });

=head1 DESCRIPTION

The handler turns canonical API request bodies into governed engine calls.
It does not construct engines, authenticate users, choose tenants or modify
domains: the host supplies an engine whose domain already carries every
required scope and restriction, and the handler validates every field,
operator and query-library name against that engine's domain.

Only public fields are accepted. Columns marked C<internal> and fields
listed in C<redact_fields> cannot be selected, filtered, ordered, assigned
or returned (C<field_not_public>), at any association depth. Query-library
names are no exception: a requested segment (or a view's segment) that reads
such a field, or an ordering that sorts by one, fails the same way. A
C<components.filter_choices> conditional filter whose fields are not all
public accepts only its declared choice values and no null test. Trusted
host code, the domain's required predicate and C<required_order_by> can
still use withheld fields directly through the engine.

Both entry points fail with C<missing_tenant_scope> when the domain has a
tenant field but the engine has no tenant boundary; see
L<Selecto::Engine/assert_tenant_boundary>.

=head1 CONSTRUCTOR

=head2 new

All limits are optional non-negative integers:

  max_fields        100      selections, projections and returning fields
  max_filters       20
  max_filter_values 100      values in one in/not_in filter
  max_orders        10
  max_segments      20
  max_limit         1000
  default_limit     100      must not exceed max_limit
  max_offset        100_000  deep offsets scan and discard earlier rows
  max_write_count   1000     largest expected_count

Throws C<invalid_api_handler> for invalid limits.

=head1 METHODS

=head2 query

  my $data = $handler->query($engine, \%body);
  my $data = $handler->query($engine, \%body, export_scalars => 1);

With C<< export_scalars => 1 >> the rows hold the engine's canonical export
scalars (see L<Selecto::Engine/all>): use it when the result will be
exported as CSV, TSV or XLSX so decimals keep their column scale. Without
it the result is unchanged.

Body keys:

=over 4

=item C<select>, C<projection> or C<view>

Exactly one. C<select> is an array of field paths or
C<< {field => ..., alias => ..., format => ...} >> objects, where C<format>
is an allowlisted date/time format (see L<Selecto::DateFormat>). A nested
array groups fields of one direct to-many association into a subtable: the
root row is returned once, and the association's rows are returned in a
column named after the association:

  select => ['id', ['lines.sku', {field => 'lines.shipped_on', alias => 'day', format => 'day'}]]

C<projection> names one or more query-library projections; C<view> names a
query-library view (its segments and ordering apply too). Domain
C<required_selected> fields are always included.

=item C<segments>, C<parameters>

Query-library segments to apply and their typed parameters.

=item C<filters>

An array of C<< {field, op, value} >> objects, ANDed together. Operators:
C<eq>, C<ne>, C<gt>, C<gte>, C<lt>, C<lte>, C<between> (with C<value> and
C<end>), C<in>, C<not_in>, C<is_null>, C<not_null>, C<starts_with>,
C<text_contains>, C<ends_with> and their C<_ci> forms (text fields only), and
C<date_shortcut> (temporal fields; values such as C<this_month>, see
L<Selecto::DateShortcut>). Values are JSON scalars and are always bound.

=item C<ordering> or C<order_by>

A query-library ordering name, or an array of C<< {field, direction} >>.

=item C<limit>, C<offset>

Bounded by C<max_limit> and C<max_offset>; C<limit> defaults to
C<default_limit>.

=item C<timezone>

An IANA zone name for date/time interpretation.

=item C<row_format>

C<arrays> (default) or C<objects>, applied to root rows and subtable rows
alike.

=back

The result has C<columns>, C<rows>, C<returned>, C<limit>, C<offset>,
C<row_format>, C<subtables> (per association, its C<columns>, C<limit> and
C<complete: true>) and
C<query_library> (the applied definitions).

=head2 write

  my $data = $handler->write($engine, \%body);   # Selecto::Write::Result->to_hash

Validates the body with L</write_command> and executes it through the
engine.

=head2 write_command

  my $command = $handler->write_command($engine, \%body);

Normalizes a write body into a L<Selecto::Write::Command> without executing
it, for hosts that compose their own transaction. The command must still be
executed through a governed engine. Body keys:

=over 4

=item C<operation>

C<insert>, C<update>, C<upsert> or C<delete>; must be enabled in the
domain's C<writes.operations>.

=item C<assignments>

Public root fields to values. Required fields are enforced for inserts and
upserts (C<missing_required_write_fields>); deletes take none.

=item C<filters> (write)

Required for updates and deletes, rejected otherwise. Root fields only, with
C<eq>, C<ne>, C<gt>, C<gte>, C<lt>, C<lte>, C<in>, C<is_null> and
C<not_null>. The engine's required predicate is always added, by the engine
when the command is governed (see L<Selecto::Engine/REQUIRED PREDICATES>);
the returned command does not carry it, so it is never applied twice.

=item C<expected_count>

Default 1; values above 1 need C<bulk> on the operation.

=item C<returning>, C<conflict_target>, C<upsert_update_fields>

Root field lists. Upserts require the last two and are refused on domains
with a required predicate (C<query_enforcement_unsupported_operation>).

=back

On a domain whose required predicate reads an association field every write
is refused with C<query_rule_unsupported_field> (details C<relation> and
C<fields>), and inserts must satisfy a root-field required predicate
(C<query_rule_violation>). Like the other write refusals these are client
errors: return them through L<Selecto::API> as C<['error', {...}]>, which
responds 422 with the error code unless you set another status.

A rolled-back write reports C<cardinality_mismatch> with the expected count
only.

=head2 describe_openapi

  $handler->describe_openapi($api);

Adds this handler's request schemas and limits to a L<Selecto::API>
object's OpenAPI document.

=head1 ERRORS

C<invalid_api_query>, C<invalid_api_write>, C<field_not_public>,
C<missing_tenant_scope>, plus any engine or query-library error.

=head1 SEE ALSO

L<Selecto>, L<Selecto::API>, L<Selecto::Engine>, L<Selecto::QueryLibrary>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
