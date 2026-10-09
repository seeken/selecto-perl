package Selecto::FieldPolicy;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Domain::QueryContract ();
use Selecto::Error ();
use Selecto::OperationBudget ();

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
    # Admit the whole plain profile and snapshot before consulting any host
    # capability callback. Context remains an opaque, trusted host value.
    my $input = _copy_plain({operation => $args{operation} // 'update',
        profile => $args{profile}, snapshot => $args{snapshot} // {},
        include_hidden_values => exists($args{include_hidden_values}) ? $args{include_hidden_values} : 0});
    @args{qw(operation profile snapshot)} = @{$input}{qw(operation profile snapshot)};
    Selecto::Error->throw('invalid_field_policy',
        'field policy include_hidden_values must be boolean')
        unless _is_boolean($input->{include_hidden_values});
    my $include_hidden_values = $input->{include_hidden_values} ? 1 : 0;
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
    my $output_budget = Selecto::OperationBudget->new(code => 'invalid_field_policy');
    my $callback_budget = Selecto::OperationBudget->new(code => 'invalid_field_policy');
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
            $entry->{view_capability}, 'view', $field, $operation, \%args, $callback_budget,
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
            $entry->{edit_capability}, 'edit', $field, $operation, \%args, $callback_budget,
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

        my $resolved = {
            field => $field,
            label => $label,
            type => $type,
            state => $state,
            control => $control,
            required => $required,
            nullable => $entry->{nullable} ? 1 : 0,
            writable => $contract_writable,
            ($state ne 'hidden' || $include_hidden_values
                ? (value => exists($snapshot->{$field}) ? $snapshot->{$field} : undef) : ()),
            (defined($entry->{action}) ? (action => _identifier(
                $entry->{action}, "field policy action for $field",
            )) : ()),
            (defined($entry->{placeholder}) ? (
                placeholder => _scalar($entry->{placeholder}),
            ) : ()),
            (defined($entry->{rows}) ? (rows => 0 + $entry->{rows}) : ()),
            (ref($entry->{options}) eq 'ARRAY' ? (
                options => $entry->{options},
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
        # Charge emitted occurrences cumulatively before retaining another
        # descriptor; long host decisions cannot amplify across a short profile.
        $output_budget->check_tree($resolved, label => 'field policy result');
        push @resolved, $resolved;
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

sub _decision ($self, $capability, $phase, $field, $operation, $args, $budget) {
    return {status => 'enabled'} unless defined($capability)
        && length _scalar($capability);
    $budget->check_tree({capability => $capability, phase => $phase,
        field => $field, operation => $operation, snapshot => $args->{snapshot}},
        label => 'field policy capability request');
    my $decision = $self->authorize->({
        capability => _scalar($capability),
        phase => $phase,
        field => $field,
        operation => $operation,
        context => $args->{context},
        snapshot => _copy_plain({snapshot => $args->{snapshot}})->{snapshot},
    });
    $decision = _copy_plain({decision => $decision})->{decision};
    $budget->check_tree($decision, label => 'field policy capability decision');
    Selecto::Error->throw(
        'invalid_field_policy', 'field policy authorization returned an invalid decision',
        {field => $field, capability => _scalar($capability)},
    ) unless ref($decision) eq 'HASH'
        && _scalar($decision->{status}) =~ /\A(?:enabled|disabled|hidden)\z/
        && !grep { defined($decision->{$_}) && ref($decision->{$_}) } qw(reason reason_code);
    return $decision;
}

sub _copy_plain ($value) {
    my $copy;
    my $ok = eval { $copy = Selecto::Domain::QueryContract->copy_declaration($value); 1 };
    unless ($ok) {
        my $error = $@;
        die $error unless ref($error) && UNIVERSAL::isa($error, 'Selecto::Error')
            && $error->code eq 'invalid_query_contract';
        Selecto::Error->throw('invalid_field_policy',
            'field policy metadata must be plain and within its resource limits');
    }
    return $copy;
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
    for my $name (qw(field label control placeholder mode action view_capability edit_capability reason)) {
        Selecto::Error->throw('invalid_field_policy',
            "field policy $name must be a scalar", {index => $index})
            if defined($entry->{$name}) && ref($entry->{$name});
    }
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
        ) if !defined($entry->{rows}) || ref($entry->{rows}) || "$entry->{rows}" !~ /\A\d+\z/
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

__END__

=head1 NAME

Selecto::FieldPolicy - resolve form fields to hidden, read-only, editable or action-backed

=head1 SYNOPSIS

  use Selecto::FieldPolicy;

  my $policy = Selecto::FieldPolicy->new(
      domain    => $domain,
      authorize => sub {
          my ($request) = @_;   # {capability, phase, field, operation, context, snapshot}
          return {status => can($request) ? 'enabled' : 'hidden'};
      },
  );

  my $fields = $policy->resolve(
      operation => 'update',                 # insert, update, upsert or view
      profile   => [
          'name',
          {field => 'status', mode => 'action', action => 'close'},
          {field => 'notes', control => 'textarea', rows => 4,
           edit_capability => 'orders.edit_notes'},
      ],
      snapshot  => $current_row,             # values, and eligibility context
      context   => {actor => $user},
  );
  # [{field => 'name', label => 'Name', type => 'string', state => 'editable',
  #   control => 'text', required => 0, writable => 1, value => ...}, ...]

  my $accepted = $policy->accepted_fields(%same_args);   # names that may be submitted

=head1 DESCRIPTION

A field policy intersects the domain's public field metadata, its C<writes>
permissions, a form I<profile> chosen by the host, host capability decisions
and record-state eligibility, and returns one descriptor per profile field
with a C<state> of C<hidden>, C<read-only>, C<editable> or
C<action-backed>. Hidden and read-only descriptors carry a C<reason_code>
such as C<field_not_public>, C<write_not_permitted>, C<state_ineligible> or
C<edit_denied>.

It is HTTP-neutral and does not write anything. Use L</accepted_fields> to
filter a submission, then write through L<Selecto::Engine>, which enforces
the contract again.

=head1 METHODS

=head2 new

C<domain> is required. C<authorize> receives a request hash and returns
C<< {status => 'enabled'|'disabled'|'hidden', reason => ..., reason_code => ...} >>;
it is only called for profile entries that name a C<view_capability> or
C<edit_capability>. The default allows everything.

=head2 resolve

Arguments: C<operation> (default C<update>), C<profile> (field names or
entry hashes), C<snapshot> and C<context>. Entry keys: C<field>, C<label>,
C<control>, C<required>, C<nullable>, C<placeholder>, C<rows>, C<options>,
C<mode> (C<auto>, C<hidden>, C<read_only>, C<editable> or C<action>),
C<action>, C<view_capability>, C<edit_capability>, C<eligible> and
C<reason>. Throws C<invalid_field_policy>.

Profiles, snapshots, options and returned capability decisions must be plain
bounded metadata. They are copied without invoking object or serialization
hooks; the trusted C<context> value is passed through unchanged. Capability
callbacks receive independent snapshot copies. Hidden descriptors omit their
values by default. A trusted host can explicitly request complete descriptors
with C<include_hidden_values =E<gt> 1>; this option is not a field-profile setting
and must not come from an untrusted submission. L</visible> still removes hidden
descriptors with either option. Complete host metadata must not be serialized
as a public response. These helpers do not authorize write execution.
Emitted metadata and cumulative capability request/decision copies
each share the native finite node and byte budgets.

=head2 visible

The descriptors from L</resolve> whose state is not C<hidden>.

=head2 accepted_fields

The names of the C<editable> fields.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain>, L<Selecto::Engine>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
