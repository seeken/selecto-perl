package Selecto::Expression;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

sub new {
    my ($class, $kind, @arguments) = @_;
    return bless { kind => "$kind", arguments => [map { _clone($_) } @arguments], alias_name => undef }, $class;
}

sub field   { my ($class, $name) = @_; return $class->new('field', "$name"); }
sub literal { my ($class, $value) = @_; return $class->new('literal', $value); }
sub count   { my ($class) = @_; return $class->new('count'); }
sub count_field { my ($class, $field) = @_; return $class->new('count_field', $class->_operand($field)); }
sub count_distinct { my ($class, $field) = @_; return $class->new('count_distinct', $class->_operand($field)); }
sub avg     { my ($class, $field) = @_; return $class->new('avg', $class->_operand($field)); }
sub sum     { my ($class, $field) = @_; return $class->new('sum', $class->_operand($field)); }
sub sum_zero { my ($class, $field) = @_; return $class->new('sum_zero', $class->_operand($field)); }
sub min     { my ($class, $field) = @_; return $class->new('min', $class->_operand($field)); }
sub max     { my ($class, $field) = @_; return $class->new('max', $class->_operand($field)); }
sub true_count { my ($class, $field) = @_; return $class->new('true_count', $class->_operand($field)); }
sub false_count { my ($class, $field) = @_; return $class->new('false_count', $class->_operand($field)); }
sub true_percentage { my ($class, $field) = @_; return $class->new('true_percentage', $class->_operand($field)); }
sub grouping {
    my ($class, @fields) = @_;
    @fields = @{$fields[0]} if @fields == 1 && ref($fields[0]) eq 'ARRAY';
    return $class->new('grouping', [map {
        $class->_operand($_)
    } @fields]);
}
sub window {
    my ($class, $function, $arguments, %over) = @_;
    _known_options(\%over, [qw(partition_by order_by frame)], 'window');
    $function = defined($function) ? lc("$function") : '';
    $arguments //= [];
    $arguments = [$arguments] unless ref($arguments) eq 'ARRAY';
    my %field_arguments = map { $_ => 1 } qw(
        sum avg min max count first_value last_value nth_value lag lead
    );
    my @arguments = map {
        my $index = $_;
        my $value = $arguments->[$index];
        blessed($value) && $value->isa(__PACKAGE__) ? $value
            : $field_arguments{$function} && $index == 0 ? $class->field($value)
            : $class->literal($value)
    } 0 .. $#$arguments;
    my $partition = $over{partition_by} // [];
    $partition = [$partition] unless ref($partition) eq 'ARRAY';
    my $orders = $over{order_by} // [];
    $orders = [$orders] unless ref($orders) eq 'ARRAY';
    my @orders = map {
        my ($field, $direction) = ref($_) eq 'ARRAY' ? @$_ : ($_, 'asc');
        [$class->_operand($field), defined($direction) ? lc("$direction") : 'asc']
    } @$orders;
    return $class->new('window', $function, \@arguments, {
        partition_by => [map { $class->_operand($_) } @$partition],
        order_by => \@orders,
        (exists($over{frame}) ? (frame => $over{frame}) : ()),
    });
}
sub row_number { my ($class, %over) = @_; return $class->window('row_number', [], %over); }
sub rank { my ($class, %over) = @_; return $class->window('rank', [], %over); }
sub dense_rank { my ($class, %over) = @_; return $class->window('dense_rank', [], %over); }
sub window_sum { my ($class, $field, %over) = @_; return $class->window('sum', [$field], %over); }
sub window_avg { my ($class, $field, %over) = @_; return $class->window('avg', [$field], %over); }
sub lag {
    my ($class, $field, $offset, $default, %over) = @_;
    $offset //= 1;
    my @arguments = ($field, $offset);
    push @arguments, $default if defined $default;
    return $class->window('lag', \@arguments, %over);
}
sub lead {
    my ($class, $field, $offset, $default, %over) = @_;
    $offset //= 1;
    my @arguments = ($field, $offset);
    push @arguments, $default if defined $default;
    return $class->window('lead', \@arguments, %over);
}
sub dimension_display {
    my ($class, $display_field, $dimension_key) = @_;
    return $class->new(
        'dimension_display',
        $class->_operand($display_field),
        $class->_operand($dimension_key),
    );
}
sub related_collection {
    my ($class, $association, $fields, %options) = @_;
    _known_options(\%options, [qw(filters order_by limit after aggregate)], 'related collection');
    Selecto::Error->throw('invalid_query', 'related collection association is invalid')
        unless defined($association) && !ref($association)
        && "$association" =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
    Selecto::Error->throw('invalid_query', 'related collection fields must be an array')
        unless ref($fields) eq 'ARRAY';
    my @fields = map {
        if (!ref($_)) {
            "$_";
        } elsif (ref($_) eq 'HASH') {
            Selecto::Error->throw(
                'invalid_query', 'related collection field requires key and expression',
            ) unless defined($_->{key}) && !ref($_->{key}) && length("$_->{key}")
                && blessed($_->{expression}) && $_->{expression}->isa(__PACKAGE__)
                && !grep { $_ ne 'key' && $_ ne 'expression' && $_ ne 'stringify' } keys %$_;
            Selecto::Error->throw(
                'invalid_query', 'related collection stringify must be boolean',
            ) if exists($_->{stringify}) && ref($_->{stringify});
            {key => "$_->{key}", expression => $_->{expression},
                (exists($_->{stringify}) ? (stringify => !!$_->{stringify}) : ())};
        } else {
            Selecto::Error->throw('invalid_query', 'related collection field is invalid');
        }
    } @$fields;
    my $filters = $options{filters} // [];
    Selecto::Error->throw('invalid_query', 'related collection filters must be an array')
        unless ref($filters) eq 'ARRAY';
    my @filters = map {
        my ($field, $value) = ref($_) eq 'ARRAY' ? @$_ : ();
        Selecto::Error->throw('invalid_query', 'related collection filter is invalid')
            unless ref($_) eq 'ARRAY' && @$_ == 2
            && defined($field) && !ref($field)
            && "$field" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        ["$field", $value];
    } @$filters;
    my $orders = $options{order_by} // [];
    Selecto::Error->throw('invalid_query', 'related collection ordering must be an array')
        unless ref($orders) eq 'ARRAY';
    my @orders = map {
        my ($field, $direction) = ref($_) eq 'ARRAY' ? @$_ : ();
        Selecto::Error->throw('invalid_query', 'related collection ordering is invalid')
            unless ref($_) eq 'ARRAY' && @$_ == 2
            && defined($field) && !ref($field)
            && "$field" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
            && defined($direction) && !ref($direction)
            && "$direction" =~ /\A(?:asc|desc)\z/i;
        ["$field", lc("$direction")];
    } @$orders;
    my $limit = $options{limit};
    if (defined $limit) {
        Selecto::Error->throw('invalid_query', 'per-parent collection limit is invalid')
            unless !ref($limit) && "$limit" =~ /\A[1-9][0-9]*\z/;
        Selecto::Error->throw('invalid_query', 'per-parent collection limit requires ordering')
            unless @orders;
        $limit = int($limit);
    }
    my $after = $options{after};
    if (defined $after) {
        Selecto::Error->throw('invalid_query', 'per-parent collection cursor requires a limit, parent key, and ordering values')
            unless defined($limit) && ref($after) eq 'HASH'
            && keys(%$after) == 2 && exists($after->{parent_key}) && exists($after->{values})
            && defined($after->{parent_key}) && !ref($after->{parent_key})
            && ref($after->{values}) eq 'ARRAY';
        $after = {
            parent_key => $after->{parent_key},
            values => [@{$after->{values}}],
        };
    }
    my $aggregate = $options{aggregate};
    if (defined $aggregate) {
        Selecto::Error->throw('invalid_query', 'related aggregate requires one scalar field and no ordering or limit')
            unless !ref($aggregate) && ($aggregate eq 'sum' || $aggregate eq 'count')
            && @fields == 1 && !ref($fields[0]) && !@orders && !defined($limit)
            && !defined($after);
    }
    return @filters || @orders || defined($limit) || defined($after) || defined($aggregate)
        ? $class->new('related_collection', "$association", \@fields, {
            (@filters ? (filters => \@filters) : ()),
            (@orders ? (order_by => \@orders) : ()),
            (defined($limit) ? (limit => $limit) : ()),
            (defined($after) ? (after => $after) : ()),
            (defined($aggregate) ? (aggregate => $aggregate) : ()),
        })
        : $class->new('related_collection', "$association", \@fields);
}

