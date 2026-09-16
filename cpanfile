requires 'perl', '5.034';
requires 'DBI', '1.643';
requires 'DateTime::TimeZone';
requires 'DateTime';
requires 'Encode';
requires 'Excel::Writer::XLSX', '1.10';
requires 'File::Temp';
requires 'JSON::PP', '4.06';
requires 'Mojolicious', '9.40';
requires 'Text::CSV', '2.04';
recommends 'DBD::Pg', '3.016';
recommends 'DBD::MariaDB', '1.24';
recommends 'DBD::ODBC', '1.61';
recommends 'DBD::SQLite', '1.64';
recommends 'DBD::DuckDB', '0.16';

on test => sub {
    requires 'Test::More';
};
