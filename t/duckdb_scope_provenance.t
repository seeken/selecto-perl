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
use Selecto::QueryEnforcement ();
use Selecto::Write ();

# Round-3 review R25 and R26 on DuckDB: a write's caller predicate keeps
# DuckDB's collation even on a column its query enforcement or host scope
# compares (the scope stays exact); a column declared integer over VARCHAR
# storage compares the canonical integer text by bytes in scope, and a range
# on it is refused.
plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
my $x = 'Selecto::Expression';
sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return 'ok ' . (ref($value) eq 'ARRAY' ? join(',', @$value) : $value // '') if !$@;
    return blessed($@) && $@->can('code') ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'W',
    source => {source_table => 'w', primary_key => 'id', fields => [qw(id k note)],
        columns => {id => {type => 'integer'}, k => {type => 'string'}, note => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
        delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
for my $case (['update', 'query_enforcement'], ['delete', 'query_enforcement'], ['delete', 'scope_predicate']) {
    my ($operation, $mode) = @$case;
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE w (id INTEGER PRIMARY KEY, k VARCHAR COLLATE NOCASE, note VARCHAR)');
    $dbh->do(q{INSERT INTO w VALUES (1, 'a', 'n'), (2, 'B', 'n'), (3, 'b', 'n'), (4, 'A', 'n')});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(duckdb => (dbh => $dbh)));
    my %extra = $mode eq 'query_enforcement'
        ? (query_enforcement => Selecto::QueryEnforcement->capture($domain, $engine->query->where($x->in('k', ['a', 'B']))))
        : (scope_predicate => $x->in('k', ['a', 'B']));
    is(outcome(sub { $engine->execute_write(Selecto::Write::Command->new(operation => $operation, relation => 'w',
        ($operation eq 'update' ? (assignments => {note => 'u'}) : ()),
        predicate => $x->all($x->eq('id', 2), $x->eq('k', 'b')), %extra))->affected_rows }), 'ok 1',
        "$operation $mode: the caller's k = 'b' keeps the collation");
}
my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE codes (id INTEGER PRIMARY KEY, code VARCHAR)');
$dbh->do(q{INSERT INTO codes VALUES (1, '1'), (2, '01'), (3, ' 1'), (4, '1x'), (5, '10'), (6, '5')});
my $codes = sub {
    my ($required) = @_;
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => Selecto::Domain->parse({schema_version => 1,
        name => 'Codes', source => {source_table => 'codes', primary_key => 'id', fields => [qw(id code)],
            columns => {id => {type => 'integer'}, code => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {}})
        ->with_required_predicate($required));
    return outcome(sub { [map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}}] });
};
is($codes->($x->eq('code', '01')), 'ok 1', 'a non-canonical integer literal compares as its canonical text');
is($codes->($x->eq('code', 1)), 'ok 1', 'an integer literal matches only the canonical text');
is($codes->($x->gte('code', 5)), 'query_rule_not_evaluable/inexact_text', 'a range on an integer stored as text is refused');
done_testing;
