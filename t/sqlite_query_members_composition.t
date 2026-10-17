use 5.034;
use strict;
use warnings;
use Test::More;
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
use JSON::PP ();
use DBI;
use Storable qw(dclone);
use Selecto;
use Selecto::Verification::GovernedQueryComposition;
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };

sub load_json { open my $h, '<:raw', $_[0] or die $!; local $/; JSON::PP->new->utf8->decode(<$h>) }
my $fixtures = load_json('t/fixtures/query_members.json');
my $oracles = load_json('t/fixtures/query_members_expected.json');
my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
$db->do('PRAGMA temp_store=MEMORY');
$db->do(q{ATTACH DATABASE ':memory:' AS tenant_a});
$db->do(q{ATTACH DATABASE ':memory:' AS tenant_b});
my $adapter = Selecto->adapter(sqlite => dbh => $db);
sub engine { Selecto::Engine->new(adapter => $adapter, @_) }
sub code_of { my ($run) = @_; my $ok = eval { $run->(); 1 }; my $e = $@; return $ok ? 'ok' : ref($e) && UNIVERSAL::isa($e, 'Selecto::Error') ? $e->code : die $e }
my $events = 0;
$db->sqlite_set_authorizer(sub { ++$events; 0 });
sub refusal { my ($name, $code, $run) = @_; $events = 0; is(code_of($run), $code, $name); is($events, 0, "$name before native SQL") }

my $members = Selecto::Domain->project_query_members($fixtures->{D048}{governed_domain});
is_deeply({map { ($_ => [map { $_->{id} } @{$members->{query_members}{$_}}]) } keys %{$members->{query_members}}},
    $oracles->{D048}[1], 'D048 complete unchanged declaration projects five named families');
is_deeply($members->{declaration}, $fixtures->{D048}{governed_domain}, 'whole authoritative metadata is retained');
$members->{declaration}{query_members}{ctes}{open_items}{query}{kind} = 'changed';
is($fixtures->{D048}{governed_domain}{query_members}{ctes}{open_items}{query}{kind}, 'declared_callback', 'projected declaration is independent');
my $invalid = Selecto::Domain->validate_schema($fixtures->{D049}{invalid_domain});
is_deeply([sort map { $_->{code} } @{$invalid->{errors}}], $oracles->{D049}[1], 'D049 accumulates both original invalid family/spec diagnostics');

$db->do('CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name TEXT,nickname TEXT,active INTEGER,score NUMERIC,joined_on TEXT,created_at TEXT)');
$db->do(q{INSERT INTO selecto_cert_people(id,name,active) VALUES(1,'Ada',1),(2,'Grace',0)});
$db->do('CREATE TABLE selecto_cert_orders(id INTEGER PRIMARY KEY,person_id INTEGER,state TEXT,total NUMERIC)');
$db->do('INSERT INTO selecto_cert_orders VALUES(?,?,?,?)', undef, @$_)
    for ([101,1,'open',12.5],[102,1,'closed',7.5],[103,2,'open',20],[104,undef,'orphan',5],[105,3,'open',20.25]);
my $strict = engine(domain => Selecto::Domain->parse($fixtures->{D050}{strict_domain}), mode => 'strict');
my $named = $strict->query->with_values($fixtures->{D050}{member})->select($fixtures->{D050}{select});
ok($strict->validate_query($named), 'D050 named member is policy-admitted');
is_deeply($strict->all($named->order_by('id'))->{rows}, [[1,'Active'],[2,'Inactive']], 'strict declared VALUES executes real numeric Boolean joins');
my $direct = $fixtures->{D050}{direct_values};
refusal('D050 direct VALUES forbidden under strict policy', 'ad_hoc_source_forbidden', sub {
    $strict->query->with_values($direct->{rows}, columns => $direct->{columns}, as => $direct->{as});
});
my $orders = engine(domain => Selecto::Domain->parse($fixtures->{D051}{domain}));
my $order_query = $orders->query->with_values($fixtures->{D051}{member})->select($fixtures->{D051}{select});
$order_query = $order_query->order_by(@$_) for @{$fixtures->{D051}{order_by}};
is_deeply($orders->all($order_query)->{rows}, $oracles->{D051}[3], 'D051 complete original domain and intent yield unchanged five native rows');
for my $edit (
    sub { $_[0]{joins}{person}{source} = 'other_people' },
    sub { $_[0]{joins}{person}{fields}{id}{type} = 'string' },
    sub { $_[0]{joins}{person}{on}[0]{left} = 'id' },
) {
    my $raw = dclone($fixtures->{D051}{domain}); $edit->($raw);
    refusal('redundant portable join cannot override authoritative association', 'invalid_domain', sub { Selecto::Domain->parse($raw) });
}

