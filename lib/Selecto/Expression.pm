package Selecto::Expression;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);

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
    return $class->new($kind, $class->_operand($field), $class->literal($value));
}

sub _operand {
    my ($class, $value) = @_;
    return $value if blessed($value) && $value->isa('Selecto::Expression');
    return $class->field($value);
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
