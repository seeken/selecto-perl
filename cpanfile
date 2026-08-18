requires 'perl', '5.034';
requires 'DBI', '1.643';
requires 'JSON::PP', '4.06';
requires 'Mojolicious', '9.40';
recommends 'DBD::Pg', '3.016';
recommends 'DBD::SQLite', '1.64';

on test => sub {
    requires 'Test::More';
};
