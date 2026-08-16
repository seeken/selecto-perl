package Selecto::Action;

use 5.034;
use strict;
use warnings;
use Selecto::Action::Capability ();
use Selecto::Action::Planner ();

sub plan {
    my ($class, $domain, $intent) = @_;
    return Selecto::Action::Planner->plan($domain, $intent);
}

sub authorize {
    my ($class, $plan, $phase, %options) = @_;
    return Selecto::Action::Capability->authorize($plan, $phase, %options);
}

sub capability_request {
    my ($class, $plan, $phase) = @_;
    return Selecto::Action::Capability->request($plan, $phase);
}

1;
