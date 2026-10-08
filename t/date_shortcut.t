use 5.034;
use strict;
use warnings;

use Test::More;
use Selecto::DateShortcut ();
use Selecto::Domain ();
use Selecto::DuckDB ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::SQLite ();

my %choice = map { $_->{id} => $_ } @{Selecto::DateShortcut->choices};
for my $id (qw(
    last_14_days last_3_months this_and_last_month this_and_last_year
)) {
    ok $choice{$id}, "$id is published as a reusable date shortcut";
}

is_deeply [Selecto::DateShortcut->bounds('last_14_days', '2026-09-22')],
    ['2026-09-09', '2026-09-23'],
    'last 14 days includes today and the preceding 13 days';
is_deeply [Selecto::DateShortcut->bounds('last_3_months', '2026-09-22')],
    ['2026-06-01', '2026-09-23'],
    'last 3 months follows calendar-month boundaries through today';
is_deeply [Selecto::DateShortcut->bounds('this_and_last_month', '2026-01-15')],
    ['2025-12-01', '2026-02-01'],
    'combined month shortcut crosses year boundaries';
is_deeply [Selecto::DateShortcut->bounds('this_and_last_year', '2026-09-22')],
    ['2025-01-01', '2027-01-01'],
    'combined year shortcut includes both complete calendar years';

my $domain = Selecto::Domain->new(name => 'Events', table => 'events',
    fields => {id => 'integer', day => 'date', at => 'utc_datetime', epoch => 'epoch_datetime'});
my %engine = map {
    $_->[0] => Selecto::Engine->new(domain => $domain, adapter => $_->[1]->new(dbh => bless({}, 'Test::NoDBH')))
} [postgresql => 'Selecto::PostgreSQL'], [duckdb => 'Selecto::DuckDB'], [sqlite => 'Selecto::SQLite'];
sub where_sql {
    my ($engine, $predicate, $query) = @_;
    my $statement = $engine->compile(($query // $engine->query)->select('id')->where($predicate));
    my ($where) = $statement->sql =~ /WHERE (.*)/s;
    return ($where, $statement->params);
}

for my $name (qw(postgresql duckdb)) {
    my ($where, $params) = where_sql($engine{$name},
        Selecto::DateShortcut->expression('at', 'this_quarter'));
    like $where, qr/"at" >= CAST\(DATE_TRUNC\('quarter', CURRENT_DATE\) AS DATE\)/,
        "$name measures a shortcut from the database current date";
    is_deeply $params, [], "$name binds no server date";
    ($where) = where_sql($engine{$name}, Selecto::DateShortcut->expression('epoch', 'this_week'));
    like $where, qr/TO_TIMESTAMP\("s0"\."epoch"\) >= /, "$name compares an epoch column as an instant";
    ($where, $params) = where_sql($engine{$name}, Selecto::DateShortcut->expression('at', 'yesterday'),
        $engine{$name}->query->use_timezone('America/Vancouver'));
    like $where, qr/CAST\(\(CURRENT_TIMESTAMP AT TIME ZONE \$\d+\) AS DATE\)/,
        "$name takes today in the query time zone when it has one";
    ok scalar(grep { $_ eq 'America/Vancouver' } @$params), "$name binds that zone";
}
my ($literal_where, $literal_params) = where_sql($engine{postgresql},
    Selecto::DateShortcut->expression('day', 'this_quarter', '2026-10-08'));
unlike $literal_where, qr/CURRENT_DATE/, 'an explicit today binds literal dates';
is_deeply $literal_params, ['2026-10-01', '2027-01-01'], 'for that day';
my ($fallback_where, $fallback_params) = where_sql($engine{sqlite},
    Selecto::DateShortcut->expression('day', 'this_quarter'));
unlike $fallback_where, qr/CURRENT_DATE/, 'other adapters bind the server date';
is_deeply $fallback_params, [Selecto::DateShortcut->bounds('this_quarter')], 'as before';
ok !eval { Selecto::Expression->date_shortcut('day', 'fortnight'); 1 }, 'an unknown shortcut is refused';
ok !eval { where_sql($engine{postgresql}, Selecto::Expression->date_shortcut('id', 'today')); 1 },
    'a shortcut needs a date or time field';

done_testing;
