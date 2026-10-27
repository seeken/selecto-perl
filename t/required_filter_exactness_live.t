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

# R3 clarification: a plain REQUIRED filter on a VARCHAR column compares by
# bytes on DuckDB (COLLATE NOCASE, default_collation 'nocase') and on MySQL
# and MariaDB, on a domain with no tenant and no host or trusted scope, for
# =, <>, IN, ranges, BETWEEN and prefix/substring/suffix matches, under NOT
# too. Required filters on non-text columns compare natively and are never
# refused as identity columns (item 49 is not extended to them). Caller
# filters keep the collation (item 55). Expected values are PostgreSQL's.
# The same holds when the column's declared type is a name Selecto does not
# know (R16): the stored type decides.
my $x = 'Selecto::Expression';
sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return 'ok ' . join(',', @$value) if !$@;
    return blessed($@) && $@->can('code') ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}
my @text = (
    ['eq', $x->eq('k', 't1'), '1'], ['ne', $x->ne('k', 't1'), '2,3,4'], ['in', $x->in('k', ['t1']), '1'],
    ['not eq', $x->not($x->eq('k', 't1')), '2,3,4'], ['gte', $x->gte('k', 't1'), '1,3,4'], ['lt', $x->lt('k', 't1'), '2'],
    ['between', $x->between('k', 't1', 't1'), '1'], ['not between', $x->not($x->between('k', 't1', 't1')), '2,3,4'],
    ['starts_with', $x->starts_with('k', 't1'), '1,3'], ['text_contains', $x->text_contains('k', 't1'), '1,3'],
    ['ends_with', $x->ends_with('k', 't1'), '1'], ['not starts_with', $x->not($x->starts_with('k', 't1')), '2,4'],
);
my @other = (
    ['eq decimal', $x->eq('d', '2.50'), '2'], ['gt decimal', $x->gt('d', '2'), '2,3,4'],
    ['between decimal', $x->between('d', '2', '3.5'), '2,3'], ['eq double', $x->eq('f', 2.5), '2'],
    ['lt double', $x->lt('f', 3), '1,2'], ['eq date', $x->eq('dt', '2024-06-02'), '2'], ['gte date', $x->gte('dt', '2024-06-03'), '3,4'],
);
my @lossy = (
    ['eq id 1.4 (integer)', $x->eq('id', '1.4'), 'query_rule_not_evaluable/inexact_literal'],
    ['eq id 1e0 (integer)', $x->eq('id', '1e0'), 'query_rule_not_evaluable/inexact_literal'],
    ['gt id 1.4 (integer)', $x->gt('id', '1.4'), 'query_rule_not_evaluable/inexact_literal'],
    ['eq id 1 (integer, exact)', $x->eq('id', '1'), 'ok 1'],
    ['eq d 2.505 (DECIMAL(10,2))', $x->eq('d', '2.505'), 'query_rule_not_evaluable/inexact_literal'],
    ['eq d 2.500 (DECIMAL(10,2), exact)', $x->eq('d', '2.500'), 'ok 2'],
    ['eq d 1e1 (DECIMAL(10,2))', $x->eq('d', '1e1'), 'query_rule_not_evaluable/inexact_literal'],
    ['eq f 2.5 (DOUBLE, exact)', $x->eq('f', '2.5'), 'ok 2'],
);
sub domain {
    my ($table, $required, $type) = @_;
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Required',
        source => {source_table => $table, primary_key => 'id', fields => [qw(id k d f dt)],
            columns => {id => {type => 'integer'}, k => {type => $type // 'string'}, d => {type => 'decimal'}, f => {type => 'float'},
                dt => {type => 'date'}}, associations => {}}, schemas => {}, joins => {}});
    return defined($required) ? $domain->with_required_predicate($required) : $domain;
}
sub run_cases {
    my ($label, $adapter, $table, $caller_want) = @_;
    my $ids = sub {
        my ($required, $filter, $type) = @_;
        my $engine = Selecto::Engine->new(domain => domain($table, $required, $type), adapter => $adapter);
        my $query = $engine->query->select('id')->order_by('id');
        $query = $query->where($filter) if $filter;
        return outcome(sub { [map { $_->[0] } @{$engine->all($query)->{rows}}] });
    };
    is($ids->($_->[1]), "ok $_->[2]", "$label: required $_->[0] on VARCHAR compares bytes") for @text;
    # R16: a declared type Selecto does not know (email, tenant_code) on a
    # VARCHAR column never falls back to the collated compare.
    for my $type (qw(email tenant_code)) {
        is($ids->($_->[1], undef, $type), "ok $_->[2]", "$label: required $_->[0] on a VARCHAR declared $type compares bytes") for @text;
    }
    is($ids->($_->[1]), "ok $_->[2]", "$label: required $_->[0] compares natively") for @other;
    is($ids->(undef, $x->starts_with('k', 't1')), "ok $caller_want", "$label: a caller prefix keeps the collation");
    # R3 clarification 2: a native compare only for a literal the stored type
    # holds exactly; a lossy or non-canonical one is refused, never rounded.
    for my $case (@lossy) {
        my ($name, $required, $want) = @$case;
        is($ids->($required), $want, "$label: required $name");
    }
}

