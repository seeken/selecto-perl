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

__END__

=head1 NAME

Selecto::Identifier - SQL identifier validation

=head1 DESCRIPTION

Validates identifiers separately from bound values, so no caller-supplied
text reaches SQL unchecked.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
