use 5.034;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
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
        'JSON::PP'    => '4.06',
        'Math::BigInt' => 0,
        'Mojolicious' => '9.49',
        'Scalar::Util'=> 0,
        'Storable'    => 0,
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
                prereqs => { runtime => { requires => { 'DBD::Pg' => '3.016' } } },
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
