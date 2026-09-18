package Selecto::Analytics::Pipeline;

use 5.034;
use strict;
use warnings;

use List::Util qw(min max sum);
use Selecto::Analytics::TransformRegistry ();
use Selecto::Error ();

sub apply {
    my ($class, $values, $transforms, $unit, $behavior) = @_;
    Selecto::Error->throw('invalid_analytics', 'analytical values must be an array')
        unless ref($values) eq 'ARRAY';
    $transforms //= [];
    Selecto::Error->throw('invalid_analytics', 'analytical transforms must be an array')
        unless ref($transforms) eq 'ARRAY';
    Selecto::Error->throw('invalid_analytics', 'too many analytical transforms')
        if @$transforms > 8;

    my @raw = map { _number_or_undef($_) } @$values;
    my @current = @raw;
    my $current_unit = $unit;
    my @derivation;
    for my $requested (@$transforms) {
        my $spec = _normalize_transform($requested);
        my $type = $spec->{type};
        my $output_unit = Selecto::Analytics::TransformRegistry->result_unit(
            $type, $current_unit, $behavior,
        );
        @current = @{_transform($type, \@current, $spec)};
        push @derivation, {
            type => $type,
            parameters => {%{$spec->{parameters}}},
            input_unit => $current_unit,
            output_unit => $output_unit,
        };
        $current_unit = $output_unit;
        $behavior = undef unless $type eq 'moving_average'
            || $type eq 'exponential_moving_average';
    }

    return {
        unit => $current_unit,
        transforms => \@derivation,
        points => [map {
            +{
                raw_value => $raw[$_],
                value => $current[$_],
                derivation => [map { +{%$_, parameters => {%{$_->{parameters}}}} } @derivation],
            }
        } 0 .. $#raw],
    };
}

sub _normalize_transform {
    my ($requested) = @_;
    $requested = {type => $requested} if defined($requested) && !ref($requested);
    Selecto::Error->throw('invalid_analytics', 'analytical transform must be an object')
        unless ref($requested) eq 'HASH';
    my $type = $requested->{type};
    Selecto::Error->throw('invalid_analytics', 'analytical transform type is required')
        unless defined($type) && !ref($type) && "$type" ne '';
    Selecto::Error->throw(
        'invalid_analytics', 'analytical transform is not available', {transform => "$type"},
    ) unless Selecto::Analytics::TransformRegistry->definition("$type");
    my $parameters = ref($requested->{parameters}) eq 'HASH'
        ? {%{$requested->{parameters}}} : {};
    return {type => "$type", parameters => $parameters};
}

sub _transform {
    my ($type, $values, $spec) = @_;
    return _percent_of_total($values) if $type eq 'percent_of_total';
    return _previous_change($values, 1) if $type eq 'percent_change';
    return _previous_change($values, 0) if $type eq 'percentage_point_change';
    return _index_to_first($values) if $type eq 'index_to_first';
    return _cumulative($values) if $type eq 'cumulative';
    return _moving_average($values, _integer_parameter($spec, 'window', 2, 365))
        if $type eq 'moving_average';
    return _exponential_moving_average(
        $values, _decimal_parameter($spec, 'alpha', 0, 1, 1),
    ) if $type eq 'exponential_moving_average';
    return _min_max($values) if $type eq 'min_max';
    return _z_score($values) if $type eq 'z_score';
    Selecto::Error->throw(
        'invalid_analytics', 'analytical transform execution is not available', {transform => $type},
    );
}

sub _percent_of_total {
    my ($values) = @_;
    my $total = sum(grep { defined } @$values) // 0;
    return [map { defined($_) && $total != 0 ? ($_ / $total) * 100 : undef } @$values];
}

sub _previous_change {
    my ($values, $percent) = @_;
    my @result;
    for my $index (0 .. $#$values) {
        my $value = $values->[$index];
        my $previous = $index ? $values->[$index - 1] : undef;
        push @result, !defined($value) || !defined($previous)
            || ($percent && $previous == 0) ? undef
            : $percent ? (($value - $previous) / $previous) * 100
            : $value - $previous;
    }
    return \@result;
}

sub _index_to_first {
    my ($values) = @_;
    my ($baseline) = grep { defined($_) && $_ != 0 } @$values;
    return [map { defined($_) && defined($baseline) ? ($_ / $baseline) * 100 : undef } @$values];
}

sub _cumulative {
    my ($values) = @_;
    my ($running, @result) = (0);
    for my $value (@$values) {
        if (defined $value) {
            $running += $value;
            push @result, $running;
        } else {
            push @result, undef;
        }
    }
    return \@result;
}

sub _moving_average {
    my ($values, $window) = @_;
    my @result;
    for my $index (0 .. $#$values) {
        if (!defined($values->[$index])) {
            push @result, undef;
            next;
        }
        my $start = $index - $window + 1;
        $start = 0 if $start < 0;
        my @window_values = grep { defined } @$values[$start .. $index];
        push @result, @window_values ? sum(@window_values) / @window_values : undef;
    }
    return \@result;
}

sub _exponential_moving_average {
    my ($values, $alpha) = @_;
    my ($previous, @result);
    for my $value (@$values) {
        if (!defined $value) {
            push @result, undef;
            next;
        }
        $previous = defined($previous) ? ($alpha * $value) + ((1 - $alpha) * $previous) : $value;
        push @result, $previous;
    }
    return \@result;
}

sub _min_max {
    my ($values) = @_;
    my @defined = grep { defined } @$values;
    return [map { undef } @$values] unless @defined;
    my ($minimum, $maximum) = (min(@defined), max(@defined));
    my $span = $maximum - $minimum;
    return [map { defined($_) && $span != 0 ? (($_ - $minimum) / $span) * 100 : undef } @$values];
}

sub _z_score {
    my ($values) = @_;
    my @defined = grep { defined } @$values;
    return [map { undef } @$values] unless @defined;
    my $mean = sum(@defined) / @defined;
    my $variance = sum(map { ($_ - $mean) ** 2 } @defined) / @defined;
    my $deviation = sqrt($variance);
    return [map { defined($_) && $deviation != 0 ? ($_ - $mean) / $deviation : undef } @$values];
}

sub _integer_parameter {
    my ($spec, $name, $minimum, $maximum) = @_;
    my $value = $spec->{parameters}{$name};
    Selecto::Error->throw(
        'invalid_analytics', "$name must be an integer from $minimum through $maximum",
    ) unless defined($value) && !ref($value) && "$value" =~ /\A\d+\z/
        && $value >= $minimum && $value <= $maximum;
    return 0 + $value;
}

sub _decimal_parameter {
    my ($spec, $name, $minimum, $maximum, $exclusive_minimum) = @_;
    my $value = $spec->{parameters}{$name};
    Selecto::Error->throw('invalid_analytics', "$name must be a bounded number")
        unless defined($value) && !ref($value)
        && "$value" =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/
        && ($exclusive_minimum ? $value > $minimum : $value >= $minimum)
        && $value <= $maximum;
    return 0 + $value;
}

sub _number_or_undef {
    my ($value) = @_;
    return undef unless defined $value;
    Selecto::Error->throw('invalid_analytics', 'analytical series contains a non-numeric value')
        if ref($value) || "$value" !~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return 0 + $value;
}

1;
