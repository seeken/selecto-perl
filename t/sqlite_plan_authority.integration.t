use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use FindBin qw($Bin);
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }

sub document {
    return {name => 'Physical authority', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id quantity)], columns => {id => {type => 'integer'}, quantity => {type => 'integer'}}}, schemas => {},
        writes => {operations => {map { ($_ => {enabled => 1, conflict_targets => [['id']]}) } qw(insert update delete upsert)},
            fields => {map { ($_ => {insertable => 1, updatable => 1}) } qw(id quantity)}}};
}
sub engine { Selecto::Engine->new(domain => Selecto::Domain->parse($_[1] // document()), adapter => Selecto::SQLite->new(dbh => $_[0])) }
sub command { Selecto::Write::Command->new(@_) }
sub matches { Selecto::Expression->eq(@_) }
sub memory {
    my ($schema, $work) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    $db->do('PRAGMA temp_store=MEMORY'); $db->do('PRAGMA foreign_keys=ON');
    $db->do($_) for @$schema;
    $work->($db);
    is_deeply [grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'every SQLite schema is in memory';
    $db->disconnect;
}
sub refuses {
    my ($work, $expected) = @_;
    my $ok = eval { $work->(); 1 }; my $error = $@;
    ok !$ok, 'public operation refuses';
    is ref($error) && $error->can('code') ? $error->code : "$error", $expected // 'required_data_rule_pending', 'typed authority refusal';
}

for my $action ('CASCADE', 'SET NULL', 'SET DEFAULT') {
    for my $operation (qw(update delete upsert)) {
        subtest "ordinary $operation incoming $action" => sub {
            memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER)',
                "CREATE TABLE hidden(owner INTEGER DEFAULT 9 REFERENCES items ON UPDATE $action ON DELETE $action)",
                'INSERT INTO items VALUES(1,1),(9,9)', 'INSERT INTO hidden VALUES(1)'], sub {
                my ($db) = @_;my $writer = engine($db);
                my $write = command(operation => $operation, relation => 'items',
                    assignments => $operation eq 'delete' ? {} : $operation eq 'upsert' ? {id => 1, quantity => 2} : {id => 2},
                    predicate => matches('id',1),
                    $operation eq 'upsert' ? (metadata => {conflict_target => ['id'], upsert_update_fields => ['id','quantity']}) : ());
                my $before = $db->selectrow_array('SELECT total_changes()');
                $db->begin_work;
                refuses(sub { $writer->preview_write($write) });
                refuses(sub { $writer->execute_write($write) });
                refuses(sub { $writer->execute_batch(Selecto::Write::Batch->new(
                    command(operation => 'insert', relation => 'items', assignments => {id => 8, quantity => 8}), $write)) });
                is $db->selectrow_array('SELECT total_changes()'), $before, 'no business mutation, including batch prefix';
                is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'), [[1,1],[9,9]], 'parent rows preserved';
                is_deeply $db->selectall_arrayref('SELECT owner FROM hidden'), [[1]], 'undeclared child preserved';
                ok !$db->{AutoCommit}, 'host transaction remains open';$db->rollback;
            });
        };
    }
}
for my $kind ('main trigger','TEMP trigger','generated') {
    subtest "unselected transformed parent key: $kind" => sub {
        my @schema = ('CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER' .
            ($kind eq 'generated' ? ',derived TEXT GENERATED ALWAYS AS (CAST(quantity AS TEXT)) STORED UNIQUE' : '') . ')',
            'CREATE TABLE hidden(owner ' . ($kind eq 'generated' ? 'TEXT REFERENCES items(derived)' : 'INTEGER REFERENCES items(id)') . ' ON UPDATE CASCADE)',
            'INSERT INTO items(id,quantity) VALUES(1,1)', "INSERT INTO hidden VALUES('1')");
        push @schema, 'CREATE ' . ($kind eq 'TEMP trigger' ? 'TEMP ' : '') . 'TRIGGER indirect AFTER UPDATE OF quantity ON items BEGIN UPDATE items SET id=id+10 WHERE id=NEW.id;END' unless $kind eq 'generated';
        memory(\@schema, sub {
            my ($db) = @_;my $writer = engine($db);my $write = command(operation => 'update', relation => 'items', assignments => {quantity => 2}, predicate => matches('id',1));
            my $before = $db->selectrow_array('SELECT total_changes()');
            refuses(sub { $writer->preview_write($write) });refuses(sub { $writer->execute_write($write) });
            is $db->selectrow_array('SELECT total_changes()'), $before, 'hidden transformation causes zero business DML';
            is $db->selectrow_array('SELECT quantity FROM items'), 1, 'quantity unchanged';
            is $db->selectrow_array('SELECT owner FROM hidden'), 1, 'incoming owner unchanged';
        });
    };
}
subtest 'ordinary INSERT target trigger cannot mutate a prior referenced parent' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER)',
        'CREATE TABLE hidden(owner INTEGER REFERENCES items(id) ON UPDATE CASCADE)', 'INSERT INTO items VALUES(1,1)', 'INSERT INTO hidden VALUES(1)',
        'CREATE TRIGGER indirect AFTER INSERT ON items BEGIN UPDATE items SET id=id+10 WHERE id=1;END'], sub {
        my ($db) = @_;my $writer = engine($db);my $write = command(operation => 'insert', relation => 'items', assignments => {id => 2, quantity => 2});
        my $before = $db->selectrow_array('SELECT total_changes()');
        refuses(sub { $writer->preview_write($write) });refuses(sub { $writer->execute_write($write) });
        is $db->selectrow_array('SELECT total_changes()'), $before, 'INSERT and indirect cascade never dispatch';
        is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[1,1]], 'original parent remains';
        is $db->selectrow_array('SELECT owner FROM hidden'), 1, 'original incoming owner remains';
    });
};

