use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;
BEGIN { eval {require DBI; require DBD::SQLite; 1} or plan skip_all => 'DBD::SQLite required' }

sub domain {
    my ($collection) = @_;
    my $child = {name => 'Children', source => {source_table => 'children', primary_key => 'id', fields => [qw(id owner reference)],
        columns => {id => {type => 'integer'}, owner => {type => 'string'}, reference => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}, delete => {enabled => 1}}, fields => {reference => {updatable => 1}}}};
    my $raw = {name => 'Parents', source => {source_table => 'parents', primary_key => 'id', fields => [qw(id reference)],
        columns => {id => {type => 'string'}, reference => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {reference => {updatable => 1}}, relationships => {children => {
            writable => 1, ownership => 'owned', parent_key => 'id', child_key => 'owner', allowed_ops => [qw(update delete)],
            domain => $child, strategy => 'sync', delete_missing => 1, identity_fields => ['id']}}}};
    $raw->{rules} = {schema => 'selecto.data_rules.v1', definitions => {count => {version => 1, test => {op => 'collection.count', exact => 1}}}, normalizers => {},
        bindings => {count => {subject => {scope => 'candidate', path => ['children']}, rule => {id => 'count', version => 1}}}} if $collection;
    return Selecto::Domain->parse($raw);
}
sub attempt {
    my ($engine, $mode) = @_;
    my $root = Selecto::Write::Command->new(operation => 'update', relation => 'parents', assignments => {reference => 'new'}, predicate => Selecto::Expression->eq('id', 'a'));
    return $engine->execute_write($root) if $mode eq 'collection';
    my @nodes = ({id => 'root', command => $root});
    push @nodes, {id => 'child', command => Selecto::Write::Command->new(operation => 'update', relation => 'children', assignments => {reference => 'new'}, predicate => Selecto::Expression->eq('id', 1)),
        bindings => [{from => 'root', key => 'id', field => 'owner'}]} if $mode eq 'update';
    return $engine->execute_graph(Selecto::Write::Graph->new(nodes => \@nodes,
        $mode eq 'sync' ? (owned_sets => [{parent => 'root', relationship => 'children', nodes => [], delete_missing => 1}]) : ()));
}
my @schemas = (
    ['matching', 'id TEXT PRIMARY KEY COLLATE BINARY', 'owner TEXT REFERENCES parents(id)', [], 1],
    ['matching implicit target', 'id TEXT PRIMARY KEY', 'owner TEXT REFERENCES parents', [], 1],
    ['matching unique index', 'id TEXT', 'owner TEXT REFERENCES parents(id)', ['CREATE UNIQUE INDEX owner_identity ON parents(id)'], 1],
    ['no physical FK but exact comparator', 'id TEXT PRIMARY KEY', 'owner TEXT', [], 1],
    ['different child collation', 'id TEXT PRIMARY KEY COLLATE BINARY', 'owner TEXT COLLATE NOCASE REFERENCES parents(id)', [], 0],
    ['different affinity', 'id TEXT PRIMARY KEY', 'owner NUMERIC REFERENCES parents(id)', [], 0],
    ['two contradictory FKs, declared matching first', 'id TEXT PRIMARY KEY', 'owner TEXT REFERENCES parents(id) REFERENCES other(id)', [], 0],
    ['two contradictory FKs, declared matching last', 'id TEXT PRIMARY KEY', 'owner TEXT REFERENCES other(id) REFERENCES parents(id)', [], 0],
    ['nonunique parent', 'id TEXT', 'owner TEXT', [], 0],
    ['partial parent uniqueness', 'id TEXT', 'owner TEXT', ["CREATE UNIQUE INDEX owner_identity ON parents(id) WHERE id='a'"], 0],
    ['wrong index collation', 'id TEXT', 'owner TEXT', ['CREATE UNIQUE INDEX owner_identity ON parents(id COLLATE NOCASE)'], 0],
    ['composite uniqueness', 'id TEXT', 'owner TEXT', ['CREATE UNIQUE INDEX owner_identity ON parents(id,reference)'], 0],
    ['composite FK', 'id TEXT PRIMARY KEY', 'owner TEXT,FOREIGN KEY(owner,reference) REFERENCES parents(id,reference)', [], 0],
);
for my $schema (@schemas) {
    for my $mode (qw(update sync collection)) {
        subtest "$schema->[0], $mode" => sub {
            my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
            $db->do("CREATE TABLE parents($schema->[1],reference TEXT)");
            $db->do('CREATE TABLE other(id TEXT PRIMARY KEY)');
            $db->do("CREATE TABLE children(id INTEGER PRIMARY KEY,reference TEXT,$schema->[2])");
            $db->do($_) for @{$schema->[3]};
            $db->do($schema->[0] eq 'wrong index collation' ? "INSERT INTO parents VALUES('a','prior')" : "INSERT INTO parents VALUES('A','prior'),('a','prior')");
            $db->do('INSERT INTO children VALUES(1,?,?)', undef, 'prior', $schema->[4] ? 'a' : 'A');
            my $mutations = 0;
            $db->sqlite_trace(sub {$mutations++ if $_[0] =~ /\A\s*(?:UPDATE|DELETE\s+FROM)\s+["`\[]?(?:parents|children)\b/i});
            my $engine = Selecto::Engine->new(domain => domain($mode eq 'collection'), adapter => Selecto::SQLite->new(dbh => $db));
            my $ok = eval {attempt($engine, $mode); 1};
            if ($schema->[4]) {
                ok $ok, 'exact physical ownership admits public operation' or diag $@;
                is $db->selectrow_array("SELECT reference FROM parents WHERE id='a'"), 'new', 'actual parent update stored';
                is $db->selectrow_array('SELECT count(*) FROM children'), $mode eq 'sync' ? 0 : 1, 'actual child state follows admitted operation';
            } else {
                is ref($@) && $@->can('code') ? $@->code : "$@", 'ownership_storage_not_evaluable', 'ambiguous physical authority is refused';
                is $mutations, 0, 'whole-plan refusal precedes business DML';
                is $db->selectrow_array('SELECT reference FROM children'), 'prior', 'stored child of other physical parent retained';
            }
            is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'SQLite remains memory only';
            $db->disconnect;
        };
    }
}
subtest 'declared owner keys remain stable even when ordinary field grants allow an update' => sub {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    $db->do('CREATE TABLE parents(id TEXT PRIMARY KEY,reference TEXT)');
    $db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,owner TEXT REFERENCES parents(id),reference TEXT)');
    $db->do("INSERT INTO parents VALUES('a','prior')");
    $db->do("INSERT INTO children VALUES(1,'a','prior')");
    my $raw = domain(0)->contract;
    $raw->{writes}{fields}{id} = {updatable => 1};
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
    my $mutations = 0;
    $db->sqlite_trace(sub {$mutations++ if $_[0] =~ /\A\s*(?:UPDATE|DELETE\s+FROM)\s+["`\[]?(?:parents|children)\b/i});
    eval {$engine->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'root', command => Selecto::Write::Command->new(
        operation => 'update', relation => 'parents', assignments => {id => 'b'}, predicate => Selecto::Expression->eq('id', 'a'))}],
        owned_sets => [{parent => 'root', relationship => 'children', nodes => [], delete_missing => 1}]))};
    is ref($@) && $@->can('code') ? $@->code : "$@", 'ownership_storage_not_evaluable', 'owned cleanup cannot switch to a newly assigned parent key';
    is $mutations, 0, 'stable-owner refusal precedes root DML';
    is $db->selectrow_array('SELECT owner FROM children'), 'a', 'actual original member retained';
    $db->disconnect;
};
done_testing;
