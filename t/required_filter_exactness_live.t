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
sub domain {
    my ($table, $required) = @_;
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Required',
        source => {source_table => $table, primary_key => 'id', fields => [qw(id k d f dt)],
            columns => {id => {type => 'integer'}, k => {type => 'string'}, d => {type => 'decimal'}, f => {type => 'float'},
                dt => {type => 'date'}}, associations => {}}, schemas => {}, joins => {}});
    return defined($required) ? $domain->with_required_predicate($required) : $domain;
}
sub run_cases {
    my ($label, $adapter, $table, $caller_want) = @_;
    my $ids = sub {
        my ($required, $filter) = @_;
        my $engine = Selecto::Engine->new(domain => domain($table, $required), adapter => $adapter);
        my $query = $engine->query->select('id')->order_by('id');
        $query = $query->where($filter) if $filter;
        return outcome(sub { [map { $_->[0] } @{$engine->all($query)->{rows}}] });
    };
    is($ids->($_->[1]), "ok $_->[2]", "$label: required $_->[0] on VARCHAR compares bytes") for @text;
    is($ids->($_->[1]), "ok $_->[2]", "$label: required $_->[0] compares natively") for @other;
    is($ids->(undef, $x->starts_with('k', 't1')), "ok $caller_want", "$label: a caller prefix keeps the collation");
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
    $dbh->disconnect;
}
done_testing;
