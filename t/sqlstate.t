use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();
use Selecto::Stream ();

# A DBI double whose SQLSTATE, like DBI's, is cleared by the next call on the
# handle: rollback, or finish on one of its statements.
package StateDBH {
    our @ISA = ('TestSelecto::DBH');
    sub state    { return $_[0]{state} // ''; }
    sub rollback { my ($self) = @_; $self->{state} = ''; return $self->SUPER::rollback; }
    sub prepare  { my ($self, $sql) = @_; push @{$self->{prepared}}, $sql; return $self->{next_sth}->(); }
}

package StateSTH {
    sub new { my ($class, %args) = @_; return bless {%args}, $class; }
    sub execute { my ($self) = @_; $self->{owner}{state} = $self->{state}; die "$self->{message}\n"; }
    sub fetchrow_array { my ($self) = @_; $self->{owner}{state} = $self->{state}; die "$self->{message}\n"; }
    sub finish { $_[0]{owner}{state} = ''; return 1; }
    sub err { return 1; }
    sub errstr { return $_[0]{message}; }
}

package main;

sub failing_dbh {
    my ($state, $message) = @_;
    my $dbh = StateDBH->new;
    $dbh->{next_sth} = sub { StateSTH->new(owner => $dbh, state => $state, message => $message) };
    return $dbh;
}
my $command = Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => {name => 'after'},
    predicate => Selecto::Expression->eq('id', 7),
);

sub write_error {
    my ($state) = @_;
    my $dbh = failing_dbh($state, 'canceling statement due to lock timeout');
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    my $ok = eval { $adapter->execute_write_unsafe($command); 1 };
    return ($ok ? undef : $@, $dbh);
}

my ($lock, $lock_dbh) = write_error('55P03');
is $lock->code, 'query_error', 'a lock timeout stays a query_error';
is_deeply $lock->details, {cause => 'database_error', sqlstate => '55P03', category => 'database_error'},
    'a lock timeout keeps its SQLSTATE through the rollback';
is_deeply $lock_dbh->events, ['BEGIN', 'ROLLBACK'], 'the failed write was rolled back';
is $lock_dbh->state, '', 'the rollback cleared the handle state';

my ($deadlock) = write_error('40P01');
is_deeply $deadlock->details, {cause => 'database_error', sqlstate => '40P01', category => 'deadlock_detected'},
    'a deadlock is categorized';
my ($serialization) = write_error('40001');
is $serialization->details->{category}, 'serialization_failure', 'a serialization failure is categorized';
my ($canceled) = write_error('57014');
is $canceled->details->{category}, 'query_canceled', 'a statement timeout is categorized';

for my $generic ('', '00000', 'S1000', 'HY000', 'nonsense') {
    my ($error) = write_error($generic);
    is_deeply $error->details, {cause => 'database_error'},
        "no SQLSTATE is reported for '$generic'";
}

# A handle without state() (older doubles, custom adapters) is unchanged.
my $plain = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new);
is_deeply $plain->normalize_error("boom\n")->details, {cause => 'database_error'},
    'a handle without state reports only the cause';

# The constraint codes keep their specific public errors.
my $unique_dbh = StateDBH->new;
$unique_dbh->{state} = '23505';
is(Selecto::PostgreSQL->new(dbh => $unique_dbh)->normalize_error("duplicate\n")->code,
    'database_unique_violation', 'a unique violation keeps its specific code');

# A stream normalizes before close, which finishes the statement and clears
# the state.
my $stream_dbh = failing_dbh('57014', 'canceling statement due to statement timeout');
my $stream_adapter = Selecto::PostgreSQL->new(dbh => $stream_dbh);
my $stream = Selecto::Stream->new(
    sth => $stream_dbh->{next_sth}->(), columns => ['id'], types => ['integer'],
    decode => sub { $_[0] }, normalize_error => sub { $stream_adapter->normalize_error($_[0]) },
);
my $stream_error = eval { $stream->next; 1 } ? undef : $@;
is $stream_error->details->{sqlstate}, '57014', 'a stream failure keeps its SQLSTATE through close';
ok $stream->closed, 'the failed stream is closed';

subtest 'live PostgreSQL lock timeout' => sub {
    my $dsn = $ENV{SELECTO_PERL_SQLSTATE_TEST_DSN};
    plan skip_all => 'set SELECTO_PERL_SQLSTATE_TEST_DSN to a disposable PostgreSQL'
        unless $dsn && eval { require DBI; require DBD::Pg; 1 };
    my %attrs = (RaiseError => 1, PrintError => 0, AutoCommit => 1);
    my $holder = DBI->connect($dsn, undef, undef, \%attrs);
    my $caller = DBI->connect($dsn, undef, undef, \%attrs);
    $holder->do('CREATE TABLE IF NOT EXISTS selecto_sqlstate_probe (id integer PRIMARY KEY, name text)');
    $holder->do('INSERT INTO selecto_sqlstate_probe VALUES (7, $$before$$) ON CONFLICT (id) DO NOTHING');
    $holder->begin_work;
    $holder->do('SELECT 1 FROM selecto_sqlstate_probe WHERE id = 7 FOR UPDATE');
    $caller->do(q{SET lock_timeout = '50ms'});
    my $adapter = Selecto::PostgreSQL->new(dbh => $caller);
    my $probe = Selecto::Write::Command->new(
        operation => 'update', relation => 'selecto_sqlstate_probe', assignments => {name => 'after'},
        predicate => Selecto::Expression->eq('id', 7),
    );
    my $error = eval { $adapter->execute_write_unsafe($probe); 1 } ? undef : $@;
    ok $error, 'the blocked write fails';
    is $error && $error->details->{sqlstate}, '55P03', 'the lock timeout SQLSTATE reaches the caller';
    ok $caller->{AutoCommit}, 'the caller handle is idle after the rollback';
    $holder->rollback;
    $holder->do('DROP TABLE selecto_sqlstate_probe');
    $_->disconnect for $holder, $caller;
};

done_testing;
