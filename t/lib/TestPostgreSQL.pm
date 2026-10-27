package TestPostgreSQL;

use 5.034;
use strict;
use warnings;
use DBI;
use Mojo::URL;

# The suite's PostgreSQL server is only ever the explicit, owned
# SELECTO_PERL_TEST_POSTGRES_URL (brief item 36): never a default socket
# or port, whatever other variables (the legacy SELECTO_API_TEST_DATABASE,
# PGHOST, DATABASE_URL) say. Never embed credentials in diagnostics.
sub configured {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    return defined($url) && length($url) ? 1 : 0;
}

# (dsn, user, password) for DBI->connect.
sub connection {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    die "SELECTO_PERL_TEST_POSTGRES_URL is not set\n" unless defined($url) && length($url);
    my $parsed = Mojo::URL->new($url);
    my $database = substr($parsed->path, 1);
    die "Invalid PostgreSQL test URL\n" unless ($parsed->scheme // '') =~ /\Apostgres(?:ql)?\z/
        && $database =~ /\A[A-Za-z0-9_]+\z/ && defined($parsed->host) && length($parsed->host)
        && defined($parsed->port);
    return ('dbi:Pg:dbname=' . $database . ';host=' . $parsed->host . ';port=' . $parsed->port,
        $parsed->username, $parsed->password // '');
}

sub connect {
    my ($class, %attributes) = @_;
    return DBI->connect($class->connection,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1, %attributes});
}

1;
