package Selecto::QueryPolicy;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::OperationBudget ();

# Required clauses are installed at compilation, so replacing optional query
# intent after applying a named view cannot remove the authored obligations.
sub apply {
    my ($class, $domain, $query, $limits) = @_;
    my $contract = $domain->contract // {};
    return $query unless grep { exists $contract->{$_} } qw(default_selected required_selected required_order_by required_group_by);
    Selecto::OperationBudget->new(limits => $limits, code => 'invalid_domain')->check_tree(
        {map { exists($contract->{$_}) ? ($_ => $contract->{$_}) : () } qw(default_selected required_selected required_order_by required_group_by)},
        label => 'required query policy');
    Selecto::Error->throw('unsupported_feature', 'retargeted required query clauses require a separate policy profile')
        if $query->retarget_spec;
    my @selected = @{$query->selections};
    if (!@selected && exists $contract->{default_selected}) {
        @selected = map { _field($domain, $_) } @{_list($contract, 'default_selected')};
    }
    my @required = map { _field($domain, $_) } @{_list($contract, 'required_selected')};
    my %seen;
    @selected = grep { !$seen{_key($_)}++ } (@required, @selected);
    my @orders;
    for my $raw (@{_list($contract, 'required_order_by')}) {
        Selecto::Error->throw('invalid_domain', 'required ordering must contain a field and direction')
            unless ref($raw) eq 'ARRAY' && @$raw == 2 && defined($raw->[1]) && !ref($raw->[1]) && $raw->[1] =~ /\A(?:asc|desc)\z/;
        push @orders, [_field($domain, $raw->[0]), $raw->[1]];
    }
    %seen = ();
    @orders = grep { !$seen{_key($_->[0]) . '\0' . $_->[1]}++ } (@orders, @{$query->orders});
    my @groups = map { _field($domain, $_) } @{_list($contract, 'required_group_by')};
    %seen = ();
    @groups = grep { !$seen{_key($_)}++ } (@groups, @{$query->groups});
    return $query->_copy(selections => \@selected, orders => \@orders, groups => \@groups);
}

sub filters {
    my ($class, $domain, $query, $limits) = @_;
    Selecto::Error->throw('invalid_query', 'filter inspection requires a Selecto::Query')
        unless blessed($query) && $query->isa('Selecto::Query');
    Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query')->check_tree($query, label => 'query filters',
        allowed_classes => [qw(Selecto::Query Selecto::Expression Selecto::Domain Selecto::Domain::Association)], allowed_base_classes => ['Selecto::Query']);
    my @filters;
    for my $predicate (grep { defined } $domain->required_predicate, $query->predicate) {
        push @filters, @{_top_filters($predicate)};
    }
    return \@filters;
}

sub _top_filters {
    my ($expression) = @_;
    return [map { @{_top_filters($_)} } @{$expression->arguments->[0]}] if $expression->kind eq 'and' && $expression->{_query_filter_list};
    return [_portable($expression)];
}
sub _portable {
    my ($expression) = @_;
    my ($kind, $args) = ($expression->kind, $expression->arguments);
    return $args->[0] if $kind eq 'field' || $kind eq 'literal';
    return [$kind, [map { _portable($_) } @{$args->[0]}]] if $kind eq 'and' || $kind eq 'or';
    return ['not', _portable($args->[0])] if $kind eq 'not';
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/ && $args->[0]->kind eq 'field' && $args->[1]->kind eq 'literal') {
        my ($field, $value) = map { _portable($_) } @$args;
        return [$field, $kind eq 'eq' ? $value : [$kind eq 'ne' ? 'neq' : $kind, $value]];
    }
    return [$kind, map { blessed($_) && $_->isa('Selecto::Expression') ? _portable($_) : $_ } @$args];
}
sub _list {
    my ($contract, $key) = @_;
    return [] unless exists $contract->{$key};
    Selecto::Error->throw('invalid_domain', "$key must be an array") unless ref($contract->{$key}) eq 'ARRAY';
    return $contract->{$key};
}
sub _field {
    my ($domain, $name) = @_;
    Selecto::Error->throw('invalid_domain', 'required query clauses must contain governed field paths')
        unless defined($name) && !ref($name);
    $domain->resolve($name);
    return Selecto::Expression->field($name);
}
sub _key {
    my ($expression) = @_;
    return $expression->kind . '\0' . ($expression->alias_name // '') . '\0' . JSON::PP->new->canonical->encode($expression->arguments)
        if $expression->kind eq 'field';
    # Other expressions remain separate optional selections. Required policy
    # currently accepts governed field paths only, so it cannot erase them.
    return 'optional:' . Scalar::Util::refaddr($expression);
}

1;

=head1 NAME

Selecto::QueryPolicy - required query clauses and public filter inspection

=head1 METHODS

C<apply($domain, $query)> installs declared default selections when absent and
preserves required selected fields, orderings, and grouping fields at SQL
compilation. This bounded port accepts governed field paths for these clauses;
unsupported expression declarations fail closed. Required filters are retained
by the domain and combined with optional query predicates by the SQL compiler.
C<filters> returns a portable description of those actual expression trees.

=cut
