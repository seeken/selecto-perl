package Selecto::OperationBudget;

use 5.034;
use strict;
use warnings;
use bytes ();
use JSON::PP ();
use Scalar::Util qw(blessed refaddr reftype);
use Selecto::Error ();
use Selecto::Limits ();

# The default policy, built once. Limits objects are immutable and budgets
# only read them; each budget still has its own counters.
my $DEFAULT_LIMITS;

# JSON::PP::is_bool for a value that is not a blessed reference: true only for
# Perl core booleans, and only when this JSON::PP recognises them (CORE_BOOL,
# JSON::PP 4.11+ on Perl 5.36+). Blessed references still call is_bool itself.
use constant _CORE_BOOL => defined(&JSON::PP::CORE_BOOL) && JSON::PP::CORE_BOOL() ? 1 : 0;
BEGIN { _CORE_BOOL and warnings->unimport('experimental::builtin') }

sub new {
    my ($class, %args) = @_;
    my $limits = $args{limits} // ($DEFAULT_LIMITS //= Selecto::Limits->new);
    Selecto::Error->throw('invalid_limits', 'operation budget requires Selecto::Limits')
        unless blessed($limits) && $limits->isa('Selecto::Limits');
    return bless {limits => $limits, code => $args{code} // 'resource_limit_exceeded', counts => {}}, $class;
}
sub limits { $_[0]->{limits} }

# Every check compares against the same trusted maximum as before and, only on
# a breach, calls the original throwing path, so thresholds, error codes,
# messages and details are unchanged. The comparisons are inlined because
# admission runs per node and per parameter on every operation.
sub _check {
    my ($self, $limit, $count, $label) = @_;
    return $self->{limits}->check_count($limit, $count, $self->{code}, $label);
}
sub consume_count {
    my ($self, $limit, $count, %options) = @_;
    my $total = $self->{counts}{$limit} += $count;
    $self->_check($limit, $total, $options{label} // $limit)
        if $total > $self->{limits}->get($limit);
    return $total;
}
sub consume_value {
    my ($self, $value, %options) = @_;
    return $self->_consume_values([$value], $options{label} // 'parameter');
}
# consume_value for each value in turn, in order, with the same checks,
# thresholds, errors and counters; each maximum is looked up once per call.
# Returns the last admitted value (booleans as 1 or 0), as consume_value did.
sub _consume_values {
    my ($self, $values, $label) = @_;
    my $limits = $self->{limits};
    my $counts = $self->{counts};
    my ($value_max, $total_max, $value);
    for my $item (@$values) {
        $value = $item;
        if (ref($value) ? blessed($value) && JSON::PP::is_bool($value) : _CORE_BOOL && builtin::is_bool($value)) {
            $value = $value ? 1 : 0;
        }
        # check_bytes refuses references; keep its exact refusal on that path.
        if (ref($value)) { $self->_consume_value_slow($value, $label); next }
        my $bytes = defined($value) ? do { use bytes; length($value) } : 0;
        $limits->check_count('max_value_bytes', $bytes, $self->{code}, $label)
            if $bytes > ($value_max //= $limits->get('max_value_bytes'));
        my $total = $counts->{max_parameter_bytes} += $bytes;
        $self->_check('max_parameter_bytes', $total, 'operation parameter bytes')
            if $total > ($total_max //= $limits->get('max_parameter_bytes'));
    }
    return $value;
}
sub _consume_value_slow {
    my ($self, $value, $label) = @_;
    my $bytes = $self->{limits}->check_bytes('max_value_bytes', $value, $self->{code}, $label);
    $self->consume_count('max_parameter_bytes', $bytes, label => 'operation parameter bytes');
    return $value;
}
sub consume_parameters {
    my ($self, $values, %options) = @_;
    Selecto::Error->throw($self->{code}, 'parameters must be an array') unless ref($values) eq 'ARRAY';
    $self->consume_count('max_generated_parameters', scalar(@$values), label => 'generated parameters');
    my $label = $options{label} // 'parameter';
    if ($options{allow_flat_array_parameters}) {
        for my $value (@$values) {
            if (ref($value) eq 'ARRAY' && !blessed($value)) {
                $self->_consume_flat_array($value, $label);
            } else {
                $self->_consume_values([$value], $label);
            }
        }
    } else {
        $self->_consume_values($values, $label);
    }
    return $values;
}

# PostgreSQL's native flat text-array bind, explicitly selected by an adapter.
# Account for a conservative wire size without constructing or changing it:
# braces, commas, quoted strings with doubled escaping, and unquoted NULL.
sub _consume_flat_array {
    my ($self, $values, $label) = @_;
    my $count = scalar @$values;
    $self->consume_count('max_expression_nodes', $count, label => 'array parameter elements');
    my $bytes = 2 + ($count ? $count - 1 : 0);
    my $maximum = $self->{limits}->get('max_value_bytes');
    $self->_check('max_value_bytes', $bytes, $label) if $bytes > $maximum;
    for my $value (@$values) {
        Selecto::Error->throw($self->{code}, 'array parameter elements must be scalars') if ref($value);
        $bytes += defined($value) ? 2 * bytes::length($value) + 2 : 4;
        $self->_check('max_value_bytes', $bytes, $label) if $bytes > $maximum;
    }
    $self->consume_count('max_parameter_bytes', $bytes, label => 'operation parameter bytes');
    return $values;
}

# Iterative admission before recursive parsing, cloning or JSON encoding. An
# occurrence is charged every time it will be visited; aliases do not bypass
# accounting. Only cycles on the active path are rejected. Tree accounting is
# independent of scalar-to-parameter accounting, which belongs to a later stage.
sub check_tree {
    my ($self, $value, %options) = @_;
    my $label = $options{label} // 'input';
    my $byte_limit = $options{bytes_limit} // 'max_state_bytes';
    my $response = $byte_limit eq 'max_response_bytes' || $byte_limit eq 'max_import_preview_bytes';
    my $nodes_limit = $options{nodes_limit} // ($response ? 'max_response_nodes' : 'max_expression_nodes');
    my $depth_limit = $options{depth_limit} // ($response ? 'max_response_depth' : 'max_expression_depth');
    my $scalar_limit = $options{scalar_limit};
    my %allowed = map { $_ => 1 } @{$options{allowed_classes} // []};
    my @allowed_bases = @{$options{allowed_base_classes} // []};
    # A flat stack of (node, depth, leave) triples, visited in the same order
    # as before, without allocating a record per node.
    my (%active, @stack);
    push @stack, $value, 0, 0;
    $self->consume_count($nodes_limit, 1, label => "$label nodes");
    my $limits = $self->{limits};
    my $counts = $self->{counts};
    # The same maxima the per-node checks read, each looked up when its first
    # check runs (as before) and then reused for the rest of the call.
    my $nodes_max = $limits->get($nodes_limit);
    my ($depth_max, $bytes_max, $scalar_max);
    my $bytes_base = $counts->{"tree_bytes:$byte_limit"} // 0;
    my $bytes = 0;
    while (@stack) {
        my $leave = pop @stack;
        my $depth = pop @stack;
        my $node = pop @stack;
        if ($leave) { delete $active{$leave}; next }
        $self->_check($depth_limit, $depth, "$label depth")
            if $depth > ($depth_max //= $limits->get($depth_limit));
        # JSON::PP::is_bool is false for every unblessed reference.
        my $is_bool = ref($node) ? blessed($node) && JSON::PP::is_bool($node) : _CORE_BOOL && builtin::is_bool($node);
        if (!ref($node) || $is_bool) {
            my $scalar = $is_bool ? ($node ? 1 : 0) : $node;
            my $size = defined($scalar) ? do { use bytes; length($scalar) } : 0;
            if (defined $scalar_limit) {
                $scalar_max //= $limits->get($scalar_limit);
                $self->_check($scalar_limit, $size, "$label value bytes") if $size > $scalar_max;
            }
            $bytes += $size;
        } else {
            my $type = reftype($node) // '';
            my $class = blessed($node);
            my $class_allowed = !$class || $allowed{$class}
                || grep { UNIVERSAL::isa($node, $_) } @allowed_bases;
            Selecto::Error->throw($self->{code}, "$label contains an unsupported reference")
                if ($type ne 'ARRAY' && $type ne 'HASH') || !$class_allowed;
            my $id = refaddr($node);
            Selecto::Error->throw($self->{code}, "$label contains a cycle") if $active{$id};
            $active{$id} = 1;
            push @stack, undef, 0, $id;
            my $count = $type eq 'ARRAY' ? scalar(@$node) : scalar(keys %$node);
            # Refuse broad inputs before allocating a traversal stack of them.
            my $nodes = $counts->{$nodes_limit} += $count;
            $self->_check($nodes_limit, $nodes, "$label nodes") if $nodes > $nodes_max;
            if ($type eq 'ARRAY') {
                push @stack, $node->[$_], $depth + 1, 0 for reverse 0 .. $#$node;
            } else {
                for my $key (keys %$node) {
                    $bytes += bytes::length($key);
                    $self->_check($byte_limit, $bytes_base + $bytes, "$label bytes")
                        if $bytes_base + $bytes > ($bytes_max //= $limits->get($byte_limit));
                    push @stack, $node->{$key}, $depth + 1, 0;
                }
            }
        }
        $self->_check($byte_limit, $bytes_base + $bytes, "$label bytes")
            if $bytes_base + $bytes > ($bytes_max //= $limits->get($byte_limit));
    }
    $counts->{"tree_bytes:$byte_limit"} += $bytes;
    return $bytes;
}

1;

__END__

=head1 NAME

Selecto::OperationBudget - bounded admission and per-operation resource counters

=head1 DESCRIPTION

Construct from trusted C<Selecto::Limits>. C<check_tree> checks cumulative tree
nodes and UTF-8 scalar/key bytes, depth, cycles and reference types before a
caller copies input. It defaults to C<max_state_bytes>; C<bytes_limit> selects
another trusted ceiling. Optional C<scalar_limit> checks every scalar leaf;
omit it for grammars containing identifiers as well as values. Blessed records
are rejected unless their exact classes occur in trusted C<allowed_classes>.
Trusted C<allowed_base_classes> may explicitly permit subclasses, as query
admission does for C<Selecto::Query>. This still traverses their full record
and applies every node, byte, depth, cycle and nested-reference check.
Parameter admission remains scalar-only by default. A trusted adapter may
select C<allow_flat_array_parameters> for unblessed flat arrays of scalars.
Each array consumes one bind slot, every element consumes a node, and its
conservative PostgreSQL text-wire size consumes both the single-value and
aggregate parameter-byte budgets. Referenced elements remain refused, and
the original parameter representation is returned unchanged.
C<max_response_bytes> and C<max_import_preview_bytes> select the separate
response-node/depth defaults. C<nodes_limit> and C<depth_limit> can explicitly
select another named trusted limit. Depth counts actual container/scalar
levels, including normalized expression record wrappers; an AST meeting its
own depth check must also fit the normalized representation at compilation.

C<consume_value> separately charges scalar parameter bytes. It does not charge
tree admission again. C<consume_parameters> additionally charges actual emitted
parameter count. Use a fresh budget for final statement admission: input and
generated occurrences are different stages, and parameters reused in SQL must
be counted once for each actual emitted occurrence. Counters are request-local;
never reuse an instance across requests or populate policy from request data.

=cut
