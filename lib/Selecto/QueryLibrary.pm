package Selecto::QueryLibrary;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Limits ();

my @REGISTRIES = qw(segments projections orderings views);

sub library {
    my ($class, $domain) = @_;
    Selecto::Error->throw('invalid_domain', 'query library requires a Selecto::Domain')
        unless blessed($domain) && $domain->isa('Selecto::Domain');
    my $raw = $domain->query_library;
    return {
        (map { $_ => dclone($raw->{$_} // {}) } @REGISTRIES),
        segment_picker_groups => dclone($raw->{segment_picker_groups} // {}),
    };
}

sub segment_picker_groups {
    my ($class, $domain) = @_;
    my $library = $class->library($domain);
    my $groups = $library->{segment_picker_groups};
    Selecto::Error->throw('invalid_query_library', 'segment picker groups must be an object')
        unless ref($groups) eq 'HASH';
    my %used;
    my @result;
    for my $id (sort keys %$groups) {
        Selecto::Error->throw('invalid_query_library', 'segment picker group ID must use letters, digits, or underscores')
            unless $id =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
        my $group = $groups->{$id};
        Selecto::Error->throw('invalid_query_library', "segment picker group $id must be an object")
            unless ref($group) eq 'HASH';
        my $label = $group->{label};
        Selecto::Error->throw('invalid_query_library', "segment picker group $id needs a label")
            unless defined($label) && !ref($label) && "$label" =~ /\S/;
        my $choices = $group->{choices};
        Selecto::Error->throw('invalid_query_library', "segment picker group $id needs at least two choices")
            unless ref($choices) eq 'ARRAY' && @$choices >= 2;
        my @choices;
        for my $choice (@$choices) {
            Selecto::Error->throw('invalid_query_library', "segment picker group $id choices must be objects")
                unless ref($choice) eq 'HASH';
            my $segment = _id($choice->{segment}, 'segment picker choice');
            _definition($library->{segments}, 'segments', $segment);
            Selecto::Error->throw('invalid_query_library', "segment $segment is in more than one picker group")
                if $used{$segment}++;
            my $choice_label = $choice->{label};
            Selecto::Error->throw('invalid_query_library', "segment picker choice $segment needs a label")
                unless defined($choice_label) && !ref($choice_label) && "$choice_label" =~ /\S/;
            push @choices, {segment => $segment, label => "$choice_label"};
        }
        my $off_label = $group->{off_label} // 'Off';
        Selecto::Error->throw('invalid_query_library', "segment picker group $id needs an off label")
            unless !ref($off_label) && "$off_label" =~ /\S/;
        push @result, {
            id => $id, label => "$label", description => $group->{description} // '',
            off_label => "$off_label", choices => \@choices,
        };
    }
    return \@result;
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
    my ($class, $domain, $selection, $params, $limits) = @_;
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
    return _normalize_parameters($specs, $params, $limits);
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
    my ($class, $domain, $query, $segment_id, $params, $limits) = @_;
    return $class->apply_segments($domain, $query, [$segment_id], $params // {}, $limits);
}

sub apply_segments {
    my ($class, $domain, $query, $segment_ids, $params, $limits) = @_;
    $limits //= Selecto::Limits->new;
    Selecto::Error->throw('invalid_limits', 'query library limits must be a Selecto::Limits')
        unless blessed($limits) && $limits->isa('Selecto::Limits');
    _query($query);
    $params //= {};
    _array($segment_ids, 'query-library segments');
    Selecto::Error->throw('invalid_query_library', 'segment parameters must be an object')
        unless ref($params) eq 'HASH';
    my $library = $class->library($domain);
    my $resolved = {filters => [], parameters => {}, ids => []};
    _merge_segment($resolved, _resolve_segment($library, $_, [])) for @$segment_ids;
    my %selected = map { $_ => 1 } (
        @{$query->applied_query_library->{segments} // []}, @{$resolved->{ids}},
    );
    for my $group (@{$class->segment_picker_groups($domain)}) {
        my @chosen = grep { $selected{$_->{segment}} } @{$group->{choices}};
        Selecto::Error->throw(
            'invalid_query_library', "segment picker group $group->{label} allows only one choice",
            {group => $group->{id}, segments => [map { $_->{segment} } @chosen]},
        ) if @chosen > 1;
    }
    my $values = _normalize_parameters($resolved->{parameters}, $params, $limits);
    my @predicates = map { _filter_expression($_, $values, $limits) } @{$resolved->{filters}};
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
    my ($class, $domain, $query, $view_id, $params, $limits) = @_;
    my $view = $class->definition($domain, 'views', $view_id);
    my @segments = @{$view->{segments} // []};
    $query = $class->apply_segments($domain, $query, \@segments, $params // {}, $limits);
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
    my ($specs, $params, $limits) = @_;
    $limits //= Selecto::Limits->new;
    Selecto::Error->throw('invalid_limits', 'query library limits must be a Selecto::Limits')
        unless blessed($limits) && $limits->isa('Selecto::Limits');
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
        if (ref($value) eq 'ARRAY') {
            _bounded_members($value, $limits);
        } elsif (!ref($value)) {
            $limits->check_bytes('max_parameter_bytes', $value,
                'invalid_query_library', 'segment parameter');
        }
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
        return $value ? 1 : 0 if JSON::PP::is_bool($value);
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
    my ($filter, $values, $limits) = @_;
    Selecto::Error->throw('invalid_query_library', 'segment filters must be arrays')
        unless ref($filter) eq 'ARRAY' && @$filter;
    my ($operator, @args) = @$filter;
    $operator = lc("$operator");
    if ($operator eq 'and' || $operator eq 'or') {
        my $items = @args == 1 && ref($args[0]) eq 'ARRAY' ? $args[0] : \@args;
        my @expressions = map { _filter_expression($_, $values, $limits) } @$items;
        return $operator eq 'and'
            ? Selecto::Expression->all(\@expressions)
            : Selecto::Expression->any(\@expressions);
    }
    return Selecto::Expression->not(_filter_expression($args[0], $values, $limits)) if $operator eq 'not';
    my ($field, $raw_value, $raw_end) = @args;
    my $value = _substitute($raw_value, $values);
    return Selecto::Expression->is_null($field) if $operator eq 'is_null';
    return Selecto::Expression->not_null($field) if $operator eq 'not_null';
    if ($operator eq 'in') {
        _bounded_members($value, $limits);
        return Selecto::Expression->in($field, $value);
    }
    if ($operator eq 'csv_in') {
        Selecto::Error->throw('invalid_query_library', 'csv_in requires a scalar value')
            if ref($value);
        $limits->check_bytes('max_parameter_bytes', $value,
            'invalid_query_library', 'csv_in input');
        my @values;
        # Input bytes are bounded before tokenization, and list growth stops at
        # the first excess member instead of materializing a full split.
        my $text = defined($value) ? "$value" : '';
        while ($text =~ /([^,]*)(?:,|\z)/g) {
            my $item = $1;
            $item =~ s/\A\s+|\s+\z//g;
            next unless length $item;
            $limits->check_bytes('max_value_bytes', $item, 'invalid_query_library', 'csv_in item');
            $limits->check_count('max_filter_values', @values + 1, 'invalid_query_library', 'csv_in values');
            push @values, $item;
        }
        Selecto::Error->throw('invalid_query_library', 'csv_in requires at least one value')
            unless @values;
        return Selecto::Expression->in($field, \@values);
    }
    return Selecto::Expression->between($field, $value, _substitute($raw_end, $values))
        if $operator eq 'between';
    return Selecto::Expression->starts_with($field, $value)
        if $operator eq 'starts_with';
    Selecto::Error->throw('invalid_query_library', "unsupported segment filter operator $operator")
        unless $operator =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/;
    return Selecto::Expression->can($operator)->('Selecto::Expression', $field, $value);
}

sub _bounded_members {
    my ($values, $limits) = @_;
    Selecto::Error->throw('invalid_query_library', 'in requires a non-empty scalar list')
        unless ref($values) eq 'ARRAY' && @$values;
    $limits->check_count('max_filter_values', scalar(@$values), 'invalid_query_library', 'in values');
    my $total = 0;
    for my $value (@$values) {
        $total += $limits->check_bytes('max_value_bytes', JSON::PP::is_bool($value) ? ($value ? 1 : 0) : $value,
            'invalid_query_library', 'in item');
        $limits->check_count('max_parameter_bytes', $total, 'invalid_query_library', 'in bytes');
    }
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

__END__

=head1 NAME

Selecto::QueryLibrary - named segments, projections, orderings and views

=head1 SYNOPSIS

  my $domain = Selecto::Domain->new(
      name   => 'Products',
      table  => 'products',
      fields => {id => 'integer', name => 'string', stock => 'integer'},
      query_library => {
          segments => {
              low_stock => {
                  filters    => [['lt', 'stock', ['param', 'threshold']]],
                  parameters => {threshold => {type => 'integer', required => 1}},
              },
          },
          projections => {summary => {fields => [qw(id name stock)]}},
          orderings   => {stock_first => {order_by => [['stock', 'asc']]}},
          views       => {
              replenishment => {
                  segments   => ['low_stock'],
                  projection => 'summary',
                  ordering   => 'stock_first',
              },
          },
      },
  );
  my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

  my $query = $engine->apply_view($engine->query, 'replenishment', {threshold => '8'});
  my $rows  = $engine->all($query)->{rows};
  my $applied = $query->applied_query_library;
  # {segments => ['low_stock'], projection => 'summary', ordering => 'stock_first',
  #  views => ['replenishment'], projections => ['summary']}

=head1 DESCRIPTION

A domain can own reusable query intent under C<query_library>. Definitions
are data, not SQL: segments use the portable filter AST, parameters are
typed and always bound, and every field is resolved against the domain.
Applying definitions records their names on the query
(C<applied_query_library>) so saved views and API responses can report what
was used.

Query-library C<capability> values are descriptive metadata only; they do
not replace application authorization or database row-level security.

The engine methods C<apply_segment>, C<apply_segments>,
C<apply_projection>, C<apply_ordering> and C<apply_view> delegate to the
class methods below with the engine's domain.

=head1 DEFINITIONS

=over 4

=item C<segments>

  segments => {
      active    => {filters => [['eq', 'status', 'A']]},
      named     => {filters => [['starts_with', 'name', ['param', 'prefix']]],
                    parameters => {prefix => {type => 'string', required => 1}}},
      active_or_new => {segment_groups => [{operator => 'or', segments => ['active', 'new']}]},
      composite => {segments => ['active', 'named']},
  }

C<filters> is a list of filter ASTs (see
L<Selecto::Expression/from_filter_ast>), ANDed together, where
C<['param', NAME]> stands for a parameter value. C<segments> includes other
segments. C<segment_groups> combine segments with C<and>, C<or>, C<not> (one
segment), C<nor> or C<xor> (exactly two). Cycles are rejected.

Parameter types C<string>, C<integer>, C<decimal>, C<float>, C<boolean>,
C<date>, C<datetime>, C<naive_datetime>, C<utc_datetime> and C<uuid> are
validated; other type names pass values through for the host to interpret.
Parameters are required unless they declare a C<default>.

=item C<projections>

C<< {fields => [...], projections => [...], associations => [{name => 'customer', fields => [...]}]} >>.
Associations expand to dotted field paths. The domain's
C<required_selected> fields are always included.

=item C<orderings>

C<< {order_by => [['field', 'asc'], ...]} >>, after the domain's
C<required_order_by>.

=item C<views>

C<< {segments => [...], projection => ..., ordering => ...} >>.

=item C<segment_picker_groups>

  segment_picker_groups => {
      pdf_sent => {label => 'PDF sent', off_label => 'Either',
          choices => [{segment => 'pdf_sent', label => 'Yes'},
                      {segment => 'pdf_not_sent', label => 'No'}]},
  }

Mutually exclusive segments for user interfaces. At most one choice of a
group may be applied, including through views.

=back

=head1 CLASS METHODS

All take the domain as their first argument.

=over 4

=item C<library($domain)>

The four registries plus C<segment_picker_groups>, as copies.

=item C<definitions($domain, $registry)>, C<definition($domain, $registry, $id)>

One registry (C<segments>, C<projections>, C<orderings> or C<views>), or one
definition. Unknown names throw C<invalid_query_library>.

=item C<segment_picker_groups($domain)>

The validated picker groups as a sorted list.

=item C<apply_segment($domain, $query, $id, \%params)>, C<apply_segments($domain, $query, \@ids, \%params)>

AND the segments' filters into the query's predicate. The combined parameter
contract is validated before the query changes.

=item C<apply_projection($domain, $query, $id_or_ids)>

Replace the selections.

=item C<apply_ordering($domain, $query, $id)>

Replace the orderings.

=item C<apply_view($domain, $query, $id, \%params)>

Apply a view's segments, projection and ordering.

=item C<view_segments>, C<parameter_specs>, C<normalize_parameters_for_selection>, C<projection_fields>, C<ordering_entries>

Introspection helpers for user interfaces and API handlers.

=back

=head1 ERRORS

C<invalid_query_library> and C<query_library_cycle>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Engine>, L<Selecto::API::EngineHandler>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
