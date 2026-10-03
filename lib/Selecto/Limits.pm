package Selecto::Limits;

use 5.034;
use strict;
use warnings;
use bytes ();
use Scalar::Util qw(blessed);
use Selecto::Error ();

my %DEFAULTS = (
    max_fields => 100, max_filter_values => 100,
    max_parameter_bytes => 65_536, max_value_bytes => 4_096,
    max_action_targets => 1_000,
    max_collection_rows => 100, max_total_collection_rows => 10_000,
    max_response_bytes => 16_777_216,
    max_file_bytes => 16_777_216, max_total_decoded_bytes => 33_554_432,
    max_total_cells => 1_000_000,
    max_state_bytes => 131_072, max_bucket_ranges => 100,
    max_bucket_bytes => 16_384, max_numeric_digits => 15,
    max_generated_selections => 256, max_generated_parameters => 1_000,
    max_expression_nodes => 10_000,
    max_expression_depth => 64, max_expression_arity => 1_000,
    max_json_path_segments => 64,
    max_rule_numeric_digits => 1_024, max_rule_work => 1_000_000,
    max_regex_states => 4_096, max_import_preview_bytes => 16_777_216,
    max_result_cell_bytes => 65_536, max_response_temp_bytes => 33_554_432,
    max_response_nodes => 100_000, max_response_depth => 32,
);

sub new {
    my ($class, %overrides) = @_;
    for my $name (keys %overrides) {
        my $value = $overrides{$name};
        Selecto::Error->throw('invalid_limits', 'unknown resource limit')
            unless exists $DEFAULTS{$name};
        Selecto::Error->throw('invalid_limits', "$name must be a positive bounded integer")
            unless defined($value) && !ref($value) && "$value" =~ /\A[1-9][0-9]{0,8}\z/;
    }
    return bless {%DEFAULTS, %overrides}, $class;
}

sub get {
    my ($self, $name) = @_;
    Selecto::Error->throw('invalid_limits', 'unknown resource limit')
        unless exists $DEFAULTS{$name};
    return $self->{$name};
}

sub tightened {
    my ($self, %ceilings) = @_;
    my %next = %$self;
    for my $name (keys %ceilings) {
        my $maximum = $self->get($name);
        my $value = $ceilings{$name};
        Selecto::Error->throw('invalid_limits', 'a tightened ceiling must be a non-negative integer')
            unless defined($value) && !ref($value) && "$value" =~ /\A[0-9]{1,9}\z/;
        $next{$name} = 0 + $value if $value < $maximum;
    }
    return bless \%next, ref($self);
}

sub intersect {
    my ($self, $other) = @_;
    Selecto::Error->throw('invalid_limits', 'limits must be a Selecto::Limits')
        unless blessed($other) && $other->isa(__PACKAGE__);
    return $self->tightened(map { $_ => $other->get($_) } keys %DEFAULTS);
}

sub check_count {
    my ($self, $name, $count, $code, $label) = @_;
    my $maximum = $self->get($name);
    Selecto::Error->throw($code // 'resource_limit_exceeded',
        ($label // $name) . ' exceeds its resource limit', {maximum => 0 + $maximum})
        if $count > $maximum;
    return $count;
}

sub check_bytes {
    my ($self, $name, $value, $code, $label) = @_;
    Selecto::Error->throw($code // 'invalid_resource_value',
        ($label // $name) . ' must be a scalar') if ref($value);
    # Perl's byte length counts the UTF-8 representation of decoded strings
    # without allocating an encoded copy; raw byte strings retain their size.
    return $self->check_count($name, defined($value) ? bytes::length($value) : 0,
        $code, $label);
}

1;

__END__

=head1 NAME

Selecto::Limits - trusted finite resource budgets

=head1 DESCRIPTION

Construct once from trusted host configuration. Never populate overrides from
request data. Defaults limit membership to 100 values, values to 4 KiB,
parameters to 64 KiB, action targets to 1,000, child collections to 100 rows per
parent and 10,000 total rows, and responses to 16 MiB. Import inspection accepts
at most 16 MiB of UTF-8 input, 32 MiB of decoded cell bytes and one million cells.
Operation admission defaults to 10,000 node occurrences and 64 structural
levels; Boolean/variadic arity is 1,000 and JSON paths have at most 64 segments.
Response admission has separate ceilings of 100,000 nodes and 32 levels, with
64 KiB per result cell and 32 MiB of encoder temporary bytes. Import previews
have a 16 MiB encoded ceiling intersected with the response limit. Exact rule
numbers allow 1,024 integer/fraction digits, independently of the 15-digit
bucket policy. Patterns compile to at most 4,096 NFA states; an evaluation
shares a 1,000,000-work-unit rule ceiling.
Overrides are positive integers at most 999,999,999; applications should tighten
them to their worker and database budgets. Byte checks count UTF-8 bytes, not
characters. A transport must additionally bound incoming bodies before buffering.

=cut
