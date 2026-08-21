package Selecto::QueryLibrary;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed looks_like_number);
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::Expression ();

my @REGISTRIES = qw(segments projections orderings views);

sub library {
    my ($class, $domain) = @_;
    Selecto::Error->throw('invalid_domain', 'query library requires a Selecto::Domain')
        unless blessed($domain) && $domain->isa('Selecto::Domain');
    my $raw = $domain->query_library;
    return { map { $_ => dclone($raw->{$_} // {}) } @REGISTRIES };
}

sub definitions {
    my ($class, $domain, $registry) = @_;
    Selecto::Error->throw('invalid_query_library', 'unknown query library registry')
        unless grep { $_ eq "$registry" } @REGISTRIES;
    return $class->library($domain)->{$registry};
}

sub definition {
    my ($class, $domain, $registry, $id) = @_;
    return dclone(_definition($class->definitions($domain, $registry), $registry, $id));
}

sub view_segments {
    my ($class, $domain, $view_id) = @_;
    my $view = $class->definition($domain, 'views', $view_id);
    my $segments = $view->{segments} // [];
    _array($segments, 'view segments');
    return [map { _id($_, 'segment') } @$segments];
}

sub parameter_specs {
    my ($class, $domain, %selection) = @_;
    my @segments = @{$selection{segments} // []};
    push @segments, @{$class->view_segments($domain, $selection{view})}
        if defined($selection{view}) && "$selection{view}" ne '';
    my $library = $class->library($domain);
    my (%specs, %visiting);
    _collect_segment_parameters($library, $_, \%specs, \%visiting) for @segments;
    return dclone(\%specs);
}

sub normalize_parameters_for_selection {
    my ($class, $domain, $selection, $params) = @_;
    $selection //= {};
    $params //= {};
    Selecto::Error->throw('invalid_query_library', 'query-library selection must be an object')
        unless ref($selection) eq 'HASH';
    Selecto::Error->throw('invalid_query_library', 'query-library parameters must be an object')
        unless ref($params) eq 'HASH';
    my $specs = $class->parameter_specs(
        $domain,
        view => $selection->{view},
        segments => $selection->{segments} // [],
    );
    return _normalize_parameters($specs, $params);
}

sub projection_fields {
    my ($class, $domain, $projection_ids) = @_;
    my @ids = ref($projection_ids) eq 'ARRAY' ? @$projection_ids : ($projection_ids);
    Selecto::Error->throw('invalid_query_library', 'projection names must not be empty') unless @ids;
    my $library = $class->library($domain);
    my (%seen, @fields);
    for my $id (@ids) {
        my $resolved = _resolve_projection($library, $id, []);
        push @fields, grep { !$seen{$_}++ } @{$resolved->{fields}};
    }
    return \@fields;
}

sub ordering_entries {
    my ($class, $domain, $ordering_id) = @_;
    my $spec = $class->definition($domain, 'orderings', $ordering_id);
    my $orders = $spec->{order_by} // [];
    _array($orders, 'ordering order_by');
    return [map { _order($_) } @$orders];
}

sub apply_segment {
    my ($class, $domain, $query, $segment_id, $params) = @_;
    return $class->apply_segments($domain, $query, [$segment_id], $params // {});
}

sub apply_segments {
    my ($class, $domain, $query, $segment_ids, $params) = @_;
    _query($query);
    $params //= {};
    _array($segment_ids, 'query-library segments');
    Selecto::Error->throw('invalid_query_library', 'segment parameters must be an object')
        unless ref($params) eq 'HASH';
    my $library = $class->library($domain);
    my $resolved = {filters => [], parameters => {}, ids => []};
    _merge_segment($resolved, _resolve_segment($library, $_, [])) for @$segment_ids;
    my $values = _normalize_parameters($resolved->{parameters}, $params);
    my @predicates = map { _filter_expression($_, $values) } @{$resolved->{filters}};
    my $predicate = @predicates == 1 ? $predicates[0]
        : @predicates ? Selecto::Expression->all(\@predicates) : undef;
    if ($predicate) {
        my $existing = $query->predicate;
        $query = $query->where($existing
            ? Selecto::Expression->all([$existing, $predicate]) : $predicate);
    }
    my $applied = $query->applied_query_library;
    _append_unique($applied->{segments}, $_) for @{$resolved->{ids}};
    return $query->with_applied_query_library($applied);
}

sub apply_projection {
    my ($class, $domain, $query, $projection_ids) = @_;
    _query($query);
    my @ids = ref($projection_ids) eq 'ARRAY' ? @$projection_ids : ($projection_ids);
    my $library = $class->library($domain);
    my (%seen, @fields, @applied_ids);
    for my $id (@ids) {
        my $resolved = _resolve_projection($library, $id, []);
        push @fields, grep { !$seen{$_}++ } @{$resolved->{fields}};
        _append_unique(\@applied_ids, $_) for @{$resolved->{ids}};
    }
    my $contract = $domain->contract // {};
    my @required = ref($contract->{required_selected}) eq 'ARRAY'
        ? @{$contract->{required_selected}} : ();
    @fields = grep { !$seen{"required\0$_"}++ } (@required, @fields);
    Selecto::Error->throw('invalid_query_library', 'projection does not select any fields')
        unless @fields;
    $domain->resolve($_) for @fields;
    $query = $query->replace_selections(\@fields);
    my $applied = $query->applied_query_library;
    _append_unique($applied->{projections}, $_) for @applied_ids;
    $applied->{projection} = "$ids[-1]";
    return $query->with_applied_query_library($applied);
}

sub apply_ordering {
    my ($class, $domain, $query, $ordering_id) = @_;
    _query($query);
    my $contract = $domain->contract // {};
    my @required = ref($contract->{required_order_by}) eq 'ARRAY'
        ? map { _order($_) } @{$contract->{required_order_by}} : ();
    my @orders = (@required, @{$class->ordering_entries($domain, $ordering_id)});
    my (%seen, @unique);
    for my $order (@orders) {
        my $key = join("\0", @$order);
        push @unique, $order unless $seen{$key}++;
        $domain->resolve($order->[0]);
    }
    $query = $query->replace_orders(\@unique);
    my $applied = $query->applied_query_library;
    $applied->{ordering} = "$ordering_id";
    return $query->with_applied_query_library($applied);
}

sub apply_view {
    my ($class, $domain, $query, $view_id, $params) = @_;
    my $view = $class->definition($domain, 'views', $view_id);
    my @segments = @{$view->{segments} // []};
    $query = $class->apply_segments($domain, $query, \@segments, $params // {});
    $query = $class->apply_projection($domain, $query, $view->{projection})
        if defined($view->{projection}) && "$view->{projection}" ne '';
    $query = $class->apply_ordering($domain, $query, $view->{ordering})
        if defined($view->{ordering}) && "$view->{ordering}" ne '';
    my $applied = $query->applied_query_library;
    _append_unique($applied->{views}, "$view_id");
    return $query->with_applied_query_library($applied);
}

sub _resolve_segment {
    my ($library, $id, $stack) = @_;
    my $key = _id($id, 'segment');
    Selecto::Error->throw('query_library_cycle', 'query-library segment cycle detected')
        if grep { $_ eq $key } @$stack;
    my $spec = _definition($library->{segments}, 'segments', $key);
    my $resolved = {filters => [], parameters => {}, ids => []};
    for my $child (@{$spec->{segments} // []}) {
        _merge_segment($resolved, _resolve_segment($library, $child, [@$stack, $key]));
    }
    for my $group (@{$spec->{segment_groups} // []}) {
        _merge_segment($resolved, _resolve_group($library, $group, [@$stack, $key]));
    }
    push @{$resolved->{filters}}, @{$spec->{filters} // []};
    for my $name (keys %{$spec->{parameters} // {}}) {
        my $parameter_key = _id($name, 'parameter');
        my $candidate = $spec->{parameters}{$name};
        if (exists($resolved->{parameters}{$parameter_key})
            && _canonical($resolved->{parameters}{$parameter_key}) ne _canonical($candidate)) {
            Selecto::Error->throw('invalid_query_library', "conflicting segment parameter $parameter_key");
        }
        $resolved->{parameters}{$parameter_key} = dclone($candidate);
    }
    _append_unique($resolved->{ids}, $key);
    return $resolved;
}

sub _resolve_group {
    my ($library, $group, $stack) = @_;
    Selecto::Error->throw('invalid_query_library', 'segment group must be an object')
        unless ref($group) eq 'HASH';
    my $operator = lc($group->{operator} // '');
    my $ids = $group->{segments} // [];
    _array($ids, 'segment group segments');
    my @parts = map { _resolve_segment($library, $_, $stack) } @$ids;
    my $merged = {filters => [], parameters => {}, ids => []};
    _merge_segment($merged, $_) for @parts;
    my $predicate;
    if ($operator eq 'and') {
        $merged->{filters} = [map { @{$_->{filters}} } @parts];
        return $merged;
    } elsif ($operator eq 'or') {
        if (!@parts || grep { !@{$_->{filters}} } @parts) {
            $merged->{filters} = [];
            return $merged;
        }
        my @operands = map { _filters_operand($_->{filters}) } @parts;
        $predicate = ['or', \@operands];
    } elsif ($operator eq 'not') {
        my @operands = map { _filters_operand($_->{filters}) } @parts;
        Selecto::Error->throw('invalid_query_library', 'not segment groups require one segment')
            unless @operands == 1;
        $predicate = ['not', $operands[0]];
    } elsif ($operator eq 'nor') {
        my @operands = map { _filters_operand($_->{filters}) } @parts;
        $predicate = ['not', ['or', \@operands]];
    } elsif ($operator eq 'xor') {
        my @operands = map { _filters_operand($_->{filters}) } @parts;
        Selecto::Error->throw('invalid_query_library', 'xor segment groups require two segments')
            unless @operands == 2;
        $predicate = ['and', [
            ['or', \@operands], ['not', ['and', \@operands]],
        ]];
    } else {
        Selecto::Error->throw('invalid_query_library', 'unsupported segment group operator');
    }
    $merged->{filters} = [$predicate];
    return $merged;
}

sub _resolve_projection {
    my ($library, $id, $stack) = @_;
    my $key = _id($id, 'projection');
    Selecto::Error->throw('query_library_cycle', 'query-library projection cycle detected')
        if grep { $_ eq $key } @$stack;
    my $spec = _definition($library->{projections}, 'projections', $key);
    my (%seen, @fields, @ids);
    for my $child (@{$spec->{projections} // []}) {
        my $part = _resolve_projection($library, $child, [@$stack, $key]);
        push @fields, grep { !$seen{$_}++ } @{$part->{fields}};
        _append_unique(\@ids, $_) for @{$part->{ids}};
    }
    push @fields, grep { !$seen{$_}++ } map { "$_" } @{$spec->{fields} // []};
    for my $association (@{$spec->{associations} // []}) {
        push @fields, grep { !$seen{$_}++ } @{_association_fields($association, undef)};
    }
    _append_unique(\@ids, $key);
    return {fields => \@fields, ids => \@ids};
}

sub _association_fields {
    my ($association, $parent) = @_;
    Selecto::Error->throw('invalid_query_library', 'projection association must be an object')
        unless ref($association) eq 'HASH';
    my $name = _id($association->{name}, 'association');
    my $path = defined($parent) ? "$parent.$name" : $name;
    my @fields = map { "$path.$_" } @{$association->{fields} // []};
    push @fields, @{_association_fields($_, $path)} for @{$association->{associations} // []};
    return \@fields;
}

sub _collect_segment_parameters {
    my ($library, $id, $specs, $visiting) = @_;
    my $key = _id($id, 'segment');
    Selecto::Error->throw('query_library_cycle', 'query-library segment cycle detected')
        if $visiting->{$key};
    local $visiting->{$key} = 1;
    my $segment = _definition($library->{segments}, 'segments', $key);
    for my $name (keys %{$segment->{parameters} // {}}) {
        my $parameter_key = _id($name, 'parameter');
        my $candidate = $segment->{parameters}{$name};
        Selecto::Error->throw('invalid_query_library', "conflicting segment parameter $parameter_key")
            if exists($specs->{$parameter_key})
                && _canonical($specs->{$parameter_key}) ne _canonical($candidate);
        $specs->{$parameter_key} = dclone($candidate);
    }
    _collect_segment_parameters($library, $_, $specs, $visiting)
        for @{$segment->{segments} // []};
    for my $group (@{$segment->{segment_groups} // []}) {
        next unless ref($group) eq 'HASH' && ref($group->{segments}) eq 'ARRAY';
        _collect_segment_parameters($library, $_, $specs, $visiting) for @{$group->{segments}};
    }
}

sub _normalize_parameters {
    my ($specs, $params) = @_;
    my %known = map { $_ => 1 } keys %$specs;
    my @unknown = sort grep { !$known{$_} } keys %$params;
    Selecto::Error->throw('invalid_query_library', 'unknown segment parameters', {names => \@unknown})
        if @unknown;
    my %values;
    for my $id (keys %$specs) {
        my $spec = $specs->{$id};
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be an object")
            unless ref($spec) eq 'HASH';
        my $present = exists($params->{$id});
        my $value = $present ? $params->{$id} : $spec->{default};
        if (!defined($value) && ($spec->{required} // !exists($spec->{default}))) {
            Selecto::Error->throw('invalid_query_library', "missing required segment parameter $id");
        }
        $values{$id} = defined($value)
            ? _cast_parameter($id, $spec->{type}, $value)
            : undef;
    }
    return \%values;
}

sub _cast_parameter {
    my ($id, $type, $value) = @_;
    $type = lc(defined($type) && !ref($type) ? "$type" : '');
    if ($type eq 'string') {
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be string")
            if ref($value);
        return "$value";
    }
    if ($type eq 'integer') {
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be integer")
            unless !ref($value) && "$value" =~ /\A[+-]?\d+\z/;
        return 0 + $value;
    }
    if ($type eq 'float' || $type eq 'decimal') {
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be $type")
            unless !ref($value) && looks_like_number($value);
        return "$value";
    }
    if ($type eq 'boolean') {
        return 1 if !ref($value) && "$value" =~ /\A(?:1|true|yes|on)\z/i;
        return 0 if !ref($value) && "$value" =~ /\A(?:0|false|no|off)\z/i;
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be boolean");
    }
    if ($type eq 'date') {
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be date")
            unless !ref($value) && "$value" =~ /\A\d{4}-\d{2}-\d{2}\z/;
    }
    if ($type =~ /\A(?:datetime|naive_datetime|utc_datetime)\z/) {
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be $type")
            unless !ref($value) && "$value" =~ /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;
    }
    if ($type eq 'uuid') {
        Selecto::Error->throw('invalid_query_library', "segment parameter $id must be uuid")
            unless !ref($value) && "$value" =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i;
    }
    Selecto::Error->throw('invalid_query_library', 'segment parameter type must be a non-empty string')
        unless length($type);
    return $value;
}

sub _filter_expression {
    my ($filter, $values) = @_;
    Selecto::Error->throw('invalid_query_library', 'segment filters must be arrays')
        unless ref($filter) eq 'ARRAY' && @$filter;
    my ($operator, @args) = @$filter;
    $operator = lc("$operator");
    if ($operator eq 'and' || $operator eq 'or') {
        my $items = @args == 1 && ref($args[0]) eq 'ARRAY' ? $args[0] : \@args;
        my @expressions = map { _filter_expression($_, $values) } @$items;
        return $operator eq 'and'
            ? Selecto::Expression->all(\@expressions)
            : Selecto::Expression->any(\@expressions);
    }
    return Selecto::Expression->not(_filter_expression($args[0], $values)) if $operator eq 'not';
    my ($field, $raw_value, $raw_end) = @args;
    my $value = _substitute($raw_value, $values);
    return Selecto::Expression->is_null($field) if $operator eq 'is_null';
    return Selecto::Expression->not_null($field) if $operator eq 'not_null';
    return Selecto::Expression->in($field, $value) if $operator eq 'in';
    return Selecto::Expression->between($field, $value, _substitute($raw_end, $values))
        if $operator eq 'between';
    Selecto::Error->throw('invalid_query_library', "unsupported segment filter operator $operator")
        unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/;
    return Selecto::Expression->can($operator)->('Selecto::Expression', $field, $value);
}

sub _substitute {
    my ($value, $params) = @_;
    if (ref($value) eq 'ARRAY' && @$value == 2 && "$value->[0]" eq 'param') {
        my $id = "$value->[1]";
        Selecto::Error->throw('invalid_query_library', "missing resolved segment parameter $id")
            unless exists($params->{$id});
        return $params->{$id};
    }
    if (ref($value) eq 'ARRAY' && @$value == 2 && "$value->[0]" eq 'field') {
        my $field = "$value->[1]";
        Selecto::Error->throw('invalid_query_library', 'field references require a non-empty field name')
            unless length($field);
        return Selecto::Expression->field($field);
    }
    return [map { _substitute($_, $params) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => _substitute($value->{$_}, $params)) } keys %$value}
        if ref($value) eq 'HASH';
    return $value;
}

sub _filters_operand {
    my ($filters) = @_;
    Selecto::Error->throw('invalid_query_library', 'boolean segment references an unconstrained segment')
        unless @$filters;
    return $filters->[0] if @$filters == 1;
    return ['and', [@$filters]];
}

sub _merge_segment {
    my ($target, $source) = @_;
    push @{$target->{filters}}, @{$source->{filters}};
    for my $name (keys %{$source->{parameters}}) {
        Selecto::Error->throw('invalid_query_library', "conflicting segment parameter $name")
            if exists($target->{parameters}{$name})
                && _canonical($target->{parameters}{$name}) ne _canonical($source->{parameters}{$name});
        $target->{parameters}{$name} = dclone($source->{parameters}{$name});
    }
    _append_unique($target->{ids}, $_) for @{$source->{ids}};
}

sub _definition {
    my ($registry, $kind, $id) = @_;
    my $key = _id($id, $kind);
    my ($stored) = grep { "$_" eq $key } keys %$registry;
    Selecto::Error->throw('unknown_query_library_definition', "unknown query-library $kind $key")
        unless defined($stored) && ref($registry->{$stored}) eq 'HASH';
    return $registry->{$stored};
}

sub _order {
    my ($order) = @_;
    Selecto::Error->throw('invalid_query_library', 'ordering entries must contain field and direction')
        unless ref($order) eq 'ARRAY' && @$order == 2;
    my ($field, $direction) = @$order;
    $direction = lc("$direction");
    Selecto::Error->throw('invalid_query_library', 'ordering direction must be asc or desc')
        unless $direction eq 'asc' || $direction eq 'desc';
    return ["$field", $direction];
}

sub _query {
    my ($query) = @_;
    Selecto::Error->throw('invalid_query', 'query-library application requires a Selecto::Query')
        unless blessed($query) && $query->isa('Selecto::Query');
}

sub _array {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_query_library', "$label must be an array")
        unless ref($value) eq 'ARRAY';
}

sub _id {
    my ($value, $kind) = @_;
    Selecto::Error->throw('invalid_query_library', "$kind name must be a non-empty string")
        if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

sub _append_unique {
    my ($values, $value) = @_;
    push @$values, "$value" unless grep { $_ eq "$value" } @$values;
}

sub _canonical {
    my ($value) = @_;
    require JSON::PP;
    return JSON::PP->new->canonical(1)->encode($value);
}

1;
