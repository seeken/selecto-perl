package Selecto::MariaDB;

use Mojo::Base 'Selecto::MySQLFamily';

sub name    { return 'mariadb'; }
sub dialect { return __PACKAGE__; }

1;
