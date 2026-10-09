package Selecto::Verification::WriteCapabilitySafety;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed reftype);
use JSON::PP ();
use Selecto::Write ();
use Selecto::Expression ();
use Selecto::Write::Capabilities ();
use Selecto::Error ();

my @PROFILES = qw(full no_returning flat_only missing_version wrong_version);
my @SHAPES = qw(insert insert_returning update batch graph generated_graph);
my @INVARIANTS = qw(dispatch_matches_independent_matrix missing_semantics_fail_closed protocol_mismatch_never_dispatches);

sub _capabilities {
    my ($profile) = @_;
    my $base = {protocol_version => 1, map { $_ => 1 } qw(insert update delete upsert transactions atomic_batch write_graph)};
    @{$base}{qw(returning generated_keys)} = (0, 0);
    if ($profile eq 'full') { @{$base}{qw(returning generated_keys)} = (1, 'returning') }
    elsif ($profile eq 'flat_only') { return {protocol_version => 1, insert => 1, update => 1, returning => 0} }
    elsif ($profile eq 'missing_version') { delete $base->{protocol_version} }
    elsif ($profile eq 'wrong_version') { $base->{protocol_version} = 99 }
    return $base;
}
sub _command {
    my ($operation, %options) = @_;
    return Selecto::Write::Command->new(operation => $operation, relation => $options{relation} // 'items',
        assignments => {name => 'safe'}, metadata => $options{returning} ? {returning => ['id']} : {},
        $operation eq 'update' ? (predicate => Selecto::Expression->eq('id', 1)) : ());
}
sub _write {
    my ($shape) = @_;
    return _command('insert') if $shape eq 'insert';
    return _command('insert', returning => 1) if $shape eq 'insert_returning';
    return _command('update') if $shape eq 'update';
    return Selecto::Write::Batch->new(_command('insert'), _command('update')) if $shape eq 'batch';
    my $generated = $shape eq 'generated_graph';
    return Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => _command('insert', returning => $generated)},
        {id => 'children', command => _command('insert', relation => 'children'),
            bindings => $generated ? [{field => 'parent_id', from => 'root', key => 'id'}] : []},
    ]);
}
sub _expected {
    my ($profile, $shape) = @_;
    return 1 if $profile eq 'full';
    return $shape eq 'insert' || $shape eq 'update' || $shape eq 'batch' || $shape eq 'graph' if $profile eq 'no_returning';
    return $shape eq 'insert' || $shape eq 'update' if $profile eq 'flat_only';
    return 0;
}
sub states {
    my @states;
    for my $profile (@PROFILES) {
        for my $shape (@SHAPES) {
            push @states, {profile => $profile, shape => $shape, capabilities => _capabilities($profile), write => _write($shape)};
        }
    }
    return \@states;
}
sub verify {
    my ($class, %options) = @_;
    Selecto::Error->throw('invalid_argument', 'unknown write capability safety option') if grep { $_ ne 'preflight' } keys %options;
    my $preflight = $options{preflight} // sub { Selecto::Write::Capabilities->require(@_) };
    Selecto::Error->throw('invalid_argument', 'preflight verifier must be an explicit host callback') unless ref($preflight) eq 'CODE';
    my (@counterexamples, $state_count, $check_count); $state_count = $check_count = 0;
    for my $state (@{$class->states}) {
        ++$state_count;
        my $expected = _expected(@{$state}{qw(profile shape)});
        for my $invariant (@INVARIANTS) {
            ++$check_count;
            my ($result, $error);
            { local $@; my $ok = eval { $result = $preflight->($state->{capabilities}, $state->{write}); 1 }; $error = $@ unless $ok }
            my $success = !defined($error) && defined($result) && !defined(reftype($result)) && $result eq '1';
            my $typed_error = defined($error) && length(blessed($error) // '') && UNIVERSAL::isa($error, 'Selecto::Error');
            my $valid = $invariant eq 'dispatch_matches_independent_matrix' ? !!$success == !!$expected
                : $invariant eq 'missing_semantics_fail_closed' ? $expected || $typed_error
                : $state->{profile} eq 'missing_version' || $state->{profile} eq 'wrong_version' ? !$success : 1;
            push @counterexamples, {state => {map { $_ => $state->{$_} } qw(profile shape)}, invariant => $invariant,
                expected_dispatch => $expected ? JSON::PP::true : JSON::PP::false,
                actual_dispatch => $success ? JSON::PP::true : JSON::PP::false} unless $valid;
        }
    }
    return {proof_level => 'bounded_exhaustive', model => 'selecto.write_capability_preflight.v1',
        state_count => $state_count, check_count => $check_count, invariant_count => scalar(@INVARIANTS), counterexamples => \@counterexamples};
}
1;

=head1 DESCRIPTION

The complete finite D063 dispatch model enumerates five actual adapter reports
against six native command, batch and two-row graph shapes. Every invariant
calls public capability preflight; counts reflect executed states/checks. Its
independent matrix covers absent returning, graph/batch support and protocol
versions. The optional explicit host C<preflight> callback supports meaningful
fault injection. This model proves only its finite capability boundary, not
driver, SQL, transaction or arbitrary native write behavior.

=cut
