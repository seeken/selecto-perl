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
    my ($class, $association, $fields) = @_;
    return $class->new('related_collection', "$association", [map { "$_" } @$fields]);
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
sub is_null { my ($class, $field) = @_; return $class->new('is_null', $class->_operand($field)); }
sub not_null { my ($class, $field) = @_; return $class->new('not_null', $class->_operand($field)); }

sub eq  { my ($class, $field, $value) = @_; return $class->_binary('eq',  $field, $value); }
sub ne  { my ($class, $field, $value) = @_; return $class->_binary('ne',  $field, $value); }
sub gt  { my ($class, $field, $value) = @_; return $class->_binary('gt',  $field, $value); }
sub gte { my ($class, $field, $value) = @_; return $class->_binary('gte', $field, $value); }
sub lt  { my ($class, $field, $value) = @_; return $class->_binary('lt',  $field, $value); }
sub lte { my ($class, $field, $value) = @_; return $class->_binary('lte', $field, $value); }

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
