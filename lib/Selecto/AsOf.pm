package Selecto::AsOf;

use 5.034;
use strict;
use warnings;
use DateTime ();
use Selecto::Error ();
use Selecto::DateShortcut ();

# ISO calendar dates and full timestamps only. Never pass unchecked date text
# to a database parser (which may admit relative words or normalize bad dates).
sub validate {
    my ($class, $value) = @_;
    $class->_parse($value);
    return "$value";
}

sub _parse {
    my ($class, $value) = @_;
    my $bad = sub { Selecto::Error->throw('invalid_query',
        'as_of must be a valid ISO date (YYYY-MM-DD) or timestamp (YYYY-MM-DDTHH:MM:SS, optional Z or +/-HH:MM)') };
    $bad->() if !defined($value) || ref($value) || length($value) > 45;
    $bad->() unless "$value" =~ /\A(\d{4}-\d{2}-\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})?)?\z/;
    my ($date, $hour, $minute, $second, $fraction, $zone) = ($1, $2, $3, $4, $5, $6);
    $bad->() unless Selecto::DateShortcut->valid_date($date) && substr($date, 0, 4) ne '0000';
    my $is_date = !defined $hour;
    my $offset = 0;
    if (defined($zone) && $zone ne 'Z') {
        my ($sign, $h, $m) = $zone =~ /([+-])(\d{2}):(\d{2})/;
        $bad->() if $h > 23 || $m > 59;
        $offset = ($h * 60 + $m) * 60 * ($sign eq '-' ? -1 : 1);
    }
    $bad->() if !$is_date && ($hour > 23 || $minute > 59 || $second > 59);
    my ($year, $month, $day) = split /-/, $date;
    my $dt = eval { DateTime->new(year => $year, month => $month, day => $day,
        hour => $hour // 0, minute => $minute // 0, second => $second // 0,
        nanosecond => defined($fraction) ? int($fraction * 1_000_000_000 + 0.5) : 0,
        time_zone => 'UTC') };
    $bad->() unless $dt;
    $dt->subtract(seconds => $offset) if $offset;
    return ($dt, $is_date, $fraction // '');
}

sub date {
    my ($class, $value, $timezone) = @_;
    my ($dt, $is_date) = $class->_parse($value);
    $dt->set_time_zone($timezone) if !$is_date && defined $timezone;
    return $dt->ymd;
}

sub timestamp {
    my ($class, $value, $timezone) = @_;
    my ($dt, $is_date, $fraction) = $class->_parse($value);
    if ($is_date && defined $timezone) {
        ($dt) = $class->_parse(Selecto::DateShortcut->day_start_instant($value, $timezone));
    }
    # UTC wall time also works on dialects with naive timestamp storage.
    return $dt->strftime('%Y-%m-%d %H:%M:%S') . $fraction . '+00:00';
}

1;

__END__

=head1 NAME

Selecto::AsOf - validated read clock values

=head1 DESCRIPTION

Internal ISO date/timestamp admission and normalization for
L<Selecto::Query/as_of>. Date clocks retain their calendar day; timestamp
clocks normalize offsets to UTC and derive dates in the query timezone.
No system clock or database parser is used to validate input.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2026 Chris Rohlfs. This is free software under the Artistic
License 2.0 (GPL Compatible).

=cut
