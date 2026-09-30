package Selecto::MariaDB;

use Mojo::Base 'Selecto::MySQLFamily';

sub name    { return 'mariadb'; }
sub dialect { return __PACKAGE__; }

1;

__END__

=head1 NAME

Selecto::MariaDB - MariaDB adapter

=head1 SYNOPSIS

  my $dbh = DBI->connect('dbi:MariaDB:database=app;host=db', $user, $password,
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});
  my $adapter = Selecto->adapter(mariadb => (dbh => $dbh));

=head1 DESCRIPTION

Registered as C<mariadb>. It uses L<DBD::MariaDB> 1.24 or newer and has the
same behavior and limits as L<Selecto::MySQL>; the two remain separate
adapters so each server is identified and certified on its own.

=head1 SEE ALSO

L<Selecto>, L<Selecto::MySQL>, L<Selecto::SQL>, L<DBD::MariaDB>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
