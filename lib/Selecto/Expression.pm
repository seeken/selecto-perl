package Selecto::Expression;

use 5.034;
use strict;
use warnings;

sub new {
    my ($class, $kind, @arguments) = @_;
    return bless { kind => "$kind", arguments => [map { _clone($_) } @arguments], alias_name => undef }, $class;
}

sub field   { my ($class, $name) = @_; return $class->new('field', "$name"); }
sub literal { my ($class, $value) = @_; return $class->new('literal', $value); }
sub count   { my ($class) = @_; return $class->new('count'); }
sub sum     { my ($class, $field) = @_; return $class->new('sum', $class->field($field)); }
sub min     { my ($class, $field) = @_; return $class->new('min', $class->field($field)); }
sub max     { my ($class, $field) = @_; return $class->new('max', $class->field($field)); }
sub datetime_format {
    my ($class, $field, $format) = @_;
    return $class->new('datetime_format', $class->field($field), "$format");
}
sub is_null { my ($class, $field) = @_; return $class->new('is_null', $class->field($field)); }
sub not_null { my ($class, $field) = @_; return $class->new('not_null', $class->field($field)); }

sub eq  { my ($class, $field, $value) = @_; return $class->_binary('eq',  $field, $value); }
sub gt  { my ($class, $field, $value) = @_; return $class->_binary('gt',  $field, $value); }
sub gte { my ($class, $field, $value) = @_; return $class->_binary('gte', $field, $value); }

sub in {
    my ($class, $field, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    return $class->new('in', $class->field($field), [@values]);
}

sub all {
    my ($class, @expressions) = @_;
    @expressions = @{$expressions[0]} if @expressions == 1 && ref($expressions[0]) eq 'ARRAY';
    return $class->new('and', [@expressions]);
}

sub _binary {
    my ($class, $kind, $field, $value) = @_;
    return $class->new($kind, $class->field($field), $class->literal($value));
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
