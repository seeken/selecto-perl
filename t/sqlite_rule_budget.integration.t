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
use Selecto::DataRules;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }

sub document {
    my (%spec) = @_;
    my $rules = {schema => 'selecto.data_rules.v1', definitions => {
        text => {version => 1, test => {op => 'presence.required'}},
        positive => {version => 1, test => {op => 'number.gt', bound => 0}}}, normalizers => {}, bindings => {}};
    for my $stage (qw(input candidate transaction)) {
        next unless $spec{$stage};
        $rules->{normalizers}{$stage} = {version => 1, steps => [map { +{op => 'text.trim', profile => 'ascii_v1'} } 1 .. $spec{$stage}]};
        $rules->{bindings}{$stage} = {subject => {scope => $stage, path => ['label']}, rule => {id => 'text', version => 1},
            normalizer => {id => $stage, version => 1}, enforcement => 'advisory', condition => {op => 'presence.absent'}};
    }
    $rules->{bindings}{positive} = {subject => {scope => $spec{failure}, path => ['quantity']}, rule => {id => 'positive', version => 1}} if $spec{failure};
    return {name => 'Shared native rule work', source => {source_table => 'items', primary_key => 'id', fields => [qw(id quantity label)],
        columns => {id => {type => 'integer'}, quantity => {type => 'integer'}, label => {type => 'string'}}}, schemas => {},
        writes => {operations => {insert => {enabled => 1}}, fields => {map { ($_ => {insertable => 1}) } qw(id quantity label)}}, rules => $rules};
}
sub command { Selecto::Write::Command->new(operation => 'insert', relation => 'items', assignments => {id => $_[0], quantity => $_[1], label => $_[2]}) }
sub with_memory {
    my ($raw, $work) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    $db->do('PRAGMA temp_store=MEMORY');$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER,label TEXT)');
    my $writer = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
    $work->($writer,$db);
    is_deeply [grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'SQLite databases remain in memory';
    $db->disconnect;
}
sub refuses {
    my ($db,$work,$code) = @_;
    my $before = $db->selectrow_array('SELECT total_changes()');
    my $ok = eval {$work->();1};my $error = $@;
    ok !$ok, 'native public operation refuses';
    is ref($error) && $error->can('code') ? $error->code : "$error", $code // 'evaluation_limit', 'finite typed refusal';
    is $db->selectrow_array('SELECT total_changes()'), $before, 'no business DML dispatched';
    is $db->selectrow_array('SELECT count(*) FROM items'), 0, 'no stored row';
}
for my $stages ([candidate => 300, transaction => 300],[input => 300,candidate => 300]) {
    subtest join('+',@$stages) => sub {
        with_memory(document(@$stages), sub {my($writer,$db)=@_;my $write=command(1,1,'a'x4000);
            refuses($db,sub {$writer->preview_write($write)});refuses($db,sub {$writer->execute_write($write)});
            $writer->execute_write(command(1,1,'short'));is $db->selectrow_array('SELECT label FROM items'),'short','resource exception releases the prior proof scope';
        });
    };
}
subtest 'native INSERT batch shares accepted INPUT work' => sub {
    with_memory(document(input => 300), sub {my($writer,$db)=@_;
        refuses($db,sub {$writer->execute_batch(Selecto::Write::Batch->new(command(1,1,'a'x4000),command(2,1,'b'x4000)))});
    });
};
subtest 'known ordinary candidate failure cannot hide later stage resource work' => sub {
    with_memory(document(failure => 'candidate',transaction => 700), sub {my($writer,$db)=@_;my $write=command(1,0,'a'x4000);
        refuses($db,sub {$writer->preview_write($write)});refuses($db,sub {$writer->execute_write($write)});
    });
};
subtest 'known ordinary INSERT candidate failure cannot hide later batch resource work' => sub {
    with_memory(document(failure => 'candidate',transaction => 700), sub {my($writer,$db)=@_;
        refuses($db,sub {$writer->execute_batch(Selecto::Write::Batch->new(command(1,0,'a'),command(2,1,'b'x4000)))});
    });
};
subtest 'rejected raw INPUT still stops before native stages' => sub {
    with_memory(document(failure => 'input',transaction => 700), sub {my($writer,$db)=@_;
        refuses($db,sub {$writer->execute_write(command(1,0,'a'x4000))},'data_rule_failed');
    });
};
subtest 'separate accepted operations receive separate budgets' => sub {
    with_memory(document(input => 300), sub {my($writer,$db)=@_;
        $writer->preview_write(command(1,1,'a'x4000));is $db->selectrow_array('SELECT total_changes()'),0,'preview has no DML';
        $writer->execute_write(command(1,1,'a'x4000));$writer->execute_write(command(2,1,'b'x4000));
        is_deeply $db->selectall_arrayref('SELECT id,quantity,length(label) FROM items ORDER BY id'), [[1,1,4000],[2,1,4000]], 'each bounded operation stores its actual native values';
    });
};
open my $fixture_file, '<', "$Bin/fixtures/data_rules_write_inputs_v1.json" or die $!;
my $fixture = JSON::PP->new->decode(do { local $/; <$fixture_file> });
sub graph_document {
    my ($failure, $steps) = @_;
    my $raw = dclone($fixture->{nested_domain});
    $raw->{rules} = document(transaction => $steps // 300)->{rules};
    $raw->{writes}{fields}{id} = {insertable => 1};
    $_->{subject}{path} = ['reference'] for values %{$raw->{rules}{bindings}};
    my $child = $raw->{writes}{relationships}{items}{domain};
    push @{$child->{source}{fields}}, 'label';
    $child->{source}{columns}{label} = {type => 'string'};
    $child->{writes}{fields}{label} = {insertable => 1, updatable => 1};
    $child->{writes}{fields}{id} = {insertable => 1};
    $child->{rules} = document(candidate => $failure ? 1 : 300, $failure ? (failure => 'candidate') : ())->{rules};
    return $raw;
}
for my $failure (0,1) {
    subtest $failure ? 'failed child candidate cannot hide available parent resource work' : 'whole graph shares native stage work' => sub {
        my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
        $db->do('PRAGMA temp_store=MEMORY');$db->do('PRAGMA foreign_keys=ON');
        $db->do('CREATE TABLE rule_write_orders(id INTEGER PRIMARY KEY,reference TEXT)');
        $db->do('CREATE TABLE rule_write_items(id INTEGER PRIMARY KEY,order_id INTEGER REFERENCES rule_write_orders(id),product_id INTEGER,quantity INTEGER,label TEXT)');
        my $writer = Selecto::Engine->new(domain => Selecto::Domain->parse(graph_document($failure,$failure ? 700 : 300)),adapter => Selecto::SQLite->new(dbh => $db));
        my $graph = Selecto::Write::Graph->new(nodes => [
            {id => 'root',command => Selecto::Write::Command->new(operation => 'insert',relation => 'rule_write_orders',assignments => {id => 42,reference => 'a'x4000})},
            {id => 'child',command => Selecto::Write::Command->new(operation => 'insert',relation => 'rule_write_items',assignments => {id => 11,product_id => 5,quantity => $failure ? 0 : 1,label => 'b'x4000}),
                bindings => [{from => 'root',key => 'id',field => 'order_id'}]}]);
        my $ok = eval {$writer->execute_graph($graph);1};my $error = $@;
        ok !$ok,'native graph refuses';is ref($error) && $error->can('code') ? $error->code : "$error",'evaluation_limit','whole-proof resource refusal';
        is $db->selectrow_array('SELECT total_changes()'),0,'no prefix or child DML';
        is $db->selectrow_array('SELECT count(*) FROM rule_write_orders'),0,'no parent stored';
        is $db->selectrow_array('SELECT count(*) FROM rule_write_items'),0,'no child stored';
        is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}],[],'graph schemas remain in memory';$db->disconnect;
    };
}
done_testing;
