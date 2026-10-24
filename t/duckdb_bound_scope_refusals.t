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

# DuckDB never re-reads an updated row, so a bound-scope update (engine
# tenant, writes.scope, host scope predicate, required tenant pin) is refused
# with write_capability_missing before any DML: a generated scope column
# moved the row out of its scope when only a source column was assigned.
# Updates without a bound scope keep working.
plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
my $x = 'Selecto::Expression';
my $state = sub { join ' ', map { join ':', map { $_ // 'NULL' } @$_ }
    @{$dbh->selectall_arrayref('SELECT id, org_key, note, gen FROM selecto_duck_rows ORDER BY id')} };
my $reset = sub {
    $dbh->do('DROP TABLE IF EXISTS selecto_duck_rows');
    $dbh->do(q{CREATE TABLE selecto_duck_rows (id INTEGER PRIMARY KEY, org_key VARCHAR, note VARCHAR, status VARCHAR,
        gen VARCHAR GENERATED ALWAYS AS (CASE WHEN note = 'evil' THEN 't2' ELSE org_key END) VIRTUAL)});
    $dbh->do(q{INSERT INTO selecto_duck_rows (id, org_key, note, status) VALUES (1, 't1', 'n', 'open'), (2, 't2', 'n', 'open')});
};
sub document {
    my (%o) = @_;
    return {schema_version => 1, name => 'DuckScope',
        source => {source_table => 'selecto_duck_rows', primary_key => 'id', fields => [qw(gen id note org_key status)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'},
                status => {type => 'string'}, gen => {type => 'string'}},
            associations => {}, ($o{tenant_field} ? (tenant_field => $o{tenant_field}) : ())},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}, status => {updatable => 1}},
            ($o{scope} ? (scope => {tenant => {field => 'gen', satisfied_by => ['trusted_context']}}) : ())},
        ($o{required} ? (required_filters => $o{required}) : ())};
}
my %bound = (
    'host scope predicate' => sub { (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document())),
        {scope_predicate => $x->eq('gen', 't1')}) },
    'engine tenant' => sub { (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document(tenant_field => 'gen')),
        scope => {tenant => 't1'}), {}) },
    'writes.scope' => sub { (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document(scope => 1)),
        scope => {tenant => 't1'}), {}) },
    'required tenant pin' => sub { (Selecto::Engine->new(adapter => $adapter,
        domain => Selecto::Domain->parse(document(tenant_field => 'gen', required => [['gen', 't1']]))), {}) },
);
my $run = sub {
    my ($engine, $extra, $assignments, %options) = @_;
    return eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_rows',
        assignments => $assignments, predicate => $x->eq('id', 1), %$extra,
        ($options{returning} ? (metadata => {returning => ['id']}) : ()))); 'applied' } // (blessed($@) ? $@->code : "died: $@");
};
for my $mode (sort keys %bound) {
    for my $returning (0, 1) {
        my $label = "$mode" . ($returning ? ', RETURNING' : '');
        $reset->();
        is($run->($bound{$mode}->(), {note => 'evil'}, returning => $returning), 'write_capability_missing',
            "$label: a bound-scope update is refused");
        is($state->(), '1:t1:n:t1 2:t2:n:t2', "$label: and the generated scope column did not move");
    }
}
for my $case (['no scope', document()], ['a plain required filter', document(required => [['status', 'open']])]) {
    $reset->();
    is($run->(Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($case->[1])), {}, {status => 'closed'}),
        'applied', "$case->[0]: the update applies");
    is($dbh->selectrow_array('SELECT status FROM selecto_duck_rows WHERE id = 1'), 'closed', "$case->[0]: as written");
}
$dbh->do('DROP TABLE IF EXISTS selecto_duck_rows');
done_testing;
