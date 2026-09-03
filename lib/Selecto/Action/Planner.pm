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

sub plan {
    my ($class, $input, $intent) = @_;
    my $contract = _contract($input);
    _object($intent, 'action intent');
    my $action_id = _id($intent->{action});
    Selecto::Error->throw('invalid_action_intent', 'action intent must include an action id') if $action_id eq '';

    my $actions = $contract->{actions} // {};
    _object($actions, 'domain actions');
    my $action = $actions->{$action_id};
    Selecto::Error->throw('invalid_action_intent', 'action is not exposed by this domain contract', { action => $action_id })
        unless ref($action) eq 'HASH';

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
    _validate_changes($writes, $changes, $operation);
    my $collection_patches = _collection_patches($execution, $inputs);

    my ($scope, $filters, $expected, $target) = _target($contract, $action, $operation_spec, $intent->{target});
    my ($transition, $preconditions) = _transition($writes, $action, $changes);
    $preconditions = [@{_declared_preconditions($contract, $action, $operation)}, @$preconditions];
    push @$filters, map {
        ($_->{comparator} // 'eq') eq 'eq' ? [$_->{field}, $_->{value}]
            : [$_->{field}, $_->{comparator}, $_->{value}]
    } @$preconditions;

    my $capability = defined($action->{capability}) ? "$action->{capability}" : undef;
    _validate_capability($contract, $capability, $action_id, $operation);

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
        inputs               => $inputs,
        variant              => $variant,
        execution_case       => $execution_case,
        collection_patches   => $collection_patches,
    );
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
    $submitted //= {};
    _object($submitted, 'action inputs');

    my $base_specs = _input_specs($action->{inputs});
    my $base_inputs = _normalize_inputs($base_specs, $submitted, 1);
    my $variants = $action->{variants};
    return (_normalize_inputs($base_specs, $submitted, 0), undef, $action->{execution})
        unless defined $variants;
    Selecto::Error->throw('invalid_action_variants', 'action variants must be a non-empty list')
        unless ref($variants) eq 'ARRAY' && @$variants;

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
    my $inputs = _normalize_inputs($specs, $submitted, 0);
    return ($inputs, $variant_id, $variant->{execution} // $action->{execution});
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
    return dclone($value) if ref($value);
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

sub _target {
    my ($contract, $action, $operation_spec, $target) = @_;
    my $primary_key = "$contract->{source}{primary_key}";
    $primary_key = 'id' if $primary_key eq '';
    my $declared_scope = _id($action->{scope}) || (_id($action->{type}) eq 'bulk_action' ? 'bulk' : 'row');

    if (ref($target) eq 'HASH' && exists($target->{ids})) {
        my $ids = $target->{ids};
        Selecto::Error->throw('invalid_action_target', 'bulk target ids must be a non-empty list')
            unless ref($ids) eq 'ARRAY' && @$ids;
        my %seen;
        Selecto::Error->throw('invalid_action_target', 'bulk target ids must not contain duplicates')
            if grep { $seen{"$_"}++ } @$ids;
        Selecto::Error->throw('action_scope_mismatch', 'row action cannot target a bulk selection')
            unless $declared_scope eq 'bulk' || $action->{bulk}{enabled};
        Selecto::Error->throw('bulk_action_operation_not_enabled', 'bulk action requires a bulk-enabled write operation')
            unless $operation_spec->{bulk};
        my @normalized = map { _target_value($_) } @$ids;
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
        my $permission = $operation eq 'insert' ? 'insertable' : 'updatable';
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
