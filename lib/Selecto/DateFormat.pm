package Selecto::DateFormat;

use 5.034;
use strict;
use warnings;

my @PUBLIC_FORMATS = (
    {id => 'iso8601',          label => 'ISO 8601'},
    {id => 'rfc3339_millis',   label => 'RFC 3339 (Milliseconds)'},
    {id => 'epoch_seconds',    label => 'Unix Epoch Seconds'},
    {id => 'epoch_milliseconds', label => 'Unix Epoch Milliseconds'},
    {id => 'day',           label => 'Day'},
    {id => 'time',          label => 'Time'},
    {id => 'day_hour',      label => 'Day + Hour'},
    {id => 'week',          label => 'Week'},
    {id => 'iso_week',      label => 'ISO Week'},
    {id => 'iso_week_date', label => 'ISO Week Date'},
    {id => 'month',         label => 'Month'},
    {id => 'quarter',       label => 'Quarter'},
    {id => 'year',          label => 'Year'},
    {id => 'month_of_year', label => 'Month of Year'},
    {id => 'day_of_month',  label => 'Day of Month'},
    {id => 'day_of_week',   label => 'Day of Week Name'},
    {id => 'day_of_week_num', label => 'Day of Week Number'},
    {id => 'day_of_year',   label => 'Day of Year'},
    {id => 'hour',          label => 'Hour of Day'},
    {id => 'timezone_offset', label => 'Timezone Offset'},
);
my %PUBLIC = map { $_->{id} => 1 } @PUBLIC_FORMATS;

sub choices {
    return [map { {%$_} } @PUBLIC_FORMATS];
}

sub valid {
    my ($format) = @_;
    return defined($format) && !ref($format) && $PUBLIC{"$format"} ? 1 : 0;
}

1;

__END__

=head1 NAME

Selecto::DateFormat - allowlisted date and time format names

=head1 DESCRIPTION

Lists the governed date/time format names accepted by
L<Selecto::Expression/datetime_format> and the canonical API. Arbitrary
database format strings are never accepted.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Expression>, L<Selecto::API::EngineHandler>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