for my $stage (qw(candidate transaction)) {
    for my $enforcement (qw(required advisory)) {
        subtest "explicit NULL rowid alias unknown: $stage $enforcement" => sub {
            memory(['CREATE TABLE items(id INTEGER PRIMARY KEY DEFAULT 7,quantity INTEGER)'], sub {
                my ($db) = @_;my $doc = document();
                $doc->{rules} = {schema => 'selecto.data_rules.v1', definitions => {r => {version => 1, test => {op => 'value.eq', value => undef}}}, normalizers => {},
                    bindings => {r => {subject => {scope => $stage, path => ['id']}, rule => {id => 'r', version => 1}, enforcement => $enforcement, condition => {op => 'presence.absent'}}}};
                my $writer = engine($db,$doc);my $write = command(operation => 'insert', relation => 'items', assignments => {id => undef, quantity => 1});
                my $before = $db->selectrow_array('SELECT total_changes()');
                refuses(sub { $writer->preview_write($write) });refuses(sub { $writer->execute_write($write) });
                is $db->selectrow_array('SELECT total_changes()'), $before, 'unknown generated candidate never dispatches';
            });
        };
    }
}
for my $indexed (0,1) {
    subtest 'NULL query guard: ' . ($indexed ? 'indexed PK DESC' : 'generated rowid') => sub {
        memory(['CREATE TABLE items(id INTEGER PRIMARY KEY' . ($indexed ? ' DESC' : '') . ',quantity INTEGER)'], sub {
            my ($db) = @_;my $writer = engine($db);
            my $write = $writer->enforce_query(command(operation => 'insert', relation => 'items', assignments => {id => undef, quantity => 1}),
                $writer->query->where(Selecto::Expression->is_null('id')));
            if ($indexed) { $writer->execute_write($write);is_deeply $db->selectall_arrayref('SELECT id FROM items'), [[undef]], 'native indexed key remains NULL' }
            else { refuses(sub { $writer->execute_write($write) }, 'query_rule_not_evaluable');is $db->selectrow_array('SELECT count(*) FROM items'), 0, 'generated key is not fabricated as NULL' }
        });
    };
}
subtest 'indexed NULL rule and unconsumed generated identity remain usable' => sub {
    for my $indexed (0,1) {
        memory(['CREATE TABLE items(id INTEGER PRIMARY KEY' . ($indexed ? ' DESC' : '') . ',quantity INTEGER)'], sub {
            my ($db) = @_;my $doc = document();
            $doc->{rules} = {schema => 'selecto.data_rules.v1', definitions => {r => {version => 1, test => $indexed ? {op => 'value.eq', value => undef} : {op => 'number.gt', bound => 0}}}, normalizers => {},
                bindings => {r => {subject => {scope => 'candidate', path => [$indexed ? 'id' : 'quantity']}, rule => {id => 'r', version => 1}}}};
            my $writer = engine($db,$doc);my $write = command(operation => 'insert', relation => 'items', assignments => {id => undef, quantity => 1});
            $writer->preview_write($write);$writer->execute_write($write);
            is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[$indexed ? undef : 1,1]], 'only the real stored identity is claimed';
        });
    }
};

open my $fixture_file, '<', "$Bin/fixtures/data_rules_write_inputs_v1.json" or die $!;
my $fixture = JSON::PP->new->decode(do { local $/; <$fixture_file> });
for my $cleanup (0,1) {
    subtest $cleanup ? 'owned cleanup refuses before parent prefix' : 'graph child DELETE refuses before parent prefix' => sub {
        memory(['CREATE TABLE rule_write_orders(id INTEGER PRIMARY KEY,reference TEXT)', 'CREATE TABLE rule_write_items(id INTEGER PRIMARY KEY,order_id INTEGER,product_id INTEGER,quantity INTEGER)',
            'CREATE TABLE undeclared(owner INTEGER REFERENCES rule_write_items(id) ON DELETE CASCADE)', "INSERT INTO rule_write_orders VALUES(42,'before')",
            'INSERT INTO rule_write_items VALUES(11,42,5,1)', 'INSERT INTO undeclared VALUES(11)'], sub {
            my ($db) = @_;my $doc = dclone($fixture->{nested_domain});delete $doc->{rules};delete $doc->{writes}{relationships}{items}{domain}{rules};
            my @nodes = ({id => 'root', command => command(operation => 'update', relation => 'rule_write_orders', assignments => {reference => 'after'}, predicate => matches('id',42))});
            push @nodes, {id => 'child', command => command(operation => 'delete', relation => 'rule_write_items', predicate => matches('id',11)), bindings => [{from => 'root', key => 'id', field => 'order_id'}]} unless $cleanup;
            if ($cleanup) {
                $doc->{writes}{relationships}{items}{delete_missing} = JSON::PP::true;
                $doc->{writes}{relationships}{items}{strategy} = 'sync';
                $doc->{writes}{relationships}{items}{allowed_ops} = [qw(insert update delete)];
            }
            my $graph = Selecto::Write::Graph->new(nodes => \@nodes,
                $cleanup ? (owned_sets => [{parent => 'root', relationship => 'items', nodes => [], delete_missing => 1}]) : ());
            my $writer = engine($db,$doc);my $before = $db->selectrow_array('SELECT total_changes()');
            refuses(sub { $writer->execute_graph($graph) });is $db->selectrow_array('SELECT total_changes()'), $before, 'whole plan has zero business mutations';
            is $db->selectrow_array('SELECT reference FROM rule_write_orders'), 'before', 'earlier parent prefix unchanged';
            is $db->selectrow_array('SELECT owner FROM undeclared'), 11, 'unsubmitted descendant preserved';
        });
    };
}
done_testing;
