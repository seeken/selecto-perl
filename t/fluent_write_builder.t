use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;
use Selecto::Write::Builder ();

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
$db->do('CREATE TABLE tasks(id INTEGER PRIMARY KEY, org_id INTEGER NOT NULL, name TEXT, state TEXT, reason TEXT)');
my $raw = {
    name => 'Tasks', source => {source_table => 'tasks', primary_key => 'id', tenant_field => 'org_id',
        fields => [qw(id org_id name state reason)], associations => {},
        columns => {map { $_ => {type => ($_ eq 'id' || $_ eq 'org_id') ? 'integer' : 'string'} } qw(id org_id name state reason)}},
    schemas => {}, joins => {},
    writes => {
        operations => {map { $_ => {enabled => JSON::PP::true, returning => 'all', bulk => JSON::PP::true,
            ($_ eq 'upsert' ? (conflict_targets => [['id']]) : ())} } qw(insert update delete upsert)},
        fields => {map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true, ($_ eq 'org_id' ? (required_on => ['insert']) : ())} } qw(id org_id name state reason)},
        scope => {tenant => {field => 'org_id', required => JSON::PP::true, satisfied_by => ['trusted_context']}},
        transitions => {state => {done => ['archived']}},
    },
    actions => {
        archive => {type => 'transition', scope => 'row', capability => 'tasks.archive',
            transition => {field => 'state', from => 'done', to => 'archived'},
            inputs => {reason => {type => 'string', required => JSON::PP::true}},
            execution => {kind => 'updato', operation => 'update', set => {state => 'archived', reason => ['input', 'reason']}}},
        bulk_archive => {type => 'bulk_action', scope => 'bulk', capability => 'tasks.archive',
            execution => {kind => 'updato', operation => 'update', set => {state => 'archived'}}},
    },
    capabilities => {'tasks.archive' => {operations => ['action', 'update']}},
};
my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto->adapter(sqlite => (dbh => $db)));
sub w { Selecto::Write->new($engine)->with_tenant(8) }
sub error {
    my ($work) = @_;
    my $ok = eval { $work->(); 1 };
    return $ok ? undef : $@;
}
subtest 'scalar helpers bind tenant before required validation and preview safely' => sub {
    my $w = w()->insert;
    is($w->assignments(id => 1, name => 'Test', state => 'done'), $w, 'separate setters return same facade');
    $w->returning(qw(id org_id name));
    my $preview = $w->preview;
    like($preview->{sql}, qr/INSERT.*RETURNING/s, 'native SQL preview');
    unlike($preview->{sql}, qr/Test/, 'data not interpolated into SQL');
    is($db->selectrow_array('SELECT count(*) FROM tasks'), 0, 'preview does no mutation');
    my $res = $w->execute;
    is_deeply($res->values, {id => 1, org_id => 8, name => 'Test'}, 'native returning result with omitted tenant');
    is_deeply($engine->write_context, {}, 'original engine remains unbound');
    is(error(sub { $w->execute })->code, 'invalid_write_builder', 'second execution refuses');
    is(error(sub { $w->assignments(name => 'late') })->code, 'invalid_write_builder', 'consumed draft cannot change');
    for my $value (9, undef) {
        my $e = error(sub { w()->insert->assignments(id => 2, org_id => $value, name => 'bad')->execute });
        isa_ok($e, 'Selecto::Error', 'tenant contradiction refuses');
    }
    is($db->selectrow_array('SELECT count(*) FROM tasks'), 1, 'refusals preserve storage');
    isa_ok(error(sub { Selecto::Write->new($engine->with_write_context({tenant_id => 9}))->with_tenant(8) }), 'Selecto::Error', 'cannot rebind trusted tenant');
};
subtest 'input copies, setter atomicity, filtering and cardinality' => sub {
    my $values = {id => 2, name => 'Original', state => 'done'};
    my $w = w()->insert->assignments($values);
    $values->{name} = 'changed outside';
    isa_ok(error(sub { $w->assignments(name => 'first', name => 'second') }), 'Selecto::Error', 'duplicate pairs refuse');
    isa_ok(error(sub { $w->assignments('odd') }), 'Selecto::Error', 'odd pairs refuse');
    $w->execute;
    is($db->selectrow_array('SELECT name FROM tasks WHERE id = 2'), 'Original', 'copy and previous draft retained');
    $db->do(q{INSERT INTO tasks VALUES(3,9,'Other','done',NULL)});
    my $predicate = Selecto::Expression->eq('id', 2);
    my $change = w()->update->assignments(name => 'Renamed')->filter($predicate);
    $predicate->{arguments}[1]{arguments}[0] = 3;
    $change->execute;
    is($db->selectrow_array('SELECT name FROM tasks WHERE id = 2'), 'Renamed', 'governed filter update');
    isa_ok(error(sub { w()->update->assignments(name => 'bad')->filter(['id', 3])->execute }), 'Selecto::Error', 'cross-tenant exact target fails');
    isa_ok(error(sub { w()->update->assignments(name => 'too many')->filter(['id','in',[1,2]])->execute }), 'Selecto::Error', 'default one count rolls back multiple matches');
    is($db->selectrow_array('SELECT name FROM tasks WHERE id = 2'), 'Renamed', 'mismatch rolled back');
    w()->delete->filter(['id', 2])->execute;
    is($db->selectrow_array('SELECT count(*) FROM tasks WHERE id = 2'), 0, 'delete governed normally');
    isa_ok(error(sub { bless({}, 'Selecto::Write::Builder')->execute }), 'Selecto::Error', 'forged builder refuses');
    isa_ok(error(sub { w()->insert->action('archive') }), 'Selecto::Error', 'operation/action mixing refuses');
};
subtest 'upsert masks reuse immutable portable authoring and governance' => sub {
    my $contract = Selecto::Domain::QueryContract->copy_declaration($raw);
    delete $contract->{writes}{scope};
    delete $contract->{source}{tenant_field};
    delete $contract->{writes}{transitions};
    my $host = Selecto::Engine->new(domain => Selecto::Domain->parse($contract), adapter => $engine->adapter);
    Selecto::Write->new($host)->insert->assignments(id => 10, org_id => 8, name => 'upsert', state => 'original')->execute;
    my $upsert = Selecto::Write->new($host)->upsert->assignments(id => 10, org_id => 8, name => 'masked', state => 'ignored')
        ->conflict_target('id')->upsert_update_fields('name')->returning(qw(id name state));
    like($upsert->preview->{sql}, qr/ON CONFLICT/, 'actual upsert SQL');
    is_deeply($upsert->execute->values, {id => 10, name => 'masked', state => 'original'}, 'mask narrows declared conflict updates');
    isa_ok(error(sub { Selecto::Write->new($host)->upsert->assignments(id => 10, name => 'bad')
        ->upsert_update_fields('unknown')->execute }), 'Selecto::Error', 'mask cannot grant new fields');
};
subtest 'named actions retain phase authorization and transitions' => sub {
    my @phases;
    my $policy = sub { push @phases, $_[0]{phase}; return 'enabled' };
    my $a = w()->action('archive')->target(1)->inputs(reason => 'completed');
    isa_ok(error(sub { $a->assignments(state => 'archived') }), 'Selecto::Error', 'action assignments cannot be overridden');
    isa_ok(error(sub { $a->returning('id') }), 'Selecto::Error', 'action result cannot be overridden');
    my $preview = $a->preview(resolver => $policy, context => {actor => {id => 7}});
    is($preview->{phase}, 'preview', 'native preview envelope');
    is($db->selectrow_array('SELECT state FROM tasks WHERE id = 1'), 'done', 'preview preserves row');
    my $res = $a->execute(resolver => $policy, context => {actor => {id => 7}});
    is_deeply(\@phases, ['preview', 'execute'], 'execute resolves its own permission');
    is($res->{action}, 'archive', 'native action envelope');
    is_deeply($db->selectrow_arrayref('SELECT state,reason FROM tasks WHERE id = 1'), ['archived','completed'], 'declared effect and input persisted');
    for my $decision ('disabled', 'hidden') {
        isa_ok(error(sub { w()->action('archive')->target(3)->inputs(reason => 'bad')->execute(resolver => sub { $decision }) }), 'Selecto::Error', "$decision refuses");
    }
    isa_ok(error(sub { w()->action('archive')->target(3)->inputs(reason => 'bad')->execute }), 'Selecto::Error', 'missing resolver refuses');
    isa_ok(error(sub { w()->action('archive')->target(1)->inputs(reason => 'again')->execute(resolver => $policy) }), 'Selecto::Error', 'stale transition refuses');
    isa_ok(error(sub { w()->action('archive')->target(3)->inputs(reason => 'cross tenant')->execute(resolver => $policy) }), 'Selecto::Error', 'enabled capability does not bypass tenant');
    is($db->selectrow_array('SELECT state FROM tasks WHERE id = 3'), 'done', 'other tenant unchanged');
    isa_ok(error(sub { w()->action('unknown') }), 'Selecto::Error', 'unknown action refuses');
    isa_ok(error(sub { w()->action('archive')->target(3)->execute(resolver => $policy) }), 'Selecto::Error', 'missing required input refuses');
    isa_ok(error(sub { w()->action('bulk_archive')->target({ids => [1,1]})->execute(resolver => $policy) }), 'Selecto::Error', 'duplicate bulk target refuses');
    w()->insert->assignments(id => 6, name => 'Preview permission', state => 'done')->execute;
    my $preview_only = w()->action('archive')->target(6)->inputs(reason => 'not allowed');
    my $phase_policy = sub { $_[0]{phase} eq 'preview' ? 'enabled' : 'disabled' };
    is($preview_only->preview(resolver => $phase_policy)->{phase}, 'preview', 'preview-only permission actually previews');
    isa_ok(error(sub { $preview_only->execute(resolver => $phase_policy) }), 'Selecto::Error', 'preview permission alone cannot execute');
    is($db->selectrow_array('SELECT state FROM tasks WHERE id = 6'), 'done', 'denied execute after allowed preview leaves storage unchanged');
    isa_ok(error(sub { w()->action('archive')->target(3)->inputs(reason => 'bad')->execute(grant => {}) }), 'Selecto::Error', 'caller grants are not accepted by helper');
    for my $id (4, 5) { w()->insert->assignments(id => $id, name => "bulk $id", state => 'done')->execute }
    my $bulk = w()->action('bulk_archive')->target({ids => [4,5]})->execute(resolver => $policy);
    is($bulk->{result}->affected_rows, 2, 'declared bounded bulk action executes');
    is_deeply($db->selectall_arrayref('SELECT id,state FROM tasks WHERE id IN (4,5) ORDER BY id'),
        [[4,'archived'],[5,'archived']], 'native readback verifies all bulk effects');
    my $limited = $engine->with_limits(Selecto::Limits->new(max_action_targets => 1));
    isa_ok(error(sub { Selecto::Write->new($limited)->with_tenant(8)->action('bulk_archive')
        ->target({ids => [4,5]})->execute(resolver => $policy) }), 'Selecto::Error', 'host bulk target ceiling retained');
};
subtest 'unsupported edit adapters refuse without target mutation' => sub {
    my $count = $db->selectrow_array('SELECT count(*) FROM tasks');
    isa_ok(error(sub { $engine->transaction(sub {
        my ($tx) = @_;
        Selecto::Write->new($tx)->with_tenant(8)->insert->assignments(id => 99, name => 'unsupported')->return_for_update('id')->execute;
    }) }), 'Selecto::Error', 'SQLite reservation never masquerades as a row handle');
    is($db->selectrow_array('SELECT count(*) FROM tasks'), $count, 'unsupported edit insert never executed');
};
subtest 'native returning preserves Unicode, null and exact large identity' => sub {
    my $large = 9007199254740993;
    my $res = w()->insert->assignments(id => $large, name => 'Tokyo 東京', state => undef)
        ->returning(qw(id name state))->execute;
    is("" . $res->values->{id}, "$large", 'large integer identity never passes through floating-point JSON');
    is($res->values->{name}, 'Tokyo 東京', 'native literal Unicode preserved');
    ok(exists($res->values->{state}) && !defined($res->values->{state}), 'explicit null retained');
};
subtest 'compound root identities retain exact write scope and action targets' => sub {
    $db->do('CREATE TABLE compound_tasks(org_id INTEGER NOT NULL, id TEXT NOT NULL, name TEXT, state TEXT, reason TEXT, PRIMARY KEY(org_id,id))');
    my $contract = Selecto::Domain::QueryContract->copy_declaration($raw);
    $contract->{name} = 'Compound tasks';
    $contract->{source}{source_table} = 'compound_tasks';
    $contract->{source}{primary_key} = [qw(org_id id)];
    $contract->{source}{columns}{id}{type} = 'string';
    $contract->{writes}{operations}{upsert}{conflict_targets} = [[qw(org_id id)]];
    my $native = Selecto::Domain->new(name => 'Compound', table => 'compound_tasks',
        fields => {org_id => 'integer', id => 'string'}, primary_key => [qw(org_id id)]);
    my $exported = $native->as_contract;
    $exported->{source}{primary_key}[0] = 'id';
    is_deeply($native->primary_keys, [qw(org_id id)], 'native contract export owns its compound key copy');
    my $host = Selecto::Engine->new(domain => Selecto::Domain->parse($contract), adapter => $engine->adapter,
        write_context => {tenant_id => 8});
    my $new = sub { Selecto::Write->new($host) };
    for my $id ('東京', 'other') {
        $new->()->insert->assignments(id => $id, name => 'Test', state => 'done')->execute;
    }
    $db->do(q{INSERT INTO compound_tasks VALUES(9,'東京','other tenant','done',NULL)});
    my $changed = $new->()->update->assignments(name => 'exact')->filter(Selecto::Expression->all(
        Selecto::Expression->eq('org_id', 8), Selecto::Expression->eq('id', '東京')))->execute;
    is($changed->affected_rows, 1, 'captured native predicate preserves compound source identity');
    my $before = $db->selectrow_array('SELECT total_changes()');
    my $failure = error(sub { $new->()->update->assignments(name => 'too broad')->execute });
    is($failure->code, 'cardinality_mismatch', 'partial identity cannot bypass bounded probe');
    is($db->selectrow_array('SELECT total_changes()'), $before, 'broad refusal occurs before target DML');
    $new->()->update->assignments(name => 'bounded set')->expected_cardinality(['exactly',2])->execute;
    is_deeply($db->selectall_arrayref('SELECT org_id,id,name FROM compound_tasks ORDER BY org_id,id'),
        [[8,'other','bounded set'],[8,'東京','bounded set'],[9,'東京','other tenant']], 'probe binds full tuples without cross-tenant effects');
    my $action = $new->()->action('archive')->target({org_id => 8, id => '東京'})->inputs(reason => 'complete');
    my $policy = sub { 'enabled' };
    my $preview = $action->preview(resolver => $policy);
    like($preview->{statement}{sql}, qr/"org_id".*"id"/s, 'action preview includes every target component');
    $action->execute(resolver => $policy);
    is($db->selectrow_array(q{SELECT state FROM compound_tasks WHERE org_id=8 AND id='東京'}), 'archived', 'named row action targets native compound identity');
    for my $target ({id => '東京'}, {org_id => undef, id => '東京'}, {org_id => 8,id => '東京',name => 'extra'}, '東京') {
        isa_ok(error(sub { $new->()->action('archive')->target($target)->inputs(reason => 'bad')->execute(resolver => $policy) }),
            'Selecto::Error', 'incomplete or ambiguous action identity refuses');
    }
    isa_ok(error(sub { $new->()->action('bulk_archive')->target({ids => [{org_id => 8, id => 'other'}]})->execute(resolver => $policy) }),
        'Selecto::Error', 'unimplemented compound bulk target refuses explicitly');
    for my $key ([], ['id','id'], ['id','missing'], ['id',{}]) {
        my $bad = Selecto::Domain::QueryContract->copy_declaration($contract);
        $bad->{source}{primary_key} = $key;
        isa_ok(error(sub { Selecto::Domain->parse($bad) }), 'Selecto::Error', 'invalid native primary-key declaration refuses');
    }
};
done_testing;
