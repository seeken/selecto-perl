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
            # Keys become JSON object keys in SQL text; only identifier paths
            # are accepted so no quoting rule of any dialect is relied upon.
            Selecto::Error->throw(
                'invalid_query', 'related collection key must be an identifier path',
            ) unless "$_->{key}" =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
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
sub starts_with_ci {
    my ($class, $field, $prefix) = @_;
    Selecto::Error->throw('invalid_query', 'starts_with_ci requires a string prefix')
        if !defined($prefix) || ref($prefix);
    return $class->_binary('starts_with_ci', $field, "$prefix");
}
# Literal substring and suffix matches; LIKE wildcards in the value are escaped.
sub text_contains {
    my ($class, $field, $text) = @_;
    Selecto::Error->throw('invalid_query', 'text_contains requires a string value')
        if !defined($text) || ref($text);
    return $class->_binary('text_contains', $field, "$text");
}
sub text_contains_ci {
    my ($class, $field, $text) = @_;
    Selecto::Error->throw('invalid_query', 'text_contains_ci requires a string value')
        if !defined($text) || ref($text);
    return $class->_binary('text_contains_ci', $field, "$text");
}
sub ends_with {
    my ($class, $field, $suffix) = @_;
    Selecto::Error->throw('invalid_query', 'ends_with requires a string suffix')
        if !defined($suffix) || ref($suffix);
    return $class->_binary('ends_with', $field, "$suffix");
}
sub ends_with_ci {
    my ($class, $field, $suffix) = @_;
    Selecto::Error->throw('invalid_query', 'ends_with_ci requires a string suffix')
        if !defined($suffix) || ref($suffix);
    return $class->_binary('ends_with_ci', $field, "$suffix");
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

# Nesting beyond 64 levels is refused, as in the Go core: compile time grows
# with depth, and no authored filter needs more.
sub from_filter_ast {
    my ($class, $filter, $depth) = @_;
    $depth //= 0;
    Selecto::Error->throw('invalid_query', 'filter expression is nested too deeply')
        if $depth > 64;
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
        my @expressions = map { $class->from_filter_ast($_, $depth + 1) } @$items;
        return $operator eq 'and' ? $class->all(\@expressions) : $class->any(\@expressions);
    }
    if ($operator eq 'not') {
        Selecto::Error->throw('invalid_query', 'not filter requires one expression')
            unless @arguments == 1;
        return $class->not($class->from_filter_ast($arguments[0], $depth + 1));
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
        unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte|(?:starts_with|text_contains|ends_with)(?:_ci)?)\z/;
    Selecto::Error->throw('invalid_query', "$operator filter requires a value")
        unless @arguments == 2;
    if ($operator =~ /\A(?:starts_with|text_contains|ends_with)(?:_ci)?\z/) {
        Selecto::Error->throw('invalid_query', "$operator requires a string value")
            if !defined($value) || ref($value);
        return $class->$operator($field, $value);
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

# Every field path an expression reads, in argument order: field operands,
# value-expression dependencies and related-collection children (whose
# named fields, filters and orderings are relative to the association;
# expression fields carry full paths). Arrays and hashes of expressions are
# walked in order.
sub field_references {
    my ($class, $value) = @_;
    if (blessed($value) && $value->isa('Selecto::Expression')) {
        my ($kind, $arguments) = ($value->kind, $value->arguments);
        return ($arguments->[0]) if $kind eq 'field';
        return () if $kind eq 'literal';
        if ($kind eq 'value') {
            require Selecto::ValueExpression;
            return Selecto::ValueExpression->dependencies($arguments->[0]);
        }
        if ($kind eq 'related_collection') {
            my ($association, $fields, $options) = @$arguments;
            $options = {} unless ref($options) eq 'HASH';
            return (
                (map {
                    !ref($_) ? "$association.$_"
                        # A nested collection's association is relative to this one.
                        : $_->{expression}->kind eq 'related_collection'
                            ? (map { "$association.$_" } $class->field_references($_->{expression}))
                        : $class->field_references($_->{expression})
                } @{ref($fields) eq 'ARRAY' ? $fields : []}),
                (map { "$association.$_->[0]" }
                    @{$options->{filters} // []}, @{$options->{order_by} // []}),
            );
        }
        return map { $class->field_references($_) } @$arguments;
    }
    return map { $class->field_references($_) } @$value if ref($value) eq 'ARRAY';
    return map { $class->field_references($value->{$_}) } sort keys %$value if ref($value) eq 'HASH';
    return ();
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

__END__

=head1 NAME

Selecto::Expression - fields, predicates, aggregates and other query expressions

=head1 SYNOPSIS

  use Selecto::Expression;

  my $recent = Selecto::Expression->all(
      Selecto::Expression->eq('status', 'shipped'),
      Selecto::Expression->between('ordered_on', '2026-01-01', '2026-03-31'),
      Selecto::Expression->any(
          Selecto::Expression->in('region', [qw(north east)]),
          Selecto::Expression->starts_with_ci('customer.name', 'acme'),
      ),
  );

  my $revenue = Selecto::Expression->sum('total')->as('revenue');

  # The same predicate from portable data, e.g. a JSON request body:
  my $filter = Selecto::Expression->from_filter_ast(
      ['and', [['eq', 'status', 'shipped'], ['gte', 'total', 100]]]);

=head1 DESCRIPTION

Expressions are small immutable trees. They name fields by dotted path and
carry literal values separately, so adapters always emit placeholders and
pass values as bound parameters. Nothing in an expression is ever pasted
into SQL text.

All constructors are class methods. Where an argument is a field, you can
pass a field path string or another expression; the right-hand side of a
comparison is a literal unless you pass an expression, which lets you compare
two governed fields (C<< Selecto::Expression->ne('id', Selecto::Expression->field('parent_id')) >>).

Some expressions need adapter capabilities. An adapter that cannot compile
one fails with C<unsupported_feature> or C<invalid_query> before execution.

=head1 OPERANDS

=head2 field

  Selecto::Expression->field('customer.name')

=head2 literal

  Selecto::Expression->literal(42)

=head2 as

  my $aliased = $expression->as('total_freight');

Returns a copy with a result-column alias.

=head1 PREDICATES

=head2 eq, ne, gt, gte, lt, lte

  Selecto::Expression->gte('total', '100.00')

=head2 between

  Selecto::Expression->between('ordered_on', $from, $to)

=head2 in

  Selecto::Expression->in('status', [qw(open pending)])
  Selecto::Expression->in('status', 'open', 'pending')

=head2 is_null, not_null

  Selecto::Expression->is_null('shipped_at')

=head2 starts_with, text_contains, ends_with

  Selecto::Expression->text_contains('name', '50%_off')

Literal prefix, substring and suffix matches. C<%>, C<_> and the escape
character in the value are escaped, so user input is never a LIKE pattern.
Each has a case-insensitive C<_ci> variant (C<starts_with_ci>,
C<text_contains_ci>, C<ends_with_ci>). Matching follows the database
collation. An empty prefix matches every non-null value.

=head2 all, any, not

  Selecto::Expression->all(@predicates)    # AND
  Selecto::Expression->any(@predicates)    # OR
  Selecto::Expression->not($predicate)

C<all> and C<any> also accept a single array reference.

=head2 from_filter_ast

  my $predicate = Selecto::Expression->from_filter_ast($ast);

Builds a predicate from the portable filter AST used by query-library
segments, computed predicate columns and API clients:

  ['and', [AST, ...]]           ['or', [AST, ...]]           ['not', AST]
  ['eq', FIELD, VALUE]          # also ne gt gte lt lte
  ['between', FIELD, LOW, HIGH]
  ['in', FIELD, [VALUE, ...]]
  ['is_null', FIELD]            ['not_null', FIELD]
  ['starts_with', FIELD, TEXT]  # also text_contains, ends_with and the _ci forms
  ['array_contains', FIELD, [VALUE, ...]]   # also array_contained, array_overlap
  ['json_contains', FIELD, {DOCUMENT}]

A comparison VALUE may be C<['field', PATH]> to compare two fields. Field
names must be dotted identifiers; anything else throws C<invalid_query>, as
does nesting C<and>, C<or> and C<not> more than 64 levels deep.

=head2 field_references

  my @paths = Selecto::Expression->field_references($expression_or_list);

Every field path an expression reads, in argument order: field operands,
the dependencies of computed values and the children, filters and orderings
of related collections (prefixed with their association). Literals add
nothing. Public surfaces use it to refuse expressions that read a field the
domain withholds (L<Selecto::Domain/field_is_public>).

=head1 AGGREGATES

=over 4

=item C<count> - C<COUNT(*)>

=item C<count_field($field)>, C<count_distinct($field)>

=item C<sum($field)>, C<sum_zero($field)> (null-safe sum), C<avg>, C<min>, C<max>

=item C<true_count($field)>, C<false_count($field)>

=item C<true_percentage($field)>

Percentage of true values among non-null booleans; null for an empty or
all-null group.

=item C<grouping(@expressions)>

The SQL C<GROUPING()> marker for rollup queries; see
L<Selecto::Query/group_by_rollup>.

=back

=head1 WINDOW FUNCTIONS

  Selecto::Expression->window_sum('total',
      partition_by => ['customer_id'],
      order_by     => [['id', 'asc']],
      frame        => {type => 'rows', start => 'unbounded_preceding', end => 'current_row'},
  )->as('running_total');

C<row_number>, C<rank>, C<dense_rank>, C<window_sum>, C<window_avg>,
C<lag($field, $offset, $default, %over)> and C<lead(...)> are shortcuts for
C<< window($function, \@arguments, %over) >>, which accepts the allowlisted
functions C<row_number rank dense_rank percent_rank cume_dist ntile lag lead
first_value last_value nth_value count sum avg min max>. Frames take
C<type> (C<rows>, C<range> or C<groups>) and C<start>/C<end> boundaries:
C<unbounded_preceding>, C<current_row>, C<unbounded_following>,
C<< {preceding => N} >> or C<< {following => N} >>. Requires the
C<window_functions> capability.

=head1 RELATED COLLECTIONS

  Selecto::Expression->related_collection('lines', [qw(sku quantity)],
      order_by => [['sku', 'asc']], limit => 20)->as('lines');
  Selecto::Expression->related_sum('lines', 'quantity')->as('units');
  Selecto::Expression->related_count('lines', 'id')->as('line_count');

A correlated JSON array of child rows, or a correlated scalar aggregate, over
a to-many association. The outer query keeps one row per root record and the
association is not joined into it. Options: C<filters> (C<[[field, value]]>
equalities), C<order_by> (C<[[field, direction]]>), C<limit> (per parent,
requires C<order_by>) and C<after> (a keyset cursor). Field entries may also
be C<< {key => 'name', expression => $expression} >>.

=head1 DATES AND TIMES

=head2 datetime_format

  Selecto::Expression->datetime_format('ordered_at', 'month')

Formats a date or time with an allowlisted format name (C<iso8601>,
C<rfc3339_millis>, C<epoch_seconds>, C<epoch_milliseconds>, C<day>,
C<time>, C<day_hour>, C<week>, C<iso_week>, C<iso_week_date>, C<month>,
C<quarter>, C<year>, C<month_of_year>, C<day_of_month>, C<day_of_week>,
C<day_of_week_num>, C<day_of_year>, C<hour>, C<timezone_offset>). Use the
same expression in C<select>, C<group_by> and C<order_by>. PostgreSQL and
DuckDB implement these; other adapters fail closed. The instant formats
(C<iso8601> of a C<utc_datetime>, C<rfc3339_millis>, the epochs and
C<timezone_offset>) read a C<utc_datetime> column declared
C<< storage => 'naive_utc' >> as C<(column AT TIME ZONE 'UTC')>, with or
without L<Selecto::Query/use_timezone>.

=head2 epoch_datetime

Treats a numeric epoch column as an instant.

=head2 bucket, count_bucket

  Selecto::Expression->bucket('price', {kind => 'numeric_increment', increment => 50})

Adapter-compiled bucketing for aggregate views. Bucket kinds include
C<numeric_increment>, C<year_increment>, C<text_prefix>, C<numeric_ranges>,
C<elapsed_days_ranges>, C<date_relative_ranges> and C<year_ranges>.
C<count_bucket($field, $minimum, $maximum)> counts values within bounds.

=head1 POSTGRESQL-ONLY EXPRESSIONS

=over 4

=item C<text_search($fields, $query, configuration => 'simple', mode => 'plain')>

=item C<text_rank($fields, $query, ...)>

Full-text search and rank. Configurations and modes are allowlisted; the
search text is bound.

=item C<array_contains($field, @values)>, C<array_contained(...)>, C<array_overlap(...)>

Array predicates over a column declared with an C<items> type. Each value is
bound and the list is cast to the element type. Null arrays never match.

=item C<json_contains($field, \%document)>

JSON containment with the document bound as canonical JSON.

=back

=head1 OTHER EXPRESSIONS

=head2 value

  Selecto::Expression->value(['divide', ['field', 'cents'], ['literal', 100]])->as('dollars')

A computed value from the closed AST in L<Selecto::ValueExpression>,
type-checked against the engine's domain. Requires the C<value_expressions>
capability (PostgreSQL, DuckDB).

=head2 dimension_display

  Selecto::Expression->dimension_display('ref_status.description', 'status_id')

Displays a star-dimension label while grouping by its key.

=head1 INSPECTION

C<kind>, C<arguments> (a deep copy) and C<alias_name> expose an expression's
structure for adapters and tools.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Query>, L<Selecto::ValueExpression>, L<Selecto::DateFormat>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
