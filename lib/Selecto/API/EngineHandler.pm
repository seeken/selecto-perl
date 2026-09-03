package Selecto::API::EngineHandler;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Engine ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::QueryLibrary ();

has max_fields        => 100;
has max_filters       => 20;
has max_filter_values => 100;
has max_orders        => 10;
has max_segments      => 20;
has max_limit         => 1000;
has default_limit     => 100;

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    for my $name (qw(
        max_fields max_filters max_filter_values max_orders max_segments
        max_limit default_limit
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
    return $self;
}

sub query ($self, $engine, $body) {
    Selecto::Error->throw(
        'invalid_api_host', 'API query handler requires a Selecto engine',
    ) unless blessed($engine) && $engine->isa('Selecto::Engine');
    _object($body, 'query body');
    _reject_unknown($body, [qw(
        select projection view segments parameters filters ordering order_by limit offset
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

    if ($has_select) {
        my @fields = _string_array(
            $body->{select}, 'select', $self->max_fields, 1,
        );
        _public_field_definition($domain, $_) for @fields;
        $query = $query->select(\@fields);
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

    my $result = $engine->all($query);
    Selecto::Error->throw(
        'invalid_api_host', 'Selecto adapter returned an invalid result',
    ) unless ref($result) eq 'HASH'
        && ref($result->{columns}) eq 'ARRAY'
        && ref($result->{rows}) eq 'ARRAY';
    return {
        columns => $result->{columns},
        rows => $result->{rows},
        returned => scalar(@{$result->{rows}}),
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
                type => 'array', items => {type => 'string'},
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
        },
    };
    $openapi->{components}{schemas}{SelectoFilter} = {
        type => 'object', additionalProperties => JSON::PP::false,
        required => [qw(field op)],
        properties => {
            field => {type => 'string'},
            op => {
                type => 'string',
                enum => [qw(eq ne gt gte lt lte between in is_null not_null)],
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
    return $api;
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
