use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# A stream never rolls back or un-aborts the host's transaction. When its cursor
# is gone, because the host rolled back, committed, aborted or moved on, that is
# the host's transaction: the stream reports transaction_state_unsafe and leaves
# the connection alone. Only a cursor of its name that differs is a replacement.
# (A pin of behaviour that already held: t/pg_stream_host_work_live.t tests the rest.)
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS r64h_t, r64h_log');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE r64h_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT)', 'CREATE TABLE r64h_log (id SERIAL PRIMARY KEY, who TEXT)',
    q{INSERT INTO r64h_t SELECT g, 't1', 'n' FROM generate_series(1, 10) g};
my @f = qw(id org note);
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'H', source => {source_table => 'r64h_t', primary_key => 'id', tenant_field => 'org', fields => \@f,
    columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}});
my $insert = sub { $_[0]->do(q{INSERT INTO r64h_log (who) VALUES ('host')}) };
my $run = sub {
    my ($name, $raise, $before, $between, $after, $want_rows) = @_;
    $admin->do('TRUNCATE r64h_log');
    my ($dsn, @auth) = TestPostgreSQL->connection;
    my $dbh = DBI->connect($dsn, @auth, {RaiseError => $raise, PrintError => 0, AutoCommit => 1});
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1');
    $before->($dbh) if $before;
    my $stream = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 2);
    $stream->next for 1 .. 4;
    eval { $between->($dbh) };
    my $ok = eval { 1 while $stream->next; 1 };
    my $error = $@;
    ok(!$ok && blessed($error) && $error->code eq 'transaction_state_unsafe', "$name: the stream reports transaction_state_unsafe");
    eval { $after->($dbh) } if $after;
    is(join(',', @{$admin->selectcol_arrayref('SELECT who FROM r64h_log ORDER BY id')}), $want_rows, "$name: the host's rows are the host's to keep or lose");
    eval { $dbh->rollback } unless $dbh->{AutoCommit};
    $dbh->disconnect;
};
my $commit = sub { $_[0]->commit };
for my $raise (1, 0) {
    # The FETCH of the missing cursor aborts the transaction the host opened, as
    # it always has: its COMMIT rolls back, and the host is told. Nothing is
    # rolled back or un-aborted on its behalf.
    $run->("own stream, host rollback, begin, insert (RaiseError $raise)", $raise, undef,
        sub { $_[0]->rollback; $_[0]->begin_work; $insert->($_[0]) }, $commit, '');
    $run->("own stream, host commit, begin, insert (RaiseError $raise)", $raise, undef,
        sub { $_[0]->commit; $_[0]->begin_work; $insert->($_[0]) }, $commit, '');
    # An aborted transaction stays aborted: its COMMIT rolls back.
    $run->("host transaction aborted between fetches (RaiseError $raise)", $raise, sub { $_[0]->begin_work; $insert->($_[0]) },
        sub { local $_[0]->{RaiseError} = 0; $_[0]->do('SELECT 1/0') }, $commit, '');
}

# A TimeZone the host sets between fetches, in the stream's own transaction: the stream
# pins its own for each FETCH and reads every row, calling nothing replaced, and the
# close says the host's setting went with the stream's transaction.
{
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1');
    my $all = scalar @{$e->all($e->query->select('id')->order_by('id'))->{rows}};
    my $stream = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 2);
    my $n = 0;
    $n++, $stream->next for 1 .. 2;
    $dbh->do(q{SET LOCAL TimeZone = 'Asia/Tokyo'});
    my $ok = eval { $n++ while $stream->next; 1 };
    my $error = $@;
    is($n, $all, 'a setting the host changes between fetches does not stop the stream: it reads every row');
    ok(!$ok && ref($error) && $error->code eq 'stream_host_work_discarded', 'and the close says the setting was rolled back')
        or diag $error;
    $dbh->disconnect;
}

done_testing;
