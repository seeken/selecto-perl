package Selecto::API::ResponsePolicy;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed isdual);
use JSON::PP ();
use B ();
use bytes ();
use Selecto::Limits ();
use Selecto::OperationBudget ();

# Perl 5.36 and newer tell a scalar made as a number from one made as a
# string without B; JSON::PP reports core booleans when it supports them.
use constant _CREATED => $] >= 5.036 ? 1 : 0;
use constant _CORE_BOOL => defined(&JSON::PP::CORE_BOOL) && JSON::PP::CORE_BOOL() ? 1 : 0;
BEGIN { warnings->unimport('experimental::builtin') if _CREATED }

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
    # _tree_within accepts exactly what check_tree would; anything else is
    # checked (and refused) by check_tree itself.
    Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')
        ->check_tree($value, label => 'API result', bytes_limit => 'max_response_bytes',
            scalar_limit => undef)
        unless _tree_within($value, $limits);
    return $value if $debug;
    return _copy($value, 0);
}

# Exact canonical JSON byte admission, without allocating escaped copies of
# unbounded strings or the whole envelope. Numeric flags match JSON::PP's
# scalar typing; string-looking numbers remain strings. Keys are always strings.
#
# A single pass (_json_bytes_within) computes the same node count, depth,
# traversal bytes and JSON bytes as the exact walk below and returns its
# result when every limit holds. Each limit compares a running total that
# only grows, so the totals deciding it are the final ones. Anything else (a
# limit reached, a blessed or unsupported reference, a cycle, a scalar root)
# takes the exact walk, which raises the same error as before.
sub check_json {
    my ($class, $value, $limits) = @_;
    my $bytes = _json_bytes_within($value, $limits);
    return defined($bytes) ? $bytes : $class->_check_json_exact($value, $limits);
}

