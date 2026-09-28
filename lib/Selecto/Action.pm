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

# Resolve conditional input specifications without requiring a write executor
# or a complete submission. Hosts use this for forms and lookup discovery;
# execution must still go through plan/authorize/execute.
sub input_form {
    my ($class, $action, $inputs) = @_;
    return Selecto::Action::Planner->input_form($action, $inputs);
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
