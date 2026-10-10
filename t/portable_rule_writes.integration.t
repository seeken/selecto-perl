use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;
BEGIN { eval {require DBI; require DBD::SQLite; 1} or plan skip_all => 'DBD::SQLite required' }

sub rules {
    my (@bindings) = @_;
    my (%definitions, %compiled);
    for my $i (0 .. $#bindings) {
        my ($stage, $field, $test, $extra) = @{$bindings[$i]};
        $definitions{"rule$i"} = {version => 1, test => $test};
        $compiled{"rule$i"} = {subject => {scope => $stage, path => [$field]}, rule => {id => "rule$i", version => 1}, %{$extra // {}}};
    }
    return {schema => 'selecto.data_rules.v1', definitions => \%definitions, normalizers => {}, bindings => \%compiled};
}
sub flat {
    my ($rules) = @_;
    return {name => 'NativeRules', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id quantity reference)], columns => {id => {type => 'integer'}, quantity => {type => 'decimal'}, reference => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}, rules => $rules, writes => {operations => {insert => {enabled => 1}, update => {enabled => 1}},
            fields => {quantity => {insertable => 1, updatable => 1}, reference => {insertable => 1, updatable => 1}}}};
}
sub memory {
    my $run = shift;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    $db->do("CREATE TABLE items(id INTEGER PRIMARY KEY,quantity NUMERIC,reference TEXT DEFAULT 'fallback')");
    my $mutations = 0;
    $db->sqlite_trace(sub {$mutations++ if $_[0] =~ /\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+["`\[]?(?:items|parents|children)\b/i});
    $run->($db, Selecto::SQLite->new(dbh => $db), \$mutations);
    is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'native fixture uses memory only';
    $db->disconnect;
}
sub engine { Selecto::Engine->new(domain => Selecto::Domain->parse($_[0]), adapter => $_[1]) }
sub code { my $run = shift; return eval {$run->(); 1} ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@" }
sub insert { Selecto::Write::Command->new(operation => 'insert', relation => 'items', assignments => $_[0]) }

subtest 'raw missing INPUT and physical candidate types remain distinct' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    my $raw = flat(rules(['input', 'reference', {op => 'presence.absent'}],
        ['candidate', 'quantity', {op => 'number.gt', bound => '0'}]));
    is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => '0.25'}))}), 'ok', 'known absent INPUT is valid before database default';
    is $db->selectrow_array('SELECT reference FROM items'), 'fallback', 'actual default stores after input absence admission';
    $raw = flat(rules(['input', 'reference', {op => 'type.is', type => 'integer'}],
        ['candidate', 'reference', {op => 'type.is', type => 'text'}]));
    is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => '0.25', reference => 1}))}), 'ok', 'raw numeric INPUT is checked before TEXT candidate conversion';
    is $db->selectrow_array('SELECT reference FROM items ORDER BY id DESC LIMIT 1'), '1', 'physical TEXT candidate is actually stored';
    $raw = flat(rules(['input', 'quantity', {op => 'value.eq', value => '1e-400'}],
        ['candidate', 'quantity', {op => 'number.gt', bound => '0'}]));
    my $before = $$mutations;
    my $error = code(sub {engine($raw, $adapter)->execute_write(insert({quantity => '1e-400', reference => 'new'}))});
    is $error, 'data_rule_failed', 'raw INPUT acceptance cannot restore NUMERIC underflow candidate';
    is $$mutations, $before, 'underflow refusal happens before any business DML';
    is $db->selectrow_array('SELECT count(*) FROM items'), 2, 'admitted earlier rows retained';
    $raw = flat(rules(['input', 'quantity', {op => 'type.is', type => 'text'}],
        ['candidate', 'quantity', {op => 'type.is', type => 'decimal'}]));
    is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => '0.25', reference => 'decimal'}))}),
        'ok', 'raw decimal text and actual native numeric candidate have distinct scalar kinds';
    is $db->selectrow_array('SELECT typeof(quantity) FROM items ORDER BY id DESC LIMIT 1'), 'real', 'native decimal candidate actually stores numeric affinity';
})};

