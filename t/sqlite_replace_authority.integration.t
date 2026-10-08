use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }
sub document {
    return {name => 'Conflict authority', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id label)], columns => {id => {type => 'integer'}, label => {type => 'string'}}}, schemas => {},
        writes => {operations => {map { ($_ => {enabled => 1, conflict_targets => [['id']]}) } qw(insert update delete upsert)},
            fields => {map { ($_ => {insertable => 1, updatable => 1}) } qw(id label)}}};
}
sub writer { Selecto::Engine->new(domain => Selecto::Domain->parse($_[1] // document()), adapter => Selecto::SQLite->new(dbh => $_[0])) }
sub command { Selecto::Write::Command->new(@_) }
sub matches { Selecto::Expression->eq(@_) }
sub memory {
    my ($ddl, $work) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    $db->do('PRAGMA temp_store=MEMORY'); $db->do('PRAGMA foreign_keys=ON');
    $db->do($_) for @$ddl;
    my $mutations = 0;
    $db->sqlite_trace(sub { $mutations++ if $_[0] =~ /\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+["`\[]?(?:items|roots|hidden)\b/i });
    $work->($db, \$mutations);
    is_deeply [grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'every SQLite schema remains in memory';
    $db->disconnect;
}
sub refuses {
    my ($work, $expected) = @_;
    my $ok = eval { $work->(); 1 }; my $error = $@;
    ok !$ok, 'public native operation refuses before mutation';
    is ref($error) && $error->can('code') ? $error->code : "$error", $expected // 'required_data_rule_pending', 'unproved replacement has explicit pending authority';
}
for my $schema (
    ['rowid PK', 'id INTEGER PRIMARY KEY ON CONFLICT REPLACE,label TEXT'],
    ['table PK', 'id INTEGER,label TEXT,PRIMARY KEY(id) ON CONFLICT REPLACE'],
    ['column unique', 'id INTEGER PRIMARY KEY,label TEXT UNIQUE ON CONFLICT REPLACE'],
    ['table unique', 'id INTEGER PRIMARY KEY,label TEXT,UNIQUE(label) ON CONFLICT REPLACE'],
    ['not null replacement', q{id INTEGER PRIMARY KEY,label TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'replacement'}],
    ['comment separated mixed case', 'id INTEGER PRIMARY KEY,label TEXT UNIQUE on /* policy */ conflict -- policy\n replace'],
) {
    subtest "$schema->[0] INSERT preview and execute" => sub {
        my $declaration = $schema->[1]; $declaration =~ s/\\n/\n/g;
        memory(["CREATE TABLE items($declaration)", 'CREATE TABLE hidden(owner INTEGER REFERENCES items(id) ON DELETE CASCADE)',
            q{INSERT INTO items(id,label) VALUES(1,'one'),(2,'two')}, 'INSERT INTO hidden VALUES(2)'], sub {
            my ($db, $n) = @_; my $engine = writer($db);
            my $command = command(operation => 'insert', relation => 'items', assignments => {
                id => $schema->[0] =~ /PK/ ? 2 : 3, label => $schema->[0] eq 'not null replacement' ? undef : 'two'});
            $db->begin_work;
            refuses(sub { $engine->preview_write($command) });
            refuses(sub { $engine->execute_write($command) });
            is $$n, 0, 'no target INSERT, replacement DELETE or child cascade dispatches';
            is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'), [[1,'one'],[2,'two']], 'both actual parents remain';
            is_deeply $db->selectall_arrayref('SELECT owner FROM hidden'), [[2]], 'unsubmitted child remains';
            ok !$db->{AutoCommit}, 'caller transaction remains open'; $db->rollback;
        });
    };
}
for my $operation (qw(update upsert)) {
    subtest "ordinary $operation has no replacement delete authority" => sub {
        memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE ON CONFLICT REPLACE)',
            'CREATE TABLE hidden(owner INTEGER REFERENCES items(id) ON DELETE CASCADE)',
            q{INSERT INTO items VALUES(1,'one'),(2,'two')}, 'INSERT INTO hidden VALUES(2)'], sub {
            my ($db, $n) = @_; my $engine = writer($db);
            my $command = command(operation => $operation, relation => 'items', assignments => $operation eq 'upsert' ? {id => 3,label => 'two'} : {label => 'two'},
                predicate => matches('id',1), $operation eq 'upsert' ? (metadata => {conflict_target => ['id'],upsert_update_fields => ['label']}) : ());
            refuses(sub { $engine->preview_write($command) }); refuses(sub { $engine->execute_write($command) });
            is $$n, 0, 'neither business update nor implicit deletion dispatches';
            is_deeply $db->selectall_arrayref('SELECT * FROM items ORDER BY id'), [[1,'one'],[2,'two']], 'actual conflicting row is retained';
            is $db->selectrow_array('SELECT owner FROM hidden'), 2, 'unsubmitted child retained';
        });
    };
}
subtest 'whole graph proves every replacement target before ordinary parent prefix' => sub {
    memory(['CREATE TABLE roots(id INTEGER PRIMARY KEY,label TEXT)',
        'CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE ON CONFLICT REPLACE,root_id INTEGER REFERENCES roots(id))',
        'CREATE TABLE hidden(owner INTEGER REFERENCES items(id) ON DELETE CASCADE)', q{INSERT INTO roots VALUES(1,'before')},
        q{INSERT INTO items VALUES(2,'two',1)}, 'INSERT INTO hidden VALUES(2)'], sub {
        my ($db, $n) = @_;
        my $child = document(); $child->{source}{fields} = [qw(id label root_id)]; $child->{source}{columns}{root_id} = {type => 'integer'};
        my $doc = document(); $doc->{source}{source_table} = 'roots';
        $doc->{writes}{relationships}{items} = {writable => 1,ownership => 'owned',parent_key => 'id',child_key => 'root_id',allowed_ops => ['insert'],domain => $child};
        my $engine = writer($db, $doc);
        my $graph = Selecto::Write::Graph->new(nodes => [
            {id => 'root',command => command(operation => 'update',relation => 'roots',assignments => {label => 'after'},predicate => matches('id',1))},
            {id => 'child',command => command(operation => 'insert',relation => 'items',assignments => {id => 3,label => 'two'}),bindings => [{from => 'root',key => 'id',field => 'root_id'}]}]);
        refuses(sub { $engine->execute_graph($graph) });
        is $$n, 0, 'ordinary prefix never dispatches';
        is $db->selectrow_array('SELECT label FROM roots'), 'before', 'actual parent prefix remains';
        is $db->selectrow_array('SELECT owner FROM hidden'), 2, 'implicit descendant remains';
    });
};
subtest 'batch proves all physical conflicts before any prefix' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE ON CONFLICT REPLACE)',
        q{INSERT INTO items VALUES(2,'two')}], sub {
        my ($db, $n) = @_;
        my $batch = Selecto::Write::Batch->new(command(operation => 'insert',relation => 'items',assignments => {id => 1,label => 'one'}),
            command(operation => 'insert',relation => 'items',assignments => {id => 3,label => 'two'}));
        refuses(sub { writer($db)->execute_batch($batch) });
        is $$n, 0, 'whole batch dispatches no prefix';
        is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[2,'two']], 'actual original remains';
    });
};
for my $ddl (
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT DEFAULT 'ON CONFLICT REPLACE')},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT,"ON CONFLICT REPLACE" TEXT)},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT,`ON CONFLICT REPLACE` TEXT)},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT,[ON CONFLICT REPLACE] TEXT)},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE /* ON CONFLICT REPLACE */ ON CONFLICT ABORT)},
    "CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE -- ON CONFLICT REPLACE\n ON CONFLICT IGNORE)",
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT DEFAULT 'escaped '' ON CONFLICT REPLACE')},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT,"escaped "" ON CONFLICT REPLACE" TEXT)},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT,`escaped `` ON CONFLICT REPLACE` TEXT)},
    q{CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT CHECK(label <> 'ON CONFLICT REPLACE'))},
) {
    subtest 'quoted/commented words are not physical replacement policy' => sub {
        memory([$ddl], sub {
            my ($db, $n) = @_; my $engine = writer($db);
            my $insert = command(operation => 'insert',relation => 'items',assignments => {id => 1,label => 'one'});
            $engine->preview_write($insert); is $$n, 0, 'ordinary preview dispatches no mutation';
            $engine->execute_write($insert);
            $engine->execute_write(command(operation => 'update',relation => 'items',assignments => {label => 'after'},predicate => matches('id',1)));
            is_deeply $db->selectall_arrayref('SELECT id,label FROM items'), [[1,'after']], 'positive INSERT and UPDATE store actual authored values';
            is $$n, 2, 'exact two declared writes dispatch';
        });
    };
}
subtest 'guarded INSERT cannot use replacement effects to establish its query rule' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY ON CONFLICT REPLACE,label TEXT)',q{INSERT INTO items VALUES(1,'before')}],sub {
        my ($db, $n) = @_;my $engine = writer($db);
        my $guarded = $engine->enforce_query(command(operation => 'insert',relation => 'items',assignments => {id => 1,label => 'after'}),
            $engine->query->where(matches('label','after')));
        refuses(sub { $engine->preview_write($guarded) }, 'query_rule_not_evaluable');
        refuses(sub { $engine->execute_write($guarded) }, 'query_rule_not_evaluable');
        is $$n, 0, 'guard never dispatches a replacement';
        is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[1,'before']], 'original guarded root remains';
    });
};
subtest 'advisory false condition does not bypass physical conflict proof' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE ON CONFLICT REPLACE)',q{INSERT INTO items VALUES(1,'one')}],sub {
        my ($db, $n) = @_;my $doc = document();
        $doc->{rules} = {schema => 'selecto.data_rules.v1',definitions => {r => {version => 1,test => {op => 'text.nonblank'}}},normalizers => {},
            bindings => {r => {subject => {scope => 'candidate',path => ['label']},rule => {id => 'r',version => 1},enforcement => 'advisory',condition => {op => 'presence.absent'}}}};
        my $engine = writer($db,$doc);my $insert = command(operation => 'insert',relation => 'items',assignments => {id => 2,label => 'one'});
        refuses(sub { $engine->preview_write($insert) });refuses(sub { $engine->execute_write($insert) });
        is $$n, 0, 'advisory condition admits no implicit business deletion';
        is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[1,'one']], 'actual original retained';
    });
};
subtest 'readonly graph anchor with replacement schema remains a read' => sub {
    memory(['CREATE TABLE roots(id INTEGER PRIMARY KEY ON CONFLICT REPLACE,label TEXT)',
        'CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT,root_id INTEGER REFERENCES roots(id))',q{INSERT INTO roots VALUES(1,'before')}],sub {
        my ($db, $n) = @_;
        my $child = document();$child->{source}{fields} = [qw(id label root_id)];$child->{source}{columns}{root_id} = {type => 'integer'};
        my $doc = document();$doc->{source}{source_table} = 'roots';
        $doc->{writes}{relationships}{items} = {writable => 1,ownership => 'owned',parent_key => 'id',child_key => 'root_id',allowed_ops => ['insert'],domain => $child};
        my $graph = Selecto::Write::Graph->new(nodes => [
            {id => 'root',reference_only => 1,command => command(operation => 'update',relation => 'roots',predicate => matches('id',1))},
            {id => 'child',command => command(operation => 'insert',relation => 'items',assignments => {id => 3,label => 'child'}),bindings => [{from => 'root',key => 'id',field => 'root_id'}]}]);
        writer($db,$doc)->execute_graph($graph);
        is $$n, 1, 'only declared ordinary child INSERT dispatches';
        is_deeply $db->selectall_arrayref('SELECT * FROM roots'), [[1,'before']], 'anchor never mutates replacement root';
        is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[3,'child',1]], 'actual owned child inserted';
    });
};
subtest 'ordinary DELETE does not activate a replacement conflict policy' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT UNIQUE ON CONFLICT REPLACE)',q{INSERT INTO items VALUES(1,'one'),(2,'two')}],sub {
        my ($db, $n) = @_;
        writer($db)->execute_write(command(operation => 'delete',relation => 'items',predicate => matches('id',1)));
        is $$n, 1, 'only explicit governed DELETE dispatches';
        is_deeply $db->selectall_arrayref('SELECT * FROM items'), [[2,'two']], 'unrelated row remains';
    });
};
done_testing;
