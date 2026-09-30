package Selecto::Action::Grant;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed refaddr);
use Time::HiRes ();
use Selecto::Error ();

# A single-use, phase-bound authorization for one action plan.
#
# Selecto::Engine->grant_action asks the host's capability resolver once and
# issues a grant bound to the phase, the plan's content, the domain
# fingerprint, the engine's trusted tenant, and the actor. preview_action or
# execute_action consumes it: it works once, for that exact binding, before it
# expires. Grants are opaque; this registry is the only record of what was
# issued, so a blessed lookalike authorizes nothing.

my %GRANTS;
my $JSON = JSON::PP->new->canonical(1)->allow_blessed(1)->convert_blessed(0);

sub _issue {
    my ($class, %binding) = @_;
    my ($package) = caller;
    Selecto::Error->throw('action_grant_invalid', 'action grants are issued by Selecto::Engine')
        unless $package eq 'Selecto::Engine';
    my $grant = bless \(my $opaque = undef), $class;
    my $id = sha256_hex(join ':', refaddr($grant), Time::HiRes::time(), rand());
    $GRANTS{refaddr $grant} = {%binding, id => substr($id, 0, 32)};
    return $grant;
}

# Stable digest of a plan's content (action, operation, target, changes, ...).
sub plan_digest {
    my ($class, $plan) = @_;
    return sha256_hex($JSON->encode($plan->to_hash));
}

sub id       { my $record = $GRANTS{refaddr $_[0]}; return $record ? $record->{id} : undef; }
sub phase    { my $record = $GRANTS{refaddr $_[0]}; return $record ? $record->{phase} : undef; }
sub decision { my $record = $GRANTS{refaddr $_[0]}; return $record ? {%{$record->{decision}}} : undef; }

# Consumes $grant for %expected; returns its decision or throws.
sub consume {
    my ($class, $grant, %expected) = @_;
    my $record = blessed($grant) && $grant->isa(__PACKAGE__) ? $GRANTS{refaddr $grant} : undef;
    Selecto::Error->throw('action_grant_invalid', 'action grant is unknown, used, or expired')
        unless $record && !$record->{used}
            && (!defined($record->{expires_at}) || Time::HiRes::time() < $record->{expires_at});
    for my $key (qw(phase plan domain tenant actor)) {
        my ($have, $want) = ($record->{$key}, $expected{$key});
        next if !defined($have) && !defined($want);
        next if defined($have) && defined($want) && "$have" eq "$want";
        # A grant presented for another binding may have leaked; revoke it.
        $record->{used} = 1;
        Selecto::Error->throw('action_grant_mismatch', "action grant was issued for a different $key",
            {binding => $key});
    }
    $record->{used} = 1;
    return {%{$record->{decision}}, grant => $record->{id}};
}

sub DESTROY { delete $GRANTS{refaddr $_[0]} if defined $_[0]; }

1;

__END__

=head1 NAME

Selecto::Action::Grant - single-use, phase-bound action authorization

=head1 SYNOPSIS

  my $grant = $engine->grant_action($plan, phase => 'execute',
      resolver => $policy, context => $ctx, expires_in => 300);

  # later, on the same engine tenant and actor:
  my $done = $engine->execute_action($plan, grant => $grant, context => $ctx);
  audit($done->{decision}{grant} eq $grant->id);

=head1 DESCRIPTION

A grant records that a host resolver approved one phase of one action plan,
so that authorization and execution can happen at different moments (for
example across a confirmation step). Grants are issued only by
L<Selecto::Engine/grant_action> and are bound to the phase, a digest of the
plan's content, the domain fingerprint, the engine's trusted tenant and the
context's actor.

A grant works once and only before it expires. Using it with a different
binding fails with C<action_grant_mismatch> and revokes it; a used, revoked,
expired or forged grant fails with C<action_grant_invalid>. A denied
capability issues no grant.

Grants are opaque in-process objects: the record of what was issued lives in
the Perl process that issued it, so a grant cannot be serialized, stored or
used from another process. Letting the grant object go out of scope revokes
it.

=head1 METHODS

=over 4

=item C<id>

An opaque identifier for audit records; also returned as
C<< $result->{decision}{grant} >> when the grant is consumed.

=item C<phase>

C<preview> or C<execute>.

=item C<decision>

A copy of the resolver decision.

=item C<plan_digest($plan)>

Class method: the stable SHA-256 digest of a plan's content.

=back

=head1 SEE ALSO

L<Selecto>, L<Selecto::Engine/grant_action>, L<Selecto::Action>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
