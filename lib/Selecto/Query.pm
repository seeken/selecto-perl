package Selecto::Query;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();

sub new {
    my ($class, %args) = @_;
    return bless {
        selections  => [@{$args{selections} // []}],
        predicate   => $args{predicate},
        groups      => [@{$args{groups} // []}],
        orders      => [map { [@$_] } @{$args{orders} // []}],
        limit_value => $args{limit_value},
        offset_value=> $args{offset_value},
    }, $class;
}

sub select {
    my ($self, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    my @expressions = map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @values;
    return $self->_copy(selections => \@expressions);
}

sub where {
    my ($self, $expression) = @_;
    Selecto::Error->throw('invalid_query', 'where expects an expression')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    return $self->_copy(predicate => $expression);
}

sub group_by {
    my ($self, @fields) = @_;
    @fields = @{$fields[0]} if @fields == 1 && ref($fields[0]) eq 'ARRAY';
    return $self->_copy(groups => [map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @fields]);
}

sub order_by {
    my ($self, $field, $direction) = @_;
    $direction = defined($direction) ? lc("$direction") : 'asc';
    Selecto::Error->throw('invalid_query', 'order direction must be asc or desc')
        unless $direction eq 'asc' || $direction eq 'desc';
    my $expression = blessed($field) && $field->isa('Selecto::Expression')
        ? $field : Selecto::Expression->field($field);
    return $self->_copy(orders => [@{$self->{orders}}, [$expression, $direction]]);
}

sub limit  { my ($self, $value) = @_; return $self->_copy(limit_value  => _nonnegative($value, 'limit')); }
sub offset { my ($self, $value) = @_; return $self->_copy(offset_value => _nonnegative($value, 'offset')); }

sub _nonnegative {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_query', "$label must be a non-negative integer")
        unless defined($value) && "$value" =~ /\A\d+\z/;
    return int($value);
}

sub _copy {
    my ($self, %changes) = @_;
    my %state = (
        selections   => $self->{selections},
        predicate    => $self->{predicate},
        groups       => $self->{groups},
        orders       => $self->{orders},
        limit_value  => $self->{limit_value},
        offset_value => $self->{offset_value},
        %changes,
    );
    return ref($self)->new(%state);
}

sub selections   { return [@{$_[0]->{selections}}]; }
sub predicate    { return $_[0]->{predicate}; }
sub groups       { return [@{$_[0]->{groups}}]; }
sub orders       { return [map { [@$_] } @{$_[0]->{orders}}]; }
sub limit_value  { return $_[0]->{limit_value}; }
sub offset_value { return $_[0]->{offset_value}; }

1;
