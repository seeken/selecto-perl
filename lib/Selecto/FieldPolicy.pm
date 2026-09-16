package Selecto::FieldPolicy;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Domain ();
use Selecto::Error ();

has 'domain';
has authorize => sub { return sub { return {status => 'enabled'} } };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy requires a Selecto domain',
    ) unless blessed($self->domain) && $self->domain->isa('Selecto::Domain');
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy authorize must be a callback',
    ) unless ref($self->authorize) eq 'CODE';
    return $self;
}

sub resolve ($self, %args) {
    my $operation = lc _scalar($args{operation} // 'update');
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy operation is not supported',
        {operation => $operation},
    ) unless $operation =~ /\A(?:insert|update|upsert|view)\z/;

    my $profile = $args{profile};
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy profile must be an array',
    ) unless ref($profile) eq 'ARRAY';
    my $snapshot = $args{snapshot} // {};
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy snapshot must be an object',
    ) unless ref($snapshot) eq 'HASH';

    my $writes = $self->domain->writes;
    my $write_fields = ref($writes->{fields}) eq 'HASH'
        ? $writes->{fields} : {};
    my $operation_spec = ref($writes->{operations}) eq 'HASH'
        ? $writes->{operations}{$operation} : undef;
    my $operation_enabled = $operation eq 'view' ? 0
        : ref($operation_spec) eq 'HASH' && $operation_spec->{enabled} ? 1 : 0;

    my (@resolved, %seen);
    for my $index (0 .. $#$profile) {
        my $entry = $profile->[$index];
        $entry = {field => $entry} if defined($entry) && !ref($entry);
        Selecto::Error->throw(
            'invalid_field_policy', 'field policy profile entries must be objects',
            {index => $index},
        ) unless ref($entry) eq 'HASH';
        _reject_unknown($entry, $index);
        my $field = _identifier($entry->{field}, 'field policy field');
        Selecto::Error->throw(
            'invalid_field_policy', 'field policy profile contains a duplicate field',
            {field => $field},
        ) if $seen{$field}++;

        my $definition = eval { $self->domain->resolve($field) };
        Selecto::Error->throw(
            'invalid_field_policy', 'field policy references an unknown field',
            {field => $field},
        ) unless ref($definition) eq 'HASH';
        my $metadata = $self->domain->field_metadata($field);
        my $public = $self->domain->field_is_public($field) ? 1 : 0;
        my $requested_mode = lc _scalar($entry->{mode} // 'auto');
        Selecto::Error->throw(
            'invalid_field_policy', 'field policy mode is not supported',
            {field => $field, mode => $requested_mode},
        ) unless $requested_mode =~ /\A(?:auto|hidden|read_only|editable|action)\z/;

        my $view = $self->_decision(
            $entry->{view_capability}, 'view', $field, $operation, \%args,
        );
        my $state = !$public || $requested_mode eq 'hidden'
            || $view->{status} ne 'enabled' ? 'hidden' : undef;
        my ($reason, $reason_code);
        if ($state) {
            $reason = $view->{reason};
            $reason_code = !$public ? 'field_not_public'
                : $requested_mode eq 'hidden' ? 'profile_hidden'
                : $view->{reason_code} // 'view_denied';
        }

        my $root = !defined($definition->{association});
        my $write_spec = $root && ref($write_fields->{$field}) eq 'HASH'
            ? $write_fields->{$field} : {};
        my $permission = $operation eq 'insert' || $operation eq 'upsert'
            ? 'insertable' : 'updatable';
        my $contract_writable = $operation_enabled && $root
            && $write_spec->{$permission} ? 1 : 0;
        my $edit = $self->_decision(
            $entry->{edit_capability}, 'edit', $field, $operation, \%args,
        );
        my $eligible = !exists($entry->{eligible}) || $entry->{eligible} ? 1 : 0;

        unless ($state) {
            if ($requested_mode eq 'action' || defined($entry->{action})) {
                $state = 'action-backed';
                if ($edit->{status} ne 'enabled' || !$eligible) {
                    $state = 'read-only';
                    $reason = $entry->{reason} // $edit->{reason}
                        // 'This workflow is not currently available.';
                    $reason_code = !$eligible ? 'state_ineligible'
                        : $edit->{reason_code} // 'edit_denied';
                }
            }
            elsif ($requested_mode eq 'read_only' || !$contract_writable
                || $edit->{status} ne 'enabled' || !$eligible) {
                $state = 'read-only';
                $reason = $entry->{reason} // $edit->{reason};
                $reason_code = $requested_mode eq 'read_only' ? 'profile_read_only'
                    : !$contract_writable ? 'write_not_permitted'
                    : !$eligible ? 'state_ineligible'
                    : $edit->{reason_code} // 'edit_denied';
            }
            else {
                $state = 'editable';
            }
        }

        my $type = lc _scalar($definition->{type} // 'string');
        my $control = _scalar($entry->{control});
        $control = _control_for_type($type) unless length $control;
        my $required = $entry->{required} ? 1 : 0;
        $required = 1 if ($operation eq 'insert' || $operation eq 'upsert')
            && $write_spec->{required};
        my $label = _scalar($entry->{label});
        $label = _scalar($metadata->{label}) unless length $label;
        $label = _humanize($field) unless length $label;

        push @resolved, {
            field => $field,
            label => $label,
            type => $type,
            state => $state,
            control => $control,
            required => $required,
            nullable => $entry->{nullable} ? 1 : 0,
            writable => $contract_writable,
            value => exists($snapshot->{$field}) ? $snapshot->{$field} : undef,
            (defined($entry->{action}) ? (action => _identifier(
                $entry->{action}, "field policy action for $field",
            )) : ()),
            (defined($entry->{placeholder}) ? (
                placeholder => _scalar($entry->{placeholder}),
            ) : ()),
            (defined($entry->{rows}) ? (rows => 0 + $entry->{rows}) : ()),
            (ref($entry->{options}) eq 'ARRAY' ? (
                options => dclone($entry->{options}),
            ) : ()),
            (defined($entry->{view_capability}) ? (
                view_capability => _scalar($entry->{view_capability}),
            ) : ()),
            (defined($entry->{edit_capability}) ? (
                edit_capability => _scalar($entry->{edit_capability}),
            ) : ()),
            (defined($reason) && length("$reason") ? (reason => "$reason") : ()),
            (defined($reason_code) && length("$reason_code")
                ? (reason_code => "$reason_code") : ()),
        };
    }
    return \@resolved;
}

sub visible ($self, %args) {
    return [grep { $_->{state} ne 'hidden' } @{$self->resolve(%args)}];
}

sub accepted_fields ($self, %args) {
    return [map { $_->{field} } grep {
        $_->{state} eq 'editable'
    } @{$self->resolve(%args)}];
}

sub _decision ($self, $capability, $phase, $field, $operation, $args) {
    return {status => 'enabled'} unless defined($capability)
        && length _scalar($capability);
    my $decision = $self->authorize->({
        capability => _scalar($capability),
        phase => $phase,
        field => $field,
        operation => $operation,
        context => $args->{context},
        snapshot => $args->{snapshot},
    });
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy authorization returned an invalid decision',
        {field => $field, capability => _scalar($capability)},
    ) unless ref($decision) eq 'HASH'
        && _scalar($decision->{status}) =~ /\A(?:enabled|disabled|hidden)\z/;
    return $decision;
}

