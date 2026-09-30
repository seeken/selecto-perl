package Selecto::Action::Capability;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Action::Plan ();
use Selecto::Error ();

sub request {
    my ($class, $plan, $phase) = @_;
    _plan($plan);
    _phase($phase);
    return dclone({
        phase         => "$phase",
        capability    => $plan->capability,
        action        => $plan->action,
        operation     => $plan->operation,
        scope         => $plan->scope,
        target        => $plan->target,
        filters       => $plan->filters,
        transition    => $plan->transition,
        preconditions => $plan->preconditions,
    });
}

sub authorize {
    my ($class, $plan, $phase, %options) = @_;
    my $request = $class->request($plan, $phase);
    my $capability = $plan->capability;
    return _decision('enabled', undef) unless defined($capability) && "$capability" ne '';

    my $resolver = $options{resolver};
    Selecto::Error->throw(
        'missing_capability_resolver',
        "Action $phase requires a host capability resolver.",
        { status => 'hidden', phase => "$phase", capability => "$capability" },
    ) unless ref($resolver) eq 'CODE';

    my $raw = $resolver->($request, $options{context} // {}, \%options);
    $raw = $raw->[1] if ref($raw) eq 'ARRAY' && @$raw == 2 && $raw->[0] eq 'ok';
    my $decision = _normalize($raw, "$capability");
    return $decision if $decision->{status} eq 'enabled';

    Selecto::Error->throw(
        $decision->{code} // 'action_capability_denied',
        $decision->{reason} // 'Action capability denied.',
        {
            status     => $decision->{status},
            capability => $decision->{capability},
            reason     => $decision->{reason},
        },
    );
}

sub _normalize {
    my ($raw, $capability) = @_;
    return _decision($raw, $capability) if defined($raw) && !ref($raw) && $raw =~ /\A(?:enabled|disabled|hidden)\z/;
    if (ref($raw) eq 'HASH') {
        my $status = $raw->{status} // $raw->{decision} // '';
        Selecto::Error->throw('invalid_capability_decision', 'Capability resolver returned an invalid decision.')
            unless $status =~ /\A(?:enabled|disabled|hidden)\z/;
        return {
            status     => "$status",
            capability => defined($raw->{capability}) ? "$raw->{capability}" : $capability,
            reason     => $raw->{reason},
            code       => $raw->{code},
        };
    }
    Selecto::Error->throw('invalid_capability_decision', 'Capability resolver returned an invalid decision.');
}

sub _decision {
    my ($status, $capability) = @_;
    return { status => "$status", capability => $capability };
}

sub _plan {
    my ($plan) = @_;
    Selecto::Error->throw('invalid_action_plan', 'action plan is required')
        unless blessed($plan) && $plan->isa('Selecto::Action::Plan');
}

sub _phase {
    my ($phase) = @_;
    Selecto::Error->throw('invalid_action_phase', 'action phase must be preview or execute')
        unless defined($phase) && "$phase" =~ /\A(?:preview|execute)\z/;
}

1;

__END__

=head1 NAME

Selecto::Action::Capability - phase-bound capability authorization for action plans

=head1 DESCRIPTION

Builds the capability request passed to a host resolver and normalizes its
C<enabled>, C<disabled> or C<hidden> decision. Use
L<Selecto::Action/authorize> or the engine action methods instead.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Action>, L<Selecto::Engine>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
