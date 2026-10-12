package Selecto::SQL::RollupEmulation;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Statement ();

# Shared by the adapters whose dialect has no GROUP BY ROLLUP with GROUPING()
# markers it can order (SQLite, and MySQL/MariaDB, where MariaDB has no
# GROUPING() and neither allows NULLS FIRST/LAST): each grouping level compiles
# as an ordinary GROUP BY branch, and the branches are combined with UNION ALL.

our %AGGREGATES = map { $_ => 1 } qw(
    count count_field count_distinct sum sum_zero avg min max
    true_count false_count true_percentage count_bucket
);

sub validate_projection {
    my ($self, $expression, $dimensions) = @_;
    my $key = Selecto::SQL::_expression_key($expression);
    return if exists($dimensions->{$key}) || $expression->kind eq 'literal'
        || $AGGREGATES{$expression->kind};
    my ($kind, $args) = ($expression->kind, $expression->arguments);
    if ($kind eq 'grouping') {
        Selecto::Error->throw('invalid_query', 'GROUPING must reference at most 31 rollup dimensions')
            unless ref($args->[0]) eq 'ARRAY' && @{$args->[0]} && @{$args->[0]} <= 31
                && !grep { !exists $dimensions->{Selecto::SQL::_expression_key($_)} } @{$args->[0]};
        return;
    }
    if ($kind eq 'dimension_display') {
        Selecto::Error->throw('invalid_query', 'dimension display requires a rollup dimension')
            unless @$args == 2 && blessed($args->[1]) && $args->[1]->isa('Selecto::Expression')
                && exists $dimensions->{Selecto::SQL::_expression_key($args->[1])};
        return;
    }
    # Scalar compositions may use dimensions, constants, and closed measures.
    # A free field, window, subquery, or unrelated value AST is not a measure.
    Selecto::Error->throw('invalid_query', 'rollup projections require dimensions or closed aggregates')
        if $kind =~ /\A(?:field|value|window|related_collection|recursion_depth)\z/;
    my @children = _expression_children($args);
    Selecto::Error->throw('invalid_query', 'rollup projections require dimensions or closed aggregates')
        unless @children;
    validate_projection($self, $_, $dimensions) for @children;
}

sub _expression_children {
    my ($value) = @_;
    return ($value) if blessed($value) && $value->isa('Selecto::Expression');
    return map { _expression_children($_) } @$value if ref($value) eq 'ARRAY';
    return map { _expression_children($value->{$_}) } sort keys %$value if ref($value) eq 'HASH';
    return ();
}

# $order_sql->($position, $column, $direction, $nulls) renders one outer ORDER
# BY term; $nulls is 'first' or 'last'.
sub compile {
    my ($self, $domain, $query, $order_sql, %options) = @_;
    my $groups = $query->groups;
    my %dimensions;
    for my $index (0 .. $#$groups) {
        my $key = Selecto::SQL::_expression_key($groups->[$index]);
        Selecto::Error->throw('invalid_query', 'rollup requires at most 31 distinct dimensions')
            if @$groups > 31 || exists $dimensions{$key};
        $dimensions{$key} = $index;
    }
    Selecto::Error->throw('invalid_query', 'rollup requires at least one dimension') unless @$groups;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support row locks')
        if defined $query->row_lock;
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    validate_projection($self, $_, \%dimensions) for @$selections;
    my @columns = map { $self->_selection_name($_) } @$selections;
    my @aliased = map { $selections->[$_]->as($columns[$_]) } 0 .. $#$selections;
    my (@branches, @params);
    for (my $level = @$groups; $level >= 0; $level--) {
        my $branch = $query->_copy(
            selections => \@aliased,
            grouping_mode => 'plain', groups => $level ? [@$groups[0 .. $level - 1]] : [],
            orders => [], limit_value => undef, offset_value => undef,
        );
        my $statement = $self->_compile_single($domain, $branch, %options,
            rollup_projection => {dimensions => \%dimensions, level => $level});
        # A derived table also keeps branch-local WITH clauses legal in a union.
        push @branches, 'SELECT * FROM (' . $statement->sql . ') AS '
            . $self->quote_identifier('__selecto_rollup_branch' . $level);
        push @params, @{$statement->params};
    }
    my $sql = 'SELECT * FROM (' . join(' UNION ALL ', @branches) . ') AS '
        . $self->quote_identifier('__selecto_rollup');
    my @orders;
    for my $order (@{$query->orders}) {
        my $key = Selecto::SQL::_expression_key($order->[0]);
        my ($position) = grep {
            Selecto::SQL::_expression_key($selections->[$_]) eq $key
                || ($order->[0]->kind eq 'field' && $order->[0]->arguments->[0] eq $columns[$_])
        } 0 .. $#$selections;
        Selecto::Error->throw('invalid_query', 'rollup ordering must reference a selected output column')
            unless defined $position;
        push @orders, [$position, uc($order->[1])];
    }
    my ($marker) = grep {
        $selections->[$_]->kind eq 'grouping'
            && Selecto::SQL::_value_key($selections->[$_]->arguments->[0]) eq Selecto::SQL::_value_key($groups)
    } 0 .. $#$selections;
    if (@orders) {
        my $nulls = @$groups == 1 && defined($marker) ? 'last' : 'first';
        my @terms = map { $order_sql->($_->[0] + 1, $columns[$_->[0]], $_->[1], $nulls) } @orders;
        if (defined $marker) {
            my $term = $order_sql->($marker + 1, $columns[$marker], 'DESC', undef);
            @$groups == 1 ? unshift(@terms, $term) : push(@terms, $term);
        }
        $sql .= ' ORDER BY ' . join(', ', @terms);
    }
    $sql .= $self->_compile_pagination($query->limit_value, $query->offset_value, @orders ? 1 : 0);
    return Selecto::Statement->new(sql => $sql, params => \@params,
        columns => \@columns, adapter_name => $self->name);
}

