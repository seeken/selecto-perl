use 5.034;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => 'Selecto::Adapter::FutureDB',
    VERSION_FROM => 'lib/Selecto/Adapter/FutureDB.pm',
    PREREQ_PM => { 'Selecto' => '0.002000' },
);
