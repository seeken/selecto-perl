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

# Review finding R3 on DuckDB: a prefix, substring or suffix match in host,
# trusted or required scope on a VARCHAR identity column matches its bytes,
# whatever the column's COLLATE NOCASE or the session's default_collation,
# as PostgreSQL's oracle answers for the fixture; a case-insensitive match
# there is refused, and a match on a non-VARCHAR identity column too.
# Caller matches keep DuckDB's collation.
plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
my $x = 'Selecto::Expression';
sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return 'ok ' . join(',', @$value) if !$@;
    return blessed($@) && $@->can('code') ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}
for my $config (['COLLATE NOCASE column', 'org_key VARCHAR COLLATE NOCASE', undef],
    ["default_collation 'nocase'", 'org_key VARCHAR', q{SET default_collation = 'nocase'}]) {
    my ($label, $ddl, $session) = @$config;
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do("CREATE TABLE t (id INTEGER PRIMARY KEY, $ddl, n INTEGER, note VARCHAR)");
    $dbh->do(q{INSERT INTO t VALUES (1, 't1', 11, 'mine'), (2, 'T1', 12, 'SECRET'), (3, 't1 ', 13, 'pad'), (4, 'xt1_', 14, 'x')});
    $dbh->do($session) if $session;
    my $ids = sub {
        my ($required, $filter) = @_;
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'D',
            source => {source_table => 't', primary_key => 'id', fields => [qw(id org_key n note)],
                columns => {id => {type => 'integer'}, org_key => {type => 'string'}, n => {type => 'integer'}, note => {type => 'string'}},
                associations => {}}, schemas => {}, joins => {}});
        $domain = $domain->with_required_predicate($required) if $required;
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(duckdb => (dbh => $dbh)));
        my $query = $engine->query->select('id')->order_by('id');
        $query = $query->where($filter) if $filter;
        return outcome(sub { [map { $_->[0] } @{$engine->all($query)->{rows}}] });
    };
    is($ids->($x->starts_with('org_key', 't1')), 'ok 1,3', "$label: a scope prefix matches bytes");
    is($ids->($x->text_contains('org_key', 't1')), 'ok 1,3,4', "$label: a scope substring matches bytes");
    is($ids->($x->ends_with('org_key', 't1')), 'ok 1', "$label: a scope suffix matches bytes");
    is($ids->($x->not($x->starts_with('org_key', 't1'))), 'ok 2,4', "$label: and stays exact under NOT");
    is($ids->($x->starts_with('org_key', 't1_')), 'ok ', "$label: LIKE wildcards in the value are literal");
    is($ids->($x->starts_with_ci('org_key', 't1')), 'query_rule_not_evaluable/inexact_text',
        "$label: a case-insensitive scope match is refused");
    like($ids->($x->eq('n', 11), $x->starts_with('org_key', 't1')), qr/\Aok 1\z/, "$label: a caller prefix still filters");
    like($ids->(undef, $x->starts_with('org_key', 't1')), qr/\Aok 1,2,3\z|\Aok 1,3\z/, "$label: a caller prefix keeps DuckDB's own match");
}
done_testing;
