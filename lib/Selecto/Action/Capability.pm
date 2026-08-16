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
