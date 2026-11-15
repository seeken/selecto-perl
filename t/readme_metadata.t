use 5.034;
use strict;
use warnings;
use Test::More;
use FindBin;
use ExtUtils::MM;

sub contents {
    my ($file) = @_;
    open my $fh, '<', "$FindBin::Bin/../$file" or die "$file: $!";
    local $/;
    return <$fh>;
}

my $version = MM->parse_version("$FindBin::Bin/../lib/Selecto.pm");
like contents('README.md'), qr/alpha software \(version \Q$version\E\)/,
    'README reports the VERSION_FROM distribution version';
my ($floor) = contents('Makefile.PL') =~ /'DBD::Pg'\s*=>\s*'>= ([0-9.]+)'/;
ok $floor, 'authoritative optional feature declares a PostgreSQL driver floor';
like contents('cpanfile'), qr/recommends 'DBD::Pg', '>= \Q$floor\E'/,
    'cpanfile agrees with the package feature floor';
like contents('README.md'), qr/`DBD::Pg`\s+>= \Q$floor\E\s*\|/,
    'installation guide agrees with the package feature floor';
done_testing;
