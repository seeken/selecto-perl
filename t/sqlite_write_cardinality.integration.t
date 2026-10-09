use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::SQLite;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is required' }

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
    {RaiseError=>1, PrintError=>0, AutoCommit=>1});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)');
my $adapter = Selecto::SQLite->new(dbh=>$db);
$adapter->write_capabilities; # Complete real driver feature discovery before counters.
my $raw = {schema_version=>1, name=>'Items',
    source=>{source_table=>'items', primary_key=>'id', fields=>[qw(id name)],
        columns=>{id=>{type=>'integer'},name=>{type=>'string'}}, associations=>{}}, schemas=>{}, joins=>{},
    writes=>{operations=>{insert=>{enabled=>JSON::PP::true},
        update=>{enabled=>JSON::PP::true,bulk=>JSON::PP::true,expected_cardinality=>'many'},
        delete=>{enabled=>JSON::PP::true,bulk=>JSON::PP::true,expected_cardinality=>'many'}},
        fields=>{id=>{insertable=>JSON::PP::true},name=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}}}};
my $engine = Selecto::Engine->new(domain=>Selecto::Domain->parse($raw, strict=>1), adapter=>$adapter);
sub reset_rows {
    $db->sqlite_set_authorizer(undef); $db->sqlite_update_hook(undef);
    $db->do('DELETE FROM items');
    $db->do(q{INSERT INTO items VALUES(1,'one'),(2,'two'),(3,'three')});
}
sub rows { $db->selectall_arrayref('SELECT id,name FROM items ORDER BY id') }
sub command {
    my ($range,%options) = @_;
    Selecto::Write::Command->new(operation=>'update', relation=>'items', assignments=>{name=>'changed'},
        predicate=>Selecto::Expression->lte('id', 2), expected_count=>undef,
        metadata=>{expected_cardinality=>$range}, %options);
}
sub reject {
    my ($label,$work,$code,%options) = @_;
    $db->sqlite_set_authorizer(undef); my $before = rows();
    my ($prepares,$updates) = (0,0);
    $db->sqlite_set_authorizer(sub { ++$prepares; 0 });
    $db->sqlite_update_hook(sub { ++$updates });
    my $ok = eval { $work->(); 1 }; my $error=$@;
    ok(!$ok && blessed($error) && UNIVERSAL::isa($error,'Selecto::Error'), "$label returns a typed error");
    is(blessed($error)?$error->code:'untyped', $code, "$label has the expected diagnostic");
    is($prepares,0,"$label never prepares any native SQL") if $options{no_sql};
    is($updates,0,"$label never mutates native SQLite") if $options{no_sql};
    ok($updates>0,"$label observes attempted native mutations before rollback") if $options{mutated};
    $db->sqlite_set_authorizer(undef); $db->sqlite_update_hook(undef);
    is_deeply(rows(),$before,"$label preserves all stored rows");
    is($db->sqlite_get_autocommit ? 1 : 0, $options{caller_transaction} ? 0 : 1,
        "$label preserves transaction ownership");
    return $error;
}
reset_rows();
for my $range ('many',['exactly',2],['at_most',2],['at_least',2],['between',1,2]) {
    reset_rows();
    my $result = $adapter->execute_write_unsafe(command($range));
    is($result->affected_rows,2,'native logical affected count satisfies the declared range');
    is_deeply(rows(),[[1,'changed'],[2,'changed'],[3,'three']], 'range success retains actual native effects');
}
for my $returning ([],['id']) {
    for my $range (['at_most',1],['at_least',3],['between',3,4],['exactly',1]) {
        reset_rows();
        reject('post-DML range mismatch',sub{$adapter->execute_write_unsafe(
            command($range,metadata=>{expected_cardinality=>$range,returning=>$returning}))},
            'cardinality_mismatch',mutated=>1);
    }
    for my $range ('many',['at_most',0],['at_least',0],['between',0,1]) {
        reset_rows();
        my $result=$adapter->execute_write_unsafe(command($range,predicate=>Selecto::Expression->eq('id',99),
            metadata=>{expected_cardinality=>$range,returning=>$returning}));
        is($result->affected_rows,0,'an explicitly zero-admitting range accepts no affected rows');
        is_deeply($result->values,{},'empty RETURNING retains no invented values');
        is_deeply(rows(),[[1,'one'],[2,'two'],[3,'three']], 'empty success preserves actual native rows');
    }
    reset_rows();
    reject('zero rows below declared minimum',sub{$adapter->execute_write_unsafe(command(['at_least',1],
        predicate=>Selecto::Expression->eq('id',99), metadata=>{expected_cardinality=>['at_least',1],returning=>$returning}))},
        'cardinality_mismatch');
}
reset_rows();
reject('legacy empty RETURNING still refuses',sub{$adapter->execute_write_unsafe(command('many',
    predicate=>Selecto::Expression->eq('id',99),metadata=>{returning=>['id']}))},'write_returning_missing');
