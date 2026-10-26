use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }
use Selecto::SQLite;

# Stored-stage rules validate a candidate inside the write's native
# transaction. A host transaction_handler must open that transaction on the
# adapter's connection (its documented contract); a handler that runs the
# work in autocommit is refused before business DML for stored-rule writes.
sub domain {
    my ($rules) = @_;
    return {name => 'Handler', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id name)], columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}},
        schemas => {}, writes => {operations => {map { $_ => {enabled => JSON::PP::true,
                ($_ eq 'upsert' ? (conflict_targets => [['id']]) : ())} } qw(insert update upsert)},
            fields => {id => {insertable => JSON::PP::true}, name => {insertable => JSON::PP::true, updatable => JSON::PP::true}}},
        ($rules ? (rules => {schema => 'selecto.data_rules.v1',
            definitions => {nonblank => {version => 1, test => {op => 'text.nonblank'}}}, normalizers => {},
            bindings => {name => {subject => {scope => 'candidate', path => ['name']}, operations => [qw(insert update upsert)],
                rule => {id => 'nonblank', version => 1}}}}) : ())};
}
sub code_of {
    my ($work) = @_;
    return 'ok' if eval { $work->(); 1 };
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return join '/', $error->code, $error->details->{reason} // ();
}

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
$db->do(q{INSERT INTO items VALUES(1, 'stored')});
my @hooks; $db->sqlite_update_hook(sub { push @hooks, [@_] if $_[1] eq 'main' });
my $autocommit = sub { $_[0]->() };
my $transactional = sub {
    my ($work) = @_;
    return $work->() unless $db->{AutoCommit};
    $db->begin_work;
    my $value = eval { $work->() };
    if (my $error = $@) { $db->rollback; die $error }
    $db->commit;
    return $value;
};
my $engine = sub {
    my ($rules, $handler) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse(domain($rules)),
        adapter => Selecto::SQLite->new(dbh => $db, transaction_handler => $handler));
};
my $insert = sub { Selecto::Write::Command->new(operation => 'insert', relation => 'items', assignments => {id => $_[0], name => 'x'}) };
my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => 'items', assignments => {name => 'y'},
    predicate => Selecto::Expression->eq('id', $_[0]), expected_count => 1) };
my $upsert = sub { Selecto::Write::Command->new(operation => 'upsert', relation => 'items', assignments => {id => $_[0], name => 'z'},
    metadata => {conflict_target => ['id'], upsert_update_fields => ['name']}) };

subtest 'an autocommit handler cannot carry stored-rule writes' => sub {
    my $e = $engine->(1, $autocommit);
    for my $case (['insert', $insert->(2)], ['update', $update->(1)], ['upsert', $upsert->(1)]) {
        # A handler that runs the work outside a transaction is refused
        # before the stored-rule check is reached.
        is(code_of(sub { $e->execute_write($case->[1]) }), 'transaction_unavailable/autocommit',
            "$case->[0] with stored rules refuses before DML");
    }
    is(scalar @hooks, 0, 'no business row was mutated');
    is_deeply($db->selectall_arrayref('SELECT * FROM items ORDER BY id'), [[1, 'stored']], 'stored rows unchanged');
    ok($db->{AutoCommit}, 'the handle is left in autocommit');
};

subtest 'autocommit handlers are refused; transactional handlers carry every write' => sub {
    # A write can be refused after its statement, which an autocommit
    # handler could not undo: every write it runs is refused before DML.
    my $plain = $engine->(0, $autocommit);
    is(code_of(sub { $plain->execute_write($insert->(3)) }), 'transaction_unavailable/autocommit', 'autocommit handler refuses a rule-free insert');
    is(code_of(sub { $plain->execute_write($update->(3)) }), 'transaction_unavailable/autocommit', 'autocommit handler refuses a rule-free update');
    my $rule_free = $engine->(0, $transactional);
    is(code_of(sub { $rule_free->execute_write($insert->(3)) }), 'ok', 'transactional handler carries a rule-free insert');
    is(code_of(sub { $rule_free->execute_write($update->(3)) }), 'ok', 'transactional handler carries a rule-free update');
    my $e = $engine->(1, $transactional);
    is(code_of(sub { $e->execute_write($insert->(4)) }), 'ok', 'transactional handler carries a stored-rule insert');
    is(code_of(sub { $e->execute_write($update->(4)) }), 'ok', 'transactional handler carries a stored-rule update');
    is(code_of(sub { $e->execute_write($upsert->(1)) }), 'ok', 'transactional handler carries a protected upsert');
    is_deeply($db->selectall_arrayref('SELECT * FROM items ORDER BY id'), [[1, 'z'], [3, 'y'], [4, 'y']], 'admitted writes stored');
};

$db->sqlite_update_hook(undef);
$db->disconnect;
done_testing;
