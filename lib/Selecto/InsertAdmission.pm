package Selecto::InsertAdmission;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed looks_like_number);
use Selecto::Error ();

# The standalone QueryEnforcement scalar evaluator has a portable, untyped
# contract. Governed insert admission instead validates domain-typed scalars,
# then asks an adapter to compare a prospective row using actual storage types.
sub prepare {
    my ($class, $predicate, $assignments, $types) = @_;
    my (%values, %used);
    my @pending = ($predicate);
    while (my $expression = pop @pending) {
        _unsupported() unless blessed($expression) && $expression->isa('Selecto::Expression');
        my $kind = $expression->kind;
        my $args = $expression->arguments;
        if ($kind eq 'and' || $kind eq 'or') {
            _unsupported() unless ref($args->[0]) eq 'ARRAY' && @{$args->[0]};
            push @pending, @{$args->[0]};
            next;
        }
        if ($kind eq 'not') { push @pending, $args->[0]; next; }
        _unsupported() unless $kind =~ /\A(?:eq|ne|gt|gte|lt|lte|in|is_null|not_null)\z/;
        my $operand = $args->[0];
        _unsupported() unless blessed($operand) && $operand->kind eq 'field';
        my $field = $operand->arguments->[0];
        _unsupported() unless exists($types->{$field}) && $field !~ /\./;
        my $type = lc($types->{$field} // '');
        $type = 'string' if $type eq 'text';
        _unsupported() unless $type =~ /\A(?:integer|decimal|string|boolean)\z/;
        _not_evaluable($field) unless exists $assignments->{$field};
        my $value = $assignments->{$field};
        if (blessed($value) && $value->isa('Selecto::Write::Expression')) {
            _not_evaluable($field) unless $value->kind eq 'literal';
            $value = $value->arguments->[0];
        }
        $values{$field} = _value($type, $value, $field);
        $used{$field} = $type;
        next if $kind eq 'is_null' || $kind eq 'not_null';
        my @expected;
        if ($kind eq 'in') {
            _unsupported() unless ref($args->[1]) eq 'ARRAY' && @{$args->[1]};
            @expected = @{$args->[1]};
        } else {
            _unsupported() unless blessed($args->[1]) && $args->[1]->kind eq 'literal';
            @expected = ($args->[1]->arguments->[0]);
        }
        _value($type, $_, $field) for @expected;
    }
    return {values => \%values, types => \%used};
}

sub _value {
    my ($type, $value, $field) = @_;
    return undef unless defined $value;
    _not_evaluable($field) if ref($value);
    my $text = "$value";
    if ($type eq 'integer') {
        _not_evaluable($field) unless $text =~ /\A-?(?:0|[1-9][0-9]*)\z/;
        my $digits = $text; $digits =~ s/^-//;
        my $maximum = $text =~ /^-/ ? '9223372036854775808' : '9223372036854775807';
        _not_evaluable($field) if length($digits) > length($maximum)
            || (length($digits) == length($maximum) && $digits gt $maximum);
    } elsif ($type eq 'decimal') {
        _not_evaluable($field) unless $text =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/;
    } elsif ($type eq 'boolean') {
        _not_evaluable($field) unless $text =~ /\A[01]\z/;
    } elsif (looks_like_number($value)) {
        # Preserve the existing portable refusal of native/non-finite scalars.
        _not_evaluable($field) unless $text =~ /\A[ \t\r\n\f\x0b]*[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?[ \t\r\n\f\x0b]*\z/;
    }
    return $value;
}

sub _not_evaluable {
    my ($field) = @_;
    Selecto::Error->throw('query_rule_not_evaluable',
        'insert policy requires an explicit canonical typed scalar', {field => $field});
}

sub _unsupported {
    Selecto::Error->throw('query_rule_unsupported_predicate',
        'insert policy is outside the supported typed storage subset');
}

1;
