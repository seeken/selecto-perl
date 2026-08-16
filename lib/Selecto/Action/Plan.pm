package Selecto::Action::Plan;

use 5.034;
use Mojo::Base -base, -signatures;
use Storable qw(dclone);

has [qw(action type operation scope capability target filters changes expected_cardinality transition preconditions)];

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
    });
}

1;
