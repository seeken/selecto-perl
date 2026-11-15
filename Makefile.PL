use 5.034;
use strict;
use warnings;
use ExtUtils::MakeMaker;

# Optional native acceleration. Probe both compilation and linking first;
# a source installation without a working toolchain remains pure Perl.
my ($cc) = map { /\ACC=(.*)\z/ ? $1 : () } @ARGV;
my $xs = !$ENV{SELECTO_PERL_NO_XS} && eval {
    require ExtUtils::CBuilder;
    ExtUtils::CBuilder->new(quiet => 1, (defined($cc) ? (config => {cc => $cc}) : ()))->have_compiler;
};
print $xs ? "Optional canonical XS enabled\n" : "Canonical conversion: pure Perl (optional XS unavailable or disabled)\n";

WriteMakefile(
    XS               => $xs ? {'xs/CanonicalXS.xs' => 'CanonicalXS.c'} : {},
    C                => $xs ? ['CanonicalXS.c'] : [],
    OBJECT           => $xs ? 'CanonicalXS$(OBJ_EXT)' : '',
    clean            => { FILES => 'CanonicalXS.c CanonicalXS.o' },
    NAME             => 'Selecto',
    VERSION_FROM     => 'lib/Selecto.pm',
    ABSTRACT_FROM    => 'lib/Selecto.pm',
    AUTHOR           => 'Chris Rohlfs <seeken@gmail.com>',
    LICENSE          => 'artistic_2',
    MIN_PERL_VERSION => '5.034',
    PREREQ_PM        => {
        'DBI'         => '1.652',
        'DateTime::TimeZone' => 0,
        'DateTime' => 0,
        'Digest::SHA' => 0,
        'Encode'      => 0,
        'Excel::Writer::XLSX' => '1.10',
        'File::Temp'  => 0,
        'File::Find'  => 0,
        'Hash::Util::FieldHash' => 0,
        'JSON::PP'    => '4.06',
        'Cpanel::JSON::XS' => '4.38',
        'Math::BigInt' => 0,
        'Math::BigRat' => 0,
        'Math::BigFloat' => 0,
        'MIME::Base64' => 0,
        'Mojolicious' => '9.49',
        'Scalar::Util'=> 0,
        'Storable'    => 0,
        'Unicode::Normalize' => 0,
        'Text::CSV'   => '2.04',
    },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '6.64',
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        # 4.80 reorders canonical keys outside the BMP (breaks ER005 and fingerprints).
        prereqs => { runtime => { requires => { 'Cpanel::JSON::XS' => '>= 4.38, < 4.80' } } },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/seeken/selecto-perl.git',
                web  => 'https://github.com/seeken/selecto-perl',
            },
            bugtracker => {
                web => 'https://github.com/seeken/selecto-perl/issues',
            },
        },
        no_index => {
            directory => [qw(t docs script)],
        },
        optional_features => {
            postgresql => {
                description => 'PostgreSQL execution and certification',
                prereqs => { runtime => { requires => { 'DBD::Pg' => '>= 3.21.2' } } },
            },
            mysql => {
                description => 'MySQL execution and certification',
                prereqs => { runtime => { requires => { 'DBD::MariaDB' => '1.24' } } },
            },
            mariadb => {
                description => 'MariaDB execution and certification',
                prereqs => { runtime => { requires => { 'DBD::MariaDB' => '1.24' } } },
            },
            mssql => {
                description => 'Microsoft SQL Server execution and certification',
                prereqs => { runtime => { requires => { 'DBD::ODBC' => '1.61' } } },
            },
            sqlite => {
                description => 'SQLite execution and certification',
                prereqs => { runtime => { requires => { 'DBD::SQLite' => '1.64' } } },
            },
            duckdb => {
                description => 'DuckDB execution and certification',
                prereqs => { runtime => { requires => { 'DBD::DuckDB' => '0.16' } } },
            },
        },
    },
);

# Keep the XS source out of MakeMaker's automatic top-level *.xs discovery,
# so disabled/no-compiler builds cannot accidentally request a shared library.
sub MY::postamble {
    return '' unless $xs;
    return <<'MAKE';
CanonicalXS.c: xs/CanonicalXS.xs $(XSUBPPDEPS)
	$(XSUBPPRUN) $(XSPROTOARG) $(XSUBPPARGS) $(XSUBPP_EXTRA_ARGS) xs/CanonicalXS.xs > CanonicalXS.xsc
	$(MV) CanonicalXS.xsc CanonicalXS.c
MAKE
}