reject('legacy exact count still rolls back',sub{$adapter->execute_write_unsafe(command('many',
    expected_count=>1,metadata=>{}))},'cardinality_mismatch',mutated=>1);

for my $bad (undef,'all',['exactly',0],['between',2,1],['at_most',-1],['at_least',1.5],['exactly',1,2],{}) {
    reject('malformed cardinality',sub{$adapter->execute_write_unsafe(command($bad))},
        'invalid_expected_cardinality',no_sql=>1);
}
for my $bad ([],{},-1,1.5,'NaN','1e3') {
    my $fresh=Selecto::SQLite->new(dbh=>$db);
    reject('malformed legacy count before fresh native discovery',sub{$fresh->execute_write_unsafe(
        command('many',metadata=>{},expected_count=>$bad))},'invalid_write',no_sql=>1);
}
reject('conflicting legacy exact count',sub{$adapter->execute_write_unsafe(command(['exactly',2],expected_count=>1))},
    'invalid_expected_cardinality',no_sql=>1);
my $malformed=command('many'); my $hooks=0;
$malformed->{metadata}{expected_cardinality}=sub{++$hooks};
reject('callback cardinality',sub{$adapter->execute_write_unsafe($malformed)},'invalid_write',no_sql=>1);
is($hooks,0,'rejected cardinality callback is never invoked');

# The actual engine supplies the trusted key/ceiling. Broad ranges do not turn
# that work bound into a request to mutate an arbitrary matching prefix.
reset_rows();
my $limited=$engine->with_limits(Selecto::Limits->new(max_action_targets=>1));
my $ceiling_error=reject('trusted ceiling limits many',sub{$limited->execute_write(command('many'))},'cardinality_mismatch');
is_deeply($ceiling_error->details,{expected=>'many'},'public cardinality diagnostic does not expose prospective matching row count');
reject('minimum exceeding trusted ceiling',sub{$limited->execute_write(command(['at_least',2]))},'invalid_write',no_sql=>1);
my $result=$engine->execute_write(command(['between',1,2]));
is($result->affected_rows,2,'native governed range resolves through actual domain policy');

reset_rows();
my $prefix=Selecto::Write::Command->new(operation=>'insert', relation=>'items',assignments=>{id=>10,name=>'prefix'});
my $failing=command(['at_most',1],metadata=>{expected_cardinality=>['at_most',1],returning=>['id']});
reject('batch range failure rolls back its prefix',sub{$adapter->execute_batch_unsafe(
    Selecto::Write::Batch->new($prefix,$failing))},'cardinality_mismatch',mutated=>1);
reject('graph range failure rolls back its prefix',sub{$adapter->execute_graph_unsafe(
    Selecto::Write::Graph->new(nodes=>[{id=>'root',command=>$prefix},{id=>'second',command=>$failing}]))},
    'cardinality_mismatch',mutated=>1);
my $invalid=command(['between',3,2]);
my $fresh_adapter=Selecto::SQLite->new(dbh=>$db);
reject('malformed range before fresh native feature discovery',sub{$fresh_adapter->execute_write_unsafe($invalid)},
    'invalid_expected_cardinality',no_sql=>1);
reject('batch malformed range before any prefix',sub{$adapter->execute_batch_unsafe(
    Selecto::Write::Batch->new($prefix,$invalid))},'invalid_expected_cardinality',no_sql=>1);
reject('graph malformed range before any prefix',sub{$adapter->execute_graph_unsafe(
    Selecto::Write::Graph->new(nodes=>[{id=>'root',command=>$prefix},{id=>'second',command=>$invalid}]))},
    'invalid_expected_cardinality',no_sql=>1);

$db->begin_work;
$db->do(q{INSERT INTO items VALUES(50,'caller-owned')});
reject('range mismatch preserves caller transaction',sub{$adapter->execute_batch_unsafe(
    Selecto::Write::Batch->new($prefix,$failing))},'cardinality_mismatch',mutated=>1,caller_transaction=>1);
is($db->selectrow_array('SELECT name FROM items WHERE id=50'),'caller-owned','caller work survives failed write savepoint');
$db->commit;
ok($db->sqlite_get_autocommit,'caller may still commit normally after cardinality refusal');
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP stays in memory');
ok(!grep(length($_->[2]),@{$db->selectall_arrayref('PRAGMA database_list')}),'all schemas remain in memory');
$db->disconnect;
done_testing;
