use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();

{
    package CommitFailureDBH;
    our @ISA = ('TestSelecto::DBH');
    sub commit { die 'synthetic commit failure' }
}
my $domain = TestSelecto::writable_domain(name => 'Tasks', table => 'tasks', fields => {id => 'integer', name => 'string'});
my $db = CommitFailureDBH->new;
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $db));
my $runs = 0;
my $ok = eval { $engine->transaction(sub { ++$runs; return 'completed callback' }); 1 };
ok(!$ok, 'commit failure propagates after completed callback');
my $error = $@;
isa_ok($error, 'Selecto::Error');
is($error->details->{commit_state}, 'unknown', 'never claims safe rollback after ambiguous commit');
ok(!$error->details->{retryable}, 'commit ambiguity cannot authorize automatic retry');
is($runs, 1, 'callback never retries');

my $retry_adapter = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new,
    transaction_handler => sub { my ($work) = @_; $work->(); $work->() });
my $retry_engine = Selecto::Engine->new(domain => $domain, adapter => $retry_adapter);
$runs = 0;
$ok = eval { $retry_engine->transaction(sub { ++$runs; return 1 }); 1 };
ok(!$ok, 'host handler cannot replay callback');
is($@->code, 'invalid_transaction', 'stable callback replay refusal');
is($runs, 1, 'second callback invocation prevented before user code');
my $committed_adapter = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new,
    transaction_handler => sub {
        $_[0]->();
        Selecto::Error->throw('post_commit_failure', 'synthetic post-commit result failure',
            {committed => JSON::PP::true, retryable => JSON::PP::false, commit_state => 'committed'});
    });
my $committed_engine = Selecto::Engine->new(domain => $domain, adapter => $committed_adapter);
$ok = eval { $committed_engine->transaction(sub { return 1 }); 1 };
ok(!$ok, 'native post-commit failure propagates');
is($@->details->{commit_state}, 'committed', 'known native commit state is preserved');
ok($@->details->{committed} && !$@->details->{retryable}, 'native commit/retry flags preserved');
done_testing;
