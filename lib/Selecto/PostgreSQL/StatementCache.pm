package Selecto::PostgreSQL::StatementCache;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(refaddr);

# Handles are kept by DBI's prepare_cached, so they live in the database
# handle's CachedKids and are freed with it. The private attribute keeps
# these entries apart from the host's own prepare_cached entries for the
# same SQL; the cache key is the SQL text and this attribute, nothing else.
my $ATTRIBUTES = {private_selecto_statement_cache => 1};
my $USED = 'private_selecto_statement_used';
my $RETIRED = "\0selecto_retired\0";
my $RETIRED_LENGTH = length $RETIRED;

# Runs $sql with @$params on a statement handle kept for this connection
# and returns the executed handle. Options: size (entries kept), execute
# (code: handle, params), normalize (code: error -> Selecto::Error) and
# failure (the message when execute returns undef without raising).
sub execute {
    my ($class, $dbh, $sql, $params, %options) = @_;
    # if_active 1: a handle left active by an interrupted fetch is finished.
    my $sth = $dbh->prepare_cached($sql, $ATTRIBUTES, 1);
    die _message($dbh, $options{failure}) unless $sth;
    # The handle's own text must match exactly before it runs, so no other
    # statement can ever run under this entry.
    unless (defined($sth->{Statement}) && $sth->{Statement} eq $sql) {
        _retire($dbh, $sth);
        $sth = $dbh->prepare_cached($sql, $ATTRIBUTES, 1);
        die _message($dbh, $options{failure}) unless $sth;
        die "statement cache returned a handle for different SQL\n"
            unless defined($sth->{Statement}) && $sth->{Statement} eq $sql;
    }
    my $cached = defined $sth->{$USED};
    my ($ok, $error) = _run($sth, $params, \%options);
    # Failures are normalized here, before anything else runs on the handle
    # or the handle is dropped, either of which would clear its SQLSTATE.
    my $normalize = $options{normalize} // sub { $_[0] };
    if (!$ok && $cached) {
        my $state = eval { $sth->state } // '';
        my $normalized = $normalize->($error);
        die $normalized unless $state eq '26000' || $state eq '0A000';
        # The statement is gone (26000: DISCARD ALL, DEALLOCATE) or its
        # result type changed (0A000).
        _retire($dbh, $sth);
        undef $sth;
        # Prepare once more only outside any transaction: in one, the failure
        # has aborted it and the original error is the answer.
        my $status = eval { $dbh->pg_ping } // 0;
        die $normalized unless $status == 1;
        $sth = $dbh->prepare_cached($sql, $ATTRIBUTES, 1);
        die _message($dbh, $options{failure}) unless $sth;
        $cached = 0;
        ($ok, $error) = _run($sth, $params, \%options);
    }
    if (!$ok) {
        # A handle whose first execution failed was never prepared on the
        # server (DBD::Pg sends it unnamed), so dropping it touches nothing.
        my $normalized = $normalize->($error);
        _forget_entry($dbh, $sth) unless $cached;
        die $normalized;
    }
    $sth->{$USED} = ++$dbh->{private_selecto_statement_clock};
    # Safe point: the statement succeeded, so the transaction (if any) is
    # healthy and deallocating retired or evicted handles cannot disturb it.
    _drain($dbh) if $dbh->{private_selecto_statement_retired};
    _evict($dbh, $options{size} // 256) unless $cached;
    return $sth;
}

# Forgets every cached handle without deallocating on the server, for a
# host that has run DISCARD ALL or DEALLOCATE ALL on the connection.
sub forget {
    my ($class, $dbh) = @_;
    my $kids = _kids($dbh) or return;
    local $dbh->{pg_skip_deallocate} = 1;
    my @keys = grep { substr($_, 0, $RETIRED_LENGTH) eq $RETIRED || _ours($kids->{$_}) } keys %$kids;
    delete @{$kids}{@keys};
    $dbh->{private_selecto_statement_retired} = 0;
    return;
}

# The number of handles this cache keeps for the connection.
sub count {
    my ($class, $dbh) = @_;
    my $kids = _kids($dbh) or return 0;
    return scalar grep { substr($_, 0, $RETIRED_LENGTH) ne $RETIRED && _ours($kids->{$_}) } keys %$kids;
}

sub _kids {
    my ($dbh) = @_;
    my $kids = eval { $dbh->{CachedKids} };
    return ref($kids) eq 'HASH' ? $kids : undef;
}

# Entries this cache made (and that succeeded at least once).
sub _ours {
    my ($sth) = @_;
    return ref($sth) && defined(eval { $sth->{$USED} }) ? 1 : 0;
}

sub _key_of {
    my ($kids, $sth) = @_;
    my $address = refaddr($sth);
    return grep { ref($kids->{$_}) && refaddr($kids->{$_}) == $address && substr($_, 0, $RETIRED_LENGTH) ne $RETIRED }
        keys %$kids;
}

sub _forget_entry {
    my ($dbh, $sth) = @_;
    my $kids = _kids($dbh) or return;
    delete @{$kids}{_key_of($kids, $sth)};
    return;
}

sub _run {
    my ($sth, $params, $options) = @_;
    my $result;
    my $ok = eval { $result = $options->{execute}->($sth, $params); 1 };
    return (0, $@) unless $ok;
    # Without RaiseError a failed execute returns undef. It is a failure here
    # too, so a failed statement is never cached or counted as a safe point.
    return (0, _message($sth, $options->{failure})) unless defined $result;
    return (1);
}

sub _message {
    my ($handle, $fallback) = @_;
    my $message = eval { $handle->errstr };
    return defined($message) && length("$message") ? "$message" : ($fallback // 'database execution failed');
}

# Moves an entry aside without destroying its handle. Destroying a handle
# prepared on the server deallocates it, and DBD::Pg rolls back a failed
# transaction to do that, so retired handles wait for the next safe point.
sub _retire {
    my ($dbh, $sth) = @_;
    my $kids = _kids($dbh) or return;
    my @keys = _key_of($kids, $sth);
    return unless @keys;
    delete @{$kids}{@keys};
    $kids->{$RETIRED . refaddr($sth)} = $sth;
    $dbh->{private_selecto_statement_retired} = 1;
    return;
}

sub _drain {
    my ($dbh) = @_;
    my $kids = _kids($dbh);
    delete @{$kids}{grep { substr($_, 0, $RETIRED_LENGTH) eq $RETIRED } keys %$kids} if $kids;
    $dbh->{private_selecto_statement_retired} = 0;
    return;
}

# After a new entry: drops the least recently used entries beyond the bound.
sub _evict {
    my ($dbh, $size) = @_;
    my $kids = _kids($dbh) or return;
    my %used;
    for my $key (keys %$kids) {
        next if substr($key, 0, $RETIRED_LENGTH) eq $RETIRED || !ref($kids->{$key});
        my $tick = eval { $kids->{$key}{$USED} };
        $used{$key} = $tick if defined $tick;
    }
    my $excess = keys(%used) - $size;
    return if $excess <= 0;
    my @oldest = (sort { $used{$a} <=> $used{$b} } keys %used)[0 .. $excess - 1];
    delete @{$kids}{@oldest};
    return;
}

1;

__END__

=head1 NAME

Selecto::PostgreSQL::StatementCache - opt-in per-connection statement handles

=head1 DESCRIPTION

Used by L<Selecto::PostgreSQL> when its C<statement_cache> attribute is
true. Each distinct SQL text keeps one DBI statement handle per database
handle (through C<prepare_cached>, with a private attribute that keeps these
entries apart from the host's own), so DBD::Pg prepares it on the server as a named statement (on its
second execution, by DBD::Pg's C<pg_switch_prepared> default) and later
executions send only Bind/Execute. The cache is keyed by the exact SQL text
and nothing else; parameter values are always bound, never part of a key or
a statement name (DBD::Pg names statements C<dbdpg_pPID_N>).

At most C<statement_cache_size> handles are kept per connection; the least
recently used one is dropped, and DBD::Pg deallocates it. Handles are
dropped only right after a statement succeeded, never inside a failed
transaction (where DBD::Pg would roll back to deallocate).

A statement the server no longer has (SQLSTATE 26000) or whose result type
changed (0A000) is dropped and prepared once more when the connection is
outside a transaction. Inside one, the original error is returned, as the
transaction is already aborted; the next call prepares afresh.

=head1 METHODS

=head2 forget

  Selecto::PostgreSQL::StatementCache->forget($dbh);

Drops the cached handles without deallocating them. Call it after running
C<DISCARD ALL> or C<DEALLOCATE ALL> on a handle that has cached statements.

=head2 count

The number of cached handles on a database handle.

=cut
