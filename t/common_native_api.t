use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::Write::Builder ();

my ($backend, $db) = ('sqlite');
if (my $url = $ENV{SELECTO_COMMON_API_POSTGRES_URL}) {
    require Selecto::Certification;
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
    $db = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, pg_enable_utf8 => 1});
    $backend = 'postgresql';
} else {
    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
    $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
}
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

my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto->adapter($backend => (dbh => $db)));
my $bound = $engine->with_tenant(8);
sub error { my ($work) = @_; return eval { $work->(); 1 } ? undef : $@ }
sub refused { my ($code, $work, $label) = @_; my $e = error($work); isa_ok($e, 'Selecto::Error', $label); is($e->code, $code, $label) if ref($e) }

subtest 'one domain-owned binding supplies native writes and reads' => sub {
    is_deeply($engine->scope, {}, 'original engine remains unbound');
    is_deeply($engine->write_context, {}, 'original context remains unchanged');
    is_deeply($bound->scope, {tenant => 8}, 'trusted tenant bound once');
    is_deeply($bound->with_tenant(8)->scope, {tenant => 8}, 'same binding is idempotent');
    refused('tenant_mismatch', sub { $bound->with_tenant(9) }, 'rebinding refuses');
    refused('tenant_mismatch', sub { $bound->with_tenant('8') }, 'identity type is not coerced');
    for my $value (undef, '', '  ') {
        refused('invalid_tenant_context', sub { $engine->with_tenant($value) }, 'empty identity refuses');
    }
    refused('invalid_tenant_context', sub { $engine->with_tenant(8, 9) }, 'extra identity refuses');
    refused('invalid_write_builder', sub { $bound->write('insert') }, 'builder operation is explicit');
    my $draft = $bound->write->insert->assignments(id => 1, name => 'Tokyo 東京', state => 'done')->returning(qw(id org_id name));
    my $preview = $draft->preview;
    like($preview->{sql}, qr/"org_id"/, 'domain tenant column appears in SQL');
    ok(scalar(grep { defined($_) && "$_" eq '8' } @{$preview->{params}}), 'tenant remains a bound value');
    my $result = $draft->execute;
    is_deeply($result->values, {id => 1, org_id => 8, name => 'Tokyo 東京'}, 'omitted custom tenant stored and returned');
    $db->do(q{INSERT INTO tasks VALUES(2,9,'Other','done',NULL)});
    is_deeply($bound->all($bound->query->select('id')->order_by('id'))->{rows}, [[1]], 'native reads automatically scoped');
    my $handler = Selecto::API::EngineHandler->new;
    my $api = $handler->write($bound, {operation => 'insert', assignments => {id => 3, name => 'Public', state => 'done'}});
    is($db->selectrow_array('SELECT org_id FROM tasks WHERE id=3'), 8, 'public handler inherits host context');
    for my $tenant (9, undef) {
        refused('tenant_mismatch', sub { $bound->write->insert->assignments(id => 4, org_id => $tenant, name => 'Bad')->execute }, 'explicit contradiction refuses');
    }
    refused('cardinality_mismatch', sub { $bound->write->update->assignments(name => 'Bad')->filter(['id', 2])->execute }, 'cross-tenant update refuses');
    is($db->selectrow_array('SELECT name FROM tasks WHERE id=2'), 'Other', 'other tenant unchanged');
    $bound->write->insert->assignments(id => 4, org_id => 8, name => 'Equal', state => 'done')->execute;
    is($db->selectrow_array('SELECT org_id FROM tasks WHERE id=4'), 8, 'explicit equal assignment accepted');
};
subtest 'actions and transaction engines inherit the same binding' => sub {
    my @phases;
    my $resolver = sub { push @phases, $_[0]{phase}; 'enabled' };
    my $action = $bound->action('archive')->target(1)->inputs(reason => 'Closed');
    $action->preview(resolver => $resolver);
    $action->execute(resolver => $resolver);
    is_deeply(\@phases, ['preview','execute'], 'action reauthorizes each phase');
    is($db->selectrow_array('SELECT state FROM tasks WHERE id=1'), 'archived', 'native action effect');
    isa_ok(error(sub { $bound->action('archive')->target(2)->inputs(reason => 'Bad')->execute(resolver => $resolver) }), 'Selecto::Error', 'action cannot cross tenant');
    is($db->selectrow_array('SELECT state FROM tasks WHERE id=2'), 'done', 'foreign action row unchanged');
    $bound->transaction(sub {
        my ($tx) = @_;
        is_deeply($tx->scope, {tenant => 8}, 'callback engine inherits binding');
        is_deeply($tx->with_tenant(8)->scope, {tenant => 8}, 'idempotent binding inside callback');
        $tx->write->insert->assignments(id => 5, name => 'Committed', state => 'done')->execute;
        $tx->action('archive')->target(5)->inputs(reason => 'Tx')->execute(resolver => $resolver);
    });
    is($db->selectrow_array('SELECT org_id FROM tasks WHERE id=5'), 8, 'transaction insert inherited tenant');
    is($db->selectrow_array('SELECT state FROM tasks WHERE id=5'), 'archived', 'transaction action inherited context');
    ok(error(sub { $bound->transaction(sub { $_[0]->write->insert->assignments(id => 6, name => 'Rolled back')->execute; die "rollback\n" }) }), 'callback failure propagates');
    is($db->selectrow_array('SELECT count(*) FROM tasks WHERE id=6'), 0, 'transaction rollback retains atomicity');
};
subtest 'legacy read context never becomes write authority' => sub {
    my $legacy = $engine->with_read_context({tenant_id => 8, tenant_field => 'org_id'})->apply_tenant_scope;
    is_deeply($legacy->scope, {}, 'explicit read context remains untrusted for writes');
    is(scalar @{$legacy->all($legacy->query->select('id'))->{rows}}, 4, 'legacy scoped reads remain available');
    refused('unsupported_feature', sub { $legacy->write->insert->assignments(id => 7, name => 'Bad')->execute }, 'read context cannot execute writes');
    refused('unsupported_feature', sub { $legacy->with_tenant(8) }, 'common binding cannot promote attached context');
    my $alias = $engine->with_tenant({tenant_id => 8, tenant_field => 'org_id'});
    is_deeply($alias->scope, {}, 'structured legacy alias does not grant trusted scope');
    my $unscoped = Selecto::Domain::QueryContract->copy_declaration($raw);
    delete $unscoped->{source}{tenant_field}; delete $unscoped->{writes}{scope};
    refused('tenant_not_declared', sub { Selecto::Engine->new(domain => Selecto::Domain->parse($unscoped), adapter => $bound->adapter)->with_tenant(8) }, 'undeclared tenant refuses instead of guessing');
};
subtest 'required predicates and independent scope columns remain distinct' => sub {
    my $excluded = $engine->domain->with_required_predicate(Selecto::Expression->eq('org_id', 9));
    refused('tenant_mismatch', sub { Selecto::Engine->new(domain => $excluded, adapter => $bound->adapter)->with_tenant(8) }, 'contradictory trusted predicate refuses at binding');
    $db->do('CREATE TABLE sites(id INTEGER PRIMARY KEY, org_id INTEGER NOT NULL, site_id INTEGER NOT NULL, name TEXT, state TEXT, reason TEXT)');
    my $two = Selecto::Domain::QueryContract->copy_declaration($raw);
    $two->{source}{source_table} = 'sites';
    push @{$two->{source}{fields}}, 'site_id';
    $two->{source}{columns}{site_id} = {type => 'integer'};
    $two->{writes}{scope}{tenant}{field} = 'site_id';
    $two->{writes}{fields}{site_id} = {insertable => JSON::PP::true, updatable => JSON::PP::true};
    my $domain = Selecto::Domain->parse($two)->with_required_predicate(Selecto::Expression->eq('site_id', 42));
    my $e = Selecto::Engine->new(domain => $domain, adapter => $bound->adapter)->with_tenant(8);
    $e->write->insert->assignments(id => 1, site_id => 42, name => 'Two scopes')->execute;
    is_deeply($db->selectrow_arrayref('SELECT org_id,site_id FROM sites'), [8,42], 'root tenant never copied into independent write scope');
    isa_ok(error(sub { $e->write->insert->assignments(id => 2, site_id => 8, name => 'Bad')->execute }), 'Selecto::Error', 'independent write scope remains enforced');
    is($db->selectrow_array('SELECT count(*) FROM sites'), 1, 'scope failure leaves storage unchanged');
    $db->do(q{INSERT INTO sites VALUES(3,8,99,'Other site',NULL,NULL),(4,9,42,'Other org',NULL,NULL)});
    $e->write->update->filter(['id', 1])->assignments(name => 'Updated')->execute;
    is($db->selectrow_array('SELECT name FROM sites WHERE id=1'), 'Updated', 'two-column update retains caller filter');
    for my $id (3,4) {
        refused('cardinality_mismatch', sub { $e->write->delete->filter(['id', $id])->execute }, 'both independent predicates bound deletion');
    }
    is($db->selectrow_array('SELECT count(*) FROM sites'), 3, 'foreign rows survive');
};
subtest 'source-only tenant needs no duplicate write-scope declaration' => sub {
    $db->do('CREATE TABLE root_only(id INTEGER PRIMARY KEY, org_id INTEGER NOT NULL, name TEXT, state TEXT, reason TEXT)');
    my $contract = Selecto::Domain::QueryContract->copy_declaration($raw);
    $contract->{source}{source_table} = 'root_only';
    delete $contract->{writes}{scope};
    my $e = Selecto::Engine->new(domain => Selecto::Domain->parse($contract), adapter => $bound->adapter)->with_tenant(8);
    my $res = $e->write->insert->assignments(id => 1, name => 'Root')->returning(qw(id org_id))->execute;
    is_deeply($res->values, {id => 1, org_id => 8}, 'domain tenant field alone supplies omitted assignment');
    $db->do(q{INSERT INTO root_only VALUES(2,9,'Other',NULL,NULL)});
    is_deeply($e->all($e->query->select('id'))->{rows}, [[1]], 'source-only read is bounded');
    refused('cardinality_mismatch', sub { $e->write->update->filter(['id', 2])->assignments(name => 'Bad')->execute }, 'source-only update is bounded');
};
done_testing;
