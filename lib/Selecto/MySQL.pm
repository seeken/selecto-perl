package Selecto::MySQL;

use Mojo::Base 'Selecto::MySQLFamily';

sub name    { return 'mysql'; }
sub dialect { return __PACKAGE__; }

1;
