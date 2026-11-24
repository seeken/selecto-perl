package TestSavedViews;

use 5.034;
use strict;
use warnings;
use DBI ();
use lib 't/lib';
use TestPostgreSQL ();

sub backends {
    my @backends = (['sqlite', sub { DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0}) }]);
    push @backends, ['postgresql', sub { TestPostgreSQL->connect }] if TestPostgreSQL->configured && eval { require DBD::Pg; 1 };
    for my $backend (qw(mysql mariadb)) {
        my $url = $ENV{'SELECTO_PERL_TEST_' . uc($backend) . '_URL'};
        next unless defined($url) && length($url) && eval { require DBD::MariaDB; 1 };
        require Mojo::URL;
        my $parsed = Mojo::URL->new($url);
        push @backends, [$backend, sub { DBI->connect('dbi:MariaDB:database=' . substr($parsed->path, 1)
            . ';host=' . $parsed->host . ';port=' . $parsed->port, $parsed->username, $parsed->password // '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1}) }];
    }
    return map {
        my ($name, $connect) = @$_;
        [$name, sub {
            my $dbh = eval { $connect->() };
            die "saved-view test database connection failed\n" unless $dbh;
            return $dbh;
        }];
    } @backends;
}
my $sequence = 0;
sub pair {
    my ($class, $backend) = @_;
    my ($name, $connect) = @$backend;
    if ($name eq 'sqlite') {
        require DBD::SQLite::Constants;
        my $dsn = 'dbi:SQLite:dbname=file:sv_race_' . $$ . '_' . ++$sequence . '?mode=memory&cache=shared';
        return map { DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0,
            sqlite_open_flags => DBD::SQLite::Constants::SQLITE_OPEN_READWRITE()
                | DBD::SQLite::Constants::SQLITE_OPEN_CREATE() | DBD::SQLite::Constants::SQLITE_OPEN_URI()}) } 1 .. 2;
    }
    return map { $connect->() } 1 .. 2;
}

1;
