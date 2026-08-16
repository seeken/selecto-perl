package Selecto::Action::Planner;

use 5.034;
use strict;
use warnings;
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

    my $execution = $action->{execution};
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

    my $changes = dclone($execution->{set} // {});
    _object($changes, 'action changes');
    _validate_changes($writes, $changes, $operation);

    my ($scope, $filters, $expected, $target) = _target($contract, $action, $operation_spec, $intent->{target});
    my ($transition, $preconditions) = _transition($writes, $action, $changes);
    push @$filters, map { [$_->{field}, $_->{value}] } @$preconditions;

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
    );
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
