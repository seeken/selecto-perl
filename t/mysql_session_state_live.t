use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();

# Items 59 and 62: a row trigger or a view's stored function can SET
# time_zone or sql_mode. MySQL then compares later rows' TIMESTAMPs (and a
# write's post-image re-read) under the new zone, and the session stays
# changed for the host. Every write and read compares the session with its
# verified state: on a change it is restored and the operation refused (a
# write rolls back). Ordinary triggers (updated_at) keep working.
my $x = 'Selecto::Expression';
my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;

sub domain {
    my ($table, $write, @extra) = @_;
    return Selecto::Domain->parse({schema_version => 1, name => 'SessionState',
        source => {source_table => $table, primary_key => 'id', fields => [qw(id org_key ts note), @extra],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, ts => {type => 'naive_datetime'},
                note => {type => 'string'}, map { ($_ => {type => 'integer'}) } @extra}, associations => {}},
        schemas => {}, joins => {},
        ($write ? (writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {note => {updatable => 1}}}) : ())});
}
sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return defined($value) ? "ok $value" : blessed($@) ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my ($mode) = $dbh->selectrow_array('SELECT @@SESSION.sql_mode');
    my $session = sub { join ' / ', $dbh->selectrow_array('SELECT @@SESSION.time_zone, @@SESSION.sql_mode') };
    my $verified = "+00:00 / $mode";
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my $reset = sub {
        my ($body) = @_;
        $dbh->do('DROP TABLE IF EXISTS selecto_session_items');
        $dbh->do('CREATE TABLE selecto_session_items (id INT PRIMARY KEY, org_key VARCHAR(8), ts TIMESTAMP NULL,'
            . ' note VARCHAR(16), touched TIMESTAMP NULL) ENGINE=InnoDB');
        $dbh->do(q{INSERT INTO selecto_session_items VALUES (1, 't1', '2023-06-01 00:00:00', 'open', NULL)});
        $dbh->do("CREATE TRIGGER selecto_session_trg BEFORE UPDATE ON selecto_session_items FOR EACH ROW BEGIN $body END") if $body;
    };
    my $state = sub { join ' ', map { join ':', map { $_ // 'NULL' } @$_ } @{$dbh->selectall_arrayref(
        'SELECT id, CAST(ts AS CHAR), note FROM selecto_session_items ORDER BY id')} };
    my $engine = Selecto::Engine->new(adapter => $adapter, domain => domain('selecto_session_items', 1));
    my $write = sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_session_items',
        assignments => {note => 'x'}, predicate => $x->eq('id', 1), scope_predicate => $x->lt('ts', '2024-01-01 00:00:00')))->affected_rows };
    # (A stored program's own SET sql_mode is undone when it returns, so only
    # the time zone can leak out of a trigger.)
    for my $change ([q{SET NEW.ts = '2024-01-01 03:00:00'; SET time_zone = '-05:00';}, 'moving time_zone'],
        [q{SET time_zone = '-05:00';}, 'time_zone']) {
        for my $host (0, 1) {
            my $label = "$name $change->[1] trigger" . ($host ? ' in a host transaction' : '');
            $reset->($change->[0]);
            $dbh->begin_work if $host;
            is(outcome($write), 'query_rule_violation/session_state_changed', "$label: the write is refused");
            $dbh->commit if $host;
            is($session->(), $verified, "$label: the session is restored");
            is($state->(), '1:2023-06-01 00:00:00:open', "$label: the write is rolled back");
        }
    }
    # An ordinary updated_at trigger keeps working.
    $reset->('SET NEW.touched = CURRENT_TIMESTAMP;');
    is(outcome($write), 'ok 1', "$name: an updated_at trigger keeps working");
    is($state->(), '1:2023-06-01 00:00:00:x', "$name: and the write applies");

    # Reads: a view's function switches the zone after row 1.
    $dbh->do('DROP VIEW IF EXISTS selecto_session_view');
    $dbh->do('DROP FUNCTION IF EXISTS selecto_session_fn');
    $dbh->do('DROP TABLE IF EXISTS selecto_session_base');
    $dbh->do('CREATE TABLE selecto_session_base (id INT PRIMARY KEY, org_key VARCHAR(8), ts TIMESTAMP NULL, note VARCHAR(16)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO selecto_session_base VALUES (1, 't1', '2023-12-31 22:00:00', 'in'),
        (2, 't1', '2024-01-01 03:00:00', 'OUT'), (3, 't1', '2023-12-31 20:00:00', 'in3')});
    $dbh->do(q{CREATE FUNCTION selecto_session_fn(i INT) RETURNS INT DETERMINISTIC NO SQL
        BEGIN IF @selecto_arm = 1 AND i = 1 THEN SET time_zone = '-05:00'; END IF; RETURN i; END});
    $dbh->do('CREATE VIEW selecto_session_view AS SELECT id, org_key, ts, note, selecto_session_fn(id) AS k FROM selecto_session_base');
    my $reader = Selecto::Engine->new(adapter => $adapter,
        domain => domain('selecto_session_view', 0, 'k')->with_required_predicate($x->lt('ts', '2024-01-01 00:00:00')));
    my $query = $reader->query->select('id', 'note', 'k')->order_by('id');
    my %reads = (
        read => sub { join ',', map { $_->[1] } @{$reader->all($query)->{rows}} },
        stream => sub { my $s = $reader->stream($query); my @n; while (my $r = $s->next) { push @n, $r->[1] } join ',', @n },
    );
    for my $kind (sort keys %reads) {
        $dbh->do('SET @selecto_arm = 0');
        is(outcome($reads{$kind}), 'ok in,in3', "$name $kind: an unarmed function changes nothing");
        $dbh->do('SET @selecto_arm = 1');
        is(outcome($reads{$kind}), 'query_rule_violation/session_state_changed', "$name $kind: a zone switch mid-read is refused");
        $dbh->do('SET @selecto_arm = 0');
        is($session->(), $verified, "$name $kind: and the session is restored");
    }
    $dbh->do('DROP VIEW IF EXISTS selecto_session_view');
    $dbh->do('DROP FUNCTION IF EXISTS selecto_session_fn');
    $dbh->do('DROP TABLE IF EXISTS selecto_session_base');
    $dbh->do('DROP TABLE IF EXISTS selecto_session_items');
}
done_testing;
