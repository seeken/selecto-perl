use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::MySQLFamily::DateFormat;

my $f = \&Selecto::MySQLFamily::DateFormat::format_value;
my $ny = 'America/New_York';

# PostgreSQL's rule: a skipped wall time takes the offset before the
# transition, a repeated one the offset after it.
is($f->({format => 'rfc3339_millis', type => 'naive_datetime', timezone => $ny}, '2024-03-10 02:30:00.000000'),
    '2024-03-10T03:30:00.000-04:00', 'a spring-forward gap uses the offset before the transition');
is($f->({format => 'epoch_seconds', type => 'naive_datetime', timezone => $ny}, '2024-11-03 01:30:00.000000'),
    1730615400, 'an autumn fold uses the offset after the transition');
# CONVERT_TZ would leave these unconverted.
is($f->({format => 'iso8601', type => 'epoch_datetime', timezone => $ny}, '-0.000001'),
    '1969-12-31T18:59:59-05:00', 'a pre-1970 instant converts');
is($f->({format => 'rfc3339_millis', type => 'utc_datetime', timezone => $ny}, '2040-07-01 12:00:00.000000'),
    '2040-07-01T08:00:00.000-04:00', 'a post-2037 instant keeps daylight time');
is($f->({format => 'epoch_milliseconds', type => 'epoch_datetime'}, '-0.000001'), -1, 'epoch milliseconds floor');
is($f->({format => 'day_hour', type => 'naive_datetime', timezone => $ny}, '2024-01-01 10:00:00.000000'),
    '2024-01-01 10', 'wall-clock formats never shift naive values');
is($f->({format => 'us_datetime', type => 'date'}, '2024-01-01'), '01/01/2024 12:00 AM', 'US date and time');
is($f->({format => 'iso_week_date', type => 'date'}, '1969-12-31'), '1970-W01-3', 'ISO week date');
eval { $f->({format => 'day', type => 'date'}, 'not a date') };
is($@->code, 'query_error', 'an unexpected stored shape fails closed');

done_testing;