# Run inside the adapter's _compile_selection_expression; $compile compiles the
# expression with the adapter's own _compile_expression.
sub selection_expression {
    my ($self, $options, $compile) = @_;
    local $self->{_rollup_branch} = $options->{rollup_projection};
    local $self->{_rollup_projection} = defined $self->{_rollup_branch};
    my $sql = $compile->();
    # COUNT forces the empty grouping set to yield one row even with no measure.
    return $self->{_rollup_branch} && $self->{_rollup_branch}{level} == 0
        ? 'CASE WHEN COUNT(*) >= 0 THEN ' . $sql . ' END' : $sql;
}

# Returns the SQL for a rollup branch expression, or undef when the adapter's
# ordinary compilation applies. $super compiles with the parent class.
sub branch_expression {
    my ($self, $domain, $expression, $params, $compiled_selections, $super) = @_;
    my $branch = $self->{_rollup_branch};
    return undef unless $branch && blessed($expression) && $expression->isa('Selecto::Expression');
    my $key = Selecto::SQL::_expression_key($expression);
    if ($self->{_rollup_projection} && exists $branch->{dimensions}{$key}) {
        local $self->{_rollup_projection} = 0;
        return _null_dimension($self, sub { $super->($domain, $expression, $params, $compiled_selections) })
            if $branch->{dimensions}{$key} >= $branch->{level};
        return $super->($domain, $expression, $params, $compiled_selections);
    }
    if ($expression->kind eq 'grouping') {
        validate_projection($self, $expression, $branch->{dimensions});
        my $marker = 0;
        for my $dimension (@{$expression->arguments->[0]}) {
            my $index = $branch->{dimensions}{Selecto::SQL::_expression_key($dimension)};
            Selecto::Error->throw('invalid_query', 'GROUPING must reference rollup dimensions') unless defined $index;
            $marker = ($marker << 1) | ($index >= $branch->{level} ? 1 : 0);
        }
        return "$marker";
    }
    if ($expression->kind eq 'dimension_display') {
        my ($display, $dimension) = @{$expression->arguments};
        my $index = $branch->{dimensions}{Selecto::SQL::_expression_key($dimension)};
        Selecto::Error->throw('invalid_query', 'dimension display requires a rollup dimension') unless defined $index;
        local $self->{_rollup_projection} = 0;
        return _null_dimension($self, sub { $self->_compile_expression($domain, $display, $params) })
            if $index >= $branch->{level};
        return 'MIN(' . $self->_compile_expression($domain, $display, $params) . ')';
    }
    if ($AGGREGATES{$expression->kind}) {
        local $self->{_rollup_projection} = 0;
        return $super->($domain, $expression, $params, $compiled_selections);
    }
    return undef;
}

# A rolled-up dimension is NULL. Adapters whose UNION ALL would otherwise type
# that column from an untyped NULL keep the dimension's type with a NULL of it
# ($self->_rollup_typed_nulls); $compile compiles the dimension itself.
sub _null_dimension {
    my ($self, $compile) = @_;
    return 'NULL' unless $self->can('_rollup_typed_nulls') && $self->_rollup_typed_nulls;
    return 'MIN(CASE WHEN 1 = 0 THEN ' . $compile->() . ' END)';
}

1;

__END__

=head1 NAME

Selecto::SQL::RollupEmulation - grouping-set emulation shared by SQL adapters

=head1 DESCRIPTION

Compiles C<group_by_rollup> as one ordinary C<GROUP BY> branch per grouping
level combined with C<UNION ALL>, with C<GROUPING()> markers and dimension
displays computed per branch. Used by L<Selecto::SQLite>,
L<Selecto::MySQL> and L<Selecto::MariaDB>.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice.

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