SKIP: {
    skip 'DBD::DuckDB is not installed', 1 unless eval { require DBD::DuckDB; 1 };
    for my $config (['DuckDB COLLATE NOCASE', 'k VARCHAR COLLATE NOCASE', undef, '1,2,3'],
        ["DuckDB default_collation 'nocase'", 'k VARCHAR', q{SET default_collation = 'nocase'}, '1,3']) {
        my ($label, $ddl, $session, $caller) = @$config;
        my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do("CREATE TABLE t (id INTEGER PRIMARY KEY, $ddl, d DECIMAL(10,2), f DOUBLE, dt DATE)");
        $dbh->do(q{INSERT INTO t VALUES (1, 't1', 1.50, 1.5, DATE '2024-06-01'), (2, 'T1', 2.50, 2.5, DATE '2024-06-02'),
            (3, 't1 ', 3.50, 3.5, DATE '2024-06-03'), (4, 'u2', 4.50, 4.5, DATE '2024-06-04')});
        $dbh->do($session) if $session;
        run_cases($label, Selecto->adapter(duckdb => (dbh => $dbh)), 't', $caller);
    }
}

for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
    $dbh->do(q{SET time_zone = '+00:00'});
    $dbh->do('DROP TABLE IF EXISTS selecto_rfe');
    $dbh->do('CREATE TABLE selecto_rfe (id INT PRIMARY KEY, k VARCHAR(8), d DECIMAL(10,2), f DOUBLE, dt DATE) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO selecto_rfe VALUES (1, 't1', 1.50, 1.5, '2024-06-01'), (2, 'T1', 2.50, 2.5, '2024-06-02'),
        (3, 't1 ', 3.50, 3.5, '2024-06-03'), (4, 'u2', 4.50, 4.5, '2024-06-04')});
    run_cases($kind, Selecto->adapter($kind => (dbh => $dbh)), 'selecto_rfe', '1,2,3');
    $dbh->do('DROP TABLE IF EXISTS selecto_rfe');
    # MySQL compares a numeric column with a string as doubles: BIGINT and
    # wide DECIMAL values beyond 2^53 would match their neighbours. Accepted
    # literals are bound with an exact cast (R3 clarification 2).
    $dbh->do('DROP TABLE IF EXISTS selecto_rfe_wide');
    $dbh->do('CREATE TABLE selecto_rfe_wide (id INT PRIMARY KEY, big BIGINT, wide DECIMAL(30,2), u BIGINT UNSIGNED) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO selecto_rfe_wide VALUES (1, 9007199254740993, 1234567890123456789012345678.91, 18446744073709551615),
        (2, 9007199254740992, 1234567890123456789012345678.90, 1)});
    my $wide = sub {
        my ($required) = @_;
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($kind => (dbh => $dbh)), domain => Selecto::Domain->parse({
            schema_version => 1, name => 'Wide', source => {source_table => 'selecto_rfe_wide', primary_key => 'id', fields => [qw(id big wide u)],
                columns => {id => {type => 'integer'}, big => {type => 'integer'}, wide => {type => 'decimal'}, u => {type => 'integer'}},
                associations => {}}, schemas => {}, joins => {}})->with_required_predicate($required));
        return outcome(sub { [map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}}] });
    };
    is($wide->($x->eq('big', '9007199254740993')), 'ok 1', "$kind: a BIGINT beyond 2^53 matches exactly");
    is($wide->($x->eq('big', '9007199254740992')), 'ok 2', "$kind: and not its double neighbour");
    is($wide->($x->gt('big', '9007199254740992')), 'ok 1', "$kind: a BIGINT range is exact too");
    is($wide->($x->eq('wide', '1234567890123456789012345678.91')), 'ok 1', "$kind: a wide DECIMAL matches exactly");
    is($wide->($x->eq('wide', '1234567890123456789012345678.905')), 'query_rule_not_evaluable/inexact_literal',
        "$kind: a literal with more digits than the scale is refused");
    is($wide->($x->eq('u', '18446744073709551615')), 'ok 1', "$kind: an unsigned BIGINT matches exactly");
    is($wide->($x->eq('u', '-1')), 'query_rule_not_evaluable/inexact_literal', "$kind: a negative unsigned literal is refused");
    $dbh->do('DROP TABLE IF EXISTS selecto_rfe_wide');
    $dbh->disconnect;
}
done_testing;