subtest 'known missing INPUT cannot stand in for unknown generated CANDIDATE' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    for my $extra ({}, {enforcement => 'advisory', condition => {op => 'presence.absent'}}) {
        my $raw = flat(rules(['candidate', 'id', {op => 'presence.absent'}, $extra]));
        is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => 1, reference => 'new'}))}),
            'required_data_rule_pending', 'unknown generated key remains pending even with advisory or false condition';
        is $$mutations, 0, 'unknown generated scalar never dispatches';
    }
})};

subtest 'logical collection conditions cannot hide unknown child fields' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    $db->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,label TEXT)');
    $db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES parents(id),quantity INTEGER)');
    my $child = {name => 'Children', source => {source_table => 'children', primary_key => 'id', fields => [qw(id parent_id quantity)],
        columns => {id => {type => 'integer'}, parent_id => {type => 'integer'}, quantity => {type => 'integer'}}, associations => {}},
        schemas => {}, joins => {}, writes => {fields => {quantity => {insertable => 1}}}};
    for my $test (
        {op => 'any', rules => [{op => 'collection.count', exact => 1}, {op => 'collection.sum', path => ['id'], min => '0'}]},
        {op => 'not', rule => {op => 'value.eq', value => []}}) {
        for my $extra ({}, {enforcement => 'advisory', condition => {op => 'collection.count', exact => 0}}) {
            my $raw = {name => 'Parents', source => {source_table => 'parents', primary_key => 'id', fields => [qw(id label)],
                columns => {id => {type => 'integer'}, label => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
                rules => rules(['candidate', 'children', $test, $extra]),
                writes => {operations => {insert => {enabled => 1}}, fields => {label => {insertable => 1}}, relationships => {children => {
                    writable => 1, ownership => 'owned', parent_key => 'id', child_key => 'parent_id', allowed_ops => ['insert'], domain => $child}}}};
            my $graph = Selecto::Write::Graph->new(nodes => [
                {id => 'root', command => Selecto::Write::Command->new(operation => 'insert', relation => 'parents', assignments => {label => 'new'})},
                {id => 'child', command => Selecto::Write::Command->new(operation => 'insert', relation => 'children', assignments => {quantity => 1}),
                    bindings => [{from => 'root', key => 'id', field => 'parent_id'}]}]);
            is code(sub {engine($raw, $adapter)->execute_graph($graph)}), 'required_data_rule_pending', 'complete consumed dependencies remain unknown across logical/advisory condition';
            is $$mutations, 0, 'no graph business DML before complete authority';
        }
    }
})};

