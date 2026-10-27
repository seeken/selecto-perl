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

# Round-3 review R40 on MySQL and MariaDB: a VIEW column derived from a
# TIMESTAMP (ts + INTERVAL 0 SECOND, COALESCE over a DATETIME) reports
# DATETIME but may still be converted in the session zone, which a view
# function can switch within one statement. A scope compare on a temporal
# view column is trusted only when the view definition maps it directly to a
# base DATETIME column; otherwise it is refused (view_column_unproven).
# Columns that report TIMESTAMP keep the epoch compare.
my $x = 'Selecto::Expression';
my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    $dbh->do($_) for 'DROP VIEW IF EXISTS svt_view', 'DROP TABLE IF EXISTS svt_base', 'DROP FUNCTION IF EXISTS svt_fn',
        q{CREATE FUNCTION svt_fn(i INT) RETURNS INT DETERMINISTIC NO SQL BEGIN
            IF @svt_arm = 2 AND i = 1 THEN SET time_zone = '-05:00'; END IF;
            IF @svt_arm = 2 AND i = 3 THEN SET time_zone = '+00:00'; END IF; RETURN i; END},
        'CREATE TABLE svt_base (id INT PRIMARY KEY, ts TIMESTAMP NULL, dt DATETIME NULL) ENGINE=InnoDB',
        q{INSERT INTO svt_base VALUES (1, '2023-12-31 22:00:00', '2023-12-31 22:00:00'), (2, '2024-01-01 03:00:00', '2024-01-01 03:00:00'),
            (3, '2023-06-01 00:00:00', '2023-06-01 00:00:00'), (4, '2023-06-02 00:00:00', '2023-06-02 00:00:00')};
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'ViewTemporal',
        source => {source_table => 'svt_view', primary_key => 'id', fields => [qw(id ts k)],
            columns => {id => {type => 'integer'}, ts => {type => 'naive_datetime'}, k => {type => 'integer'}}, associations => {}},
        schemas => {}, joins => {}})->with_required_predicate($x->lt('ts', '2024-01-01 00:00:00'));
    my %views = (
        'a TIMESTAMP column' => ['ts', 'ok 1,3,4'],
        'a TIMESTAMP shifted by INTERVAL 0 SECOND' => ['ts + INTERVAL 0 SECOND', 'query_rule_not_evaluable/view_column_unproven'],
        'a COALESCE over a DATETIME' => ['COALESCE(dt)', 'query_rule_not_evaluable/view_column_unproven'],
        'a direct DATETIME column' => ['dt', 'ok 1,3,4'],
        # R40b: the reported type decides nothing; DATE_FORMAT(ts) reports
        # VARCHAR and still reads the session zone.
        'a DATE_FORMAT over a TIMESTAMP' => ["DATE_FORMAT(ts, '%Y-%m-%d %H:%i:%s')", 'query_rule_not_evaluable/view_column_unproven'],
        'a CAST of a TIMESTAMP to DATETIME' => ['CAST(ts AS DATETIME)', 'query_rule_not_evaluable/view_column_unproven'],
    );
    # R40c/R40d: the proof reads the definition with a real lexer, accepts
    # only a single SELECT over base tables, and resolves an alias through
    # that SELECT's own FROM list (never a table merely named like it).
    my ($database) = $dbh->selectrow_array('SELECT DATABASE()');
    my $fake = "`$database`.`svt_base`.`dt` AS `ts`";
    $dbh->do('DROP TABLE IF EXISTS svt_decoy');
    $dbh->do('CREATE TABLE svt_decoy (id INT PRIMARY KEY, ts DATETIME NULL) ENGINE=InnoDB');
    my %bodies = (
        'an aliased TIMESTAMP passthrough in a join' => ['SELECT svt_decoy.id, svt_decoy.ts AS ts, svt_fn(svt_decoy.id) AS k FROM svt_base svt_decoy'
            . ' JOIN svt_base AS other ON other.id = svt_decoy.id', 'ok 1,3,4'],
        'an aliased DATETIME passthrough' => ['SELECT z.id, z.dt AS ts, svt_fn(z.id) AS k FROM svt_base z', 'ok 1,3,4'],
        'faked by a doubled-quote literal' => ["SELECT id, 'a'', $fake, ''b' AS junk, ts + INTERVAL 0 SECOND AS ts, svt_fn(id) AS k FROM svt_base",
            'query_rule_not_evaluable/view_column_unproven'],
        'faked by a backslash-escaped literal' => ["SELECT id, 'a\\', $fake, \\'b' AS junk, ts + INTERVAL 0 SECOND AS ts, svt_fn(id) AS k FROM svt_base",
            'query_rule_not_evaluable/view_column_unproven'],
        'read through a derived table' => ['SELECT d.id, d.dt AS ts, d.k FROM (SELECT id, ts AS dt, svt_fn(id) AS k FROM svt_base) d',
            'query_rule_not_evaluable/view_column_unproven'],
        'a UNION with an earlier DATE_FORMAT branch' => ["SELECT id, DATE_FORMAT(ts, '%Y-%m-%d %H:%i:%s') AS ts, svt_fn(id) AS k FROM svt_base WHERE id < 0"
            . ' UNION ALL SELECT id, ts, svt_fn(id) FROM svt_base', 'query_rule_not_evaluable/view_column_unproven'],
    );
    my %cases = ((map { ($_ => ["SELECT id, $views{$_}[0] AS ts, svt_fn(id) AS k FROM svt_base", $views{$_}[1]]) } keys %views), %bodies);
    for my $label (sort keys %cases) {
        my ($body, $want) = @{$cases{$label}};
        $dbh->do('DROP VIEW IF EXISTS svt_view');
        $dbh->do("CREATE VIEW svt_view AS $body");
        for my $arm (0, 2) {
            $dbh->do("SET \@svt_arm = $arm");
            my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
            my $rows = eval { [map { $_->[0] } @{$engine->all($engine->query->select('id', 'k')->order_by('id'))->{rows}}] };
            my $got = $rows ? 'ok ' . join(',', @$rows)
                : blessed($@) ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
            $dbh->do('SET @svt_arm = 0');
            $dbh->do(q{SET time_zone = '+00:00'});
            is($got, $want, "$name: a scope compare on a view column that is $label" . ($arm ? ' (zone switched mid-read)' : ''));
        }
    }
    $dbh->do($_) for 'DROP VIEW IF EXISTS svt_view', 'DROP TABLE IF EXISTS svt_base', 'DROP TABLE IF EXISTS svt_decoy', 'DROP FUNCTION IF EXISTS svt_fn';

    # R40d regression: an alias named like a decoy table takes the type of
    # the table it aliases (VARCHAR), not the decoy's (INT), so tenant 1
    # matches only the exact text '1'.
    $dbh->do($_) for 'DROP VIEW IF EXISTS svt_keys', 'DROP TABLE IF EXISTS svt_items', 'DROP TABLE IF EXISTS svt_dd',
        'CREATE TABLE svt_items (id INT PRIMARY KEY, org_key VARCHAR(20)) ENGINE=InnoDB',
        q{INSERT INTO svt_items VALUES (1, '1'), (2, '01'), (3, ' 1'), (4, '1x'), (5, 'T1'), (6, 't1 '), (7, 't1')},
        'CREATE TABLE svt_dd (id INT PRIMARY KEY, org_key INT) ENGINE=InnoDB',
        'CREATE VIEW svt_keys AS SELECT svt_dd.id, svt_dd.org_key AS org_key FROM svt_items svt_dd';
    for my $case (['integer', 1, 'ok 1'], ['string', 't1', 'ok 7']) {
        my ($type, $tenant, $want) = @$case;
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), scope => {tenant => $tenant},
            domain => Selecto::Domain->parse({schema_version => 1, name => 'Keys', source => {source_table => 'svt_keys', primary_key => 'id',
                tenant_field => 'org_key', fields => [qw(id org_key)], columns => {id => {type => 'integer'}, org_key => {type => $type}},
                associations => {}}, schemas => {}, joins => {}}));
        my $rows = eval { [map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}}] };
        my $got = $rows ? 'ok ' . join(',', @$rows)
            : blessed($@) ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
        is($got, $want, "$name: a view aliasing a table like a decoy takes the aliased table's type ($type tenant)");
    }
    $dbh->do($_) for 'DROP VIEW IF EXISTS svt_keys', 'DROP TABLE IF EXISTS svt_items', 'DROP TABLE IF EXISTS svt_dd';
    $dbh->disconnect;
}
done_testing;
