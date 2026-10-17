package Selecto::DateShortcut;

use 5.034;
use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Selecto::Expression ();

my @CHOICES = (
    { group => 'Days', id => 'today', label => 'Today' },
    { group => 'Days', id => 'yesterday', label => 'Yesterday' },
    { group => 'Days', id => 'tomorrow', label => 'Tomorrow' },
    { group => 'Weeks', id => 'this_week', label => 'This Week' },
    { group => 'Weeks', id => 'last_week', label => 'Last Week' },
    { group => 'Weeks', id => 'next_week', label => 'Next Week' },
    { group => 'Months', id => 'this_month', label => 'This Month' },
    { group => 'Months', id => 'last_month', label => 'Last Month' },
    { group => 'Months', id => 'next_month', label => 'Next Month' },
    { group => 'Months', id => 'mtd', label => 'Month to Date' },
    { group => 'Months', id => 'mtd_all_years', label => 'Month to Date (All Years)' },
    { group => 'Quarters', id => 'this_quarter', label => 'This Quarter' },
    { group => 'Quarters', id => 'last_quarter', label => 'Last Quarter' },
    { group => 'Quarters', id => 'next_quarter', label => 'Next Quarter' },
    { group => 'Quarters', id => 'qtd', label => 'Quarter to Date' },
    { group => 'Quarters', id => 'qtd_all_years', label => 'Quarter to Date (All Years)' },
    { group => 'Years', id => 'this_year', label => 'This Year' },
    { group => 'Years', id => 'last_year', label => 'Last Year' },
    { group => 'Years', id => 'next_year', label => 'Next Year' },
    { group => 'Years', id => 'ytd', label => 'Year to Date' },
    { group => 'Years', id => 'ytd_all_years', label => 'Year to Date (All Years)' },
    { group => 'Relative periods', id => 'last_7_days', label => 'Last 7 Days' },
    { group => 'Relative periods', id => 'last_14_days', label => 'Last 14 Days' },
    { group => 'Relative periods', id => 'last_30_days', label => 'Last 30 Days' },
    { group => 'Relative periods', id => 'last_90_days', label => 'Last 90 Days' },
    { group => 'Relative periods', id => 'last_3_months', label => 'Last 3 Months' },
    { group => 'Combined periods', id => 'this_and_last_month', label => 'This Month and Last Month' },
    { group => 'Combined periods', id => 'this_and_last_year', label => 'This Year and Last Year' },
    { group => 'Relative periods', id => 'next_7_days', label => 'Next 7 Days' },
    { group => 'Relative periods', id => 'next_30_days', label => 'Next 30 Days' },
);

# Each bound is [anchor, months, days]: the start of today's day, week
# (Monday), month, quarter or year, moved by whole months and then days. Range
# shortcuts include their start and exclude their end. Recurring shortcuts
# compare the month and day of every year, from start through today.
my %TERMS = (
    today => [[today => 0, 0], [today => 0, 1]],
    yesterday => [[today => 0, -1], [today => 0, 0]],
    tomorrow => [[today => 0, 1], [today => 0, 2]],
    this_week => [[week => 0, 0], [week => 0, 7]],
    last_week => [[week => 0, -7], [week => 0, 0]],
    next_week => [[week => 0, 7], [week => 0, 14]],
    this_month => [[month => 0, 0], [month => 1, 0]],
    last_month => [[month => -1, 0], [month => 0, 0]],
    next_month => [[month => 1, 0], [month => 2, 0]],
    mtd => [[month => 0, 0], [today => 0, 1]],
    this_quarter => [[quarter => 0, 0], [quarter => 3, 0]],
    last_quarter => [[quarter => -3, 0], [quarter => 0, 0]],
    next_quarter => [[quarter => 3, 0], [quarter => 6, 0]],
    qtd => [[quarter => 0, 0], [today => 0, 1]],
    this_year => [[year => 0, 0], [year => 12, 0]],
    last_year => [[year => -12, 0], [year => 0, 0]],
    next_year => [[year => 12, 0], [year => 24, 0]],
    ytd => [[year => 0, 0], [today => 0, 1]],
    last_7_days => [[today => 0, -6], [today => 0, 1]],
    last_14_days => [[today => 0, -13], [today => 0, 1]],
    last_30_days => [[today => 0, -29], [today => 0, 1]],
    last_90_days => [[today => 0, -89], [today => 0, 1]],
    last_3_months => [[month => -3, 0], [today => 0, 1]],
    this_and_last_month => [[month => -1, 0], [month => 1, 0]],
    this_and_last_year => [[year => -12, 0], [year => 12, 0]],
    next_7_days => [[today => 0, 1], [today => 0, 8]],
    next_30_days => [[today => 0, 1], [today => 0, 31]],
);
my %RECURRING = (
    mtd_all_years => [month => 0, 0],
    qtd_all_years => [quarter => 0, 0],
    ytd_all_years => [year => 0, 0],
);

