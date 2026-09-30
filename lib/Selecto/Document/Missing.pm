package Selecto::Document::Missing;

use 5.034;
use strict;
use warnings;
use overload '""' => sub { 'Selecto.Document.Missing' }, fallback => 1;

my $INSTANCE = bless {}, __PACKAGE__;
sub value { return $INSTANCE; }

1;

__END__

=head1 NAME

Selecto::Document::Missing - marker for an absent document field

=head1 DESCRIPTION

A singleton that distinguishes a missing document field from a null value.

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
