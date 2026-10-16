package Selecto::MySQLFamily::DateFormat;

use 5.034;
use strict;
use warnings;
use DateTime ();
use DateTime::TimeZone ();
use Selecto::Error ();

# Formats one stored temporal value the MySQL-family adapters selected for a
# Selecto::DateFormat format, with PostgreSQL semantics:
# - date and naive values are wall time; under a time zone they name the
#   instant that wall time has there (a skipped wall time uses the offset in
#   force before the transition, a repeated one the offset after it);
# - utc_datetime (naive UTC) and epoch_datetime values are instants, shown
#   in the time zone (UTC when none is given);
# - wall-clock formats of date and naive values are never shifted.
# $raw is 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS.ffffff' or a decimal epoch.

my %ZONES;
sub _zone {
    my ($name) = @_;
    return undef if !defined($name) || $name eq 'UTC';
    Selecto::Error->throw('invalid_query', 'timezone must be a valid IANA timezone name') unless valid_zone($name);
    return $ZONES{$name} //= DateTime::TimeZone->new(name => $name);
}

# An IANA zone name both PostgreSQL and DateTime::TimeZone read the same way.
# DateTime::TimeZone also accepts 'local' (the host's zone), 'floating' and
# offsets such as '+0500', which PostgreSQL reads as POSIX zones with the
# opposite sign; those are refused.
sub valid_zone {
    my ($name) = @_;
    return 0 if !defined($name) || ref($name);
    $name = "$name";
    return 0 if $name =~ /\A(?:local|floating|Z)\z/i || $name !~ /\A[A-Za-z][A-Za-z0-9_+\-]*(?:\/[A-Za-z0-9_+\-]+)*\z/;
    return DateTime::TimeZone->is_valid_name($name) ? 1 : 0;
}

sub _invalid { Selecto::Error->throw('query_error', 'stored date value has an unexpected shape'); }

# A stored value PostgreSQL cannot hold (year 0, a zero month or day, or a
# value outside years 1-9999 once shown in its time zone) is a typed data
# error, never a crash or an untyped failure.
sub _out_of_range {
    Selecto::Error->throw('query_error', 'stored date value is outside the supported range',
        {sqlstate => '22008', category => 'datetime_field_overflow'});
}

# strftime with the year always written with at least four digits, as
# PostgreSQL writes years 1-999 (DateTime writes '%Y' unpadded).
sub _strftime {
    my ($datetime, $pattern) = @_;
    $pattern =~ s/%Y/sprintf('%04d', $datetime->year)/ge;
    return $datetime->strftime($pattern);
}

sub _datetime {
    my (%parts) = @_;
    _out_of_range() unless $parts{year} >= 1 && $parts{year} <= 9999;
    my $datetime = eval { DateTime->new(%parts, time_zone => 'floating') };
    _out_of_range() unless $datetime;
    return $datetime;
}

sub _wall {
    my ($type, $raw) = @_;
    if ($type eq 'date') {
        my ($y, $m, $d) = $raw =~ /\A(-?\d{4,})-(\d{2})-(\d{2})\z/ or _invalid();
        return _datetime(year => $y, month => $m, day => $d);
    }
    my ($y, $m, $d, $h, $i, $s, $f) = $raw =~ /\A(-?\d{4,})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{6})\z/
        or _invalid();
    return _datetime(year => $y, month => $m, day => $d, hour => $h, minute => $i, second => $s,
        nanosecond => $f * 1000);
}

