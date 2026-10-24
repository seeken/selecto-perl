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

# DuckDB has no savepoints, so in transaction_mode 'external' a write runs
# directly in the host's transaction. A write Selecto could refuse after its
# statement ran (an expected count, a guarded scope, foreign-key guards, a
# multi-node graph) used to leave its DML behind: a bound-scope delete with
# expected_count 2 deleted row 1 and then failed cardinality_mismatch, and
# the host's COMMIT kept the delete. Such writes are now refused before any
# DML with transaction_unavailable (reason no_savepoints); unchecked writes
# still run directly, and managed mode is unchanged.
plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'DuckExternal',
    source => {source_table => 'selecto_duck_ext', primary_key => 'id', fields => [qw(id note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1}, insert => {enabled => 1}, delete => {enabled => 1, bulk => 1}},
        fields => {note => {updatable => 1, insertable => 1}, id => {insertable => 1}, org_key => {insertable => 1}}}});
my $setup = sub {
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE selecto_duck_ext (id INTEGER PRIMARY KEY, org_key VARCHAR, note VARCHAR)');
    $dbh->do(q{INSERT INTO selecto_duck_ext VALUES (1, 't1', 'n'), (2, 't2', 'n')});
    return $dbh;
};
my $rows = sub { join ' ', map { join ':', @$_ } @{$_[0]->selectall_arrayref('SELECT id, org_key, note FROM selecto_duck_ext ORDER BY id')} };
my $outcome = sub {
    my ($code) = @_;
    return eval { $code->(); 'applied' } // do {
        my $e = $@; blessed($e) ? $e->code . (($e->details // {})->{reason} ? '/' . $e->details->{reason} : '') : "died: $e" };
};
my %checked = (
    'a bound-scope delete with expected_count' => sub { Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_duck_ext',
        predicate => $x->in('id', [1, 2]), scope_predicate => $x->eq('org_key', 't1'), expected_count => 2) },
    'an unscoped update with expected_count' => sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext',
        assignments => {note => 'x'}, predicate => $x->in('id', [1, 9]), expected_count => 2) },
    'an update declaring at most one row over two ids' => sub { Selecto::Write::Command->new(operation => 'update',
        relation => 'selecto_duck_ext', assignments => {note => 'x'}, predicate => $x->in('id', [1, 2]),
        expected_count => undef, metadata => {expected_cardinality => ['at_most', 1]}) },
    'an update by a non-key predicate' => sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext',
        assignments => {note => 'x'}, predicate => $x->eq('note', 'n')) },
);
# Writes no post-statement check can refuse after changing rows: their count
# check can fail only when nothing was affected.
my %harmless = (
    'an update by primary key (expected 1)' => [sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext',
        assignments => {note => 'direct'}, predicate => $x->eq('id', 1)) }, '1:t1:direct 2:t2:n'],
    'a scoped delete by primary key' => [sub { Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_duck_ext',
        predicate => $x->eq('id', 1), scope_predicate => $x->eq('org_key', 't1')) }, '2:t2:n'],
    'an insert' => [sub { Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_duck_ext',
        assignments => {id => 3, org_key => 't1', note => 'i'}) }, '1:t1:n 2:t2:n 3:t1:i'],
    'an update matching nothing' => [sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext',
        assignments => {note => 'x'}, predicate => $x->eq('id', 9), expected_count => undef) }, '1:t1:n 2:t2:n'],
);
for my $case (sort keys %checked) {
    my $dbh = $setup->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh, transaction_mode => 'external')), domain => $domain);
    $dbh->begin_work;
    my $code = $outcome->(sub { $engine->execute_write($checked{$case}->()) });
    $dbh->commit;
    is($code, 'transaction_unavailable/no_savepoints', "external: $case is refused before any DML");
    is($rows->($dbh), '1:t1:n 2:t2:n', "external: $case, and the host's commit keeps nothing");
}
{
    my $dbh = $setup->();
    my $adapter = Selecto->adapter(duckdb => (dbh => $dbh, transaction_mode => 'external'));
    $dbh->begin_work;
    my $code = $outcome->(sub { $adapter->execute_batch_unsafe(Selecto::Write::Batch->new(
        Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext', assignments => {note => 'a'}, predicate => $x->eq('id', 2)),
        $checked{'an unscoped update with expected_count'}->())) });
    $dbh->commit;
    is($code, 'transaction_unavailable/no_savepoints', 'external: a batch with one checked command is refused before any DML');
    is($rows->($dbh), '1:t1:n 2:t2:n', 'external: batch, nothing kept');
    $dbh->begin_work;
    $code = $outcome->(sub { $adapter->execute_graph_unsafe(Selecto::Write::Graph->new(nodes => [
        {id => 'a', command => Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext', assignments => {note => 'a'}, predicate => $x->eq('id', 1))},
        {id => 'b', command => Selecto::Write::Command->new(operation => 'update', relation => 'selecto_duck_ext', assignments => {note => 'b'}, predicate => $x->eq('id', 2))},
    ])) });
    $dbh->commit;
    is($code, 'transaction_unavailable/no_savepoints', 'external: a multi-node graph is refused before any DML');
    is($rows->($dbh), '1:t1:n 2:t2:n', 'external: graph, nothing kept');
}
# Writes that cannot be refused after changing rows run directly.
for my $case (sort keys %harmless) {
    my ($command, $expected) = @{$harmless{$case}};
    my $dbh = $setup->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh, transaction_mode => 'external')), domain => $domain);
    $dbh->begin_work;
    is($outcome->(sub { $engine->execute_write($command->()) }), 'applied', "external: $case runs directly");
    $dbh->commit;
    is($rows->($dbh), $expected, "external: $case, and the host commits it");
}
for my $case (sort keys %checked) {
    my $dbh = $setup->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => $domain);
    my $code = $outcome->(sub { $engine->execute_write($checked{$case}->()) });
    isnt($code, 'transaction_unavailable/no_savepoints', "managed: $case keeps its own checks ($code)");
    like($rows->($dbh), qr/\A(?:1:t1:n 2:t2:n|1:t1:x 2:t2:x|2:t2:n)\z/, "managed: $case rolls back or applies as a whole");
}
done_testing;
