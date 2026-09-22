use 5.034;
use strict;
use warnings;

use Test::More;
use Selecto::DateShortcut ();

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

done_testing;
