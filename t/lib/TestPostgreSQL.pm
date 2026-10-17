package TestPostgreSQL;

use 5.034;
use strict;
use warnings;
use DBI;
use Mojo::URL;

# Keep the legacy socket configuration, and also honor the same explicit owned
# URL as the rest of the native PostgreSQL suite. Never embed credentials in
# diagnostics or silently connect to another local server.
sub connect {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    if (defined($url) && length($url)) {
        my $parsed = Mojo::URL->new($url);
        my $database = substr($parsed->path, 1);
        die "Invalid PostgreSQL test URL\n" unless ($parsed->scheme // '') =~ /\Apostgres(?:ql)?\z/
            && $database =~ /\A[A-Za-z0-9_]+\z/ && defined($parsed->host);
        return DBI->connect('dbi:Pg:dbname=' . $database . ';host=' . $parsed->host
            . ';port=' . ($parsed->port // 5432), $parsed->username, $parsed->password // '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
    }
    return DBI->connect('dbi:Pg:dbname=' . $ENV{SELECTO_API_TEST_DATABASE} . ';host=/tmp',
        undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}

1;
