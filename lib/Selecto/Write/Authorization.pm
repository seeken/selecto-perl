package Selecto::Write::Authorization;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);
use Selecto::Error ();

# Proof that Selecto::Engine governed one exact write request.
#
# The engine issues an authorization for the command, batch, or graph it has
# validated against its domain, and passes both to the adapter. Adapters refuse
# to execute a write without a live authorization for that exact object, so a
# raw command handed to an adapter cannot skip domain governance. Each
# authorization is used once.
#
# Authorizations are opaque: the registry below is the only record of what was
# issued, so blessing a lookalike object authorizes nothing.

my %ISSUED;

sub _issue {
    my ($class, $subject) = @_;
    my ($package) = caller;
    Selecto::Error->throw('ungoverned_write', 'write authorizations are issued by Selecto::Engine')
        unless $package eq 'Selecto::Engine';
    Selecto::Error->throw('invalid_write', 'authorization subject must be a write object')
        unless blessed($subject);
    my $token = bless \(my $opaque = undef), $class;
    $ISSUED{refaddr $token} = refaddr $subject;
    return $token;
}

# Consumes the authorization when it covers $subject; throws otherwise.
sub require_for {
    my ($class, $subject, $authorization) = @_;
    my $key = blessed($authorization) && $authorization->isa(__PACKAGE__)
        ? refaddr($authorization) : undef;
    Selecto::Error->throw(
        'ungoverned_write',
        'adapter writes run through Selecto::Engine; trusted tooling may call the *_unsafe adapter methods',
    ) unless defined($key) && exists($ISSUED{$key})
        && blessed($subject) && $ISSUED{$key} == refaddr($subject);
    delete $ISSUED{$key};
    return 1;
}

sub DESTROY { delete $ISSUED{refaddr $_[0]} if defined $_[0]; }

1;

__END__

=head1 NAME

Selecto::Write::Authorization - single-use proof that a write was governed

=head1 DESCRIPTION

Issued only by L<Selecto::Engine> for the exact command, batch, or graph it
validated. SQL adapters require one for C<execute_write>, C<execute_batch>,
and C<execute_graph>. The C<*_unsafe> adapter methods skip the check and are
reserved for trusted internal tooling and adapter tests.

=cut
