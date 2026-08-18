use 5.034;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Selecto',
    VERSION_FROM     => 'lib/Selecto.pm',
    ABSTRACT_FROM    => 'lib/Selecto.pm',
    AUTHOR           => 'Chris Rohlfs',
    LICENSE          => 'unrestricted',
    MIN_PERL_VERSION => '5.034',
    EXE_FILES        => ['bin/selecto-certify'],
    PREREQ_PM        => {
        'DBI'         => '1.643',
        'Digest::SHA' => 0,
        'JSON::PP'    => '4.06',
        'Mojolicious' => '9.40',
        'Scalar::Util'=> 0,
        'Storable'    => 0,
        'URI::Escape' => 0,
    },
    TEST_REQUIRES => {
        'File::Temp' => 0,
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
        },
        x_license => 'O-Saasy',
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
            sqlite => {
                description => 'SQLite execution and certification',
                prereqs => { runtime => { requires => { 'DBD::SQLite' => '1.64' } } },
            },
        },
    },
);