sub relation {
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}
my $raw = {name => 'Composition', tenant_required => JSON::PP::true,
    source => {%{relation('accounts', id => 'integer', name => 'string', active => 'boolean', tenant_id => 'string', team_id => 'integer')},
        tenant_field => 'tenant_id', associations => {team => {queryable => 'team', owner_key => 'team_id', related_key => 'id'}}},
    schemas => {team => relation('teams', id => 'integer', name => 'string')}, joins => {team => {type => 'left'}},
    required_filters => [['active', JSON::PP::true]], query_members => {
        ctes => {scoped => {query => {kind => 'declared_callback'}}},
        subqueries => {scoped => {query => {kind => 'declared_callback'}, type => 'inner', on => [{left => 'id', right => 'id'}]}},
        laterals => {series => {source => ['function','bounded_row_source',[1,2]], as => 'series', join_type => 'inner'}}}};
my $domain = Selecto::Domain->parse($raw);
my $calls = 0;
sub configured {
    my ($mode, $kind, $identity) = @_;
    my $e = engine(domain => $domain, mode => $mode, member_builders => {
        'ctes:scoped' => sub { ++$calls; $_[0]->query->select(qw(id name)) },
        'subqueries:scoped' => sub { ++$calls; $_[0]->query->select(qw(id name)) }});
    $e = $e->with_tenant($kind eq 'prefix' ? {prefix => $identity} : {tenant_id => $identity});
    return $kind eq 'prefix' ? $e : $e->apply_tenant_scope;
}
for my $schema (qw(main tenant_a tenant_b)) {
    $db->do(qq{CREATE TABLE $schema.accounts(id INTEGER PRIMARY KEY,name TEXT,active INTEGER,tenant_id TEXT,team_id INTEGER)});
    $db->do(qq{CREATE TABLE $schema.teams(id INTEGER PRIMARY KEY,name TEXT)});
}
$db->do(q{INSERT INTO main.accounts VALUES(1,'Ada',1,'tenant-a',1),(2,'Grace',1,'tenant-a',1),(3,'Other',1,'tenant-b',1),(4,'Inactive',0,'tenant-a',1)});
$db->do(q{INSERT INTO tenant_a.accounts VALUES(10,'Attached Ada',1,'tenant-a',1),(11,'Attached Grace',1,'tenant-a',1),(12,'Attached Other',1,'tenant-b',1),(13,'Attached Inactive',0,'tenant-a',1)});
$db->do(q{INSERT INTO tenant_b.accounts VALUES(20,'Wrong prefix',1,'tenant-b',1)});
$db->do(qq{INSERT INTO $_.teams VALUES(1,'$_ team')}) for qw(main tenant_a tenant_b);
for my $mode (qw(permissive strict)) {
    for my $kind (qw(row prefix)) {
        my $e = configured($mode, $kind, $kind eq 'row' ? 'tenant-a' : 'tenant_a');
        my $base = $e->query->select(qw(id name));
        my @expected = $kind eq 'row' ? ([1,'Ada'],[2,'Grace']) : ([10,'Attached Ada'],[11,'Attached Grace'],[12,'Attached Other']);
        for my $q ($base, $base->with_cte('scoped'), $base->with_subquery('scoped'),
                $base->with_cte('scoped')->with_subquery('scoped')) {
            is_deeply($e->all($q->order_by('id'))->{rows}, \@expected, "$mode $kind CTE/subquery composition preserves actual required rows");
        }
        my $join = $base->join('team')->replace_selections('id', 'team.name')->order_by('id');
        is_deeply($e->all($join)->{rows}, [map { [$_->[0], ($kind eq 'row' ? 'main' : 'tenant_a') . ' team'] } @expected], "$mode $kind declared association uses same physical schema");
        for my $op (qw(union intersect except)) {
            my $rhs = $e->query->select(qw(id name))->where(Selecto::Expression->eq('name', $expected[0][1]));
            my $q = $base->with_cte('scoped')->with_subquery('scoped')->$op($rhs)->order_by('id');
            my @rows = $op eq 'union' ? @expected : $op eq 'intersect' ? ($expected[0]) : @expected[1 .. $#expected];
            is_deeply($e->all($q)->{rows}, \@rows, "$mode $kind $op executes with every protected branch");
        }
        my $opposite = configured($mode eq 'strict' ? 'permissive' : 'strict', $kind, $kind eq 'row' ? 'tenant-a' : 'tenant_a');
        refusal('mixed policy set fails closed', 'mixed_query_policies', sub { $base->union($opposite->query->select(qw(id name))) });
        my $other = configured($mode, $kind, $kind eq 'row' ? 'tenant-b' : 'tenant_b');
        refusal('mixed scope set fails closed', 'mixed_tenant_scopes', sub { $base->union($other->query->select(qw(id name))) });
        my $forged = $base->_copy(set_operations => [{operation => 'union', query => $other->query->select(qw(id name))}]);
        refusal('raw set state cannot bypass scope compatibility', 'mixed_tenant_scopes', sub { $e->all($forged) });
        my $compound = $base->union($base);
        refusal('named source after set is refused', 'invalid_query', sub { $compound->with_subquery('scoped') });
    }
}
my $strict_scope = configured('strict', 'row', 'tenant-a');
my $before = $calls;
refusal('strict ad-hoc callback is refused before invocation', 'ad_hoc_source_forbidden', sub {
    $strict_scope->query->with_cte('manual', sub { ++$calls; $strict_scope->query->select('id') });
});
is($calls, $before, 'forbidden ad-hoc builder is never called');
my $permissive = configured('permissive', 'row', 'tenant-a');
my $optional_raw = dclone($raw); $optional_raw->{tenant_required} = JSON::PP::false;
my $unscoped = engine(domain => Selecto::Domain->parse($optional_raw), mode => 'permissive');
my $flat = $unscoped->query->select('id')->order_by('id');
my $tightened = $unscoped->with_scope(tenant => 'tenant-a');
is_deeply($tightened->all($flat)->{rows}, [[1],[2]], 'approved scope tightening consumes existing flat intent with actual target obligations');
is_deeply($tightened->with_limits(Selecto::Limits->new)->all($flat)->{rows}, [[1],[2]], 'approved budget transition preserves ancestor flat intent');
refusal('scoped flat intent cannot be downgraded to ancestor', 'mixed_tenant_scopes', sub {
    $unscoped->all($tightened->query->select('id'));
});
refusal('independent scope cannot consume a different configured flat query', 'mixed_tenant_scopes', sub {
    configured('permissive', 'row', 'tenant-b')->all($tightened->query->select('id'));
});
my $sibling = $unscoped->with_scope(tenant => 'tenant-b');
is_deeply($sibling->all($tightened->query->select('id')->order_by('id'))->{rows}, [[3]],
    'a sibling trusted tenant of the same configured engine runs flat intent under its own tenant only');
is($sibling->compile($tightened->query->select('id'))->sql, $tightened->compile($tightened->query->select('id'))->sql,
    'sibling tenants compile shared flat intent to the same SQL text');
refusal('sibling trusted tenant cannot transfer a configured source graph', 'mixed_tenant_scopes', sub {
    $sibling->all($tightened->query->with_cte('scoped')->select('id'));
});
refusal('sibling with an extra read context cannot consume flat intent', 'mixed_tenant_scopes', sub {
    $tightened->all($sibling->with_tenant({tenant_id => 'tenant-b'})->apply_tenant_scope->query->select('id'));
});
refusal('scope transition cannot transfer a configured source graph', 'mixed_tenant_scopes', sub {
    $tightened->all($unscoped->query->with_cte('scoped')->select('id'));
});
my $attached_flat = $unscoped->with_tenant({tenant_id => 'tenant-a'});
refusal('initial row attachment still requires actual scope application', 'tenant_scope_missing', sub {
    $attached_flat->all($flat);
});
my $applied_flat = $attached_flat->apply_tenant_scope;
is_deeply($applied_flat->all($flat)->{rows}, [[1],[2]],
    'initial read-context attachment consumes flat ancestor intent with actual target row obligations');
refusal('attached flat intent cannot flow back to its unscoped ancestor', 'mixed_tenant_scopes', sub {
    $unscoped->all($applied_flat->query->select('id'));
});
refusal('initial read-context attachment cannot transfer a source graph', 'mixed_tenant_scopes', sub {
    $applied_flat->all($unscoped->query->with_cte('scoped')->select('id'));
});
refusal('independent attached context cannot consume the ancestor flat query', 'mixed_tenant_scopes', sub {
    engine(domain => $unscoped->domain, mode => 'permissive')
        ->with_tenant({tenant_id => 'tenant-a'})->apply_tenant_scope->all($flat);
});
refusal('existing read-context rewrite establishes no new input lineage', 'mixed_tenant_scopes', sub {
    $applied_flat->with_tenant({tenant_id => 'tenant-a', required => 1})
        ->all($applied_flat->query->select('id'));
});
my $child = $permissive->query->select(qw(id name));
my $callback_count = $calls;
$permissive->compile($permissive->query->with_cte('scoped')->select('id'));
is($calls, $callback_count + 1, 'recursive physical-source proof reuses each actual named callback expansion');
is_deeply($permissive->all($permissive->query->select('id')->with_cte('manual_callback',
    sub { ++$calls; $_[0]->query->select('id') }, join => {owner_key => 'id', related_key => 'id'})->order_by('id'))->{rows},
    [[1],[2]], 'permissive explicit host CTE callback retains configured child authority');
for my $alias (qw(accounts Accounts teams)) {
    refusal('VALUES CTE cannot shadow a configured physical relation', 'invalid_query', sub {
        $permissive->all($permissive->query->with_values([[900,'Forged',1,'tenant-a',1]],
            columns => [qw(id name active tenant_id team_id)], as => $alias)->select('id'));
    });
}
refusal('source aliases cannot case-fold onto the compiler root', 'invalid_query', sub {
    $permissive->all($permissive->query->with_values([[1]], columns => ['id'], as => 'S0')->select('id'));
});
my $order_source = Selecto::Domain->new(name => 'Order source', table => 'selecto_cert_orders', fields => {id => 'integer'});
my $deep_source = Selecto::Domain->new(name => 'Deep source', table => 'hidden_records', fields => {id => 'integer'});
my $deep = Selecto::Query->new->select('id')->subquery_join('deep', $deep_source, Selecto::Query->new->select('id'), on => [{left => 'id', right => 'id'}]);
my $middle = Selecto::Query->new->select('id')->with_cte('nested', $order_source, $deep);
my $shadow = $orders->query->select('id')
    ->with_cte('HIDDEN_RECORDS', $order_source, Selecto::Query->new->select('id'))
    ->with_cte('middle', $order_source, $middle);
refusal('outer CTE cannot shadow a deeply nested physical source', 'invalid_query', sub { $orders->all($shadow) });
my $dependent = Selecto::Domain->new(name => 'Dependent source', table => 'recent', fields => {id => 'integer'});
my $dependency_query = $orders->query->with_cte('recent', $order_source,
    Selecto::Query->new->select('id')->where(Selecto::Expression->eq('id', 101)))
    ->with_cte('recent_copy', $dependent, Selecto::Query->new->select('id'), depends_on => ['recent'],
        join => {owner_key => 'id', related_key => 'id'})
    ->select('id', 'recent_copy.id')->order_by('id');
is_deeply($orders->all($dependency_query)->{rows}, [[101,101],[102,undef],[103,undef],[104,undef],[105,undef]],
    'explicit prior-CTE dependencies remain executable and distinct from physical sources');
is_deeply($permissive->all($permissive->query->select('id')->subquery_join('manual', $domain, $child,
    on => [{left => 'id', right => 'id'}])->order_by('id'))->{rows}, [[1],[2]], 'permissive public derived subquery retains actual child tenant authority');
refusal('scoped source refuses an unconfigured child', 'mixed_tenant_scopes', sub {
    $permissive->query->with_cte('manual', $domain, Selecto::Query->new->select('id'));
});
my $wrong_builder = engine(domain => $domain, mode => 'strict', member_builders => {
    'ctes:scoped' => sub { configured('strict', 'row', 'tenant-b')->query->select(qw(id name)) }
})->with_tenant({tenant_id => 'tenant-a'})->apply_tenant_scope;
refusal('named callback cannot supply a different tenant authority', 'mixed_tenant_scopes', sub {
    $wrong_builder->all($wrong_builder->query->with_cte('scoped')->select('id'));
});
my $no_builder = engine(domain => $domain, mode => 'strict')->with_tenant({tenant_id => 'tenant-a'})->apply_tenant_scope;
refusal('inert portable marker never becomes an executable callback', 'unsupported_query_member', sub {
    $no_builder->all($no_builder->query->with_cte('scoped')->select('id'));
});
my $mutated_mode = configured('strict', 'row', 'tenant-a'); $mutated_mode->{query_mode} = 'permissive';
refusal('public policy mutation cannot replace configured authority', 'domain_modified_after_configuration', sub { $mutated_mode->query });
refusal('strict raw source plan refuses before SQL', 'ad_hoc_join_forbidden', sub {
    my $q = $strict_scope->query->_copy(subqueries => [{name => 'forged'}])->select('id'); $strict_scope->all($q);
});
refusal('native SQLite table function capability remains truthful', 'unsupported_feature', sub {
    $strict_scope->all($strict_scope->query->with_lateral('series')->select('id'));
});
my $recursive_calls = 0;
my $recursive_builder = engine(domain => $domain, mode => 'strict', member_builders => {
    'ctes:scoped' => sub { ++$recursive_calls; $_[0]->query->with_cte('scoped')->select('id') }
})->with_tenant({tenant_id => 'tenant-a'})->apply_tenant_scope;
refusal('recursive callback source expansion is bounded before SQL', 'invalid_query', sub {
    $recursive_builder->all($recursive_builder->query->with_cte('scoped')->select('id'));
});
ok($recursive_calls > 0 && $recursive_calls < 100, 'finite expansion work refuses a compact recursive host declaration');

my $report = Selecto::Verification::GovernedQueryComposition->verify;
is_deeply($report, $oracles->{D061}[1], 'D061 unchanged finite two-event public model passes all original checks');
{
    no warnings 'redefine';
    local *Selecto::QueryBinding::compose = sub { 1 };
    my $fault = Selecto::Verification::GovernedQueryComposition->verify;
    ok(grep($_->{invariant} eq 'strict_mode_rejects_ad_hoc_composition', @{$fault->{counterexamples}}), 'broken actual composition validator produces finite counterexamples');
    is($fault->{state_count}, 220, 'fault control still derives all states');
    is($fault->{check_count}, 1320, 'fault control still runs every check');
}
is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP memory');
ok(!grep(length($_->[2]), @{$db->selectall_arrayref('PRAGMA database_list')}), 'main and every attached database are memory');
$db->disconnect;
done_testing;
