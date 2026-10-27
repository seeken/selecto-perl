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
# base DATETIME column; otherwise it is refused (view_temporal_column).
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
        'a TIMESTAMP shifted by INTERVAL 0 SECOND' => ['ts + INTERVAL 0 SECOND', 'query_rule_not_evaluable/view_temporal_column'],
        'a COALESCE over a DATETIME' => ['COALESCE(dt)', 'query_rule_not_evaluable/view_temporal_column'],
        'a direct DATETIME column' => ['dt', 'ok 1,3,4'],
    );
    for my $label (sort keys %views) {
        my ($expression, $want) = @{$views{$label}};
        $dbh->do('DROP VIEW IF EXISTS svt_view');
        $dbh->do("CREATE VIEW svt_view AS SELECT id, $expression AS ts, svt_fn(id) AS k FROM svt_base");
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
    $dbh->do($_) for 'DROP VIEW IF EXISTS svt_view', 'DROP TABLE IF EXISTS svt_base', 'DROP FUNCTION IF EXISTS svt_fn';
    $dbh->disconnect;
}
done_testing;
