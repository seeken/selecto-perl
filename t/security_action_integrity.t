use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::API::EngineHandler;
use Selecto::Limits;

sub error_code {
    my ($run) = @_;
    return '' if eval { $run->(); 1 };
    return blessed($@) && $@->isa('Selecto::Error') ? $@->code : "$@";
}
sub contract {
    return {
        schema_version => 1, name => 'Security actions',
        source => {source_table => 'security_actions', primary_key => 'id',
            fields => [qw(id alternate tenant_id name touched payload)],
            columns => {id => {type => 'integer'}, alternate => {type => 'string'},
                tenant_id => {type => 'integer'}, name => {type => 'string'},
                touched => {type => 'utc_datetime'}, payload => {type => 'json'}}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1},
            upsert => {enabled => 1, conflict_targets => [['id'], ['alternate'], [qw(tenant_id alternate)]]}},
            fields => {map {$_ => {insertable => 1, updatable => 1}} qw(id alternate tenant_id name touched payload)}},
        actions => {
            bulk => {type => 'bulk_action', scope => 'bulk', capability => 'edit',
                execution => {kind => 'updato', operation => 'update', set => {name => 'edited'}}},
            mark => {type => 'action', scope => 'row', inputs => {time => {type => 'utc_datetime',
                    default => ['system', 'now']}},
                execution => {kind => 'updato', operation => 'update', set => {touched => ['input', 'time']}}},
            json => {type => 'action', scope => 'row', inputs => {value => {type => 'json', required => 1}},
                execution => {kind => 'updato', operation => 'update', set => {payload => ['input', 'value']}}},
            sync => {type => 'create', inputs => {choice => {type => 'string', required => 1}},
                execution => {kind => 'updato', operation => 'upsert', conflict_target => ['id'],
                    set => {id => 1, alternate => 'a', name => 'changed'}},
                variants => [{id => 'alternate', when => {choice => 'alternate'},
                    execution => {kind => 'updato', operation => 'upsert', conflict_target => ['alternate'],
                        set => {id => 1, alternate => 'a', name => 'changed'}}}]},
        }, capabilities => {edit => {operations => ['action', 'update'], action => 'bulk'}},
    };
}
sub engine {
    my ($raw, $backend, %args) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse($raw // contract(), strict => 1),
        adapter => Selecto->adapter(($backend // 'sqlite') => (dbh => TestSelecto::DBH->new)), %args);
}
sub upsert {
    my ($target) = @_;
    return Selecto::Write::Command->new(operation => 'upsert', relation => 'security_actions',
        assignments => {id => 1, alternate => 'a', name => 'changed'},
        metadata => {(defined($target) ? (conflict_target => $target) : ()), upsert_update_fields => ['name']});
}

subtest 'R10 every governed upsert uses the declared exact identity' => sub {
    my $engine = engine();
    for my $target (undef, [], ['name'], ['id', 'id'], ['alternate', 'tenant_id'], ['id', 'alternate']) {
        for my $method (qw(preview_write execute_write)) {
            is(error_code(sub {$engine->$method(upsert($target))}), 'conflict_target_not_declared',
                "$method refuses missing or undeclared identity");
        }
    }
    for my $target (['id'], ['alternate'], [qw(tenant_id alternate)]) {
        is(error_code(sub {$engine->preview_write(upsert($target))}), '', 'declared target accepted');
    }
    my $raw = contract(); delete $raw->{writes}{operations}{upsert}{conflict_targets};
    is(error_code(sub {engine($raw)->preview_write(upsert(['id']))}), 'conflict_target_not_declared',
        'absent allowlist fails closed');
    is(error_code(sub {Selecto::API::EngineHandler->new->write_command($engine, {
        operation => 'upsert', assignments => {id => 1, alternate => 'a', name => 'changed'},
        conflict_target => ['name'], upsert_update_fields => ['name']})}),
        'conflict_target_not_declared', 'public API shares the validator');
    is(error_code(sub {$engine->execute_batch(Selecto::Write::Batch->new(upsert(['name'])))}),
        'conflict_target_not_declared', 'batch shares the validator');
};

subtest 'R09 MySQL and MariaDB refuse unsupported identity semantics before DB work' => sub {
    for my $backend (qw(mysql mariadb)) {
        my $engine = engine(undef, $backend);
        ok(!$engine->adapter->write_capabilities->{upsert}, "$backend does not advertise upsert");
        for my $method (qw(preview_write execute_write)) {
            is(error_code(sub {$engine->$method(upsert(['id']))}), 'unsupported_upsert_conflict_target',
                "$backend $method refuses target-specific upsert");
        }
        is_deeply($engine->adapter->dbh->prepared, [], "$backend prepares no mutation");
    }
};

subtest 'R12 selected conflict identity survives planning and grant binding' => sub {
    my $engine = engine();
    my $plan = $engine->plan_action({action => 'sync', inputs => {choice => 'alternate'}});
    is_deeply($engine->action_command($plan)->metadata->{conflict_target}, ['alternate'], 'variant identity preserved');
    my $copy = Selecto::Action::Plan->new(%{$plan->to_hash});
    is_deeply($engine->action_command($copy)->metadata->{conflict_target}, ['alternate'], 'serialized plan retains identity');
    my $grant = $engine->grant_action($plan, phase => 'preview');
    $plan->{conflict_target} = ['id'];
    is(error_code(sub {$engine->preview_action($plan, grant => $grant)}), 'action_grant_mismatch',
        'identity mutation invalidates prior grant');
    my $raw = contract();
    delete $raw->{actions}{sync}{variants};
    $raw->{actions}{sync}{execution}{cases} = [{id => 'alternate_case', when => {choice => 'alternate'}, conflict_target => ['alternate']}];
    my $case_engine = engine($raw);
    my $case = $case_engine->plan_action({action => 'sync', inputs => {choice => 'alternate'}});
    is_deeply($case_engine->action_command($case)->metadata->{conflict_target}, ['alternate'], 'case identity preserved');
    $raw = contract();
    $raw->{actions}{sync}{variants}[0]{execution}{conflict_target} = ['id'];
    $raw->{actions}{sync}{variants}[0]{execution}{cases} = [{id => 'chosen_case', when => {choice => 'alternate'}, conflict_target => ['alternate']}];
    my $combined = engine($raw);
    my $selected = $combined->plan_action({action => 'sync', inputs => {choice => 'alternate'}});
    is_deeply($combined->action_command($selected)->metadata->{conflict_target}, ['alternate'],
        'case override inside selected variant is authoritative');
    $raw = contract();
    delete $raw->{actions}{sync}{variants};
    delete $raw->{actions}{sync}{execution}{conflict_target};
    $raw->{writes}{operations}{upsert}{conflict_targets} = [['alternate']];
    my $fallback = engine($raw);
    is_deeply($fallback->plan_action({action => 'sync', inputs => {choice => 'base'}})->to_hash->{conflict_target},
        ['alternate'], 'sole-target fallback is resolved and serialized while planning');
};

subtest 'R14 caller references never become authored instructions' => sub {
    my $engine = engine();
    for my $input (['system', 'now'], {kind => 'current_timestamp'}) {
        is(error_code(sub {$engine->plan_action({action => 'mark', target => 1, inputs => {time => $input}})}),
            'invalid_action_input', 'scalar input refuses referenced request data');
    }
    my $default = $engine->plan_action({action => 'mark', target => 1});
    like($engine->preview_action($default)->{statement}{sql}, qr/CURRENT_TIMESTAMP/, 'trusted default still executes');
    my $literal = $engine->plan_action({action => 'mark', target => 1, inputs => {time => '2026-10-02T12:00:00Z'}});
    unlike($engine->preview_action($literal)->{statement}{sql}, qr/CURRENT_TIMESTAMP/, 'caller timestamp stays literal');
    my $json = $engine->plan_action({action => 'json', target => 1, inputs => {value => ['system', 'now']}});
    unlike($engine->preview_action($json)->{statement}{sql}, qr/CURRENT_TIMESTAMP/, 'JSON array stays literal');
    my $forged = Selecto::Action::Plan->new(%{$literal->to_hash}, changes => {touched => ['system', 'now']});
    isnt(error_code(sub {$engine->preview_action($forged)}), '', 'decoded array cannot recreate internal timestamp instruction');
    my $grant = $engine->grant_action($default, phase => 'preview');
    $default->system_values({});
    is(error_code(sub {$engine->preview_action($default, grant => $grant)}), 'action_grant_mismatch',
        'instruction provenance is covered by the grant digest');
    my $nested = $engine->plan_action({action => 'json', target => 1,
        inputs => {value => {nested => [['system', 'now']]}}});
    my $preview = $engine->preview_action($nested)->{statement};
    unlike($preview->{sql}, qr/CURRENT_TIMESTAMP/, 'nested caller arrays stay literal');
    is($preview->{params}[0], '{"nested":[["system","now"]]}', 'structured literals bind as JSON');
};

subtest 'R04 bulk ceilings apply before normalization and authorization' => sub {
    my $engine = engine();
    for my $ids ([1 .. 1001], [(1) x 1001]) {
        is(error_code(sub {$engine->plan_action({action => 'bulk', target => {ids => $ids}})}),
            'action_cardinality_mismatch', 'raw occurrences exceed mandatory default even when duplicate');
    }
    my $plan = $engine->plan_action({action => 'bulk', target => {ids => [1]}});
    $plan->{target} = {ids => [1 .. 1001]};
    $plan->{filters} = [['id', 'in', [1 .. 1001]]];
    $plan->{expected_cardinality} = ['exactly', 1001];
    my $calls = 0;
    for my $method (qw(grant_action preview_action execute_action)) {
        is(error_code(sub {$engine->$method($plan, resolver => sub {$calls++; 'enabled'})}),
            'action_cardinality_mismatch', "$method revalidates forged plan before resolver");
    }
    is($calls, 0, 'over-limit plan never reaches host resolver');
    my $mutated = $engine->plan_action({action => 'bulk', target => {ids => [1]}});
    $mutated->target({ids => ['x' x 4097]});
    is(error_code(sub {$engine->grant_action($mutated, resolver => sub {$calls++; 'enabled'})}),
        'invalid_action_target', 'mutated ID byte excess is refused before authorization copying');
    $mutated->target({ids => [1]});
    $mutated->filters([map {['id', 1]} 1 .. 10001]);
    is(error_code(sub {$engine->grant_action($mutated, resolver => sub {$calls++; 'enabled'})}),
        'action_cardinality_mismatch', 'forged filter count is bounded before authorization copying');
    is($calls, 0, 'malformed hand-built plan still never invokes resolver');
    for my $action_max (undef, 2, 10) {
        my $raw = contract();
        $raw->{actions}{bulk}{selection} = {max_rows => $action_max} if defined $action_max;
        my $limits = Selecto::Limits->new(max_action_targets => 3);
        my $limited = engine($raw, 'sqlite', limits => $limits);
        my $maximum = defined($action_max) && $action_max < 3 ? $action_max : 3;
        my $intent = {action => 'bulk', target => {ids => [1 .. $maximum]}};
        is(error_code(sub {$limited->plan_action($intent)}), '', 'effective N targets accepted');
        $intent->{target}{ids} = [1 .. $maximum + 1];
        is(error_code(sub {$limited->plan_action($intent)}), 'action_cardinality_mismatch',
            'smaller of host/action ceiling rejects N+1');
        is(error_code(sub {Selecto::Action->plan($limited->domain, $intent, limits => $limits)}),
            'action_cardinality_mismatch', 'standalone planner uses the same trusted limit');
    }
    is(error_code(sub {$engine->plan_action({action => 'bulk', target => {ids => [1, '01']}})}),
        'invalid_action_target', 'duplicates are checked after bounded ID normalization');
    my $limited = engine(undef, 'sqlite', limits => Selecto::Limits->new(max_action_targets => 3));
    my $safe = $limited->governed_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'security_actions', assignments => {name => 'x'},
        predicate => Selecto::Expression->eq('id', 1),
        metadata => {__selecto_primary_key => 'name', __selecto_write_limit => 10000}));
    is($safe->metadata->{__selecto_primary_key}, 'id', 'caller cannot replace bounded-write identity');
    is($safe->metadata->{__selecto_write_limit}, 3, 'caller cannot replace trusted bounded-write ceiling');
    my $registry = Selecto->domain_registry(name => 'Security::Actions')->register(records => contract());
    my $registered = Selecto::Engine->from_registry(registry => $registry, domain => 'records',
        adapter => $limited->adapter, limits => $limited->limits);
    is(error_code(sub {$registered->plan_action({action => 'bulk', target => {ids => [1 .. 4]}})}),
        'action_cardinality_mismatch', 'registered engine preserves the trusted lower ceiling');
};

subtest 'R12 live selected variant updates the intended identity' => sub {
    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBI; require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE security_actions(id INTEGER PRIMARY KEY, alternate TEXT UNIQUE, name TEXT, tenant_id INTEGER, touched TEXT, payload TEXT)');
    $dbh->do(q{INSERT INTO security_actions(id,alternate,name) VALUES(1,'a','first'),(2,'b','second')});
    my $raw = contract();
    # Both submitted identities name existing, different rows. The chosen
    # alternate identity must control the update, and id is insert-only.
    $raw->{writes}{fields}{id}{updatable} = 0;
    $raw->{actions}{sync}{variants}[0]{execution}{set} = {id => 1, alternate => 'b', name => 'selected'};
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw),
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my $plan = $engine->plan_action({action => 'sync', inputs => {choice => 'alternate'}});
    is($engine->execute_action($plan)->{result}->affected_rows, 1, 'selected upsert executes');
    is_deeply($dbh->selectall_arrayref('SELECT id,alternate,name FROM security_actions ORDER BY id'),
        [[1,'a','first'], [2,'b','selected']], 'only alternate-target row changes');
    my $mark = $engine->plan_action({action => 'mark', target => 2});
    $engine->execute_action($mark);
    like($dbh->selectrow_array('SELECT touched FROM security_actions WHERE id=2'), qr/^\d{4}-\d{2}-\d{2}/,
        'authored timestamp still executes through the governed action path');
    my $json = $engine->plan_action({action => 'json', target => 2, inputs => {value => ['system', 'now']}});
    $engine->execute_action($json);
    is($dbh->selectrow_array('SELECT payload FROM security_actions WHERE id=2'), '["system","now"]',
        'same-shaped JSON request is stored literally');
};

done_testing;
