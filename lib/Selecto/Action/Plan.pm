package Selecto::Action::Plan;

use 5.034;
use Mojo::Base -base, -signatures;
use Storable qw(dclone);

has [qw(
    action type operation scope capability target filters changes expected_cardinality
    transition preconditions inputs variant execution_case collection_patches
)];

sub to_hash ($self) {
    return dclone({
        action               => $self->action,
        type                 => $self->type,
        operation            => $self->operation,
        scope                => $self->scope,
        capability           => $self->capability,
        target               => $self->target,
        filters              => $self->filters,
        changes              => $self->changes,
        expected_cardinality => $self->expected_cardinality,
        transition           => $self->transition,
        preconditions        => $self->preconditions,
        inputs               => $self->inputs,
        variant              => $self->variant,
        execution_case       => $self->execution_case,
        collection_patches   => $self->collection_patches,
    });
}

1;

__END__

=head1 NAME

Selecto::Action::Plan - a constrained write intent produced by action planning

=head1 SYNOPSIS

  my $plan = $engine->plan_action({action => 'archive', target => 7});

  $plan->operation;              # 'update'
  $plan->filters;                # [['id', 7], ['state', 'done']]
  $plan->changes;                # {state => 'archived'}
  $plan->expected_cardinality;   # ['exactly', 1]
  my $data = $plan->to_hash;

=head1 DESCRIPTION

Plans are returned by L<Selecto::Action/plan> and
L<Selecto::Engine/plan_action> and consumed by the engine's
C<preview_action>, C<execute_action> and C<grant_action>. Treat them as
read-only values; build a new plan instead of changing one.

=head1 ACCESSORS

=over 4

=item C<action>, C<type>, C<operation>, C<scope>, C<capability>

The declared action and its resolved operation and scope (C<row> or
C<bulk>).

=item C<target>

The normalized target: a primary-key value, or C<< {ids => [...]} >>.

=item C<filters>

Field-first filters, C<[field, value]> for equality or
C<[field, comparator, value]>, combining the target, transition source state
and declared preconditions.

=item C<changes>

The assignments the action makes, after input substitution.

=item C<expected_cardinality>

C<['exactly', $n]>.

=item C<transition>, C<preconditions>, C<inputs>, C<variant>,
C<execution_case>, C<collection_patches>

Planning details for resolvers, audit records and host executors.

=back

=head2 to_hash

Returns a deep copy of all fields as a plain hash.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Action>, L<Selecto::Engine/ACTIONS>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
