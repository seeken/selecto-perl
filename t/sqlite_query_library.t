use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use DBI;
use Selecto;
use Selecto::BoundedQuery;

plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };
open my $handle, '<:raw', 't/fixtures/query_library.json' or die $!;
my $fixtures = JSON::PP->new->utf8->decode(do { local $/; <$handle> });
close $handle;
my $authored = dclone($fixtures->{QL001}{domain});
my $domain = Selecto::Domain->parse($authored);
is_deeply($authored, $fixtures->{QL001}{domain}, 'parsing does not mutate authored library');
ok($domain->validate_query_library->{valid}, 'exact original library validates through public API');
is_deeply($domain->query_contract->{query_library}, $authored->{query_library}, 'public query-contract projection retains the authored library');
my $projected = $domain->query_contract;
$projected->{query_library}{segments}{active_projects}{filters}[0][2] = 'modified';
is($domain->query_contract->{query_library}{segments}{active_projects}{filters}[0][2], 'active', 'query contract result is isolated');
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
$dbh->do('PRAGMA temp_store=MEMORY');
$dbh->do('CREATE TABLE projects(id INTEGER PRIMARY KEY,name TEXT,status TEXT,priority INTEGER,visible INTEGER,inserted_at TEXT)');
$dbh->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,project_id INTEGER REFERENCES projects(id))');
my $insert = $dbh->prepare('INSERT INTO projects VALUES (?,?,?,?,?,NULL)');
$insert->execute(@$_) for [1,'A','active',3,1], [2,'B','active',1,1], [3,'C','archived',4,1], [4,'D','pending',5,1], [5,'Hidden','active',9,0], [6,'Hidden2','archived',2,0];
$dbh->do(q{INSERT INTO items VALUES (11,'first',1),(12,'second',1),(13,'third',3)});
my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $x = 'Selecto::Expression';
my %ids = (and => [1], or => [1,2,3], not => [3,4], nor => [4], xor => [1,2,3]);
for my $selection (@{$fixtures->{QL002}{segments}}) {
    my $query = $engine->apply_segment($engine->query->select('id'), $selection->{id}, $selection->{parameters});
    is_deeply([map { $_->[0] } @{$engine->all($query)->{rows}}], $ids{$selection->{name}}, "$selection->{name} executes real SQLite predicates and retains required visibility");
    my $statement = $engine->compile($query);
    unlike($statement->sql, qr/active|archived/, 'segment values remain bound');
}
my $view = $engine->apply_view($engine->query, $fixtures->{QL004}{view}, $fixtures->{QL004}{parameters});
is_deeply($engine->all($view)->{rows}, [[1,'A','active',3]], 'view casts minimum string to numeric and executes the actual filters');
my $changed = $view->where($x->eq('visible', 0))->select('name')->replace_orders([['priority','desc']]);
is_deeply($engine->all($changed)->{rows}, [], 'replacing optional predicate cannot remove domain visibility');
my $replaced = $view->where($x->gte('priority', 0))->select('name')->replace_orders([['priority','desc']]);
is_deeply($engine->all($replaced)->{rows}, [[1,'A'],[2,'B'],[3,'C'],[4,'D']], 'required selected ID and ordering survive later selection and ordering replacement');
is_deeply($adapter->execute_query($adapter->compile($domain, $replaced))->{rows}, $engine->all($replaced)->{rows}, 'direct adapter compilation preserves the same obligations');
is_deeply([map { $_->arguments->[0] } @{$replaced->selections}], ['name'], 'compilation preserves immutable optional intent');
my $projection = $engine->apply_projection($engine->query, $fixtures->{QL003}{projection});
is_deeply($projection->applied_query_library->{projections}, [qw(project_identity item_identity item_name project_with_items)], 'merged collection projection records actual definition provenance');
is_deeply([map { $_->kind } @{$projection->selections}], [qw(field field related_collection)], 'association fields are one collection rather than joined scalar selections');
is_deeply($projection->selections->[2]->arguments->[1], [qw(id name)], 'child field definitions merge in authored order');
my $collections = Selecto::BoundedQuery->all($engine, $projection);
is_deeply([map { [$_->[0], $_->[1]] } @{$collections->{rows}}], [[1,'A'],[2,'B'],[3,'C'],[4,'D']], 'collection projection does not duplicate parent rows');
my $json = JSON::PP->new;
is_deeply($collections->{rows}->[0][2], [{id => 11,name => 'first'},{id => 12,name => 'second'}], 'native correlated collection has actual merged child values');
is_deeply($collections->{rows}->[1][2], [], 'empty native collection remains an empty array');
my $collection_only = $engine->query->select($x->related_collection('items', [qw(id name)])->as('items'));
my $prepared = Selecto::BoundedQuery->prepare($engine, $collection_only);
is_deeply($prepared->{collections}, [[1,100]], 'bounded collection ordinal follows inserted required selection');
is_deeply($prepared->{statement}->columns, [qw(id items)], 'required ID precedes collection in actual bounded statement');
sub code { my ($run) = @_; my $ok = eval { $run->(); 1 }; return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : die $@ }
is(code(sub { Selecto::BoundedQuery->all($engine, $projection, limits => Selecto::Limits->new(max_collection_rows => 1)) }), 'result_limit_exceeded', 'actual native overflow is refused by bounded collection consumer');
for my $value ('not-integer', '9223372036854775808', '-9223372036854775809', "\x{0663}") {
    is(code(sub { $engine->apply_view($engine->query, $fixtures->{QL004}{view}, {minimum => $value}) }), 'invalid_query_library', 'invalid and unbounded integer parameter is refused before SQL');
}
is(code(sub { $engine->apply_view($engine->query, $fixtures->{QL004}{view}, {}) }), 'invalid_query_library', 'missing required parameter refused');
is(code(sub { $engine->apply_view($engine->query, $fixtures->{QL004}{view}, {minimum => 3,extra => 1}) }), 'invalid_query_library', 'unknown parameter refused');
for my $bound ('9223372036854775807', '-9223372036854775808') {
    my $query = $engine->apply_segment($engine->query, 'priority_at_least', {minimum => $bound});
    is("".$engine->compile($query)->params->[1], $bound, 'signed 64-bit integer boundary is preserved exactly');
}
for my $attempt (@{$fixtures->{QL005}{attempts}}) {
    is(code(sub { Selecto::Domain->parse($attempt->{domain}) }), 'invalid_query_library', "$attempt->{id} refuses before any query execution");
}
for my $change (
    sub { $_[0]{query_library}{segments}{active_projects}{filters} = [['evil','status','active']] },
    sub { $_[0]{query_library}{segments}{active_projects}{filters} = [['not',['eq','status','active'],['eq','status','active']]] },
    sub { $_[0]{query_library}{segments}{active_projects}{filters} = [['eq','status',['param','missing']]] },
    sub { $_[0]{query_library}{segments}{active_projects}{parameters} = {p => {type => []}} },
    sub { $_[0]{query_library}{projections}{item_identity}{associations}[0]{name} = 'missing' },
    sub { $_[0]{query_library}{segments}{active_xor_archived_projects}{segment_groups}[0]{segments} = [qw(active_projects archived_projects active_projects)] },
) {
    my $bad = dclone($authored); $change->($bad);
    is(code(sub { Selecto::Domain->parse($bad) }), 'invalid_query_library', 'malformed declared library is rejected eagerly');
}
my $calls = 0;
my $callback = dclone($authored); $callback->{query_library}{segments}{active_projects}{callback} = sub { $calls++ };
is(code(sub { Selecto::Domain->parse($callback) }), 'invalid_query_library', 'executable library metadata refused before copying');
is($calls, 0, 'validation does not execute a declared callback');
my $grouped = dclone($authored); $grouped->{required_group_by} = ['id'];
my $group_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($grouped), adapter => $adapter);
like($group_engine->compile($group_engine->query->select('id')->group_by('status'))->sql, qr/GROUP BY "s0"\."id", "s0"\."status"/, 'required grouping precedes later optional grouping');
my $defaults = dclone($authored); $defaults->{default_selected} = ['name'];
my $default_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($defaults), adapter => $adapter);
is_deeply($default_engine->compile($default_engine->query)->columns, [qw(id name)], 'default selection with required selection installed when optional selection absent');
is_deeply($default_engine->compile($default_engine->query->select('priority'))->columns, [qw(id priority)], 'explicit optional selection replaces only defaults');
my $nested = dclone($authored); $nested->{query_library}{projections}{item_identity}{associations}[0]{associations} = [{name => 'missing', fields => ['id']}];
is(code(sub { Selecto::Domain->parse($nested) }), 'invalid_query_library', 'unresolved nested association refuses during metadata admission');
my $float = dclone($authored); $float->{query_library}{segments}{priority_at_least}{parameters}{minimum}{type} = 'float';
my $float_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($float), adapter => $adapter);
is_deeply([map { $_->[0] } @{$float_engine->all($float_engine->apply_segment($float_engine->query->select('id'), 'priority_at_least', {minimum => '3.5'}))->{rows}}], [3,4], 'float parameter string is bound as actual numeric value');
for my $value ('NaN','Inf','1e999') {
    is(code(sub { $float_engine->apply_segment($float_engine->query, 'priority_at_least', {minimum => $value}) }), 'invalid_query_library', 'nonfinite parameter refused before SQL');
}
is(code(sub { $engine->compile($engine->query->select($x->field('name')->as('items'), $x->related_collection('items',[qw(id name)])->as('items'))) }), 'invalid_query', 'collection result alias collision refuses before SQL execution');
is(code(sub { $engine->compile($engine->query->retarget('items')->select('id')) }), 'unsupported_feature', 'retargeting required root clauses fails closed within this bounded policy port');
my $deep = dclone($authored);
$deep->{schemas}{projects} = dclone($deep->{source}); $deep->{schemas}{projects}{associations} = {};
$deep->{schemas}{items}{associations}{project} = {queryable => 'projects',owner_key => 'project_id',related_key => 'id'};
$deep->{query_library}{projections}{item_identity}{associations}[0]{associations} = [{name => 'project',fields => ['id']}];
my $deep_domain = Selecto::Domain->parse($deep);
ok($deep_domain->validate_query_library->{valid}, 'valid deeper association metadata resolves after canonical schemas are available');
my $deep_engine = Selecto::Engine->new(domain => $deep_domain, adapter => $adapter);
is(code(sub { $deep_engine->apply_projection($deep_engine->query,'item_identity') }), 'unsupported_feature', 'deeper native collection nesting refuses without a separate bounded profile');
my $chain = dclone($authored);
for my $i (0 .. 66) { $chain->{query_library}{projections}{"chain$i"} = $i == 66 ? {fields => ['id']} : {projections => ['chain'.($i+1)]} }
is(code(sub { Selecto::Domain->parse($chain) }), 'invalid_query_library', 'flat declared reference graph cannot evade depth admission');
my $callback_contract = $domain->query_contract;
$callback_contract->{required_selected} = [{}];
my $bad_policy = dclone($authored); $bad_policy->{required_selected} = [{}];
my $bad_policy_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($bad_policy), adapter => $adapter);
is(code(sub { $bad_policy_engine->compile($bad_policy_engine->query->select('name')) }), 'invalid_domain', 'unsupported required selection shape refuses at compiler boundary');
is($dbh->selectrow_array('PRAGMA temp_store'), 2, 'TEMP is memory');
is($dbh->selectall_arrayref('PRAGMA database_list')->[0][2], '', 'main database is memory');
$dbh->disconnect;
done_testing;
