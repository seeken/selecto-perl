requires 'perl', '5.034';
requires 'File::Find';
requires 'Hash::Util::FieldHash';
requires 'DBI', '1.652';
requires 'DateTime';
requires 'DateTime::TimeZone';
requires 'Digest::SHA';
requires 'Encode';
requires 'Excel::Writer::XLSX', '1.10';
requires 'File::Temp';
requires 'JSON::PP', '4.06';
requires 'Cpanel::JSON::XS', '>= 4.38, < 4.80';  # 4.80 reorders canonical keys outside the BMP (breaks ER005 and fingerprints)
requires 'Unicode::Normalize';
requires 'Math::BigInt';
requires 'Math::BigRat';
requires 'Math::BigFloat';
requires 'Mojolicious', '9.49';
requires 'Scalar::Util';
requires 'Storable';
requires 'Text::CSV', '2.04';

recommends 'DBD::Pg', '>= 3.21.2';  # 3.20.x breaks two-column and tenant-boundary writes
recommends 'DBD::MariaDB', '1.24';
recommends 'DBD::ODBC', '1.61';
recommends 'DBD::SQLite', '1.64';
recommends 'DBD::DuckDB', '0.16';

on configure => sub {
    requires 'ExtUtils::MakeMaker', '6.64';
};

on test => sub {
    requires 'Test::More';
};
