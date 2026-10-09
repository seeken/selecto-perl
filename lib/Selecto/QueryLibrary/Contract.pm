package Selecto::QueryLibrary::Contract;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Selecto::QueryLibrary ();
use Selecto::OperationBudget ();
use Selecto::Limits ();

sub validate {
    my ($class, $domain, $limits) = @_;
    my $library = Selecto::QueryLibrary->library($domain);
    $limits //= Selecto::Limits->new;
    return {valid => JSON::PP::true, errors => []} unless grep { keys %{$library->{$_}} } qw(segments projections orderings views segment_picker_groups);
    my $work = Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query_library');
    Selecto::OperationBudget->new(limits => $limits // Selecto::Limits->new, code => 'invalid_query_library')
        ->check_tree($library, label => 'query library');
    my @errors;
    for my $registry (qw(segments projections orderings views)) {
        for my $id (sort keys %{$library->{$registry}}) {
            my $spec = $library->{$registry}{$id};
            my $path = ['query_library', $registry, $id];
            unless (ref($spec) eq 'HASH') { _error(\@errors, 'invalid_query_library', $path); next }
            my %lists = map { $_ => 1 } $registry eq 'segments' ? qw(filters segments segment_groups)
                : $registry eq 'projections' ? qw(fields projections associations)
                : $registry eq 'orderings' ? qw(order_by) : qw(segments);
            my $shape_ok = 1;
            for my $key (sort keys %lists) {
                next unless exists $spec->{$key};
                unless (ref($spec->{$key}) eq 'ARRAY') { _error(\@errors, 'invalid_query_library', [@$path, $key]); $shape_ok = 0 }
            }
            if ($registry eq 'segments' && exists($spec->{parameters}) && ref($spec->{parameters}) ne 'HASH') {
                _error(\@errors, 'invalid_segment_parameter', [@$path, 'parameters']); $shape_ok = 0;
            }
            next unless $shape_ok;
            if ($registry eq 'segments') {
                for my $name (sort keys %{$spec->{parameters} // {}}) {
                    my $parameter = $spec->{parameters}{$name};
                    _error(\@errors, 'invalid_segment_parameter', [@$path, 'parameters', $name])
                        unless ref($parameter) eq 'HASH' && defined($parameter->{type}) && !ref($parameter->{type}) && $parameter->{type} =~ /\S/ &&
                            (!exists($parameter->{required}) || JSON::PP::is_bool($parameter->{required}) ||
                                defined($parameter->{required}) && !ref($parameter->{required}) && $parameter->{required} =~ /\A[01]\z/);
                }
                my $parameters = _parameter_ids($library->{segments}, $id, {}, $limits, 0, $work);
                _filter_fields($domain, $_, [@$path, 'filters'], \@errors, $parameters) for @{$spec->{filters} // []};
                _references($library->{segments}, $spec->{segments} // [], [@$path, 'segments'], \@errors);
                for my $group (@{$spec->{segment_groups} // []}) {
                    my $valid = ref($group) eq 'HASH' && defined($group->{operator}) && !ref($group->{operator})
                        && $group->{operator} =~ /\A(?:and|or|not|nor|xor)\z/ && ref($group->{segments}) eq 'ARRAY';
                    if ($valid) {
                        my %ids; $valid = @{$group->{segments}} && !grep { !defined($_) || ref($_) } @{$group->{segments}};
                        if ($valid) { $ids{$_}++ for @{$group->{segments}} }
                        $valid = 0 if $group->{operator} eq 'not' && @{$group->{segments}} != 1;
                        $valid = 0 if $group->{operator} eq 'xor' && (@{$group->{segments}} != 2 || keys(%ids) != 2);
                    }
                    unless ($valid) { _error(\@errors, 'invalid_query_segment_group', [@$path, 'segment_groups']); next }
                    _references($library->{segments}, $group->{segments}, [@$path, 'segment_groups'], \@errors);
                }
            } elsif ($registry eq 'projections') {
                _field($domain, $_, [@$path, 'fields'], \@errors) for @{$spec->{fields} // []};
                _references($library->{projections}, $spec->{projections} // [], [@$path, 'projections'], \@errors);
                _association($domain, $_, undef, [@$path, 'associations'], \@errors) for @{$spec->{associations} // []};
            } elsif ($registry eq 'orderings') {
                for my $entry (@{$spec->{order_by} // []}) {
                    if (ref($entry) eq 'ARRAY' && @$entry == 2 && defined($entry->[1]) && !ref($entry->[1]) && $entry->[1] =~ /\A(?:asc|desc)\z/) {
                        _field($domain, $entry->[0], [@$path, 'order_by'], \@errors);
                    } else { _error(\@errors, 'invalid_query_library', [@$path, 'order_by']) }
                }
            } else {
                _references($library->{segments}, $spec->{segments} // [], [@$path, 'segments'], \@errors);
                _references($library->{projections}, [$spec->{projection}], [@$path, 'projection'], \@errors) if exists $spec->{projection};
                _references($library->{orderings}, [$spec->{ordering}], [@$path, 'ordering'], \@errors) if exists $spec->{ordering};
            }
        }
    }
    for my $registry (qw(segments projections)) {
        for my $id (sort keys %{$library->{$registry}}) {
            my $cycle = _cycle($library->{$registry}, $registry, $id, [], {}, $limits, $work);
            _error(\@errors, $registry eq 'segments' ? 'query_segment_cycle' : 'query_projection_cycle',
                ['query_library', $registry, $id]) if $cycle;
        }
    }
    my %seen;
    @errors = grep { !$seen{JSON::PP->new->canonical->encode($_)}++ } @errors;
    return {valid => @errors ? JSON::PP::false : JSON::PP::true, errors => \@errors};
}

sub _cycle {
    my ($registry, $kind, $id, $stack, $done, $limits, $work) = @_;
    $work->consume_count('max_expression_nodes', 1, label => 'query-library reference work');
    $limits->check_count('max_expression_depth', scalar(@$stack), 'invalid_query_library', 'query-library reference depth');
    return 0 unless defined($id) && !ref($id) && ref($registry->{$id}) eq 'HASH';
    return 1 if grep { $_ eq $id } @$stack;
    return 0 if $done->{$id};
    my $spec = $registry->{$id};
    my @next = ref($spec->{$kind}) eq 'ARRAY' ? @{$spec->{$kind}} : ();
    if ($kind eq 'segments' && ref($spec->{segment_groups}) eq 'ARRAY') {
        push @next, @{$_->{segments}} for grep { ref($_) eq 'HASH' && ref($_->{segments}) eq 'ARRAY' } @{$spec->{segment_groups}};
    }
    return 1 if grep { _cycle($registry, $kind, $_, [@$stack, $id], $done, $limits, $work) } @next;
    $done->{$id} = 1;
    return 0;
}
sub _parameter_ids {
    my ($registry, $id, $seen, $limits, $depth, $work) = @_;
    $work->consume_count('max_expression_nodes', 1, label => 'query-library reference work');
    $limits->check_count('max_expression_depth', $depth, 'invalid_query_library', 'segment parameter reference depth');
    return {} unless defined($id) && !ref($id) && ref($registry->{$id}) eq 'HASH' && !$seen->{$id}++;
    my $spec = $registry->{$id};
    my %parameters = ref($spec->{parameters}) eq 'HASH' ? map { $_ => 1 } keys %{$spec->{parameters}} : ();
    my @next = ref($spec->{segments}) eq 'ARRAY' ? @{$spec->{segments}} : ();
    if (ref($spec->{segment_groups}) eq 'ARRAY') {
        push @next, @{$_->{segments}} for grep { ref($_) eq 'HASH' && ref($_->{segments}) eq 'ARRAY' } @{$spec->{segment_groups}};
    }
    for my $child (@next) {
        my $more = _parameter_ids($registry, $child, $seen, $limits, $depth + 1, $work);
        @parameters{keys %$more} = values %$more;
    }
    return \%parameters;
}
sub _references {
    my ($registry, $references, $path, $errors) = @_;
    for my $id (@$references) {
        _error($errors, 'query_definition_not_found', $path)
            unless defined($id) && !ref($id) && ref($registry->{$id}) eq 'HASH';
    }
}
sub _field {
    my ($domain, $field, $path, $errors) = @_;
    my $valid = defined($field) && !ref($field) && eval { $domain->resolve($field); 1 };
    _error($errors, 'query_field_not_found', $path) unless $valid;
}
sub _filter_fields {
    my ($domain, $filter, $path, $errors, $parameters) = @_;
    unless (ref($filter) eq 'ARRAY' && @$filter && defined($filter->[0]) && !ref($filter->[0])) {
        _error($errors, 'invalid_query_library', $path); return;
    }
    my ($operator, @args) = @$filter;
    if ($operator eq 'and' || $operator eq 'or') {
        my $children = @args == 1 && ref($args[0]) eq 'ARRAY' ? $args[0] : \@args;
        unless (@$children) { _error($errors, 'invalid_query_library', $path); return }
        _filter_fields($domain, $_, $path, $errors, $parameters) for @$children;
    } elsif ($operator eq 'not') {
        unless (@args == 1) { _error($errors, 'invalid_query_library', $path); return }
        _filter_fields($domain, $args[0], $path, $errors, $parameters);
    } else {
        my $arity = $operator =~ /\A(?:is_null|not_null)\z/ ? 1
            : $operator eq 'between' ? 3
            : $operator =~ /\A(?:eq|ne|gt|gte|lt|lte|in|csv_in|starts_with)\z/ ? 2 : 0;
        unless ($arity && @args == $arity) { _error($errors, 'invalid_query_library', $path); return }
        _field($domain, $args[0], $path, $errors);
        _operand($domain, $args[$_], $path, $errors, $parameters) for 1 .. $#args;
    }
}
sub _operand {
    my ($domain, $value, $path, $errors, $parameters) = @_;
    return unless ref($value) && !JSON::PP::is_bool($value);
    if (ref($value) eq 'ARRAY') {
        if (@$value == 2 && defined($value->[0]) && !ref($value->[0]) && $value->[0] eq 'field') {
            _field($domain, $value->[1], $path, $errors);
        } elsif (@$value == 2 && defined($value->[0]) && !ref($value->[0]) && $value->[0] eq 'param') {
            _error($errors, 'invalid_segment_parameter', $path) unless defined($value->[1]) && !ref($value->[1]) && exists($parameters->{$value->[1]});
        } else { _operand($domain, $_, $path, $errors, $parameters) for @$value }
    } else { _error($errors, 'invalid_query_library', $path) }
}
sub _association {
    my ($domain, $entry, $parent, $path, $errors) = @_;
    unless (ref($entry) eq 'HASH' && defined($entry->{name}) && !ref($entry->{name}) &&
        (!exists($entry->{fields}) || ref($entry->{fields}) eq 'ARRAY') &&
        (!exists($entry->{associations}) || ref($entry->{associations}) eq 'ARRAY')) {
        _error($errors, 'invalid_query_projection_association', $path); return;
    }
    my $name = defined($parent) ? "$parent.$entry->{name}" : $entry->{name};
    _error($errors, 'query_field_not_found', $path) unless eval { $domain->resolve_association($name); 1 };
    _field($domain, "$name.$_", $path, $errors) for @{$entry->{fields} // []};
    _association($domain, $_, $name, $path, $errors) for @{$entry->{associations} // []};
}
sub _error { push @{$_[0]}, {code => $_[1], path => [@{$_[2]}], message => 'invalid query-library declaration'} }

1;


=head1 NAME

Selecto::QueryLibrary::Contract - bounded query-library declaration validation

=head1 DESCRIPTION

C<validate($domain, $limits)> returns C<valid> and structured C<errors> with
codes and declaration paths. Domain parsing and engine configuration call this
validation before any SQL. It checks definition shapes and references, governed
fields, segment operators and arity, parameter metadata, and reference cycles.
Tree size, depth and reference work use trusted C<Selecto::Limits>. Validation
never executes metadata callbacks. This port accepts field paths and scalar
collection fields; arbitrary selection expressions are not library declarations.

=cut