sub _epoch_instant {
    my ($raw) = @_;
    my ($sign, $whole, $fraction) = $raw =~ /\A(-?)(\d{1,15})(?:\.(\d{1,6})\d*)?\z/ or _invalid();
    $fraction = substr(($fraction // '') . '000000', 0, 6);
    my $micro = ($whole * 1_000_000 + $fraction) * ($sign ? -1 : 1);
    my $seconds = int($micro / 1_000_000);
    my $rest = $micro - $seconds * 1_000_000;
    if ($rest < 0) { $seconds--; $rest += 1_000_000; }
    my $instant = eval { DateTime->from_epoch(epoch => $seconds, time_zone => 'UTC')->set_nanosecond($rest * 1000) };
    _out_of_range() unless $instant;
    return $instant;
}

# The UTC instant of a wall time in $zone, with PostgreSQL's gap and fold rule.
sub _wall_instant {
    my ($wall, $zone) = @_;
    my $as_utc = $wall->clone->set_time_zone('UTC');
    return $as_utc unless $zone;
    my $before = $zone->offset_for_datetime($as_utc->clone->subtract(days => 1));
    my $after = $zone->offset_for_datetime($as_utc->clone->add(days => 1));
    my $later = $as_utc->clone->subtract(seconds => $after);
    my $check = $later->clone->set_time_zone($zone);
    return $later if _strftime($check, '%Y-%m-%d %H:%M:%S.%6N') eq _strftime($wall, '%Y-%m-%d %H:%M:%S.%6N');
    return $as_utc->clone->subtract(seconds => $before);
}

sub _offset {
    my ($seconds) = @_;
    my $sign = $seconds < 0 ? '-' : '+';
    $seconds = abs($seconds);
    return sprintf('%s%02d:%02d', $sign, int($seconds / 3600), int(($seconds % 3600) / 60));
}

my %WALL = (
    day => sub { _strftime($_[0], '%Y-%m-%d') },
    time => sub { _strftime($_[0], '%H:%M:%S') },
    day_hour => sub { _strftime($_[0], '%Y-%m-%d %H') },
    day_minute => sub { _strftime($_[0], '%Y-%m-%d %H:%M') },
    week => sub { sprintf('%04d-W%02d', $_[0]->week) },
    iso_week => sub { sprintf('%04d-W%02d', $_[0]->week) },
    iso_week_date => sub { sprintf('%04d-W%02d-%d', $_[0]->week, $_[0]->day_of_week) },
    month => sub { _strftime($_[0], '%Y-%m') },
    quarter => sub { sprintf('%04d-Q%d', $_[0]->year, $_[0]->quarter) },
    year => sub { sprintf('%04d', $_[0]->year) },
    month_of_year => sub { _strftime($_[0], '%m') },
    month_day => sub { _strftime($_[0], '%m-%d') },
    day_of_month => sub { _strftime($_[0], '%d') },
    day_of_week => sub { (qw(Monday Tuesday Wednesday Thursday Friday Saturday Sunday))[$_[0]->day_of_week - 1] },
    day_of_week_num => sub { '' . $_[0]->day_of_week },
    day_of_year => sub { sprintf('%03d', $_[0]->day_of_year) },
    hour => sub { _strftime($_[0], '%H') },
    us_date => sub { _strftime($_[0], '%m/%d/%Y') },
    us_datetime => sub {
        my $hour = $_[0]->hour % 12 || 12;
        sprintf('%s %d:%02d %s', _strftime($_[0], '%m/%d/%Y'), $hour, $_[0]->minute, $_[0]->hour < 12 ? 'AM' : 'PM');
    },
);

sub format_value {
    my ($spec, $raw) = @_;
    my ($format, $type) = @{$spec}{qw(format type)};
    my $zone = _zone($spec->{timezone});
    my $instant_type = $type eq 'utc_datetime' || $type eq 'epoch_datetime';
    my ($wall, $instant);
    if ($type eq 'epoch_datetime') {
        $instant = _epoch_instant($raw);
    } elsif ($instant_type) {
        $instant = _wall($type, $raw)->set_time_zone('UTC');
    } else {
        $wall = _wall($type, $raw);
    }
    my $local = $instant ? $instant->clone->set_time_zone($zone // 'UTC') : undef;
    _out_of_range() if $local && ($local->year < 1 || $local->year > 9999);
    if ($format eq 'iso8601') {
        return _strftime($wall, '%Y-%m-%d') if $type eq 'date';
        return _strftime($wall, '%Y-%m-%dT%H:%M:%S') unless $instant;
        return _strftime($local, '%Y-%m-%dT%H:%M:%S') . ($zone ? _offset($local->offset) : 'Z');
    }
    if ($format =~ /\A(?:rfc3339_millis|epoch_seconds|epoch_milliseconds|timezone_offset)\z/) {
        unless ($instant) {
            $instant = _wall_instant($wall, $zone);
            $local = $instant->clone->set_time_zone($zone // 'UTC');
        }
        return $instant->epoch if $format eq 'epoch_seconds';
        return $instant->epoch * 1000 + int($instant->nanosecond / 1_000_000) if $format eq 'epoch_milliseconds';
        my $offset = $zone ? _offset($local->offset) : '+00:00';
        return $offset if $format eq 'timezone_offset';
        return _strftime($local, '%Y-%m-%dT%H:%M:%S.%3N') . ($zone ? $offset : 'Z');
    }
    my $render = $WALL{$format};
    Selecto::Error->throw('invalid_query', 'datetime format is not available') unless $render;
    return $render->($local // $wall);
}

1;

__END__

=head1 NAME

Selecto::MySQLFamily::DateFormat - PostgreSQL-compatible date formatting for MySQL-family results

=head1 DESCRIPTION

Formats the stored date, naive, UTC and epoch values that the MySQL and
MariaDB adapters select for C<datetime_format> expressions, in Perl with
L<DateTime::TimeZone>, so that time zone conversions are correct for every
year (the servers' C<CONVERT_TZ> is not). Skipped and repeated wall times
follow PostgreSQL's rule.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice.

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
