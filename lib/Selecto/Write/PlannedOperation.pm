package Selecto::Write::PlannedOperation;
use 5.034; use strict; use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed reftype);
use Selecto::Error (); use Selecto::Action::Planner ();
fieldhash my %PLANS;
sub _from_plan {
    my ($class, $plan) = @_;
    Selecto::Error->throw('invalid_planned_operation', 'planned operations are created by actual public action planning',
        {code => 'invalid_planned_operation'}) unless scalar(caller) eq 'Selecto::Action';
    Selecto::Action::Planner->validate_provenance($plan);
    my $token = 0; my $self = bless \$token, __PACKAGE__;
    $PLANS{$self} = $plan;
    return $self;
}

my $bound_plan = sub {
    my ($self) = @_;
    Selecto::Error->throw('invalid_planned_operation', 'an original opaque planned operation is required',
        {code => 'invalid_planned_operation'})
        unless (blessed($self) // '') eq __PACKAGE__
            && (reftype($self) // '') eq 'SCALAR' && exists $PLANS{$self};
    my $plan = $PLANS{$self};
    Selecto::Action::Planner->validate_provenance($plan);
    return $plan;
};
my $checked_engine = sub {
    my ($engine) = @_;
    Selecto::Error->throw('invalid_action_engine', 'planned action execution requires a configured native engine')
        unless (blessed($engine) // '') eq 'Selecto::Engine';
    require Selecto::Engine;
    Selecto::Engine::assert_domain_identity($engine);
    return $engine;
};
sub authorize {
    my ($self, $engine, $phase, %options) = @_;
    Selecto::Error->throw('invalid_argument', 'the positional native engine cannot be overridden')
        if exists $options{engine};
    my $plan = $bound_plan->($self);
    $checked_engine->($engine);
    require Selecto::Action;
    return Selecto::Action->authorize_and_issue($plan, $phase, engine => $engine, %options);
}
my $dispatch = sub {
    my ($self, $engine, $phase, $options) = @_;
    my $plan = $bound_plan->($self);
    $checked_engine->($engine);
    my %plain = %$options;
    my $resolver = delete $plain{resolver};
    my $grant = delete $plain{grant};
    Selecto::Error->throw('invalid_argument', 'unknown planned action dispatch option')
        if grep { $_ ne 'context' } keys %plain;
    require Selecto::Domain::QueryContract;
    my $admitted = Selecto::Domain::QueryContract->copy_declaration(\%plain);
    Selecto::Error->throw('invalid_capability_decision', 'capability resolver must be explicit host code')
        if defined($resolver) && ref($resolver) ne 'CODE';
    Selecto::Error->throw('action_grant_invalid', 'planned action grant must be issued by the native engine')
        if defined($grant) && ((blessed($grant) // '') ne 'Selecto::Action::Grant'
            || (reftype($grant) // '') ne 'SCALAR');
    my %native = (%$admitted, defined($resolver) ? (resolver => $resolver) : (),
        defined($grant) ? (grant => $grant) : ());
    return $phase eq 'execute' ? $engine->execute_action($plan, %native)
        : $engine->preview_action($plan, %native);
};
sub execute {
    my ($self, $engine, %options) = @_;
    return $dispatch->($self, $engine, 'execute', \%options);
}
sub preview {
    my ($self, $engine, %options) = @_;
    return $dispatch->($self, $engine, 'preview', \%options);
}

1;

=head1 DESCRIPTION

C<authorize($engine, $phase, %host_options)> issues a genuine native action
grant. C<execute($engine, %host_options)> and C<preview($engine, %host_options)>
use the privately bound accepted plan through the native engine. A grant may
be supplied to consume its actual phase/context/single-use authorization. No
raw-plan getter is exposed; forged handles and modified engines refuse.

An opaque handle created only by C<Selecto::Action-E<gt>planned_operation>,
which first runs actual domain action planning. It is not an authored portable
Operation and confers no execution grant. Native action grants remain issued
by the configured Engine after host capability resolution, bound to the
original accepted plan, phase, context and expiry, and consumed once.

=cut
