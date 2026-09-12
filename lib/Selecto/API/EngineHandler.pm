package Selecto::API::EngineHandler;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Engine ();
use Selecto::Error ();
use Selecto::DateShortcut ();
use Selecto::DateFormat ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::QueryLibrary ();
use Selecto::Write ();

has max_fields        => 100;
has max_filters       => 20;
has max_filter_values => 100;
has max_orders        => 10;
has max_segments      => 20;
has max_limit         => 1000;
has default_limit     => 100;
has max_write_count   => 1000;

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    for my $name (qw(
        max_fields max_filters max_filter_values max_orders max_segments
        max_limit default_limit max_write_count
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
    return $self;
}

sub write ($self, $engine, $body) {
    Selecto::Error->throw(
        'invalid_api_host', 'API write handler requires a Selecto engine',
    ) unless blessed($engine) && $engine->isa('Selecto::Engine');
    _write_object($body, 'write body');
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
        _public_field_definition($domain, $field);
        ($field => _write_value($assignments->{$field}, "assignment $field"));
    } keys %$assignments;

    my @filters = $self->_write_filters($domain, $body->{filters} // []);
    if ($operation eq 'update' || $operation eq 'delete') {
        Selecto::Error->throw(
            'invalid_api_write', "$operation requires at least one explicit filter",
        ) unless @filters;
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

    my $scope = $domain->required_predicate;
    Selecto::Error->throw('query_enforcement_unsupported_operation', 'query-scoped API upsert is not supported')
        if $operation eq 'upsert' && defined($scope);
    Selecto::Error->throw('missing_tenant_scope', 'trusted tenant scope is required')
        if defined($domain->tenant_field) && !defined($scope);
    my $command = Selecto::Write::Command->new(
        operation => $operation,
        relation => $domain->table,
        assignments => \%normalized_assignments,
        predicate => $predicate,
        scope_predicate => $scope,
        expected_count => $expected_count,
        metadata => \%metadata,
    );
    return $engine->execute_write($command)->to_hash;
}

sub query ($self, $engine, $body) {
    Selecto::Error->throw(
        'invalid_api_host', 'API query handler requires a Selecto engine',
    ) unless blessed($engine) && $engine->isa('Selecto::Engine');
    _object($body, 'query body');
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
        my $selection_plan = _api_selections(
            $domain, $body->{select}, $self->max_fields,
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

    if (@segments) {
        my %seen;
        @segments = grep { !$seen{$_}++ } @segments;
        $query = $engine->apply_segments($query, \@segments, $parameters);
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
        $query = $engine->apply_ordering(
            $query, _required_string($named_ordering, 'ordering'),
        );
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
        ? _bounded_integer($body->{offset}, 'offset', 0, undef)
        : 0;
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

    my $result = $engine->all($query);
    Selecto::Error->throw(
        'invalid_api_host', 'Selecto adapter returned an invalid result',
    ) unless ref($result) eq 'HASH'
        && ref($result->{columns}) eq 'ARRAY'
        && ref($result->{rows}) eq 'ARRAY';
    _shape_result_rows($result, \@subtables, $row_format);
    my %subtable_metadata = map {
        $_->{column} => {columns => [@{$_->{columns}}]}
    } @subtables;
    return {
        columns => $result->{columns},
        rows => $result->{rows},
        returned => scalar(@{$result->{rows}}),
        row_format => $row_format,
        subtables => \%subtable_metadata,
        limit => $limit,
        offset => $offset,
        query_library => $query->applied_query_library,
    };
}

sub describe_openapi ($self, $api) {
    Selecto::Error->throw(
        'invalid_api_host', 'OpenAPI description requires a Selecto API object',
    ) unless blessed($api) && $api->isa('Selecto::API');
    my $openapi = $api->openapi_document;
    my $query_path = $api->base_path . '/query';
    $openapi->{paths}{$query_path}{post}{summary} = 'Run a domain read query';
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
            offset => {type => 'integer', minimum => 0, default => 0},
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
        description => 'Fields from one direct to-many association returned as a nested collection.',
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
                enum => [qw(eq ne gt gte lt lte between date_shortcut in is_null not_null)],
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
    my %seen;
    return grep { !$seen{$_}++ }
        map { _write_required_string($_, "$label entry") } @$value;
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
        my $definition = _public_field_definition($domain, $field);
        my $operand = $definition->{type} eq 'epoch_datetime'
            ? Selecto::Expression->epoch_datetime($field)
            : Selecto::Expression->field($field);

        if ($operator eq 'is_null' || $operator eq 'not_null') {
            push @expressions, Selecto::Expression->can($operator)->(
                'Selecto::Expression', $operand,
            );
            next;
        }
        if ($operator eq 'in') {
            my $values = $filter->{value};
            Selecto::Error->throw(
                'invalid_api_query',
                'in filter value must be a non-empty array',
            ) unless ref($values) eq 'ARRAY' && @$values;
            Selecto::Error->throw(
                'invalid_api_query', 'Too many in filter values',
            ) if @$values > $self->max_filter_values;
            my @values = map { _literal_value($_, 'in filter value') } @$values;
            push @expressions, Selecto::Expression->in($operand, \@values);
            next;
        }
        if ($operator eq 'between') {
            push @expressions, Selecto::Expression->between(
                $operand,
                _literal_value($filter->{value}, 'between start'),
                _literal_value($filter->{end}, 'between end'),
            );
            next;
        }
        if ($operator eq 'date_shortcut') {
            Selecto::Error->throw(
                'invalid_api_query', 'date_shortcut requires a temporal field',
            ) unless ($definition->{type} // '') =~ /\A(?:date|datetime|naive_datetime|utc_datetime|epoch_datetime)\z/;
            my $shortcut = _required_string(
                $filter->{value}, 'date shortcut value',
            );
            Selecto::Error->throw(
                'invalid_api_query', 'Date shortcut is not available',
                {value => $shortcut},
            ) unless Selecto::DateShortcut->valid($shortcut);
            push @expressions, Selecto::DateShortcut->expression($operand, $shortcut);
            next;
        }
        Selecto::Error->throw(
            'invalid_api_query', "Unsupported filter operator $operator",
        ) unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/;
        push @expressions, Selecto::Expression->can($operator)->(
            'Selecto::Expression', $operand,
            _literal_value($filter->{value}, 'filter value'),
        );
    }
    return @expressions;
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

sub _api_selections ($domain, $value, $maximum) {
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
            };
        }
        Selecto::Error->throw(
            'invalid_api_query',
            'a subtable association collides with another result column',
            {column => $association},
        ) if $column_names{$association}++;
        push @subtables, {
            column => $association,
            columns => [map { $_->{key} } @fields],
        };
        push @expressions, Selecto::Expression->related_collection(
            $association, \@fields,
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

sub _shape_result_rows ($result, $subtables, $row_format) {
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
                && eval { $decoded = JSON::PP->new->decode($decoded); 1 }
                unless $ok;
            Selecto::Error->throw(
                'invalid_api_host', 'Selecto adapter returned an invalid related collection',
                {column => $result->{columns}[$index]},
            ) unless $ok && ref($decoded) eq 'ARRAY'
                && !grep { ref($_) ne 'HASH' } @$decoded;
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