my %KNOWN = map { $_->{id} => 1 } @CHOICES;

sub choices { return [map { {%$_} } @CHOICES] }

sub valid {
    my ($class, $shortcut) = @_;
    return defined($shortcut) && !ref($shortcut) && $KNOWN{"$shortcut"} ? 1 : 0;
}

sub valid_date {
    my ($class, $date) = @_;
    return 0 unless defined($date) && !ref($date)
        && "$date" =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
    my ($year, $month, $day) = ($1, $2, $3);
    my $epoch = eval { timegm(0, 0, 12, $day, $month - 1, $year) };
    return 0 unless defined $epoch;
    return strftime('%Y-%m-%d', gmtime($epoch)) eq "$date" ? 1 : 0;
}

# The symbolic bounds an adapter compiles against its own current date.
sub terms {
    my ($class, $shortcut) = @_;
    die "date shortcut is not available\n" unless $class->valid($shortcut);
    return {kind => 'recurring_month_day', start => [@{$RECURRING{$shortcut}}],
        end => [today => 0, 0]} if $RECURRING{$shortcut};
    return {kind => 'range', start => [@{$TERMS{$shortcut}[0]}],
        end => [@{$TERMS{$shortcut}[1]}]};
}

sub bounds {
    my ($class, $shortcut, $today) = @_;
    my $plan = $class->plan($shortcut, $today);
    die "date shortcut does not have absolute bounds\n"
        unless $plan->{kind} eq 'range';
    return ($plan->{start}, $plan->{end});
}

sub plan {
    my ($class, $shortcut, $today) = @_;
    my $terms = $class->terms($shortcut);
    $today //= strftime('%Y-%m-%d', localtime);
    die "today must be an ISO date\n" unless $class->valid_date($today);
    my @bounds = map { _date($today, @$_) } $terms->{start}, $terms->{end};
    @bounds = map { substr($_, 5) } @bounds if $terms->{kind} eq 'recurring_month_day';
    return {kind => $terms->{kind}, start => $bounds[0], end => $bounds[1]};
}

# Without today, the database compares against its own current date, so the
# session's time zone decides when a day begins. A given today (an ISO date)
# is bound as literal dates instead.
sub expression {
    my ($class, $operand, $shortcut, $today) = @_;
    return Selecto::Expression->date_shortcut($operand, $shortcut)
        unless defined $today;
    my $plan = $class->plan($shortcut, $today);
    if ($plan->{kind} eq 'range') {
        return Selecto::Expression->all([
            Selecto::Expression->gte($operand, $plan->{start}),
            Selecto::Expression->lt($operand, $plan->{end}),
        ]);
    }
    my $month_day = Selecto::Expression->datetime_format($operand, 'month_day');
    return Selecto::Expression->all([
        Selecto::Expression->gte($month_day, $plan->{start}),
        Selecto::Expression->lte($month_day, $plan->{end}),
    ]);
}

sub _date {
    my ($today, $anchor, $months, $days) = @_;
    my ($year, $month) = "$today" =~ /\A(\d{4})-(\d{2})/;
    my $date = $anchor eq 'today' ? $today
        : $anchor eq 'week' ? _add_days($today, -(((gmtime(_epoch($today)))[6] + 6) % 7))
        : $anchor eq 'month' ? sprintf('%04d-%02d-01', $year, $month)
        : $anchor eq 'quarter' ? sprintf('%04d-%02d-01', $year, int(($month - 1) / 3) * 3 + 1)
        : sprintf('%04d-01-01', $year);
    $date = _add_months($date, $months) if $months;
    return $days ? _add_days($date, $days) : $date;
}

sub _epoch {
    my ($date) = @_;
    my ($year, $month, $day) = "$date" =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
    return timegm(0, 0, 12, $day, $month - 1, $year);
}

sub _add_days {
    my ($date, $days) = @_;
    return strftime('%Y-%m-%d', gmtime(_epoch($date) + $days * 86_400));
}

sub _add_months {
    my ($date, $months) = @_;
    my ($year, $month) = "$date" =~ /\A(\d{4})-(\d{2})/;
    my $offset = $year * 12 + ($month - 1) + $months;
    return sprintf('%04d-%02d-01', int($offset / 12), $offset % 12 + 1);
}

1;

__END__

=head1 NAME

Selecto::DateShortcut - calendar shortcuts such as today or this quarter

=head1 DESCRIPTION

Validates relative date shortcuts (today, this month, this quarter and
similar) and turns them into bounded date predicates for the canonical API
and user interfaces. Without an explicit today, PostgreSQL and DuckDB
compare against the database's current date, so the session time zone (or
the query's L<Selecto::Query/use_timezone>) decides when a day begins.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::API::EngineHandler>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
