package Selecto::PostgreSQL::CanonicalXS;
use strict;
use warnings;
use XSLoader ();
require Selecto;
XSLoader::load('Selecto', $Selecto::VERSION);
1;

=head1 NAME

Selecto::PostgreSQL::CanonicalXS - optional internal column converter

=head1 DESCRIPTION

Loaded opportunistically by the PostgreSQL adapter. Set SELECTO_PERL_PURE=1
or $Selecto::PostgreSQL::PURE_PERL to force the reference Perl converters.
There is no required compiler or native dependency at runtime.

=cut
