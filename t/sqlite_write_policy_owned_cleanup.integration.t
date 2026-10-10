use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
plan skip_all => 'SQLite unavailable' unless eval {require DBI;require DBD::SQLite;1};

sub domain {
    my ($table, $fields) = @_;
    return {name => $table, source => {source_table => $table, primary_key => 'id', fields => [@$fields],
        columns => {map {$_ => {type => $_ eq 'name' ? 'string' : 'integer'}} @$fields}, associations => {}}, schemas => {}};
}
for my $tenant_owner (0, 1) {
    for my $retain (0, 1) {
        next if $tenant_owner && $retain; # Exact tenant-owned cleanup branch is checked with the empty set.
        my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
        $db->do('PRAGMA temp_store=MEMORY');
        $db->do('PRAGMA foreign_keys=ON');
        $db->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,name TEXT)');
        $db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES parents(id),name TEXT)');
        $db->do(q{INSERT INTO parents VALUES(1,'one'),(2,'two')});
        $db->do(q{INSERT INTO children VALUES(11,1,'kept'),(12,1,'omitted'),(21,2,'other-parent'),(31,NULL,'orphan')});
        my $child = domain('children', [qw(id parent_id name)]);
        $child->{writes} = {operations => {update => {enabled => 1, require_filter => 1}, delete => {enabled => 1, require_filter => 1}},
            fields => {name => {updatable => 1}}};
        my $parent = domain('parents', [qw(id name)]);
        $parent->{writes} = {operations => {update => {enabled => 1, require_filter => 1}}, fields => {name => {updatable => 1}},
            relationships => {children => {writable => 1, cardinality => 'many', ownership => 'owned', allowed_ops => ['update','delete'],
                domain => $child, child_key => 'parent_id', identity_fields => ['id'], strategy => 'sync', delete_missing => 1}}};
        if ($tenant_owner) {
            $parent->{writes}{scope}{tenant} = {field => 'id', satisfied_by => ['trusted_context']};
            $child->{writes}{scope}{tenant} = {field => 'parent_id', satisfied_by => ['trusted_context']};
        }
        my $adapter = Selecto->adapter(sqlite => (dbh => $db));
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($parent), adapter => $adapter,
            $tenant_owner ? (scope => {tenant => 1}) : ());
        my @nodes = ({id => 'root', command => Selecto::Write::Command->new(operation => 'update', relation => 'parents',
            assignments => {name => 'accepted'}, predicate => Selecto::Expression->eq('id', 1))});
        if ($retain) {
            push @nodes, {id => 'kept', command => Selecto::Write::Command->new(operation => 'update', relation => 'children',
                assignments => {name => 'retained'}, predicate => Selecto::Expression->eq('id', 11)),
                bindings => [{field => 'parent_id', from => 'root', key => 'id'}]};
        }
        my $graph = Selecto::Write::Graph->new(nodes => \@nodes, owned_sets => [{parent => 'root', relationship => 'children',
            nodes => $retain ? ['kept'] : [], delete_missing => 1}]);
        my $result = $engine->execute_graph($graph);
        isa_ok $result, 'Selecto::Write::Graph::Result', 'actual governed owned graph completes';
        is_deeply $db->selectall_arrayref('SELECT id,parent_id,name FROM children ORDER BY id'),
            [$retain ? ([11,1,'retained']) : (), [21,2,'other-parent'], [31,undef,'orphan']],
            'empty/nonempty sync deletes only omitted rows of actual returned parent';
        is_deeply $db->selectall_arrayref('SELECT id,name FROM parents ORDER BY id'), [[1,'accepted'],[2,'two']],
            'root result and other parent remain exact';
        my $unscoped_child = domain('children', [qw(id parent_id name)]);
        $unscoped_child->{writes} = {operations => {delete => {enabled => 1, require_filter => 1}}};
        my $ordinary = Selecto::Engine->new(domain => Selecto::Domain->parse($unscoped_child), adapter => $adapter);
        my $before = $db->selectall_arrayref('SELECT * FROM children ORDER BY id');
        my $ok = eval {$ordinary->execute_write(Selecto::Write::Command->new(operation => 'delete', relation => 'children', expected_count => undef));1};
        my $error = $@;
        ok !$ok && ref($error) && $error->code eq 'missing_predicate', 'ordinary unfiltered delete stays refused';
        is_deeply $db->selectall_arrayref('SELECT * FROM children ORDER BY id'), $before, 'ordinary refusal preserves every child';
        is $db->selectrow_array('PRAGMA temp_store'), 2, 'temporary storage is memory';
        ok !grep(length($_->[2]), @{$db->selectall_arrayref('PRAGMA database_list')}), 'all schemas are memory';
        $db->disconnect;
    }
}
done_testing;