sub related_sum {
    my ($class, $association, $field, %options) = @_;
    return $class->related_collection($association, [$field], %options, aggregate => 'sum');
}
sub related_count {
    my ($class, $association, $field, %options) = @_;
    return $class->related_collection($association, [$field], %options, aggregate => 'count');
}
sub text_search {
    my ($class, $fields, $query, %options) = @_;
    _known_options(\%options, [qw(configuration mode)], 'text search');
    $fields = [$fields] unless ref($fields) eq 'ARRAY';
    return $class->new(
        'text_search',
        [map { $class->_operand($_) } @$fields],
        $class->literal($query),
        {
            configuration => $options{configuration} // 'simple',
            mode => $options{mode} // 'plain',
        },
    );
}
sub text_rank {
    my ($class, $fields, $query, %options) = @_;
    _known_options(\%options, [qw(configuration mode)], 'text rank');
    $fields = [$fields] unless ref($fields) eq 'ARRAY';
    return $class->new(
        'text_rank',
        [map { $class->_operand($_) } @$fields],
        $class->literal($query),
        {
            configuration => $options{configuration} // 'simple',
            mode => $options{mode} // 'plain',
        },
    );
}
sub bucket {
    my ($class, $field, $specification) = @_;
    return $class->new('bucket', $class->_operand($field), $specification);
}
sub count_bucket {
    my ($class, $field, $minimum, $maximum, $mode) = @_;
    return $class->new(
        'count_bucket',
        $class->_operand($field),
        { minimum => $minimum, maximum => $maximum, mode => $mode // 'numeric' },
    );
}
sub datetime_format {
    my ($class, $field, $format) = @_;
    return $class->new('datetime_format', $class->_operand($field), "$format");
}
sub epoch_datetime {
    my ($class, $field) = @_;
    return $class->new('epoch_datetime', $class->_operand($field));
}
# A governed computed value built from the closed Selecto::ValueExpression AST,
# for example ['divide', ['field', 'hourly_rate_cents'], ['literal', 100]].
sub value {
    my ($class, $ast, %options) = @_;
    require Selecto::ValueExpression;
    return $class->new('value', Selecto::ValueExpression->parse($ast, %options));
}
sub is_null { my ($class, $field) = @_; return $class->new('is_null', $class->_operand($field)); }
sub not_null { my ($class, $field) = @_; return $class->new('not_null', $class->_operand($field)); }

sub eq  { my ($class, $field, $value) = @_; return $class->_binary('eq',  $field, $value); }
sub ne  { my ($class, $field, $value) = @_; return $class->_binary('ne',  $field, $value); }
sub gt  { my ($class, $field, $value) = @_; return $class->_binary('gt',  $field, $value); }
sub gte { my ($class, $field, $value) = @_; return $class->_binary('gte', $field, $value); }
sub lt  { my ($class, $field, $value) = @_; return $class->_binary('lt',  $field, $value); }
sub lte { my ($class, $field, $value) = @_; return $class->_binary('lte', $field, $value); }
sub starts_with {
    my ($class, $field, $prefix) = @_;
    Selecto::Error->throw('invalid_query', 'starts_with requires a string prefix')
        if !defined($prefix) || ref($prefix);
    return $class->_binary('starts_with', $field, "$prefix");
}

sub between {
    my ($class, $field, $start, $end) = @_;
    return $class->new(
        'between',
        $class->_operand($field),
        $class->literal($start),
        $class->literal($end),
    );
}

sub in {
    my ($class, $field, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    return $class->new('in', $class->_operand($field), [@values]);
}

# Array predicates compare an array field with a bound, element-typed list:
# contains (field has every value), contained (every element is a value), and
# overlap (field has at least one value). NULL arrays never match.
sub array_contains  { my ($class, $field, @values) = @_; return $class->_array_predicate('array_contains', $field, @values); }
sub array_contained { my ($class, $field, @values) = @_; return $class->_array_predicate('array_contained', $field, @values); }
sub array_overlap   { my ($class, $field, @values) = @_; return $class->_array_predicate('array_overlap', $field, @values); }

sub _array_predicate {
    my ($class, $kind, $field, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    Selecto::Error->throw('invalid_query', "$kind requires a non-empty list of scalar values")
        unless @values && !grep { !defined($_) || ref($_) } @values;
    return $class->new($kind, $class->_operand($field), [@values]);
}

# JSON containment: the field's document contains the bound document.
sub json_contains {
    my ($class, $field, $document) = @_;
    Selecto::Error->throw('invalid_query', 'json_contains requires an object or array document')
        unless ref($document) eq 'HASH' || ref($document) eq 'ARRAY';
    return $class->new('json_contains', $class->_operand($field), $document);
}

sub all {
    my ($class, @expressions) = @_;
    @expressions = @{$expressions[0]} if @expressions == 1 && ref($expressions[0]) eq 'ARRAY';
    return $class->new('and', [@expressions]);
}

sub any {
    my ($class, @expressions) = @_;
    @expressions = @{$expressions[0]} if @expressions == 1 && ref($expressions[0]) eq 'ARRAY';
    return $class->new('or', [@expressions]);
}

sub not { my ($class, $expression) = @_; return $class->new('not', $expression); }

sub from_filter_ast {
    my ($class, $filter) = @_;
    Selecto::Error->throw('invalid_query', 'filter expression must be a non-empty array')
        unless ref($filter) eq 'ARRAY' && @$filter;
    my ($operator, @arguments) = @$filter;
    Selecto::Error->throw('invalid_query', 'filter operator must be a scalar')
        if !defined($operator) || ref($operator);
    $operator = lc "$operator";

    if ($operator eq 'and' || $operator eq 'or') {
        my $items = @arguments == 1 && ref($arguments[0]) eq 'ARRAY'
            ? $arguments[0] : \@arguments;
        Selecto::Error->throw('invalid_query', "$operator filter requires expressions")
            unless @$items;
        my @expressions = map { $class->from_filter_ast($_) } @$items;
        return $operator eq 'and' ? $class->all(\@expressions) : $class->any(\@expressions);
    }
    if ($operator eq 'not') {
        Selecto::Error->throw('invalid_query', 'not filter requires one expression')
            unless @arguments == 1;
        return $class->not($class->from_filter_ast($arguments[0]));
    }

    my ($field, $value, $end) = @arguments;
    if ($operator =~ /\A(?:array_contains|array_contained|array_overlap)\z/) {
        Selecto::Error->throw('invalid_query', "$operator filter requires a field and a value list")
            unless @arguments == 2 && ref($value) eq 'ARRAY';
        return $class->can($operator)->($class, _filter_field($field), $value);
    }
    if ($operator eq 'json_contains') {
        Selecto::Error->throw('invalid_query', 'json_contains filter requires a field and a document')
            unless @arguments == 2;
        return $class->json_contains(_filter_field($field), $value);
    }
    Selecto::Error->throw('invalid_query', 'filter field must be a governed field name')
        unless defined($field) && !ref($field)
            && "$field" =~ /\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*\z/;
    if ($operator eq 'is_null' || $operator eq 'not_null') {
        Selecto::Error->throw('invalid_query', "$operator filter accepts only a field")
            unless @arguments == 1;
        return $operator eq 'is_null' ? $class->is_null($field) : $class->not_null($field);
    }
    if ($operator eq 'in') {
        Selecto::Error->throw('invalid_query', 'in filter requires a non-empty literal list')
            unless @arguments == 2 && ref($value) eq 'ARRAY' && @$value
                && !grep { ref($_) } @$value;
        return $class->in($field, $value);
    }
    if ($operator eq 'between') {
        Selecto::Error->throw('invalid_query', 'between filter requires two literal bounds')
            unless @arguments == 3 && !ref($value) && !ref($end);
        return $class->between($field, $value, $end);
    }
    Selecto::Error->throw('invalid_query', "unsupported filter operator $operator")
        unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte|starts_with)\z/;
    Selecto::Error->throw('invalid_query', "$operator filter requires a value")
        unless @arguments == 2;
    if ($operator eq 'starts_with') {
        Selecto::Error->throw('invalid_query', 'starts_with requires a string prefix')
            if !defined($value) || ref($value);
        return $class->starts_with($field, $value);
    }
    my $right;
    if (ref($value) eq 'ARRAY' && @$value == 2
        && defined($value->[0]) && !ref($value->[0]) && "$value->[0]" eq 'field') {
        Selecto::Error->throw('invalid_query', 'field reference requires a governed field name')
            unless defined($value->[1]) && !ref($value->[1])
                && "$value->[1]" =~ /\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*\z/;
        $right = $class->field($value->[1]);
    } else {
        Selecto::Error->throw('invalid_query', "$operator filter value must be a literal or field reference")
            if ref($value);
        $right = $class->literal($value);
    }
    return $class->can($operator)->($class, $field, $right);
}

sub _filter_field {
    my ($field) = @_;
    Selecto::Error->throw('invalid_query', 'filter field must be a governed field name')
        unless defined($field) && !ref($field)
            && "$field" =~ /\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*\z/;
    return "$field";
}

sub _binary {
    my ($class, $kind, $field, $value) = @_;
    # A binary comparison normally binds its right-hand value as a literal.
    # Preserve an explicit expression there, though, so domains can safely
    # compare two governed fields (for example, id <> parent_id).
    my $right = blessed($value) && $value->isa(__PACKAGE__)
        ? $value
        : $class->literal($value);
    return $class->new($kind, $class->_operand($field), $right);
}

sub _operand {
    my ($class, $value) = @_;
    return $value if blessed($value) && $value->isa('Selecto::Expression');
    return $class->field($value);
}

sub _known_options {
    my ($options, $allowed, $label) = @_;
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$options;
    Selecto::Error->throw(
        'invalid_query',
        "$label contains unsupported options",
        {keys => \@unknown},
    ) if @unknown;
}

sub as {
    my ($self, $name) = @_;
    my $copy = bless {
        kind       => $self->{kind},
        arguments  => [map { _clone($_) } @{$self->{arguments}}],
        alias_name => "$name",
    }, ref($self);
    return $copy;
}

sub kind       { return $_[0]->{kind}; }
sub arguments  { return [map { _clone($_) } @{$_[0]->{arguments}}]; }
sub alias_name { return $_[0]->{alias_name}; }

sub _clone {
    my ($value) = @_;
    return [map { _clone($_) } @$value] if ref($value) eq 'ARRAY';
    return { map { ($_ => _clone($value->{$_})) } keys %$value } if ref($value) eq 'HASH';
    return $value;
}

1;
