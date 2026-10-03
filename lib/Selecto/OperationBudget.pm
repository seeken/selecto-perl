package Selecto::OperationBudget;

use 5.034;
use strict;
use warnings;
use bytes ();
use JSON::PP ();
use Scalar::Util qw(blessed refaddr reftype);
use Selecto::Error ();
use Selecto::Limits ();

sub new {
    my ($class, %args) = @_;
    my $limits = $args{limits} // Selecto::Limits->new;
    Selecto::Error->throw('invalid_limits', 'operation budget requires Selecto::Limits')
        unless blessed($limits) && $limits->isa('Selecto::Limits');
    return bless {limits => $limits, code => $args{code} // 'resource_limit_exceeded', counts => {}}, $class;
}
sub limits { $_[0]->{limits} }
sub _check {
    my ($self, $limit, $count, $label) = @_;
    return $self->limits->check_count($limit, $count, $self->{code}, $label);
}
sub consume_count {
    my ($self, $limit, $count, %options) = @_;
    $self->{counts}{$limit} += $count;
    return $self->_check($limit, $self->{counts}{$limit}, $options{label} // $limit);
}
sub consume_value {
    my ($self, $value, %options) = @_;
    my $label = $options{label} // 'parameter';
    $value = $value ? 1 : 0 if JSON::PP::is_bool($value);
    my $bytes = $self->limits->check_bytes('max_value_bytes', $value, $self->{code}, $label);
    $self->consume_count('max_parameter_bytes', $bytes, label => 'operation parameter bytes');
    return $value;
}
sub consume_parameters {
    my ($self, $values, %options) = @_;
    Selecto::Error->throw($self->{code}, 'parameters must be an array') unless ref($values) eq 'ARRAY';
    $self->consume_count('max_generated_parameters', scalar(@$values), label => 'generated parameters');
    $self->consume_value($_, %options) for @$values;
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
    my (%active, @stack);
    push @stack, [$value, 0, 0];
    $self->consume_count($nodes_limit, 1, label => "$label nodes");
    my $bytes = 0;
    while (@stack) {
        my ($node, $depth, $leave) = @{pop @stack};
        if ($leave) { delete $active{$leave}; next }
        $self->_check($depth_limit, $depth, "$label depth");
        if (!ref($node) || JSON::PP::is_bool($node)) {
            my $scalar = JSON::PP::is_bool($node) ? ($node ? 1 : 0) : $node;
            my $size = defined($scalar) ? bytes::length($scalar) : 0;
            $self->_check($scalar_limit, $size, "$label value bytes") if defined $scalar_limit;
            $bytes += $size;
        } else {
            my $type = reftype($node) // '';
            Selecto::Error->throw($self->{code}, "$label contains an unsupported reference")
                if ($type ne 'ARRAY' && $type ne 'HASH') || (blessed($node) && !$allowed{blessed($node)});
            my $id = refaddr($node);
            Selecto::Error->throw($self->{code}, "$label contains a cycle") if $active{$id};
            $active{$id} = 1;
            push @stack, [undef, 0, $id];
            my $count = $type eq 'ARRAY' ? scalar(@$node) : scalar(keys %$node);
            # Refuse broad inputs before allocating a traversal stack of them.
            $self->consume_count($nodes_limit, $count, label => "$label nodes");
            if ($type eq 'ARRAY') {
                push @stack, [$node->[$_], $depth + 1, 0] for reverse 0 .. $#$node;
            } else {
                for my $key (keys %$node) {
                    $bytes += bytes::length($key);
                    $self->_check($byte_limit, ($self->{counts}{"tree_bytes:$byte_limit"} // 0) + $bytes, "$label bytes");
                    push @stack, [$node->{$key}, $depth + 1, 0];
                }
            }
        }
        $self->_check($byte_limit, ($self->{counts}{"tree_bytes:$byte_limit"} // 0) + $bytes, "$label bytes");
    }
    $self->{counts}{"tree_bytes:$byte_limit"} += $bytes;
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
