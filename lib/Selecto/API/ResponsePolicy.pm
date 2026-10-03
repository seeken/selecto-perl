package Selecto::API::ResponsePolicy;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed);
use JSON::PP ();
use B ();
use bytes ();
use Selecto::Limits ();
use Selecto::OperationBudget ();

# Policy is associated with a result's lifetime, never inserted into its JSON.
# Custom handlers use the API host's policy; EngineHandler can only tighten it.
fieldhash my %result_limits;

sub bind_limits {
    my ($class, $result, $limits) = @_;
    $result_limits{$result} = $limits if ref($result) eq 'HASH';
    return $result;
}

sub limits_for {
    my ($class, $result, $host_limits) = @_;
    return $host_limits unless ref($result) eq 'HASH' && $result_limits{$result};
    return $host_limits->intersect($result_limits{$result});
}

sub public_data {
    my ($class, $value, $debug, $limits) = @_;
    # Bound traversal before copying or serializing a custom handler's result.
    Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')
        ->check_tree($value, label => 'API result', bytes_limit => 'max_response_bytes',
            scalar_limit => undef);
    return $value if $debug;
    return _copy($value, 0);
}

# Exact canonical JSON byte admission, without allocating escaped copies of
# unbounded strings or the whole envelope. Numeric flags match JSON::PP's
# scalar typing; string-looking numbers remain strings. Keys are always strings.
sub check_json {
    my ($class, $value, $limits) = @_;
    Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')
        ->check_tree($value, label => 'JSON response', bytes_limit => 'max_response_bytes');
    my @stack = ($value);
    my $bytes = 0;
    my $check = sub { $limits->check_count('max_response_bytes', $bytes,
        'api_result_limit_exceeded', 'encoded JSON response bytes') };
    while (@stack) {
        my $node = pop @stack;
        if (!ref($node) || JSON::PP::is_bool($node)) {
            $bytes += _scalar_json_bytes($node, 0, $limits, $bytes);
        } elsif (ref($node) eq 'ARRAY') {
            $bytes += 2 + (@$node ? @$node - 1 : 0);
            push @stack, @$node;
        } else {
            my @keys = keys %$node;
            $bytes += 2 + (@keys ? @keys - 1 : 0);
            for my $key (@keys) {
                $bytes += 1 + _scalar_json_bytes($key, 1, $limits, $bytes + 1);
                $check->();
            }
            push @stack, @{$node}{@keys};
        }
        $check->();
    }
    return $bytes;
}

sub _scalar_json_bytes {
    my ($value, $key, $limits, $used) = @_;
    return 4 unless defined $value;
    return $value ? 4 : 5 if JSON::PP::is_bool($value);
    my $flags = B::svref_2object(\$value)->FLAGS;
    if (!$key && ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK())) {
        # Native numeric scalars have bounded textual representations. Canonical
        # JSON's ordinary validator still rejects non-integral numeric values.
        return length(JSON::PP->new->allow_nonref->encode($value));
    }
    my $bytes = 2 + bytes::length($value);
    # Raw eight-bit Perl strings encode their high bytes as Unicode code points.
    $bytes += ($value =~ tr/\x80-\xff/\x80-\xff/) unless utf8::is_utf8($value);
    $limits->check_count('max_response_bytes', $used + $bytes,
        'api_result_limit_exceeded', 'encoded JSON scalar bytes');
    while ($value =~ /(["\\\x00-\x1f])/g) {
        $bytes += $1 =~ /[\x08\x09\x0a\x0c\x0d"\\]/ ? 1 : 5;
        $limits->check_count('max_response_bytes', $used + $bytes,
            'api_result_limit_exceeded', 'encoded JSON scalar bytes');
    }
    return $bytes;
}

sub _copy {
    my ($value, $business_data) = @_;
    return $value unless ref($value);
    return $value if blessed($value) && JSON::PP::is_bool($value);
    return [map { _copy($_, $business_data) } @$value] if ref($value) eq 'ARRAY';
    my %copy;
    for my $key (keys %$value) {
        next if !$business_data && $key =~ /\A(?:sql(?:_.*)?|(?:compiled|executable|debug|raw)_sql|params|parameters|statement|statements|debug|query_plan|explain)\z/i;
        # Published row/returning values are application data, not diagnostics.
        $copy{$key} = _copy($value->{$key}, $business_data || $key eq 'rows' || $key eq 'values');
    }
    return \%copy;
}

sub error_details {
    my ($class, $details, $debug, $limits) = @_;
    return {} unless ref($details) eq 'HASH';
    return $class->public_data($details, 1, $limits) if $debug;
    # Arbitrary driver causes/messages may embed whole SQL and bound values.
    # Retain only structured, public validation metadata in ordinary responses.
    my %allowed = map { $_ => 1 } qw(field fields missing_fields operation maximum expected
        type format expected_extension row_limit limit offset);
    my $public = {map { $_ => $details->{$_} } grep { $allowed{$_} } keys %$details};
    return $class->public_data($public, 0, $limits);
}

1;
