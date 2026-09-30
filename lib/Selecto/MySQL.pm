package Selecto::MySQL;

use Mojo::Base 'Selecto::MySQLFamily';

sub name    { return 'mysql'; }
sub dialect { return __PACKAGE__; }

1;

__END__

=head1 NAME

Selecto::MySQL - MySQL adapter

=head1 SYNOPSIS

  my $dbh = DBI->connect('dbi:MariaDB:database=app;host=db', $user, $password,
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});
  my $adapter = Selecto->adapter(mysql => (dbh => $dbh));

=head1 DESCRIPTION

Registered as C<mysql>. It uses L<DBD::MariaDB> 1.24 or newer and shares its
mechanics with L<Selecto::MariaDB> through L<Selecto::MySQLFamily>, but is a
separate adapter with its own identity and certification target.

It quotes identifiers with backticks, uses C<?> parameters and implements
upserts with C<ON DUPLICATE KEY UPDATE> (reporting one logical affected row).
Transactions and streaming are supported. CTEs, window functions, set
operations, rollups and the other advanced query features are not yet
implemented and fail closed with C<unsupported_feature>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::MariaDB>, L<Selecto::SQL>, L<DBD::MariaDB>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
