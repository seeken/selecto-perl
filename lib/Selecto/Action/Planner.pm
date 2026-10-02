package Selecto::Action::Planner;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Action::Plan ();
use Selecto::Domain ();
use Selecto::Error ();
use Selecto::Limits ();
use Selecto::Write::ConflictTarget ();
use Selecto::Write::Expression ();

sub plan {
    my ($class, $input, $intent, %options) = @_;
    my $contract = _contract($input);
    _object($intent, 'action intent');
    my $action_id = _id($intent->{action});
    Selecto::Error->throw('invalid_action_intent', 'action intent must include an action id') if $action_id eq '';

    my $actions = $contract->{actions} // {};
    _object($actions, 'domain actions');
    my $action = $actions->{$action_id};
    Selecto::Error->throw('invalid_action_intent', 'action is not exposed by this domain contract', { action => $action_id })
        unless ref($action) eq 'HASH';
    my $limits = _limits($options{limits});
    _check_target_limit($action, $intent->{target}, $limits);

    my ($inputs, $variant, $execution) = _select_variant($action, $intent->{inputs});
    my ($execution_case, $selected_execution) = _select_execution_case($execution, $inputs);
    $execution = $selected_execution;
    _object($execution, 'action execution');
    Selecto::Error->throw('unsupported_action_executor', 'action execution must use the updato executor')
        unless _id($execution->{kind}) eq 'updato';
    my $operation = _id($execution->{operation});
    Selecto::Error->throw('unsupported_action_operation', 'action operation is not portable')
        unless $operation =~ /\A(?:insert|update|upsert|delete)\z/;

    my $writes = $contract->{writes} // {};
    my $operation_spec = $writes->{operations}{$operation};
    Selecto::Error->throw('action_operation_not_enabled', 'action operation is not enabled by the write contract')
        unless ref($operation_spec) eq 'HASH' && $operation_spec->{enabled};

    my $changes = _resolve_template($execution->{set} // {}, $inputs);
    _object($changes, 'action changes');
    my %system_values;
    for my $field (keys %$changes) {
        my $value = $changes->{$field};
        my $type = $contract->{source}{columns}{$field}{type} // '';
        if (blessed($value) && $value->isa('Selecto::Write::Expression')
            && $value->kind eq 'current_timestamp') {
            Selecto::Error->throw('invalid_action_changes', 'system-now requires a temporal field', {field => $field})
                unless $type =~ /\A(?:utc_datetime|naive_datetime|datetime|timestamp|date)\z/;
            $system_values{$field} = 'now';
            $changes->{$field} = ['system', 'now'];
        } elsif (ref($value) && !JSON::PP::is_bool($value)) {
            Selecto::Error->throw('invalid_action_changes', 'structured input requires a JSON field', {field => $field})
                unless $type =~ /\A(?:json|jsonb|map)\z/;
        }
    }
    _validate_changes($writes, $changes, $operation);
    my $collection_patches = _collection_patches($execution, $inputs);

    # Guards cannot apply to a create; report that before the target shape.
    _declared_preconditions($contract, $action, $operation) if $operation eq 'insert' || $operation eq 'upsert';
    my ($scope, $filters, $expected, $target) = $operation eq 'insert' || $operation eq 'upsert'
        ? _create_target($action, $intent->{target})
        : _target($contract, $action, $operation_spec, $intent->{target}, $limits);
    my ($transition, $preconditions) = _transition($writes, $action, $changes);
    $preconditions = [@{_declared_preconditions($contract, $action, $operation)}, @$preconditions];
    push @$filters, map {
        ($_->{comparator} // 'eq') eq 'eq' ? [$_->{field}, $_->{value}]
            : [$_->{field}, $_->{comparator}, $_->{value}]
    } @$preconditions;

    my $capability = defined($action->{capability}) ? "$action->{capability}" : undef;
    _validate_capability($contract, $capability, $action_id, $operation);

    my $conflict_target;
    if ($operation eq 'upsert') {
        my $declared = $operation_spec->{conflict_targets};
        my $target = $execution->{conflict_target};
        $target //= $declared->[0] if ref($declared) eq 'ARRAY' && @$declared == 1;
        $conflict_target = Selecto::Write::ConflictTarget->validate(
            $writes, $target, $contract->{source}{columns});
    }

    return Selecto::Action::Plan->new(
        action               => $action_id,
        type                 => _id($action->{type}),
        operation            => $operation,
        scope                => $scope,
        capability           => $capability,
        target               => $target,
        filters              => $filters,
        changes              => $changes,
        expected_cardinality => $expected,
        transition           => $transition,
        preconditions        => $preconditions,
        inputs               => _display_values($inputs),
        variant              => $variant,
        execution_case       => $execution_case,
        collection_patches   => $collection_patches,
        conflict_target      => $conflict_target,
        system_values        => \%system_values,
    );
}

sub _limits {
    my ($limits) = @_;
    $limits //= Selecto::Limits->new;
    Selecto::Error->throw('invalid_limits', 'action limits must be a Selecto::Limits object')
        unless blessed($limits) && $limits->isa('Selecto::Limits');
    return $limits;
}

sub _maximum_targets {
    my ($action, $limits) = @_;
    my $maximum = $limits->get('max_action_targets');
    my $selection = ref($action->{selection}) eq 'HASH' ? $action->{selection} : {};
    if (exists($selection->{max_rows})) {
        my $declared = $selection->{max_rows};
        Selecto::Error->throw('invalid_action_contract', 'selection.max_rows must be a positive bounded integer')
            unless defined($declared) && !ref($declared) && "$declared" =~ /\A[1-9][0-9]{0,8}\z/;
        $maximum = $declared if $declared < $maximum;
    }
    return $maximum;
}

sub _check_target_limit {
    my ($action, $target, $limits) = @_;
    my $maximum = _maximum_targets($action, $limits);
    # Count occurrences before normalizing, copying, hashing or deduplicating.
    if (ref($target) eq 'HASH' && ref($target->{ids}) eq 'ARRAY') {
        Selecto::Error->throw('action_cardinality_mismatch',
            "action permits at most $maximum target rows",
            {maximum => 0 + $maximum, actual => scalar(@{$target->{ids}})},
        ) if @{$target->{ids}} > $maximum;
        for my $id (@{$target->{ids}}) {
            Selecto::Error->throw('invalid_action_target', 'target IDs must be nonempty scalars')
                unless defined($id) && !ref($id) && length("$id");
            $limits->check_bytes('max_value_bytes', $id, 'invalid_action_target', 'target ID');
        }
    }
    return $maximum;
}

# Plans are mutable host objects. Recheck their raw target and count before
# authorization serializes them or invokes a host callback.
sub validate_plan_limits {
    my ($class, $input, $plan, %options) = @_;
    Selecto::Error->throw('invalid_action_plan', 'action plan is required')
        unless blessed($plan) && $plan->isa('Selecto::Action::Plan');
    my $contract = _contract($input);
    my $action = $contract->{actions}{$plan->action};
    Selecto::Error->throw('invalid_action_plan', 'action plan belongs to a different domain')
        unless ref($action) eq 'HASH';
    my $limits = _limits($options{limits});
    my $target = $plan->target;
    Selecto::Error->throw('invalid_action_plan', 'plan bulk target must contain only an ids list')
        if ref($target) eq 'HASH' && (keys(%$target) != 1 || ref($target->{ids}) ne 'ARRAY');
    my $maximum = _check_target_limit($action, $target, $limits);
    $limits->check_bytes('max_value_bytes', $target, 'invalid_action_target', 'target ID')
        if defined($target) && !ref($target);
    my ($kind, $count) = ref($plan->expected_cardinality) eq 'ARRAY'
        ? @{$plan->expected_cardinality} : ();
    Selecto::Error->throw('invalid_action_plan', 'action cardinality must be a positive exact count')
        unless defined($kind) && $kind eq 'exactly' && defined($count) && !ref($count)
            && "$count" =~ /\A[1-9][0-9]*\z/;
    Selecto::Error->throw('action_cardinality_mismatch', 'action exceeds its target limit',
        {maximum => 0 + $maximum}) if $count > $maximum;
    my $filters = $plan->filters // [];
    Selecto::Error->throw('invalid_action_plan', 'action filters must be an array') unless ref($filters) eq 'ARRAY';
    $limits->check_count('max_expression_nodes', scalar(@$filters), 'action_cardinality_mismatch', 'action filters');
    for my $filter (@$filters) {
        next unless ref($filter) eq 'ARRAY' && @$filter == 3 && ($filter->[1] // '') eq 'in'
            && ref($filter->[2]) eq 'ARRAY';
        Selecto::Error->throw('action_cardinality_mismatch', 'action filter exceeds its target limit',
            {maximum => 0 + $maximum}) if @{$filter->[2]} > $maximum;
    }
    return $plan;
}

sub _declared_preconditions {
    my ($contract, $action, $operation) = @_;
    my $raw = $action->{preconditions};
    return [] unless defined $raw;
    Selecto::Error->throw('invalid_action_preconditions', 'action preconditions must be a list')
        unless ref($raw) eq 'ARRAY';
    Selecto::Error->throw('action_preconditions_unsupported_operation', 'action preconditions require update or delete')
        if @$raw && $operation ne 'update' && $operation ne 'delete';
    my %aliases = (eq => 'eq', '=' => 'eq', neq => 'neq', '!=' => 'neq', '<>' => 'neq',
        gt => 'gt', '>' => 'gt', gte => 'gte', '>=' => 'gte', lt => 'lt', '<' => 'lt',
        lte => 'lte', '<=' => 'lte', in => 'in');
    my $columns = $contract->{source}{columns} // {};
    _object($columns, 'source columns');
    my @result;
    for my $item (@$raw) {
        my ($field, $comparator, $value);
        if (ref($item) eq 'HASH') {
            ($field, $comparator, $value) = ($item->{field}, $item->{comparator} // $item->{operator} // $item->{op} // 'eq', $item->{value});
        } elsif (ref($item) eq 'ARRAY' && @$item == 2) {
            ($field, $value) = @$item;
            $comparator = 'eq';
        } elsif (ref($item) eq 'ARRAY' && @$item == 3) {
            ($comparator, $field, $value) = @$item;
        } else {
            Selecto::Error->throw('invalid_action_precondition', 'invalid action precondition shape');
        }
        Selecto::Error->throw('invalid_action_precondition_field', 'field must be a non-empty scalar identifier')
            if !defined($field) || ref($field) || $field eq '';
        Selecto::Error->throw('action_precondition_field_not_found', 'field must be a direct source column')
            if $field =~ /\./ || !exists($columns->{$field});
        Selecto::Error->throw('invalid_action_precondition_comparator', 'unsupported action comparator')
            if !defined($comparator) || ref($comparator) || !exists($aliases{$comparator});
        $comparator = $aliases{$comparator};
        Selecto::Error->throw('invalid_action_precondition_value', 'IN requires a non-empty list')
            if $comparator eq 'in' && (ref($value) ne 'ARRAY' || !@$value);
        push @result, {type => 'filter', field => $field, comparator => $comparator,
            value => ref($value) ? dclone($value) : $value, reason => 'action_precondition'};
    }
    return \@result;
}

sub _select_variant {
    my ($action, $submitted) = @_;
    my $form = __PACKAGE__->input_form($action, $submitted);
    return (_normalize_inputs($form->{inputs}, $submitted // {}, 0),
        $form->{variant}, $form->{execution});
}

sub input_form {
    my ($class, $action, $submitted) = @_;
    _object($action, 'action');
    $submitted //= {};
    _object($submitted, 'action inputs');

    my $base_specs = _input_specs($action->{inputs});
    my $variants = $action->{variants};
    return {inputs => $base_specs, variant => undef, execution => _clone($action->{execution})}
        unless defined $variants;
    Selecto::Error->throw('invalid_action_variants', 'action variants must be a non-empty list')
        unless ref($variants) eq 'ARRAY' && @$variants;

    my (%selectors, %seen);
    for my $variant (@$variants) {
        _object($variant, 'action variant');
        my $id = _id($variant->{id});
        Selecto::Error->throw('invalid_action_variant', 'action variants require unique ids')
            if $id eq '' || $seen{$id}++;
        _object($variant->{when}, 'action selection condition');
        for my $field (keys %{$variant->{when}}) {
            Selecto::Error->throw('invalid_action_variant', 'variant conditions must reference base inputs')
                unless exists $base_specs->{$field};
            $selectors{$field} = $base_specs->{$field};
        }
    }
    # Other required fields may be empty while choosing a variant, and a
    # variant can override their requirements. Only selectors are needed here.
    my $base_inputs = _normalize_inputs(\%selectors, $submitted, 1);
    my @matches = grep { _condition_matches($_->{when}, $base_inputs) } @$variants;
    Selecto::Error->throw('action_variant_not_found', 'normalized action inputs do not select an action variant')
        unless @matches;
    Selecto::Error->throw('ambiguous_action_variant', 'normalized action inputs select multiple action variants')
        unless @matches == 1;

    my $variant = $matches[0];
    _object($variant, 'action variant');
    my $variant_id = _id($variant->{id});
    Selecto::Error->throw('invalid_action_variant', 'action variant must include an id') if $variant_id eq '';
    my $specs = { %$base_specs, %{_input_specs($variant->{inputs})} };
    for my $field (keys %selectors) {
        Selecto::Error->throw('invalid_action_variant', 'a variant cannot override its selector input')
            unless _same_value($specs->{$field}, $base_specs->{$field});
    }
    return {inputs => $specs, variant => $variant_id,
        execution => _clone($variant->{execution} // $action->{execution})};
}

sub _select_execution_case {
    my ($execution, $inputs) = @_;
    _object($execution, 'action execution');
    my $cases = $execution->{cases};
    return (undef, dclone($execution)) unless defined $cases;
    Selecto::Error->throw('invalid_action_execution_cases', 'action execution cases must be a non-empty list')
        unless ref($cases) eq 'ARRAY' && @$cases;

    my @matches = grep { _condition_matches($_->{when}, $inputs) } @$cases;
    Selecto::Error->throw('action_execution_case_not_found', 'normalized action inputs do not select an execution case')
        unless @matches;
    Selecto::Error->throw('ambiguous_action_execution_case', 'normalized action inputs select multiple execution cases')
        unless @matches == 1;

    my $index;
    for my $candidate (0 .. $#$cases) {
        if ($cases->[$candidate] == $matches[0]) {
            $index = $candidate;
            last;
        }
    }
    my $selected = dclone($execution);
    delete $selected->{cases};
    my $case = dclone($matches[0]);
    delete $case->{when};
    $selected->{$_} = $case->{$_} for keys %$case;
    return (defined($matches[0]{id}) ? _id($matches[0]{id}) : $index, $selected);
}

sub _input_specs {
    my ($value) = @_;
    return {} unless defined $value;
    return dclone($value) if ref($value) eq 'HASH';
    if (ref($value) eq 'ARRAY') {
        my %specs;
        for my $spec (@$value) {
            _object($spec, 'action input specification');
            my $id = _id($spec->{id});
            Selecto::Error->throw('invalid_action_input', 'action input specification must include an id') if $id eq '';
            my $copy = dclone($spec);
            delete $copy->{id};
            $specs{$id} = $copy;
        }
        return \%specs;
    }
    Selecto::Error->throw('invalid_action_inputs', 'action input specifications must be an object or list');
}

sub _normalize_inputs {
    my ($specs, $submitted, $allow_unknown) = @_;
    _object($specs, 'action input specifications');
    _object($submitted, 'action inputs');
    unless ($allow_unknown) {
        my @unknown = sort grep { !exists $specs->{$_} } keys %$submitted;
        Selecto::Error->throw('unknown_action_input', 'action inputs contain undeclared fields', { fields => \@unknown })
            if @unknown;
    }

    my %normalized;
    for my $id (sort keys %$specs) {
        my $spec = $specs->{$id};
        _object($spec, 'action input specification');
        if (exists $submitted->{$id}) {
            $normalized{$id} = _normalize_input_value($submitted->{$id}, $spec, $id);
        } elsif (exists $spec->{default}) {
            $normalized{$id} = _resolve_default($spec->{default});
        } elsif ($spec->{required}) {
            Selecto::Error->throw('missing_action_input', 'required action input is missing', { input => $id });
        }
    }
    return \%normalized;
}

sub _normalize_input_value {
    my ($value, $spec, $id) = @_;
    my $type = _id($spec->{type});
    if ($type eq 'boolean') {
        return JSON::PP::true if !ref($value) && "$value" =~ /\A(?:true|1)\z/i;
        return JSON::PP::false if !ref($value) && "$value" =~ /\A(?:false|0)\z/i;
        if (JSON::PP::is_bool($value)) {
            return $value ? JSON::PP::true : JSON::PP::false;
        }
        Selecto::Error->throw('invalid_action_input', 'boolean action input is invalid', { input => $id });
    }
    if ($type eq 'collection') {
        Selecto::Error->throw('invalid_action_input', 'collection action input must be a list', { input => $id })
            unless ref($value) eq 'ARRAY';
        my $minimum = defined($spec->{min_items}) ? int($spec->{min_items}) : 0;
        Selecto::Error->throw('invalid_action_input', 'collection action input has too few entries', { input => $id })
            if @$value < $minimum;
        return dclone($value);
    }
    if ($type eq 'json' || $type eq 'jsonb' || $type eq 'map') {
        # The submitted subtree is literal data. Never recurse through it as
        # a template, even if one of its arrays resembles an instruction.
        Selecto::Error->throw('invalid_action_input', 'JSON action input must contain only JSON values', {input => $id})
            unless _json_value($value);
        return _clone($value);
    }
    Selecto::Error->throw('invalid_action_input', 'scalar action input must be a scalar', {input => $id})
        if ref($value);
    return $value;
}

sub _json_value {
    my ($value) = @_;
    return 1 unless ref($value);
    return 1 if JSON::PP::is_bool($value);
    return !grep { !_json_value($_) } @$value if ref($value) eq 'ARRAY';
    return !grep { !_json_value($_) } values %$value if ref($value) eq 'HASH';
    return 0;
}

sub _display_values {
    my ($value) = @_;
    return ['system', 'now'] if blessed($value) && $value->isa('Selecto::Write::Expression')
        && $value->kind eq 'current_timestamp';
    return [map { _display_values($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _display_values($value->{$_}) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}

sub _resolve_default {
    my ($value) = @_;
    return _resolve_template($value, {});
}

sub _condition_matches {
    my ($condition, $inputs) = @_;
    _object($condition, 'action selection condition');
    for my $field (keys %$condition) {
        return 0 unless exists $inputs->{$field};
        return 0 unless _same_value($inputs->{$field}, $condition->{$field});
    }
    return 1;
}

sub _same_value {
    my ($left, $right) = @_;
    return JSON::PP->new->canonical(1)->allow_nonref(1)->encode($left)
        eq JSON::PP->new->canonical(1)->allow_nonref(1)->encode($right);
}

sub _resolve_template {
    my ($value, $inputs) = @_;
    if (ref($value) eq 'ARRAY') {
        if (@$value == 2 && _id($value->[0]) eq 'input') {
            my $id = _id($value->[1]);
            Selecto::Error->throw('missing_action_input', 'action execution references a missing input', { input => $id })
                unless exists $inputs->{$id};
            return _clone($inputs->{$id});
        }
        # Only walking an authored template/default may construct this
        # internal instruction. Returned input subtrees are never walked.
        return Selecto::Write::Expression->current_timestamp
            if @$value == 2 && _id($value->[0]) eq 'system' && _id($value->[1]) eq 'now';
        return [map { _resolve_template($_, $inputs) } @$value];
    }
    if (ref($value) eq 'HASH') {
        return { map { $_ => _resolve_template($value->{$_}, $inputs) } keys %$value };
    }
    return $value;
}

sub _collection_patches {
    my ($execution, $inputs) = @_;
    my $specs = $execution->{collection_patches};
    return {} unless defined $specs;
    _object($specs, 'action collection patches');
    my %patches;
    for my $id (sort keys %$specs) {
        my $spec = $specs->{$id};
        _object($spec, 'action collection patch');
        my $input_id = _id($spec->{from_input}) || $id;
        Selecto::Error->throw('missing_action_input', 'collection patch references a missing input', { input => $input_id })
            unless exists $inputs->{$input_id};
        my $entries = $inputs->{$input_id};
        Selecto::Error->throw('invalid_action_collection_patch', 'collection patch input must be a list')
            unless ref($entries) eq 'ARRAY';
        for my $entry (@$entries) {
            Selecto::Error->throw('invalid_action_collection_patch', 'collection patch entries must be objects')
                unless ref($entry) eq 'HASH';
            Selecto::Error->throw('invalid_action_collection_patch', 'collection patch entry must include an operation')
                if _id($entry->{op}) eq '';
        }
        $patches{$id} = {
            target      => dclone($spec->{target}),
            strategy    => _id($spec->{strategy}),
            identity    => _id($spec->{identity}),
            order_field => _id($spec->{order_field}),
            entries     => dclone($entries),
        };
    }
    return \%patches;
}

sub _contract {
    my ($input) = @_;
    if (blessed($input) && $input->isa('Selecto::Domain')) {
        my $contract = $input->contract;
        Selecto::Error->throw('missing_domain_contract', 'canonical domain contract is required for actions')
            unless ref($contract) eq 'HASH';
        return $contract;
    }
    _object($input, 'domain contract');
    return dclone($input);
}

# Insert and upsert actions create one row from their changes; they name no
# existing row, so a submitted target is refused rather than ignored.
sub _create_target {
    my ($action, $target) = @_;
    Selecto::Error->throw('action_scope_mismatch', 'insert and upsert actions take no target')
        if defined($target) && !(ref($target) eq 'HASH' && !keys %$target);
    Selecto::Error->throw('action_scope_mismatch', 'insert and upsert actions cannot be bulk actions')
        if _id($action->{scope}) eq 'bulk' || _id($action->{type}) eq 'bulk_action';
    return ('create', [], ['exactly', 1], undef);
}

sub _target {
    my ($contract, $action, $operation_spec, $target, $limits) = @_;
    my $primary_key = "$contract->{source}{primary_key}";
    $primary_key = 'id' if $primary_key eq '';
    my $declared_scope = _id($action->{scope}) || (_id($action->{type}) eq 'bulk_action' ? 'bulk' : 'row');

    if (ref($target) eq 'HASH' && exists($target->{ids})) {
        my $ids = $target->{ids};
        Selecto::Error->throw('invalid_action_target', 'bulk target ids must be a non-empty list')
            unless ref($ids) eq 'ARRAY' && @$ids;
        my $maximum = _check_target_limit($action, $target, $limits);
        Selecto::Error->throw('action_scope_mismatch', 'row action cannot target a bulk selection')
            unless $declared_scope eq 'bulk' || $action->{bulk}{enabled};
        Selecto::Error->throw('bulk_action_operation_not_enabled', 'bulk action requires a bulk-enabled write operation')
            unless $operation_spec->{bulk};
        my @normalized = map { _target_value($_) } @$ids;
        my %seen;
        Selecto::Error->throw('invalid_action_target', 'bulk target ids must not contain duplicates')
            if grep { $seen{"$_"}++ } @normalized;
        my $selection = ref($action->{selection}) eq 'HASH' ? $action->{selection} : {};
        my $minimum = $selection->{min_rows} // 1;
        Selecto::Error->throw(
            'action_cardinality_mismatch',
            $minimum == 1 ? 'action requires at least one target row'
                : "action requires at least $minimum target rows",
            {minimum => 0 + $minimum, actual => scalar(@normalized)},
        ) if @normalized < $minimum;
        Selecto::Error->throw(
            'action_cardinality_mismatch',
            $maximum == 1 ? 'action requires exactly one target row'
                : "action permits at most $maximum target rows",
            {maximum => 0 + $maximum, actual => scalar(@normalized)},
        ) if defined($maximum) && @normalized > $maximum;
        return ('bulk', [[$primary_key, 'in', \@normalized]], ['exactly', scalar @normalized], { ids => \@normalized });
    }

    my $value;
    if (ref($target) eq 'HASH') {
        $value = exists($target->{$primary_key}) ? $target->{$primary_key} : $target->{id};
    } elsif (defined($target) && !ref($target)) {
        $value = $target;
    }
    Selecto::Error->throw('action_scope_mismatch', 'row action requires a concrete target') unless defined($value);
    Selecto::Error->throw('action_scope_mismatch', 'bulk action requires a concrete ids selection') if $declared_scope eq 'bulk';
    $value = _target_value($value);
    return ('row', [[$primary_key, $value]], ['exactly', 1], $value);
}

sub _transition {
    my ($writes, $action, $changes) = @_;
    return (undef, []) unless ref($action->{transition}) eq 'HASH';
    my $transition = dclone($action->{transition});
    my ($field, $from, $to) = map { defined($_) ? "$_" : '' } @{$transition}{qw(field from to)};
    Selecto::Error->throw('invalid_action_transition', 'transition must declare field, from, and to')
        if grep { $_ eq '' } ($field, $from, $to);
    Selecto::Error->throw('invalid_action_transition', 'transition output does not match action changes')
        unless exists($changes->{$field}) && "$changes->{$field}" eq $to;
    my $allowed = $writes->{transitions}{$field}{$from};
    Selecto::Error->throw('invalid_action_transition', 'transition is not allowed by the write contract')
        unless ref($allowed) eq 'ARRAY' && grep { "$_" eq $to } @$allowed;
    return ($transition, [{
        type       => 'field_equals',
        field      => $field,
        value      => $from,
        reason     => 'transition_from',
        transition => dclone($transition),
    }]);
}

sub _validate_changes {
    my ($writes, $changes, $operation) = @_;
    return if $operation eq 'delete';
    Selecto::Error->throw('invalid_action_changes', 'action changes must not be empty') unless keys %$changes;
    for my $field (keys %$changes) {
        my $field_spec = $writes->{fields}{$field};
        my $permission = $operation eq 'insert' || $operation eq 'upsert' ? 'insertable' : 'updatable';
        Selecto::Error->throw('action_field_not_writable', 'action changes an undeclared write field', { field => $field })
            unless ref($field_spec) eq 'HASH' && $field_spec->{$permission};
    }
}

sub _validate_capability {
    my ($contract, $capability, $action, $operation) = @_;
    return unless defined $capability;
    my $spec = $contract->{capabilities}{$capability};
    Selecto::Error->throw('action_capability_not_declared', 'action capability is not declared') unless ref($spec) eq 'HASH';
    my $declared_operations = ref($spec->{operations}) eq 'ARRAY' ? $spec->{operations} : [];
    my %operations;
    $operations{"$_"} = 1 for @$declared_operations;
    Selecto::Error->throw('action_capability_mismatch', 'capability does not permit this action operation')
        unless $operations{action} && $operations{$operation};
    Selecto::Error->throw('action_capability_mismatch', 'capability names a different action')
        if defined($spec->{action}) && "$spec->{action}" ne $action;
}

sub _target_value {
    my ($value) = @_;
    return int($value) if defined($value) && !ref($value) && "$value" =~ /\A-?\d+\z/;
    return $value;
}

sub _clone {
    my ($value) = @_;
    return ref($value) ? dclone($value) : $value;
}

sub _object {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_action_contract', "$label must be an object") unless ref($value) eq 'HASH';
}

sub _id {
    my ($value) = @_;
    return '' unless defined($value) && !ref($value);
    return "$value";
}

1;

__END__

=head1 NAME

Selecto::Action::Planner - turn a domain action and caller intent into a constrained plan

=head1 DESCRIPTION

Implements L<Selecto::Action/plan> and L<Selecto::Action/input_form>: variant
and execution-case selection, input normalization, targets, transitions and
declared preconditions.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Action>, L<Selecto::Action::Plan>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