subtest 'public advisory failures are harmless but resource exhaustion is not admission' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    my $raw = flat(rules(['candidate', 'quantity', {op => 'number.gt', bound => '10'}, {enforcement => 'advisory'}]));
    is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => 1, reference => 'ok'}))}), 'ok', 'ordinary advisory failure permits otherwise governed write';
    my $heavy = {op => 'text.pattern', profile => 'ascii_v1', pattern => '(a|b|c|d|e|f|g|h|i|j)*z', match => 'full', flags => []};
    $raw = flat(rules(['input', 'reference', {op => 'any', rules => [{op => 'presence.required'}, ($heavy) x 20]}, {enforcement => 'advisory'}]));
    my $before = $$mutations;
    $db->begin_work;
    is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => 1, reference => 'a' x 4096}))}), 'evaluation_limit', 'advisory logical resource limit is unconditional at public write';
    is $$mutations, $before, 'resource exhaustion produces no business DML';
    ok !$db->{AutoCommit}, 'host transaction remains open';
    is $db->selectrow_array('SELECT count(*) FROM items'), 1, 'prior stored advisory success retained';
    $db->rollback;
})};
subtest 'batch insert rules preflight every original INPUT before any business DML' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    my $raw = flat(rules(['input', 'reference', {op => 'presence.absent'}],
        ['candidate', 'quantity', {op => 'number.gt', bound => '0'}]));
    my $engine = engine($raw, $adapter);
    is code(sub {$engine->execute_batch(Selecto::Write::Batch->new(insert({quantity => 1}), insert({quantity => 0})))}),
        'data_rule_failed', 'later invalid candidate refuses complete batch';
    is $$mutations, 0, 'even valid prefix does not dispatch';
    is $db->selectrow_array('SELECT count(*) FROM items'), 0, 'stored table unchanged';
    is code(sub {$engine->execute_batch(Selecto::Write::Batch->new(insert({quantity => 1}), insert({quantity => 2})))}),
        'ok', 'known missing original INPUT is preserved for every batch member';
    is $db->selectrow_array('SELECT count(*) FROM items'), 2, 'valid admitted batch persists';
    is code(sub {$engine->execute_batch(Selecto::Write::Batch->new(Selecto::Write::Command->new(
        operation => 'update', relation => 'items', assignments => {quantity => 3}, predicate => Selecto::Expression->eq('id', 1))))}),
        'required_data_rule_pending', 'stored batch delta requires prospective whole-plan authority';
})};
subtest 'public action INPUT knows omission but never invents authored system values' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    my $raw = flat(rules(['action_input', 'reference', {op => 'presence.absent'}]));
    $raw->{rules}{bindings}{rule0}{subject}{action} = 'create';
    $raw->{actions}{create} = {type => 'detail_action', inputs => {reference => {type => 'string'}},
        execution => {kind => 'updato', operation => 'insert', set => {quantity => 1}}};
    my $engine = engine($raw, $adapter);
    my $plan;
    is code(sub {$plan = $engine->plan_action({action => 'create', inputs => {}})}), 'ok', 'known absent action input plans';
    is code(sub {$engine->execute_action($plan)}), 'ok', 'known absent action input executes through public API';
    is $db->selectrow_array('SELECT reference FROM items'), 'fallback', 'literal database default remains separate from action input';
    my $before = $$mutations;
    is code(sub {$engine->plan_action({action => 'create', inputs => {reference => undef}})}), 'data_rule_failed', 'explicit null action input is present';
    is $$mutations, $before, 'failed action input dispatches no mutation';
    $raw->{actions}{create}{inputs}{reference}{default} = ['system', 'now'];
    $raw->{rules}{bindings}{rule0}{enforcement} = 'advisory';
    $raw->{rules}{bindings}{rule0}{condition} = {op => 'presence.absent'};
    is code(sub {engine($raw, $adapter)->plan_action({action => 'create', inputs => {}})}),
        'required_data_rule_pending', 'unknown system input cannot hide behind advisory or condition';
    is $$mutations, $before, 'unknown action input produces no mutation';
    $raw->{actions}{create}{inputs}{note} = {type => 'string'};
    $raw->{rules}{definitions}{heavy} = {version => 1, test => {op => 'presence.required'}};
    $raw->{rules}{normalizers}{heavy} = {version => 1, steps => [({op => 'text.trim', profile => 'ascii_v1'}) x 700]};
    $raw->{rules}{bindings}{heavy} = {subject => {scope => 'action_input', action => 'create', path => ['note']},
        enforcement => 'advisory', rule => {id => 'heavy', version => 1}, normalizer => {id => 'heavy', version => 1}};
    is code(sub {engine($raw, $adapter)->plan_action({action => 'create', inputs => {note => 'a' x 4000}})}),
        'evaluation_limit', 'unknown system input cannot hide another binding resource error';
    is $$mutations, $before, 'action resource refusal dispatches no mutation';
})};
subtest 'native empty-to-null normalization runs once before physical recheck' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    my $raw = flat(rules(['candidate', 'reference', {op => 'value.eq', value => undef}]));
    $raw->{rules}{normalizers}{nullable} = {version => 1, steps => [{op => 'text.empty_to_null'}]};
    $raw->{rules}{bindings}{rule0}{normalizer} = {id => 'nullable', version => 1};
    is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => 1, reference => ''}))}),
        'ok', 'flat candidate normalizer is not replayed after storage conversion';
    is $db->selectrow_array('SELECT reference IS NULL FROM items'), 1, 'actual SQL NULL persists';
    $db->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,label TEXT)');
    $db->do('CREATE TABLE children(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES parents(id),reference TEXT)');
    my $child = dclone($raw); $child->{name} = 'Child'; $child->{source}{source_table} = 'children';
    $child->{source}{fields} = [qw(id parent_id reference)]; delete $child->{source}{columns}{quantity};
    $child->{source}{columns}{parent_id} = {type => 'integer'}; delete $child->{writes}{fields}{quantity};
    my $parent = {name => 'Parent', source => {source_table => 'parents', primary_key => 'id', fields => [qw(id label)],
        columns => {id => {type => 'integer'}, label => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}}, fields => {label => {insertable => 1}}, relationships => {children => {
            writable => 1, ownership => 'owned', parent_key => 'id', child_key => 'parent_id', allowed_ops => ['insert'], domain => $child}}}};
    my $graph = Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => Selecto::Write::Command->new(operation => 'insert', relation => 'parents', assignments => {label => 'new'})},
        {id => 'child', command => Selecto::Write::Command->new(operation => 'insert', relation => 'children', assignments => {reference => ''}),
            bindings => [{from => 'root', key => 'id', field => 'parent_id'}]}]);
    is code(sub {engine($parent, $adapter)->execute_graph($graph)}), 'ok', 'graph child final materialization does not replay normalizer';
    is $db->selectrow_array('SELECT reference IS NULL FROM children'), 1, 'actual graph child stores SQL NULL';
})};
subtest 'unavailable native evidence still exposes shared normalizer resources' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    for my $stage (qw(evidence transaction)) {
        my $raw = flat(rules([$stage, 'reference', {op => 'presence.required'},
            {enforcement => 'advisory', condition => {op => 'presence.absent'}}]));
        $raw->{rules}{normalizers}{trim} = {version => 1, steps => [({op => 'text.trim', profile => 'ascii_v1'}) x 700]};
        $raw->{rules}{bindings}{rule0}{normalizer} = {id => 'trim', version => 1};
        is code(sub {engine($raw, $adapter)->execute_write(insert({quantity => 1, reference => 'a' x 4000}))}),
            'evaluation_limit', "native $stage budget error remains unconditional";
        is $$mutations, 0, 'unavailable/advisory resource refusal precedes business DML';
    }
})};
subtest 'native collection snapshots share a whole-plan hydration ceiling' => sub {memory(sub {
    my ($db, $adapter, $mutations) = @_;
    $db->do('CREATE TABLE parents(id INTEGER PRIMARY KEY,label TEXT)');
    $db->do("INSERT INTO parents VALUES(1,'prior')");
    my (%edges, %definitions, %bindings);
    for my $side (qw(left right)) {
        my $table = "${side}_children";
        $db->do("CREATE TABLE $table(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES parents(id),quantity INTEGER)");
        my $seed = $db->prepare("INSERT INTO $table VALUES(?,1,1)");
        $seed->execute($_) for 1 .. 500;
        my $child = {name => $side, source => {source_table => $table, primary_key => 'id', fields => [qw(id parent_id quantity)],
            columns => {id => {type => 'integer'}, parent_id => {type => 'integer'}, quantity => {type => 'integer'}}, associations => {}}, schemas => {}, joins => {}, writes => {}};
        $edges{$side} = {ownership => 'owned', writable => 1, parent_key => 'id', child_key => 'parent_id', domain => $child};
        $definitions{$side} = {version => 1, test => {op => 'collection.count', exact => 500}};
        $bindings{$side} = {subject => {scope => 'candidate', path => [$side]}, rule => {id => $side, version => 1}};
    }
    my $raw = {name => 'Bounded', source => {source_table => 'parents', primary_key => 'id', fields => [qw(id label)],
        columns => {id => {type => 'integer'}, label => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {label => {updatable => 1}}, relationships => \%edges},
        rules => {schema => 'selecto.data_rules.v1', definitions => \%definitions, normalizers => {}, bindings => \%bindings}};
    $$mutations = 0;
    is code(sub {engine($raw, $adapter)->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'parents',
        assignments => {label => 'new'}, predicate => Selecto::Expression->eq('id', 1)))}),
        'required_data_rule_pending', 'two valid edge snapshots cannot bypass shared 1000-row proof';
    is $$mutations, 0, 'whole-plan hydration refusal occurs before root DML';
    is $db->selectrow_array('SELECT label FROM parents'), 'prior', 'actual stored root retained';
})};
done_testing;
