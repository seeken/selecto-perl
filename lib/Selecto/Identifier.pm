package Selecto::Identifier;

use 5.034;
use strict;
use warnings;
use Selecto::Error ();

sub valid {
    my ($value) = @_;
    return defined($value) && !ref($value) && "$value" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/ ? 1 : 0;
}

sub checked {
    my ($value) = @_;
    my $string = defined($value) ? "$value" : '';
    Selecto::Error->throw('invalid_identifier', 'invalid SQL identifier')
        unless $string =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return $string;
}

sub result_name {
    my ($path) = @_;
    my $name = defined($path) ? "$path" : '';
    my @segments = split /\./, $name, -1;
    Selecto::Error->throw('invalid_identifier', 'invalid result field path')
        unless @segments && !grep { !valid($_) } @segments;
    return join '.', @segments;
}

1;
