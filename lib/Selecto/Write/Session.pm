package Selecto::Write::Session;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(refaddr blessed);
use JSON::PP ();
use Selecto::Error ();

fieldhash my %SESSION;
sub run {
    my ($class, $engine, $work, @extra) = @_;
    Selecto::Error->throw('invalid_transaction', 'transaction requires one host callback')
        unless ref($work) eq 'CODE' && !@extra;
    $engine->assert_domain_identity;
    my $tx = $engine->with_limits($engine->limits);
    my $session = {active => 0, adapter => $engine->adapter};
    $SESSION{$tx} = $session;
    my ($ran, $finished, $result, $error) = (0, 0);
    my $ok = eval { $result = $engine->_rules_transaction(sub {
        Selecto::Error->throw('invalid_transaction', 'transaction callback cannot be retried') if $ran++;
        $session->{active} = 1;
        my ($value, $error);
        my $ok = eval { $value = $work->($tx); 1 };
        $error = $@ unless $ok;
        if ($ok && $session->{failure}) { $ok = 0; $error = $session->{failure} }
        $session->{active} = 0;
        die $error unless $ok;
        $finished = 1;
        return $value;
    }); 1 };
    if (!$ok) {
        $error = $@;
        $session->{active} = 0;
        if ($finished && blessed($error) && $error->isa('Selecto::Error')) {
            my %details = %{$error->details};
            $details{commit_state} //= exists($details{committed}) && defined($details{committed})
                ? ($details{committed} ? 'committed' : 'rolled_back') : 'unknown';
            $details{retryable} //= JSON::PP::false;
            die Selecto::Error->new(code => $error->code, message => $error->message,
                details => \%details);
        }
        die $error;
    }
    return $result;
}
sub poison {
    my ($class, $engine, $error) = @_;
    my $session = $SESSION{$engine};
    $session->{failure} //= $error if $session && $session->{active};
}
sub inherit {
    my ($class, $from, $to) = @_;
    Selecto::Error->throw('invalid_transaction', 'session inheritance is engine-owned')
        unless caller eq 'Selecto::Engine';
    $SESSION{$to} = $SESSION{$from} if exists $SESSION{$from};
    return $to;
}
sub require_live {
    my ($class, $engine) = @_;
    $engine->assert_domain_identity;
    my $session = $SESSION{$engine};
    Selecto::Error->throw('edit_handle_expired', 'editable rows require a live engine transaction callback')
        unless $session && $session->{active} && refaddr($engine->adapter) == refaddr($session->{adapter});
    die $session->{failure} if $session->{failure};
    # Dialect owns connection and actual server transaction identity. Returning
    # a scalar key or merely seeing AutoCommit disabled is not equivalent.
    my $identity = $engine->adapter->edit_transaction_identity;
    if (defined $session->{identity}) {
        Selecto::Error->throw('edit_handle_expired', 'transaction or connection lease changed')
            unless $identity eq $session->{identity};
    } else {
        $session->{identity} = $identity;
    }
    return $session;
}

1;
