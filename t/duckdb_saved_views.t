use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::Write::Operation ();

plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBI; require DBD::DuckDB; 1 };
my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
$dbh->do('CREATE TABLE sv_duck_panels (id INTEGER PRIMARY KEY, owner_id INTEGER, name VARCHAR UNIQUE, version INTEGER)');
$dbh->do("INSERT INTO sv_duck_panels VALUES (1, 11, 'original', 1)");
my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
my $handler = Selecto::API::EngineHandler->new(bounded_results => 0);

sub declaration {
    return {name => 'DuckPanels', source => {source_table => 'sv_duck_panels', primary_key => 'id',
        fields => [qw(id owner_id name version)], columns => {id => {type => 'integer'}, owner_id => {type => 'integer'},
            name => {type => 'string'}, version => {type => 'integer'}}, associations => {}}, schemas => {},
        writes => {operations => {map { $_ => {enabled => JSON::PP::true, returning => 'all',
                $_ eq 'upsert' ? (conflict_targets => [['id']]) : ()} } qw(insert update delete upsert)},
            fields => {map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} } qw(id owner_id name version)}}};
}
sub command {
    my ($operation) = @_;
    return Selecto::Write::Command->new(operation => $operation, relation => 'sv_duck_panels',
        assignments => $operation eq 'delete' ? {} : $operation eq 'update' ? {name => 'changed'} : {id => 2, name => 'new', version => 1},
        $operation =~ /\A(?:update|delete)\z/ ? (predicate => Selecto::Expression->eq('id', 1)) : (),
        $operation eq 'upsert' ? (metadata => {conflict_target => ['id'], upsert_update_fields => ['name']}) : ());
}
sub refused {
    my ($work, $missing, $label) = @_;
    my ($error, $statements);
    {
        no warnings 'redefine';
        my $execute = $adapter->can('_execute_statement');
        local *Selecto::DuckDB::_execute_statement = sub { ++$statements; $execute->(@_) };
        eval { $work->(); 1 } or $error = $@;
    }
    ok(blessed($error) && $error->isa('Selecto::Error'), "$label: typed refusal");
    is(blessed($error) ? $error->code : 'untyped', 'write_capability_missing', "$label: named capability error");
    like(blessed($error) ? $error->message : '', qr/DuckDB does not support writes/, "$label: backend limitation is explicit");
    is_deeply(blessed($error) ? $error->details : {}, {adapter => 'duckdb', missing => $missing}, "$label: declarations identified");
    is($statements // 0, 0, "$label: no statements execute");
}

for my $case (
    ['column revision', {row_revision => {column => 'version'}}, ['row_revision']],
    ['required computed revision', {row_revision => {columns => ['name'], required => JSON::PP::true}}, ['row_revision']],
    ['host binding without context', {host_bound_fields => {owner_id => {mode => 'owner', source => ['context', 'user_id']}}}, ['host_bound_fields']],
    ['database timestamp binding', {host_bound_fields => {version => {mode => 'modified_at'}}}, ['host_bound_fields']],
    ['empty host binding declaration', {host_bound_fields => {}}, ['host_bound_fields']],
    ['both declarations', {row_revision => {columns => ['name']}, host_bound_fields => {}}, [qw(row_revision host_bound_fields)]],
) {
    my ($label, $features, $missing) = @$case;
    subtest $label => sub {
        my $raw = declaration();
        @{$raw->{writes}}{keys %$features} = values %$features;
        my $engine = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($raw));
        my $result = $engine->all($engine->query->select(qw(id name)));
        is_deeply($result->{rows}, [[1, 'original']], 'engine construction and ordinary reads work');
        is(exists($result->{row_revisions}) ? 1 : 0, exists($features->{row_revision}) ? 1 : 0, 'revision read metadata remains available');
        is($handler->resource($engine, {id => 1, fields => ['name']})->{name}, 'original', 'resource read works');
        refused(sub { $engine->execute_write(command($_)) }, $missing, $_) for qw(insert update delete upsert);
        refused(sub { $engine->preview_write(command('update')) }, $missing, 'preview');
        refused(sub { $engine->write->update->assignments(name => 'changed')->filter(['id', 1])->execute }, $missing, 'fluent');
        my $intent = Selecto::Write::Operation->new($raw)->update({name => 'changed'})->filter(['id', 1]);
        $intent = $intent->row_revision($result->{row_revisions}[0]) if exists $features->{row_revision};
        my $compiled = $intent->compile(context => {user_id => 11});
        refused(sub { $engine->execute_write($compiled->{command}) }, $missing, 'portable command');
        refused(sub { $engine->execute_batch(Selecto::Write::Batch->new(command('update'))) }, $missing, 'batch');
        refused(sub { $handler->write($engine, {operation => 'update', assignments => {name => 'changed'},
            filters => [{field => 'id', op => 'eq', value => 1}]}) }, $missing, 'API');
        is_deeply($dbh->selectall_arrayref('SELECT id, owner_id, name, version FROM sv_duck_panels'),
            [[1, 11, 'original', 1]], 'all refused attempts leave storage unchanged');
    };
}

subtest 'nested graph domain cannot bypass the refusal' => sub {
    my $root = declaration();
    my $child = declaration();
    $child->{source}{source_table} = 'sv_duck_links';
    push @{$child->{source}{fields}}, 'parent_id';
    $child->{source}{columns}{parent_id} = {type => 'integer'};
    $child->{writes}{host_bound_fields} = {owner_id => {mode => 'owner', source => ['context', 'user_id']}};
    $root->{writes}{relationships}{links} = {writable => JSON::PP::true, table => 'sv_duck_links',
        parent_key => 'id', child_key => 'parent_id', allowed_ops => ['insert'], domain => $child};
    my $engine = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($root));
    my $graph = Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => command('update')},
        {id => 'child', command => Selecto::Write::Command->new(operation => 'insert', relation => 'sv_duck_links',
            assignments => {id => 2, name => 'link'}), bindings => [{from => 'root', key => 'id', field => 'parent_id'}]},
    ]);
    refused(sub { $engine->execute_graph($graph) }, ['host_bound_fields'], 'nested domain');
    is($dbh->selectrow_array('SELECT name FROM sv_duck_panels WHERE id=1'), 'original', 'root is not changed before child refusal');
};

subtest 'ordinary DuckDB writes keep unique conflict mapping' => sub {
    my $raw = declaration();
    $raw->{writes}{unique_keys} = {panel_name => ['name']};
    my $engine = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($raw));
    is($engine->execute_write(command('insert'))->affected_rows, 1, 'ordinary governed insert still works');
    my $error;
    eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'sv_duck_panels',
        assignments => {id => 3, name => 'original', version => 1})); 1 } or $error = $@;
    is(blessed($error) ? $error->code : 'untyped', 'database_unique_violation', 'unique error remains normalized');
    is_deeply($error->details->{fields}, ['name'], 'native conflict identifies its fields');
    is($error->details->{key}, 'panel_name', 'declared key name remains available');
};
$dbh->disconnect;
done_testing;