sub _check_json_exact {
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

# The traversal bytes (check_tree), node count and JSON bytes (check_json) of
# a tree of unblessed hashes and arrays whose leaves are scalars or JSON::PP
# booleans, or undef when the tree is anything else, holds a number that is
# not an integer, or a limit would be exceeded. Scalars are read through
# copies, so no value's flags change.
sub _json_bytes_within {
    my ($value, $limits) = @_;
    my $type = ref($value);
    return undef unless $type eq 'HASH' || $type eq 'ARRAY';
    my $max_nodes = $limits->get('max_response_nodes');
    my $max_depth = $limits->get('max_response_depth');
    my $max_bytes = $limits->get('max_response_bytes');
    my ($nodes, $tree, $json) = (1, 0, 0);
    my @stack = ($value, 0);
    while (@stack) {
        my $depth = pop @stack;
        my $node = pop @stack;
        # Also ends a cycle, which the exact walk then reports.
        return undef if $depth > $max_depth;
        my $hash = ref($node) eq 'HASH';
        my $count = $hash ? scalar(keys %$node) : scalar(@$node);
        next unless $count ? 1 : do { $json += 2; 0 };
        $nodes += $count;
        return undef if $nodes > $max_nodes || $depth + 1 > $max_depth;
        $json += $count + 1;
        if ($hash) {
            for my $key (keys %$node) {
                my $length = do { use bytes; length($key) };
                $tree += $length;
                $json += 3 + $length;
                $json += ($key =~ tr/\x80-\xff//) if $length == length($key);
                $json += ($key =~ tr/"\\\x08\x09\x0a\x0c\x0d//) + 5 * ($key =~ tr/\x00-\x07\x0b\x0e-\x1f//)
                    if $key =~ tr/"\\\x00-\x1f//;
            }
        }
        for my $child ($hash ? values(%$node) : @$node) {
            if (my $child_type = ref($child)) {
                if ($child_type eq 'HASH' || $child_type eq 'ARRAY') {
                    push @stack, $child, $depth + 1;
                    next;
                }
                return undef unless blessed($child) && JSON::PP::is_bool($child);
                $tree += 1;
                $json += $child ? 4 : 5;
                next;
            }
            if (!defined $child) {
                $json += 4;
                next;
            }
            my $copy = $child;
            # The exact walk's test: a boolean, else numeric flags without
            # string flags. created_as_string is false for booleans.
            my $number = 0;
            unless (_CREATED && builtin::created_as_string($copy)) {
                if (_CORE_BOOL && builtin::is_bool($copy)) {
                    $tree += 1;
                    $json += $copy ? 4 : 5;
                    next;
                }
                $number = _CREATED && builtin::created_as_number($copy) ? !isdual($copy) : _numeric_flags($copy);
            }
            if ($number) {
                my $text = "$copy";
                # JSON::PP writes such an integer as its digits. The exact walk
                # measures other numbers (fractions, exponents, -0,
                # infinities) by encoding them, and older JSON::PP types some
                # of them differently from one call to the next.
                return undef unless $text =~ /\A(?:0|-?[1-9][0-9]*)\z/;
                $tree += length($text);
                $json += length($text);
                next;
            }
            my $length = do { use bytes; length($copy) };
            $tree += $length;
            $json += 2 + $length;
            # Raw eight-bit strings encode their high bytes as code points.
            $json += ($copy =~ tr/\x80-\xff//) if $length == length($copy);
            $json += ($copy =~ tr/"\\\x08\x09\x0a\x0c\x0d//) + 5 * ($copy =~ tr/\x00-\x07\x0b\x0e-\x1f//)
                if $copy =~ tr/"\\\x00-\x1f//;
        }
        return undef if $tree > $max_bytes || $json > $max_bytes;
    }
    return $tree > $max_bytes || $json > $max_bytes ? undef : $json;
}

# True when OperationBudget->check_tree with max_response_bytes (its node,
# depth and byte limits, no scalar limit) would accept a tree of unblessed
# hashes and arrays whose leaves are scalars or JSON::PP booleans; false for
# any other tree or when a limit would be exceeded, which the caller then
# leaves to check_tree.
#
# With $rows, an array of row arrays inside the tree, it also requires that
# the rows' cells fit in max_response_bytes in all, each cell counted as
# EngineHandler counts it: a scalar's byte length, or the exact JSON bytes
# of a reference (check_json).
sub _tree_within {
    my ($value, $limits, $rows) = @_;
    my $type = ref($value);
    return 0 unless $type eq 'HASH' || $type eq 'ARRAY';
    my $max_nodes = $limits->get('max_response_nodes');
    my $max_depth = $limits->get('max_response_depth');
    my $max_bytes = $limits->get('max_response_bytes');
    my ($nodes, $tree, $cells) = (1, 0, 0);
    my @stack = ($value, 0, 0);
    while (@stack) {
        my $row = pop @stack;
        my $depth = pop @stack;
        my $node = pop @stack;
        return 0 if $depth > $max_depth;
        my $hash = ref($node) eq 'HASH';
        my $count = $hash ? scalar(keys %$node) : scalar(@$node);
        next unless $count;
        $nodes += $count;
        return 0 if $nodes > $max_nodes || $depth + 1 > $max_depth;
        if ($hash) {
            $tree += do { use bytes; length($_) } for keys %$node;
        }
        my $rows_node = defined($rows) && !$hash && $node == $rows ? 1 : 0;
        for my $child ($hash ? values(%$node) : @$node) {
            if (my $child_type = ref($child)) {
                if ($child_type eq 'HASH' || $child_type eq 'ARRAY') {
                    return 0 if $rows_node && $child_type ne 'ARRAY';
                    push @stack, $child, $depth + 1, $rows_node;
                    if ($row) {
                        my $bytes = _json_bytes_within($child, $limits);
                        return 0 unless defined $bytes;
                        $cells += $bytes;
                    }
                    next;
                }
                return 0 unless blessed($child) && JSON::PP::is_bool($child);
                $tree += 1;
                $cells += $child ? 4 : 5 if $row;
                next;
            }
            return 0 if $rows_node;
            next unless defined $child;
            my $copy = $child;
            my $length = do { use bytes; length($copy) };
            $cells += $length if $row;
            # check_tree counts a boolean as one byte; only false is shorter.
            $length = 1 if !$length && _CORE_BOOL && builtin::is_bool($copy);
            $tree += $length;
        }
        return 0 if $tree > $max_bytes || $cells > $max_bytes;
    }
    return 1;
}

# True when Selecto::API::canonical_json's validation cannot refuse the
# value: unblessed hashes and arrays whose leaves are undef, JSON::PP
# booleans, strings without numeric flags (which JSON::PP writes as strings)
# or scalars whose text is an integer. Anything else, a cycle included, is
# left to the validation, which refuses it as before.
sub _canonical_values_ok {
    my ($value) = @_;
    my @stack = ($value, 0);
    while (@stack) {
        my $depth = pop @stack;
        my $node = pop @stack;
        if (my $type = ref($node)) {
            if ($type eq 'HASH' || $type eq 'ARRAY') {
                return 0 if $depth >= 10_000;
                push @stack, map { ($_, $depth + 1) } $type eq 'HASH' ? values(%$node) : @$node;
                next;
            }
            return 0 unless blessed($node) && JSON::PP::is_bool($node);
            next;
        }
        next unless defined $node;
        next if _CREATED ? builtin::created_as_string($node) && !isdual($node) : _string_flags_only($node);
        return 0 unless "$node" =~ /\A-?(?:0|[1-9][0-9]*)\z/;
    }
    return 1;
}

sub _string_flags_only {
    my $flags = B::svref_2object(\$_[0])->FLAGS;
    return ($flags & B::SVp_POK()) && !($flags & (B::SVp_IOK() | B::SVp_NOK())) ? 1 : 0;
}

sub _numeric_flags {
    my $flags = B::svref_2object(\$_[0])->FLAGS;
    return ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK()) ? 1 : 0;
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
    return [map { ref($_) ? _copy($_, $business_data) : $_ } @$value] if ref($value) eq 'ARRAY';
    my %copy;
    for my $key (keys %$value) {
        next if !$business_data && $key =~ /\A(?:sql(?:_.*)?|(?:compiled|executable|debug|raw)_sql|params|parameters|statement|statements|debug|query_plan|explain)\z/i;
        # Published row/returning values are application data, not diagnostics.
        my $child = $value->{$key};
        $copy{$key} = ref($child) ? _copy($child, $business_data || $key eq 'rows' || $key eq 'values') : $child;
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
        type format expected_extension row_limit limit offset parameter);
    my $public = {map { $_ => $details->{$_} } grep { $allowed{$_} } keys %$details};
    return $class->public_data($public, 0, $limits);
}

1;
