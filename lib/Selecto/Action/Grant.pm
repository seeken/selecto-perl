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
        Selecto::Error->throw('action_grant_mismatch', "action grant was issued for a different $key",
            {binding => $key}) unless defined($have) && defined($want) && "$have" eq "$want";
    }
    $record->{used} = 1;
    return {%{$record->{decision}}, grant => $record->{id}};
}

sub DESTROY { delete $GRANTS{refaddr $_[0]} if defined $_[0]; }

1;

__END__

=head1 NAME

Selecto::Action::Grant - single-use, phase-bound action authorization

=cut
