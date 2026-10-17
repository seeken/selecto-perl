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

# Years 1-999 are written with four digits, as PostgreSQL writes them.
is($f->({format => 'day', type => 'date'}, '0001-02-03'), '0001-02-03', 'year 1 is zero-padded');
is($f->({format => 'month', type => 'date'}, '0999-12-31'), '0999-12', 'year 999 is zero-padded');
is($f->({format => 'iso8601', type => 'naive_datetime'}, '0042-01-01 00:00:00.000000'), '0042-01-01T00:00:00',
    'iso8601 pads the year');
is($f->({format => 'us_date', type => 'date'}, '0007-07-04'), '07/04/0007', 'US dates pad the year');
is($f->({format => 'rfc3339_millis', type => 'utc_datetime'}, '0100-01-01 00:00:00.123000'),
    '0100-01-01T00:00:00.123Z', 'rfc3339 pads the year');
is($f->({format => 'day', type => 'date'}, '9999-12-31'), '9999-12-31', 'year 9999 formats');

# Values PostgreSQL cannot hold are a typed data error, never a crash.
for my $case (['date', '0000-01-01'], ['date', '2024-00-10'], ['date', '2024-02-00'],
    ['naive_datetime', '0000-00-00 00:00:00.000000'], ['naive_datetime', '2023-02-30 00:00:00.000000']) {
    my ($type, $raw) = @$case;
    my $error = eval { $f->({format => 'day', type => $type}, $raw); undef } // $@;
    is(ref($error) && $error->code, 'query_error', "$type $raw is refused");
    is(ref($error) && $error->details->{sqlstate}, '22008', "$type $raw is a datetime overflow");
}
my $late = eval { $f->({format => 'iso8601', type => 'utc_datetime', timezone => 'Asia/Tokyo'},
    '9999-12-31 23:00:00.000000'); undef } // $@;
is(ref($late) && $late->details->{sqlstate}, '22008', 'an instant shown after year 9999 is refused');

# Zone names DateTime::TimeZone reads differently from PostgreSQL are refused.
ok(Selecto::MySQLFamily::DateFormat::valid_zone($_), "$_ is a zone") for qw(UTC America/New_York Etc/GMT+5 EST5EDT);
ok(!Selecto::MySQLFamily::DateFormat::valid_zone($_), "$_ is refused") for qw(local floating +0500 -05:00 Z Mars/Base);
my $local = eval { $f->({format => 'day', type => 'utc_datetime', timezone => 'local'}, '2024-01-01 00:00:00.000000'); undef } // $@;
is(ref($local) && $local->code, 'invalid_query', 'formatting in the host\'s local zone is refused');

done_testing;
