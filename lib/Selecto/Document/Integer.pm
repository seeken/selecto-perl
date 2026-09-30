package Selecto::Document::Integer;
use 5.034;
use strict;
use warnings;
use Math::BigInt;
use Selecto::Error ();
use overload '""' => sub { ${$_[0]} }, fallback => 1;

sub new {
    my ($class, $value) = @_;
    Selecto::Error->throw('invalid_predicate_value', 'Exact signed 64-bit decimal string required')
        unless defined($value) && !ref($value) && "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/;
    my $integer = Math::BigInt->new("$value");
    Selecto::Error->throw('invalid_predicate_value', 'Integer exceeds signed 64-bit range')
        if $integer < Math::BigInt->new('-9223372036854775808') || $integer > Math::BigInt->new('9223372036854775807');
    my $canonical = $integer->bstr;
    my $self = bless \$canonical, $class;
    Internals::SvREADONLY($canonical, 1);
    return $self;
}
sub value { ${$_[0]} }
1;

__END__

=head1 NAME

Selecto::Document::Integer - exact signed 64-bit integer for document predicates

=head1 DESCRIPTION

Carries an integer as a decimal string so document predicates preserve signed
Int64 values exactly.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Document::Plan>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
