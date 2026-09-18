package Selecto::Analytics::TransformRegistry;

use 5.034;
use strict;
use warnings;

use Storable qw(dclone);
use Selecto::Analytics::UnitRegistry ();
use Selecto::Error ();

my @ORDER = qw(
    percent_of_total percent_change percentage_point_change index_to_first
    cumulative moving_average exponential_moving_average min_max z_score
);
my %TRANSFORMS = (
    percent_of_total => {
        label => 'Percent of total', result => 'percentage',
    },
    percent_change => {
        label => 'Percent change', result => 'percentage', requires_ordered_axis => 1,
    },
    percentage_point_change => {
        label => 'Percentage-point change', result => 'percentage_input_scale',
        input_kinds => ['percentage'], requires_ordered_axis => 1,
    },
    index_to_first => {
        label => 'Index to first value', result => 'ratio', requires_ordered_axis => 1,
    },
    cumulative => {
        label => 'Cumulative total', result => 'preserve',
        input_behaviors => ['flow'], requires_ordered_axis => 1,
    },
    moving_average => {
        label => 'Moving average', result => 'preserve', requires_ordered_axis => 1,
        parameters => {window => {type => 'integer', minimum => 2, maximum => 365}},
    },
    exponential_moving_average => {
        label => 'Exponential moving average', result => 'preserve',
        requires_ordered_axis => 1,
        parameters => {alpha => {type => 'decimal', exclusive_minimum => 0, maximum => 1}},
    },
    min_max => {
        label => 'Normalize to 0–100', result => 'ratio', requires_ordered_axis => 1,
    },
    z_score => {
        label => 'Standard score', result => 'scalar', requires_ordered_axis => 1,
    },
);

sub catalog {
    my ($class, $unit, $behavior) = @_;
    return [] unless defined $unit;
    my $normalized_unit = Selecto::Analytics::UnitRegistry->normalize_unit(
        $unit, 'transform input unit',
    );
    my $normalized_behavior = defined($behavior)
        ? Selecto::Analytics::UnitRegistry->normalize_behavior(
            $behavior, 'transform input behavior',
        ) : undef;
    return [map {
        my $id = $_;
        +{id => $id, %{dclone($TRANSFORMS{$id})}}
    } grep {
        _accepts($TRANSFORMS{$_}, $normalized_unit, $normalized_behavior)
    } @ORDER];
}

sub definition {
    my ($class, $id) = @_;
    return undef unless defined($id) && !ref($id) && exists $TRANSFORMS{"$id"};
    return {id => "$id", %{dclone($TRANSFORMS{"$id"})}};
}

sub allows {
    my ($class, $id, $unit, $behavior) = @_;
    return 0 unless defined($id) && !ref($id) && exists $TRANSFORMS{"$id"};
    my $normalized_unit = eval {
        Selecto::Analytics::UnitRegistry->normalize_unit($unit, 'transform input unit')
    };
    return 0 unless $normalized_unit;
    my $normalized_behavior;
    if (defined $behavior) {
        $normalized_behavior = eval {
            Selecto::Analytics::UnitRegistry->normalize_behavior(
                $behavior, 'transform input behavior',
            )
        };
        return 0 unless defined $normalized_behavior;
    }
    return _accepts($TRANSFORMS{"$id"}, $normalized_unit, $normalized_behavior);
}

sub result_unit {
    my ($class, $id, $input_unit, $behavior) = @_;
    Selecto::Error->throw(
        'invalid_analytics', 'analytical transform is not available', {transform => $id},
    ) unless $class->allows($id, $input_unit, $behavior);
    my $input = Selecto::Analytics::UnitRegistry->normalize_unit(
        $input_unit, 'transform input unit',
    );
    my $result = $TRANSFORMS{$id}{result};
    return $input if $result eq 'preserve';
    return {kind => 'percentage', scale => 'whole'} if $result eq 'percentage';
    return {kind => 'percentage', scale => $input->{scale}}
        if $result eq 'percentage_input_scale';
    return {kind => 'ratio'} if $result eq 'ratio';
    return {kind => 'scalar'} if $result eq 'scalar';
    Selecto::Error->throw(
        'invalid_analytics', 'analytical transform result unit is not available',
        {transform => $id},
    );
}

sub _accepts {
    my ($spec, $unit, $behavior) = @_;
    if (ref($spec->{input_kinds}) eq 'ARRAY') {
        return 0 unless grep { $_ eq $unit->{kind} } @{$spec->{input_kinds}};
    }
    if (ref($spec->{input_behaviors}) eq 'ARRAY') {
        return 0 unless defined($behavior)
            && grep { $_ eq $behavior } @{$spec->{input_behaviors}};
    }
    return 1;
}

1;
