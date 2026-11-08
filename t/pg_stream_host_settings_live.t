use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# A bounded stream in the host's transaction pins search_path and the result-affecting
# settings for its own statements only. Between fetches the host's statements run under
# the host's settings, a write lands where it would with no stream open, and what the
# host sets between fetches is still in force after the stream closes. A stream that
# locks rows keeps its locks all the same.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP TABLE IF EXISTS hs_t, hs_w', 'DROP SCHEMA IF EXISTS hs_app CASCADE');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE SCHEMA hs_app', 'CREATE TABLE hs_t (id INT PRIMARY KEY, at TIMESTAMPTZ NOT NULL)',
    q{INSERT INTO hs_t SELECT i, TIMESTAMPTZ '2026-01-02 03:04:05+00' + i * INTERVAL '1 hour' FROM generate_series(1, 5) i},
    'CREATE TABLE hs_w (k TEXT, ts TIMESTAMPTZ, d DATE, seen TEXT)', 'CREATE TABLE hs_app.hs_w (k TEXT, ts TIMESTAMPTZ, d DATE, seen TEXT)';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HS', source => {source_table => 'hs_t', primary_key => 'id',
    fields => [qw(id at)], columns => {id => {type => 'integer'}, at => {type => 'timestamptz'}}, associations => {}}, schemas => {}, joins => {}});

my $settings = q{SELECT pg_catalog.current_setting('TimeZone') || ' ' || pg_catalog.current_setting('DateStyle') || ' '
    || pg_catalog.current_setting('search_path') || ' ' || pg_catalog.current_setting('extra_float_digits')};

# The host's session: its own zone, date order, path and float digits.
sub host {
    my $dbh = TestPostgreSQL->connect;
    $dbh->do($_) for q{SET TimeZone = 'Asia/Tokyo'}, q{SET DateStyle = 'SQL, DMY'}, 'SET search_path = hs_app, public',
        'SET extra_float_digits = 0';
    return ($dbh, Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh)));
}

my %result;
for my $locks (0, 1) {
    for my $mode (qw(none stream)) {
        my $label = ($locks ? 'locking ' : '') . $mode;
        my ($dbh, $engine) = host();
        my $query = $engine->query->select('id', 'at')->order_by('id');
        $query = $query->for_share if $locks;
        $dbh->begin_work;
        my ($stream, @rows) = (undef);
        if ($mode eq 'stream') {
            $stream = $engine->stream($query, bounded => 1, fetch_size => 1);
            push @rows, $stream->next;
        }
        my $between = $dbh->selectrow_array($settings);
        $dbh->do(q{INSERT INTO hs_w VALUES (?, '2026-01-02 10:00', '03/04/2026', (} . $settings . '))', undef, $label);
        $dbh->do(q{SET LOCAL TimeZone = 'Europe/Paris'});
        my $ok = eval {
            if ($stream) {
                while (my $row = $stream->next) { push @rows, $row }
                $stream->close;
            } else {
                @rows = @{$engine->all($query)->{rows}};
            }
            1;
        };
        my $error = $ok ? undef : ref($@) && $@->can('message') ? $@->code . ': ' . $@->message : "$@";
        eval { $dbh->rollback } unless $ok;
        my $held = do {
            my $other = TestPostgreSQL->connect;
            $other->begin_work;
            my $free = eval { $other->do('SELECT 1 FROM hs_t WHERE id = 1 FOR UPDATE NOWAIT'); 1 };
            $other->rollback;
            $other->disconnect;
            $free ? 'free' : 'locked';
        };
        my $after = $ok ? $dbh->selectrow_array($settings) : undef;
        $dbh->commit if $ok;
        $result{$label} = {between => $between, after => $after, held => $held, rows => [map { [@$_] } @rows], error => $error};
        $dbh->disconnect;
    }
    my ($plain, $streamed) = map { $result{($locks ? 'locking ' : '') . $_} } qw(none stream);
    my $kind = $locks ? 'a locking stream' : 'a stream';
    is $streamed->{error}, undef, "a host's SET LOCAL between fetches does not change what $kind reads";
    is $streamed->{between}, $plain->{between}, "with $kind open, the host's statements see the host's settings";
    is $streamed->{after}, $plain->{after}, "what the host set between fetches is in force after $kind closes";
    is_deeply $streamed->{rows}, $plain->{rows}, "$kind returns what the same read returns";
    is $streamed->{held}, ($locks ? 'locked' : 'free'), $locks ? 'and keeps its row lock' : 'and holds no lock';
}
my $public = $admin->selectall_arrayref(q{SELECT k FROM public.hs_w ORDER BY k});
is_deeply $public, [], 'no host write fell to another schema';
my $app = $admin->selectall_arrayref(q{SELECT k, ts AT TIME ZONE 'UTC', d, seen FROM hs_app.hs_w ORDER BY k});
is scalar(@$app), 4, 'every host write landed in its own schema' or diag explain $app;
is_deeply [map { [@{$_}[1 .. 3]] } @$app[1 .. 3]], [map { [@{$app->[0]}[1 .. 3]] } 1 .. 3],
    'with the same time, date and settings as with no stream open';

done_testing;
