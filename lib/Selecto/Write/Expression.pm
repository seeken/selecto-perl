package Selecto::Write::Expression;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

my %KINDS = map { $_ => 1 } qw(
    literal field current_timestamp default
    add subtract multiply divide coalesce
);

sub new {
    my ($class, $kind, @arguments) = @_;
    $kind = defined($kind) && !ref($kind) ? "$kind" : '';
    Selecto::Error->throw('invalid_write', 'unknown mutation expression kind')
        unless $KINDS{$kind};
    if ($kind eq 'literal') {
        Selecto::Error->throw('invalid_write', 'mutation literal requires one value')
            unless @arguments == 1;
    } elsif ($kind eq 'field') {
        Selecto::Error->throw('invalid_write', 'mutation field requires one root identifier')
            unless @arguments == 1 && defined($arguments[0]) && !ref($arguments[0])
                && "$arguments[0]" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        $arguments[0] = "$arguments[0]";
    } elsif ($kind eq 'current_timestamp' || $kind eq 'default') {
        Selecto::Error->throw('invalid_write', "mutation $kind takes no operands")
            if @arguments;
    } elsif ($kind eq 'coalesce') {
        Selecto::Error->throw('invalid_write', 'mutation coalesce requires at least two expression operands')
            unless @arguments == 1 && ref($arguments[0]) eq 'ARRAY'
                && @{$arguments[0]} >= 2
                && !grep { !blessed($_) || !$_->isa(__PACKAGE__) } @{$arguments[0]};
    } else {
        Selecto::Error->throw('invalid_write', "mutation $kind requires two expression operands")
            unless @arguments == 2
                && !grep { !blessed($_) || !$_->isa(__PACKAGE__) } @arguments;
    }
    return bless {kind => $kind, arguments => [map { _clone($_) } @arguments]}, $class;
}

sub literal { my ($class, $value) = @_; return $class->new('literal', $value); }
sub field {
    my ($class, $name) = @_;
    return $class->new('field', $name);
}
sub current_timestamp { my ($class) = @_; return $class->new('current_timestamp'); }
sub default { my ($class) = @_; return $class->new('default'); }
sub add { my ($class, $left, $right) = @_; return $class->_binary('add', $left, $right); }
sub subtract { my ($class, $left, $right) = @_; return $class->_binary('subtract', $left, $right); }
sub multiply { my ($class, $left, $right) = @_; return $class->_binary('multiply', $left, $right); }
sub divide { my ($class, $left, $right) = @_; return $class->_binary('divide', $left, $right); }
sub increment {
    my ($class, $field, $amount) = @_;
    $amount //= 1;
    return $class->add($class->field($field), $class->literal($amount));
}
sub decrement {
    my ($class, $field, $amount) = @_;
    $amount //= 1;
    return $class->subtract($class->field($field), $class->literal($amount));
}
sub coalesce {
    my ($class, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    Selecto::Error->throw('invalid_write', 'mutation coalesce requires at least two operands')
        unless @values >= 2;
    return $class->new('coalesce', [map { $class->_operand($_) } @values]);
}

sub _binary {
    my ($class, $kind, $left, $right) = @_;
    return $class->new($kind, $class->_operand($left), $class->_operand($right));
}

sub _operand {
    my ($class, $value) = @_;
    return $value if blessed($value) && $value->isa(__PACKAGE__);
    return $class->literal($value);
}

sub kind { return $_[0]->{kind}; }
sub arguments { return [map { _clone($_) } @{$_[0]->{arguments}}]; }

sub referenced_fields {
    my ($self) = @_;
    my %fields;
    _collect_fields($self, \%fields);
    return [sort keys %fields];
}

sub _collect_fields {
    my ($value, $fields) = @_;
    if (blessed($value) && $value->isa(__PACKAGE__)) {
        $fields->{$value->{arguments}[0]} = 1 if $value->{kind} eq 'field';
        _collect_fields($_, $fields) for @{$value->{arguments}};
    } elsif (ref($value) eq 'ARRAY') {
        _collect_fields($_, $fields) for @$value;
    }
}

sub _clone {
    my ($value) = @_;
    return bless {
        kind => $value->{kind},
        arguments => [map { _clone($_) } @{$value->{arguments}}],
    }, ref($value) if blessed($value) && $value->isa(__PACKAGE__);
    return [map { _clone($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _clone($value->{$_}) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}

1;
