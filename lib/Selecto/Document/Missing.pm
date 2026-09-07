package Selecto::Document::Missing;

use 5.034;
use strict;
use warnings;
use overload '""' => sub { 'Selecto.Document.Missing' }, fallback => 1;

my $INSTANCE = bless {}, __PACKAGE__;
sub value { return $INSTANCE; }

1;
