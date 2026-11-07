use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# A cancel can land on the ROLLBACK that ends a bounded stream's own transaction.
# DBI then counts the transaction over (turning AutoCommit on, which DBD::Pg ends
# with a COMMIT). The stream checks, and tries again as a statement, as a read does:
# once is a clean end. When even DBD::Pg's COMMIT was cancelled, the transaction is
# left aborted, and every try is cancelled: still a cancel, with the connection it
# could not end closed, never an uncategorized cleanup failure. (An unbounded stream
# is a read, and ends as one.)
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS src_t');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE src_t (id INT PRIMARY KEY)', 'INSERT INTO src_t SELECT generate_series(1, 5)';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'SRC', source => {source_table => 'src_t', primary_key => 'id',
    fields => ['id'], columns => {id => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {}});

# The ROLLBACK is cancelled $times times by a real cancel (the backend cancels itself
# in its place): a real 57014, and a transaction that is really aborted.
# Past the first, the transaction reads as aborted, as it is when the COMMIT that
# DBD::Pg sends on AutoCommit was cancelled too.
sub cancelled_rollbacks {
    my ($times, $work) = @_;
    my $left = $times;
    no warnings 'redefine';
    my $rollback = \&DBD::Pg::db::rollback;
    my $do = \&DBD::Pg::db::do;
    my $ping = \&DBD::Pg::db::pg_ping;
    local *DBD::Pg::db::pg_ping = sub { return $times > 1 && $left && $left < $times ? 4 : $ping->(@_) };
    my $cancel = sub {
        my ($dbh) = @_;
        $left--;
        local $dbh->{RaiseError} = 0;
        local $dbh->{PrintError} = 0;
        $do->($dbh, 'SELECT pg_catalog.pg_cancel_backend(pg_catalog.pg_backend_pid()), pg_catalog.pg_sleep(1)');
        return undef;
    };
    local *DBD::Pg::db::rollback = sub { return $left ? $cancel->($_[0]) : $rollback->(@_) };
    local *DBD::Pg::db::do = sub { return $left && ($_[1] // '') eq 'ROLLBACK' ? $cancel->($_[0]) : $do->(@_) };
    return $work->();
}

for my $route (qw(bounded)) {
    for my $case ([1, 'once'], [99, 'every time']) {
        my ($times, $label) = @$case;
        my $dbh = TestPostgreSQL->connect;
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
        my $rows = 0;
        my $ok = cancelled_rollbacks($times, sub {
            eval {
                my $s = $engine->stream($engine->query->select('id'), bounded => 1, fetch_size => 2);
                $rows++ while $s->next;
                $s->close;
                1;
            };
        });
        my $error = $@;
        my $kind = $ok ? 'ok' : blessed($error) && $error->can('details')
            ? join('/', $error->code, $error->details->{category} // '') : "untyped: $error";
        if ($times == 1) {
            is $kind, 'ok', "$route, cancelled $label: the stream still ends cleanly";
            is $rows, 5, "$route, cancelled $label: with every row";
            is $dbh->pg_ping, 1, "$route, cancelled $label: and its transaction is over";
            ok $dbh->{AutoCommit}, "$route, cancelled $label: with AutoCommit back on";
        } else {
            like $kind, qr{\A(?:stream_cleanup_failed|query_error)/query_canceled\z}, "$route, cancelled $label: still a cancel";
            ok !$dbh->{Active}, "$route, cancelled $label: and the connection it could not end is closed";
        }
        $dbh->disconnect if $dbh->{Active};
    }
}

done_testing;
