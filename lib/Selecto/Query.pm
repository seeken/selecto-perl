package Selecto::Query;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::Expression ();

sub new {
    my ($class, %args) = @_;
    my %allowed = map { $_ => 1 } qw(
        selections predicate groups grouping_mode orders limit_value offset_value applied_query_library
    );
    my @unknown = sort grep { !$allowed{$_} } keys %args;
    Selecto::Error->throw(
        'invalid_query',
        'query state contains unsupported keys',
        { keys => \@unknown },
    ) if @unknown;
    for my $order (@{$args{orders} // []}) {
        Selecto::Error->throw('invalid_query', 'order entries must contain a field and direction')
            unless ref($order) eq 'ARRAY' && @$order == 2;
        my $direction = defined($order->[1]) ? lc("$order->[1]") : 'asc';
        Selecto::Error->throw('invalid_query', 'order direction must be asc or desc')
            unless $direction eq 'asc' || $direction eq 'desc';
    }
    Selecto::Error->throw('invalid_query', 'grouping mode must be plain or rollup')
        if defined($args{grouping_mode})
        && $args{grouping_mode} ne 'plain'
        && $args{grouping_mode} ne 'rollup';
    return bless {
        selections  => [@{$args{selections} // []}],
        predicate   => $args{predicate},
        groups      => [@{$args{groups} // []}],
        grouping_mode => $args{grouping_mode} // 'plain',
        orders      => [map { [@$_] } @{$args{orders} // []}],
        limit_value  => defined($args{limit_value}) ? _nonnegative($args{limit_value}, 'limit') : undef,
        offset_value => defined($args{offset_value}) ? _nonnegative($args{offset_value}, 'offset') : undef,
        applied_query_library => dclone($args{applied_query_library} // {
            segments => [], projections => [], projection => undef,
            ordering => undef, views => [],
        }),
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
    } @fields], grouping_mode => 'plain');
}

sub group_by_rollup {
    my ($self, @fields) = @_;
    @fields = @{$fields[0]} if @fields == 1 && ref($fields[0]) eq 'ARRAY';
    return $self->_copy(groups => [map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @fields], grouping_mode => 'rollup');
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

sub replace_selections {
    my ($self, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    my @expressions = map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @values;
    return $self->_copy(selections => \@expressions);
}

sub replace_orders {
    my ($self, $orders) = @_;
    Selecto::Error->throw('invalid_query', 'orders must be an array')
        unless ref($orders) eq 'ARRAY';
    my $query = $self->_copy(orders => []);
    for my $order (@$orders) {
        Selecto::Error->throw('invalid_query', 'order entries must contain a field and direction')
            unless ref($order) eq 'ARRAY' && @$order == 2;
        $query = $query->order_by($order->[0], $order->[1]);
    }
    return $query;
}

sub with_applied_query_library {
    my ($self, $applied) = @_;
    Selecto::Error->throw('invalid_query', 'applied query library state must be an object')
        unless ref($applied) eq 'HASH';
    return $self->_copy(applied_query_library => $applied);
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
        grouping_mode => $self->{grouping_mode},
        orders       => $self->{orders},
        limit_value  => $self->{limit_value},
        offset_value => $self->{offset_value},
        applied_query_library => $self->{applied_query_library},
        %changes,
    );
    return ref($self)->new(%state);
}

sub selections   { return [@{$_[0]->{selections}}]; }
sub predicate    { return $_[0]->{predicate}; }
sub groups       { return [@{$_[0]->{groups}}]; }
sub grouping_mode { return $_[0]->{grouping_mode}; }
sub orders       { return [map { [@$_] } @{$_[0]->{orders}}]; }
sub limit_value  { return $_[0]->{limit_value}; }
sub offset_value { return $_[0]->{offset_value}; }
sub applied_query_library { return dclone($_[0]->{applied_query_library}); }

1;
