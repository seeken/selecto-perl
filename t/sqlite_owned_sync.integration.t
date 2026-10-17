use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use JSON::PP ();
use Selecto;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBD::SQLite is required';
}

sub contract {
    my $child = {
        schema_version => 1, name => 'Children',
        source => {source_table => 'children', primary_key => 'id',
            fields => [qw(id parent_id tenant_id active note)],
            columns => {map { ($_ => {type => $_ eq 'note' ? 'string' : 'integer'}) }
                qw(id parent_id tenant_id active note)}, associations => {}},
        schemas => {}, joins => {}, required_filters => [['active', 1]],
        writes => {
            operations => {map { ($_ => {enabled => 1}) } qw(insert update delete)},
            fields => {id => {insertable => 1}, note => {insertable => 1, updatable => 1},
                active => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']}},
        },
    };
    return {
        schema_version => 1, name => 'Parents',
        source => {source_table => 'parents', primary_key => 'id',
            fields => [qw(id tenant_id label)],
            columns => {id => {type => 'integer'}, tenant_id => {type => 'integer'},
                label => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {},
        writes => {
            operations => {map { ($_ => {enabled => 1}) } qw(insert update)},
            fields => {id => {insertable => 1}, label => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']}},
            relationships => {children => {writable => 1, ownership => 'owned', strategy => 'sync',
                parent_key => 'id', child_key => 'parent_id', identity_fields => [qw(tenant_id id)],
                allowed_ops => [qw(insert update delete)], delete_missing => 1, domain => $child}},
        },
    };
}

sub fixture {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,tenant_id INTEGER,label TEXT)');
    $dbh->do('CREATE TABLE children(id INTEGER PRIMARY KEY,parent_id INTEGER NOT NULL REFERENCES parents(id),tenant_id INTEGER,active INTEGER,note TEXT NOT NULL)');
    $dbh->do("INSERT INTO parents VALUES(1,7,'first'),(2,7,'second'),(3,8,'other')");
    $dbh->do("INSERT INTO children VALUES(10,1,7,1,'keep'),(11,1,7,1,'remove'),(12,2,7,1,'other parent'),(13,1,8,1,'other tenant'),(14,1,7,0,'outside policy')");
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(contract()),
        adapter => Selecto::SQLite->new(dbh => $dbh), scope => {tenant => 7});
    return ($dbh, $engine);
}

sub command {
    my ($operation, $relation, $values, $id) = @_;
    return Selecto::Write::Command->new(operation => $operation, relation => $relation,
        assignments => $values // {}, (defined($id) ? (predicate => Selecto::Expression->eq('id', $id)) : ()));
}

sub graph {
    my (@children) = @_;
    return Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => command('update', 'parents', {label => 'updated'}, 1)},
        map { {id => 'child-' . $_, command => $children[$_],
            bindings => [{from => 'root', key => 'id', field => 'parent_id'}]} } 0 .. $#children,
    ], owned_sets => [{parent => 'root', relationship => 'children',
        nodes => [map { 'child-' . $_ } 0 .. $#children], delete_missing => JSON::PP::true}]);
}

sub code_of {
    my ($work) = @_;
    return 'ok' if eval { $work->(); 1 };
    return blessed($@) && $@->isa('Selecto::Error') ? $@->code : "unexpected: $@";
}

subtest 'actual composite identities preserve tenant, parent and required scopes' => sub {
    my ($dbh, $engine) = fixture();
    ok($engine->adapter->write_capabilities->{owned_set_sync}, 'native SQLite advertises implemented sync');
    my $input = graph(command('update', 'children', {note => 'retained'}, 10));
    my $original = $input->nodes->[0]{command}->metadata;
    my $result = $engine->execute_graph($input);
    is_deeply($dbh->selectcol_arrayref('SELECT id FROM children ORDER BY id'), [10,12,13,14],
        'cleanup excludes all independently scoped rows');
    is_deeply($result->metadata->{cleanup_affected_rows}, [1], 'metadata comes from actual cleanup');
    is_deeply($input->nodes->[0]{command}->metadata, $original, 'caller graph remains unchanged');
    is_deeply($result->nodes->{'child-0'}->values, {tenant_id => 7, id => 10},
        'engine adds actual ordered identity RETURNING');
    $dbh->disconnect;
};

subtest 'empty full set uses the actual root key' => sub {
    my ($dbh, $engine) = fixture();
    $engine->execute_graph(graph());
    is_deeply($dbh->selectcol_arrayref('SELECT id FROM children ORDER BY id'), [12,13,14],
        'empty set deletes only eligible owned rows');
    $dbh->disconnect;
};

subtest 'exact generated root and child values never pass through float' => sub {
    my ($dbh, $engine) = fixture();
    $dbh->do("INSERT INTO parents VALUES(9007199254740993,7,'large')");
    $dbh->do("INSERT INTO children VALUES(9007199254740993,2,7,1,'large')");
    my $input = Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => command('insert', 'parents', {label => 'generated'})},
        {id => 'child', command => command('insert', 'children', {note => 'generated', active => 1}),
            bindings => [{from => 'root', key => 'id', field => 'parent_id'}]},
    ], owned_sets => [{parent => 'root', relationship => 'children', nodes => ['child'], delete_missing => 1}]);
    my $result = $engine->execute_graph($input);
    is('' . $result->root->values->{id}, '9007199254740994', 'root exact generated identity');
    is('' . $result->nodes->{child}->values->{id}, '9007199254740994', 'child exact generated identity');
    is('' . $dbh->selectrow_array("SELECT parent_id FROM children WHERE note='generated'"),
        '9007199254740994', 'stored generated binding remains exact');
    $dbh->disconnect;
};

subtest 'late cleanup failure rolls back graph while preserving host work' => sub {
    for my $mode (qw(managed external)) {
    my ($dbh, $engine) = fixture();
    $dbh->do("CREATE TRIGGER reject_cleanup BEFORE DELETE ON children WHEN OLD.id=11 BEGIN SELECT RAISE(ABORT,'late cleanup failure'); END");
    $dbh->begin_work;
    $engine->adapter->transaction_mode($mode);
    $dbh->do("INSERT INTO parents VALUES(4,7,'host pending')");
    isnt(code_of(sub {$engine->execute_graph(graph(command('update','children',{note=>'changed'},10)))}),
        'ok', 'actual late DELETE trigger refuses');
    is($dbh->selectrow_array('SELECT label FROM parents WHERE id=1'), 'first', 'root update rolled back');
    is($dbh->selectrow_array('SELECT note FROM children WHERE id=10'), 'keep', 'child update rolled back');
    is($dbh->selectrow_array('SELECT label FROM parents WHERE id=4'), 'host pending', 'host pending row survives');
    $dbh->rollback;
    $dbh->disconnect;
    }
};

subtest 'canonical required filters are closed and govern stored reads' => sub {
    my ($dbh, $engine) = fixture();
    my $child = Selecto::Domain->parse(contract()->{writes}{relationships}{children}{domain});
    my $reader = Selecto::Engine->new(domain => $child, adapter => $engine->adapter);
    is_deeply($reader->all($reader->query->select('id')->order_by('id'))->{rows},
        [[10],[11],[12],[13]], 'required filter constrains trusted reads');
    for my $filter (['unknown',1], ['json_contains','note',{}], ['eq','parent.note','value']) {
        my $bad = contract()->{writes}{relationships}{children}{domain};
        $bad->{required_filters} = [$filter];
        is(code_of(sub {Selecto::Domain->parse($bad)}), 'invalid_domain', 'unsupported root policy refuses');
    }
    $dbh->disconnect;
};

subtest 'policy denials and duplicate actual identities are atomic' => sub {
    my ($dbh, $engine) = fixture();
    for my $change (sub {$_[0]{writes}{relationships}{children}{ownership}='shared'},
                    sub {$_[0]{writes}{relationships}{children}{delete_missing}=0},
                    sub {$_[0]{writes}{relationships}{children}{domain}{writes}{operations}{delete}{enabled}=0}) {
        my $contract = contract(); $change->($contract);
        my $denied = Selecto::Engine->new(domain=>Selecto::Domain->parse($contract),
            adapter=>$engine->adapter,scope=>{tenant=>7});
        isnt(code_of(sub {$denied->execute_graph(graph())}), 'ok', 'undeclared cleanup refuses');
        is($dbh->selectrow_array('SELECT label FROM parents WHERE id=1'), 'first', 'denial precedes mutation');
    }
    is(code_of(sub {$engine->execute_graph(graph(command('update','children',{note=>'first'},10),
        command('update','children',{note=>'second'},10)))}), 'invalid_write_graph', 'actual duplicate identities refuse');
    is($dbh->selectrow_array('SELECT note FROM children WHERE id=10'), 'keep', 'duplicate graph rolled back');
    is(code_of(sub {$engine->execute_graph(graph(command('update','children',{note=>'foreign'},12)))}),
        'cardinality_mismatch', 'foreign parent child cannot enter the kept set');
    $dbh->disconnect;
};

done_testing;
