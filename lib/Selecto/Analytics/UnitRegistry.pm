package Selecto::Analytics::UnitRegistry;

use 5.034;
use strict;
use warnings;

use JSON::PP ();
use Selecto::Error ();

my %KINDS = map { $_ => 1 } qw(
    count currency distance duration mass percentage ratio scalar
);
my %BEHAVIORS = map { $_ => 1 } qw(flow stock ratio rate);
my %COUNT_AGGREGATES = map { $_ => 1 } qw(
    count count_distinct true_count false_count buckets age_buckets
);
my %PRESERVING_AGGREGATES = map { $_ => 1 } qw(sum avg min max);

sub normalize_column_metadata {
    my ($class, $column, $label) = @_;
    $label //= 'column';
    Selecto::Error->throw('invalid_domain', "$label must be an object")
        unless ref($column) eq 'HASH';
    my %normalized = %$column;
    my $type = $column->{type};
    my $numeric = $class->numeric_type($type);

    if (exists $column->{unit}) {
        Selecto::Error->throw(
            'invalid_domain', "$label unit is available only for numeric columns",
        ) unless $numeric;
        $normalized{unit} = $class->normalize_unit($column->{unit}, "$label unit");
    }
    if (exists $column->{behavior}) {
        Selecto::Error->throw(
            'invalid_domain', "$label behavior is available only for numeric columns",
        ) unless $numeric;
        $normalized{behavior} = $class->normalize_behavior(
            $column->{behavior}, "$label behavior",
        );
    }
    return \%normalized;
}

sub normalize_unit {
    my ($class, $value, $label) = @_;
    $label //= 'unit';
    Selecto::Error->throw('invalid_domain', "$label must be an object")
        unless ref($value) eq 'HASH';
    my %known = map { $_ => 1 } qw(kind code scale);
    my @unknown = sort grep { !$known{$_} } keys %$value;
    Selecto::Error->throw(
        'invalid_domain', "$label contains unsupported properties", {keys => \@unknown},
    ) if @unknown;

    my $kind = _required_scalar($value->{kind}, "$label kind");
    $kind = lc $kind;
    Selecto::Error->throw('invalid_domain', "$label kind is not available", {kind => $kind})
        unless $KINDS{$kind};
    my %unit = (kind => $kind);

    if ($kind eq 'currency') {
        my $code = uc _required_scalar($value->{code}, "$label currency code");
        Selecto::Error->throw('invalid_domain', "$label currency code must be three letters")
            unless $code =~ /\A[A-Z]{3}\z/;
        $unit{code} = $code;
    }
    elsif ($kind =~ /\A(?:distance|duration|mass)\z/) {
        my $code = lc _required_scalar($value->{code}, "$label code");
        Selecto::Error->throw('invalid_domain', "$label code must be an identifier")
            unless $code =~ /\A[a-z][a-z0-9_]*\z/;
        $unit{code} = $code;
    }
    elsif (exists $value->{code}) {
        Selecto::Error->throw('invalid_domain', "$label code is not valid for $kind");
    }

    if ($kind eq 'percentage') {
        my $scale = exists($value->{scale})
            ? lc _required_scalar($value->{scale}, "$label percentage scale")
            : 'fraction';
        Selecto::Error->throw(
            'invalid_domain', "$label percentage scale must be fraction or whole",
        ) unless $scale eq 'fraction' || $scale eq 'whole';
        $unit{scale} = $scale;
    }
    elsif (exists $value->{scale}) {
        Selecto::Error->throw('invalid_domain', "$label scale is not valid for $kind");
    }
    return \%unit;
}

sub normalize_behavior {
    my ($class, $value, $label) = @_;
    $label //= 'behavior';
    my $behavior = lc _required_scalar($value, $label);
    Selecto::Error->throw(
        'invalid_domain', "$label is not available", {behavior => $behavior},
    ) unless $BEHAVIORS{$behavior};
    return $behavior;
}

sub column_unit {
    my ($class, $column) = @_;
    return undef unless ref($column) eq 'HASH';
    return $class->normalize_unit($column->{unit}) if exists $column->{unit};
    return {kind => 'scalar'} if $class->numeric_type($column->{type});
    return undef;
}

sub column_behavior {
    my ($class, $column) = @_;
    return undef unless ref($column) eq 'HASH' && exists $column->{behavior};
    return $class->normalize_behavior($column->{behavior});
}

sub aggregate_unit {
    my ($class, $source_unit, $aggregate) = @_;
    $aggregate = lc _required_scalar($aggregate, 'aggregate');
    return {kind => 'count'} if $COUNT_AGGREGATES{$aggregate};
    return {kind => 'percentage', scale => 'whole'} if $aggregate eq 'true_percentage';
    Selecto::Error->throw(
        'invalid_analytics', 'aggregate result unit is not available',
        {aggregate => $aggregate},
    ) unless $PRESERVING_AGGREGATES{$aggregate};
    return undef unless defined $source_unit;
    return $class->normalize_unit($source_unit, 'aggregate source unit');
}

sub compatible {
    my ($class, $left, $right) = @_;
    return 0 unless defined($left) && defined($right);
    my $left_signature = $class->signature($left);
    my $right_signature = $class->signature($right);
    return $left_signature eq $right_signature ? 1 : 0;
}

sub signature {
    my ($class, $unit) = @_;
    my $normalized = $class->normalize_unit($unit);
    return JSON::PP->new->canonical(1)->encode($normalized);
}

sub numeric_type {
    my ($class, $type) = @_;
    return defined($type) && !ref($type)
        && "$type" =~ /\A(?:integer|int|smallint|bigint|id|decimal|number|numeric|float|double|real)\z/i
        ? 1 : 0;
}

sub _required_scalar {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_domain', "$label must be a non-empty string")
        if !defined($value) || ref($value) || "$value" eq '' || "$value" =~ /[\x00-\x1f\x7f]/;
    return "$value";
}

1;