sub _reject_unknown ($entry, $index) {
    my %allowed = map { $_ => 1 } qw(
        field label control required nullable placeholder rows options mode
        action view_capability edit_capability eligible reason
    );
    my @unknown = sort grep { !$allowed{$_} } keys %$entry;
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy profile contains unsupported settings',
        {index => $index, settings => \@unknown},
    ) if @unknown;
    for my $name (qw(required nullable eligible)) {
        next unless exists $entry->{$name};
        Selecto::Error->throw(
            'invalid_field_policy', "field policy $name must be boolean",
            {index => $index},
        ) unless _is_boolean($entry->{$name});
    }
    if (exists($entry->{rows})) {
        Selecto::Error->throw(
            'invalid_field_policy', 'field policy rows must be from 2 to 20',
            {index => $index},
        ) if ref($entry->{rows}) || "$entry->{rows}" !~ /\A\d+\z/
            || $entry->{rows} < 2 || $entry->{rows} > 20;
    }
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy options must be an array',
        {index => $index},
    ) if exists($entry->{options}) && ref($entry->{options}) ne 'ARRAY';
}

sub _is_boolean ($value) {
    return 1 if JSON::PP::is_bool($value);
    return defined($value) && !ref($value) && "$value" =~ /\A(?:0|1)\z/;
}

sub _control_for_type ($type) {
    return 'checkbox' if $type eq 'boolean';
    return 'number' if $type =~ /\A(?:integer|bigint|smallint|decimal|number|float|double|numeric)\z/;
    return 'date' if $type eq 'date';
    return 'datetime-local' if $type =~ /datetime/;
    return 'text';
}

sub _humanize ($value) {
    my $text = "$value";
    $text =~ s/\./ /g;
    $text =~ s/_/ /g;
    $text =~ s/\b([a-z])/\U$1/g;
    return $text;
}

sub _identifier ($value, $label) {
    my $text = _scalar($value);
    Selecto::Error->throw('invalid_field_policy', "$label is invalid")
        unless $text =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
    return $text;
}

sub _scalar ($value) {
    return defined($value) && !ref($value) ? "$value" : '';
}

1;
