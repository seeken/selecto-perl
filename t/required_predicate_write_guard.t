use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed refaddr);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();

# Every required predicate guards engine writes. A predicate over root fields
# confines updates and deletes, must hold for inserted rows and refuses
# upserts; a predicate that reaches into an association has no portable write
# form, so every write on its domain fails closed. writes.scope.tenant still
# applies on top. This deliberately goes beyond the shared protocol's earlier
# rule that required predicates are read scopes.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $E = 'Selecto::Expression';
my $MARK = qr/(?:\?|\$\d+)/;
our ($CONNECT, $ADAPTER, $PROJECTS, $TEAMS, $TASKS);

sub error_of {
    my ($code) = @_;
    return undef if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error : die $error;
}
sub code_of { my $error = error_of(@_); return $error ? $error->code : 'ok'; }

sub task_contract {
    return {
        schema_version => 1, name => 'Tasks',
        source => {
            source_table => $TASKS, primary_key => 'id',
            fields => [qw(id project_id label)],
            columns => {id => {type => 'integer'}, project_id => {type => 'integer'}, label => {type => 'string'}},
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => {insert => {enabled => 1}, update => {enabled => 1}},
            fields => {label => {insertable => 1, updatable => 1}},
        },
    };
}

sub project_contract {
    my (%o) = @_;
    return {
        schema_version => 1, name => 'Projects', domain_version => '1',
        domain_fingerprint => 'sha256:required-predicate-write-guard',
        source => {
            source_table => $PROJECTS, primary_key => 'id',
            fields => [qw(id site_id team_id region title state)],
            columns => {
                id => {type => 'integer'}, site_id => {type => 'integer'}, team_id => {type => 'integer'},
                region => {type => 'string'}, title => {type => 'string'}, state => {type => 'string'},
            },
            ($o{tenant} ? (tenant_field => 'site_id') : ()),
            associations => {team => {queryable => 'team', owner_key => 'team_id', related_key => 'id'}},
        },
        schemas => {
            team => {
                source_table => $TEAMS, primary_key => 'id', fields => [qw(id region)],
                columns => {id => {type => 'integer'}, region => {type => 'string'}},
                associations => {},
            },
        },
        joins => {},
        writes => {
            operations => {
                insert => {enabled => 1},
                update => {enabled => 1, bulk => 1},
                delete => {enabled => 1, bulk => 1},
                upsert => {enabled => 1, conflict_targets => [['id'], [qw(id site_id)]]},
            },
            fields => {
                id => {insertable => 1},
                site_id => {insertable => 1},
                team_id => {insertable => 1},
                region => {insertable => 1, updatable => 1},
                title => {insertable => 1, updatable => 1},
                state => {insertable => 1, updatable => 1},
            },
            transitions => {state => {open => ['closed']}},
            ($o{tenant} ? (scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}) : ()),
            relationships => {
                tasks => {
                    writable => 1, table => $TASKS,
                    parent_key => 'id', child_key => 'project_id',
                    allowed_ops => ['insert', 'update'],
                    domain => task_contract(),
                },
            },
        },
        actions => {
            close => {
                type => 'transition', scope => 'row',
                transition => {field => 'state', from => 'open', to => 'closed'},
                execution => {kind => 'updato', operation => 'update', set => {state => 'closed'}},
            },
            open_west => {
                type => 'create', label => 'Open west project',
                execution => {kind => 'updato', operation => 'insert',
                    set => {id => 50, site_id => 10, region => 'west', title => 'action west', state => 'open'}},
            },
            open_east => {
                type => 'create', label => 'Open east project',
                execution => {kind => 'updato', operation => 'insert',
                    set => {id => 51, site_id => 10, region => 'east', title => 'action east', state => 'open'}},
            },
            sync => {
                type => 'create', label => 'Sync project',
                execution => {kind => 'updato', operation => 'upsert', conflict_target => ['id'],
                    set => {id => 1, site_id => 10, region => 'west', title => 'synced', state => 'open'}},
            },
        },
    };
}

sub fresh_dbh {
    my $dbh = $CONNECT->();
    $dbh->do("DROP TABLE IF EXISTS $_") for $TASKS, $PROJECTS, $TEAMS;
    $dbh->do("CREATE TABLE $TEAMS (id integer primary key, region text)");
    $dbh->do("CREATE TABLE $PROJECTS (id integer primary key, site_id integer, team_id integer,
        region text, title text, state text)");
    my $serial = $ADAPTER eq 'postgresql' ? 'serial' : 'integer';
    $dbh->do("CREATE TABLE $TASKS (id $serial primary key, project_id integer, label text)");
    $dbh->do(qq{INSERT INTO $TEAMS VALUES (1, 'west'), (2, 'east')});
    $dbh->do(qq{INSERT INTO $PROJECTS VALUES
        (1, 10, 1, 'west', 'w1', 'open'),
        (2, 10, 2, 'east', 'e1', 'open'),
        (3, 20, 1, 'west', 'w2', 'open'),
        (4, 20, 2, 'east', 'e2', 'open')});
    $dbh->do(qq{INSERT INTO $TASKS VALUES (101, 1, 'west task'), (102, 2, 'east task')});
    return $dbh;
}

sub engine_for {
    my ($dbh, $predicate, %o) = @_;
    my $domain = Selecto::Domain->parse(project_contract(%o));
    $domain = $domain->with_required_predicate($predicate) if defined $predicate;
    return Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($ADAPTER => (dbh => $dbh)),
        (defined($o{tenant_value}) ? (scope => {tenant => $o{tenant_value}}) : ()));
}

sub command {
    my (%args) = @_;
    return Selecto::Write::Command->new(relation => $PROJECTS, %args);
}
sub update_id { my ($id, %o) = @_; command(operation => 'update', assignments => {title => 'changed'},
    predicate => $E->eq('id', $id), %o) }
sub delete_id { my ($id) = @_; command(operation => 'delete', predicate => $E->eq('id', $id)) }
sub insert_row { my (%values) = @_; command(operation => 'insert', assignments => {%values}) }
sub upsert_row {
    command(operation => 'upsert', assignments => {id => 1, region => 'west', title => 'up'},
        metadata => {conflict_target => ['id'], upsert_update_fields => ['title']});
}
sub titles { my ($dbh) = @_; return $dbh->selectall_hashref("SELECT id, title FROM $PROJECTS", 'id') }
sub title_of { my ($dbh, $id) = @_; return scalar $dbh->selectrow_array("SELECT title FROM $PROJECTS WHERE id = ?", undef, $id) }

my $west = $E->eq('region', 'west');

sub run_suite {
    subtest 'a root-field required predicate confines updates and deletes' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west);

        is(code_of(sub { $engine->execute_write(update_id(2)) }), 'cardinality_mismatch',
            'an update of a row outside the predicate matches nothing');
        is(title_of($dbh, 2), 'e1', 'the row outside the predicate is untouched');
        is($engine->execute_write(update_id(1))->affected_rows, 1, 'a row inside the predicate is updated');
        is(title_of($dbh, 1), 'changed', 'the inside row changed');

        my $bulk = command(operation => 'update', assignments => {title => 'bulk'},
            predicate => $E->gte('id', 1), expected_count => 2);
        is($engine->execute_write($bulk)->affected_rows, 2, 'a bulk update matches only rows inside the predicate');
        is_deeply([map { title_of($dbh, $_) } 1 .. 4], ['bulk', 'e1', 'bulk', 'e2'],
            'east rows are untouched by the bulk update');
        is(code_of(sub { $engine->execute_write(command(operation => 'update', assignments => {title => 'x'},
            predicate => $E->gte('id', 1), expected_count => 4)) }), 'cardinality_mismatch',
            'expected_count counts only rows inside the predicate');
        is(title_of($dbh, 2), 'e1', 'the failed bulk update rolled back');

        is(code_of(sub { $engine->execute_write(delete_id(4)) }), 'cardinality_mismatch',
            'a delete outside the predicate matches nothing');
        is($dbh->selectrow_array("SELECT COUNT(*) FROM $PROJECTS WHERE id = 4"), 1, 'the outside row still exists');
        is($engine->execute_write(delete_id(3))->affected_rows, 1, 'a delete inside the predicate applies');

        my $preview = $engine->preview_write(update_id(2));
        like($preview->{sql}, qr/WHERE .*"id" = $MARK.*"region" = $MARK/s, 'the previewed statement carries the predicate');
        is_deeply($preview->{params}, ['changed', 2, 'west'], 'the predicate value is bound');

        my $governed = $engine->governed_write(update_id(2));
        is(scalar(() = $engine->preview_write($governed)->{sql} =~ /"region"/g), 1,
            'governing an already governed command does not repeat the predicate');
        my $restated = $engine->governed_write(command(operation => 'update', assignments => {title => 'x'},
            predicate => $E->eq('id', 1), scope_predicate => $engine->domain->required_predicate));
        is(refaddr($restated->scope_predicate), refaddr($engine->domain->required_predicate),
            'a command already scoped by the required predicate is not scoped twice');
    };

    subtest 'inserts must satisfy a root-field required predicate' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west);
        is($engine->execute_write(insert_row(id => 10, region => 'west', title => 'new'))->affected_rows, 1,
            'an insert inside the predicate applies');
        my $error = error_of(sub { $engine->execute_write(insert_row(id => 11, region => 'east', title => 'out')) });
        is($error && $error->code, 'query_rule_violation', 'an insert outside the predicate is refused');
        is(code_of(sub { $engine->execute_write(insert_row(id => 12, title => 'unknown')) }), 'query_rule_not_evaluable',
            'an insert that cannot be checked against the predicate is refused');
        is($dbh->selectrow_array("SELECT COUNT(*) FROM $PROJECTS WHERE id IN (11, 12)"), 0, 'no refused insert was written');
    };

    subtest 'upsert is refused on a domain with a required predicate' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west);
        my $error = error_of(sub { $engine->execute_write(upsert_row()) });
        is($error && $error->code, 'query_enforcement_unsupported_operation', 'upsert is refused');
        is($error && $error->message, 'upsert is not supported on a domain with a required predicate',
            'with the shared message');
        is(code_of(sub { $engine->preview_write(upsert_row()) }), 'query_enforcement_unsupported_operation',
            'preview refuses the upsert too');
        is(title_of($dbh, 1), 'w1', 'nothing was written');
    };

    subtest 'batches and graph roots are guarded' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west);
        is(code_of(sub { $engine->execute_batch(Selecto::Write::Batch->new(update_id(1), update_id(2))) }),
            'cardinality_mismatch', 'a batch member outside the predicate fails the batch');
        is(title_of($dbh, 1), 'w1', 'the whole batch rolled back');
        is(scalar @{$engine->execute_batch(Selecto::Write::Batch->new(update_id(1), update_id(3)))}, 2,
            'a batch inside the predicate applies');
        is(code_of(sub { $engine->execute_batch(Selecto::Write::Batch->new(update_id(1), upsert_row())) }),
            'query_enforcement_unsupported_operation', 'a batch with an upsert is refused');

        my $graph = sub {
            my ($root) = @_;
            return Selecto::Write::Graph->new(nodes => [
                {id => 'project', command => $root},
                {id => 'task', command => Selecto::Write::Command->new(operation => 'insert',
                    relation => $TASKS, assignments => {label => 'child'}),
                 bindings => [{field => 'project_id', from => 'project', key => 'id'}]},
            ]);
        };
        my $returning = {returning => ['id']};
        # The unmatched root returns no row for its child to bind to.
        like(code_of(sub { $engine->execute_graph($graph->(update_id(2, metadata => $returning))) }),
            qr/\A(?:cardinality_mismatch|write_returning_missing)\z/, 'a graph root outside the predicate fails');
        is($dbh->selectrow_array(qq{SELECT COUNT(*) FROM $TASKS WHERE label = 'child'}), 0,
            'its child was not written');
        my $result = $engine->execute_graph($graph->(update_id(1, metadata => $returning)));
        is($result->root->affected_rows, 1, 'a graph root inside the predicate applies');
        is($dbh->selectrow_array(qq{SELECT project_id FROM $TASKS WHERE label = 'child'}), 1,
            'its child is bound to the guarded root');
        my $error = error_of(sub { $engine->execute_graph($graph->(insert_row(id => 30, region => 'east', title => 'g'))) });
        is($error && $error->code, 'query_rule_violation', 'a graph root insert outside the predicate is refused');
        $error = error_of(sub { $engine->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'root', command => upsert_row()}])) });
        is($error && $error->code, 'query_enforcement_unsupported_operation', 'a graph root upsert is refused');
        is($error && $error->details->{graph_node}, 'root', 'the refusal names the graph node');
    };

    subtest 'an association-field required predicate refuses every write' => sub {
        my $dbh = fresh_dbh();
        my $before = titles($dbh);
        my $engine = engine_for($dbh, $E->all($E->eq('site_id', 10), $E->eq('team.region', 'west')));
        my $refused = sub {
            my ($name, $code) = @_;
            my $error = error_of($code);
            is($error && $error->code, 'query_rule_unsupported_field', "$name is refused");
            is($error && $error->message, 'association fields are not portable write guards', "$name: shared message");
            is_deeply($error && $error->details, {relation => $PROJECTS, fields => ['team.region'],
                ($error && exists $error->details->{graph_node} ? (graph_node => $error->details->{graph_node}) : ())},
                "$name: details name the field path and relation");
        };
        $refused->('an update', sub { $engine->execute_write(update_id(1)) });
        $refused->('a delete', sub { $engine->execute_write(delete_id(1)) });
        $refused->('an insert', sub { $engine->execute_write(insert_row(id => 9, region => 'west', title => 'x')) });
        $refused->('an upsert', sub { $engine->execute_write(upsert_row()) });
        $refused->('a preview', sub { $engine->preview_write(update_id(1)) });
        $refused->('write_command', sub { $engine->write_command(operation => 'update',
            assignments => {title => 'x'}, filter => ['eq', 'id', 1]) });
        $refused->('a batch', sub { $engine->execute_batch(Selecto::Write::Batch->new(update_id(1))) });
        $refused->('a graph root', sub { $engine->execute_graph(Selecto::Write::Graph->new(nodes => [
            {id => 'root', command => update_id(1)}])) });
        my $resolver = sub { 'enabled' };
        $refused->('an action preview', sub { $engine->preview_action($engine->plan_action({action => 'close', target => 1}), resolver => $resolver) });
        $refused->('an action execute', sub { $engine->execute_action($engine->plan_action({action => 'close', target => 1}), resolver => $resolver) });
        my $handler = Selecto::API::EngineHandler->new;
        $refused->('an API write', sub { $handler->write($engine, {operation => 'update', assignments => {title => 'x'},
            filters => [{field => 'id', op => 'eq', value => 1}]}) });
        $refused->('an API insert', sub { $handler->write($engine, {operation => 'insert',
            assignments => {id => 9, region => 'west', title => 'x'}}) });

        my $nested = engine_for($dbh, $E->any($E->eq('region', 'west'), $E->not($E->eq('team.region', 'east'))));
        my $error = error_of(sub { $nested->execute_write(update_id(1)) });
        is($error && $error->code, 'query_rule_unsupported_field', 'an association field beneath OR and NOT is found');
        is_deeply($error && $error->details->{fields}, ['team.region'], 'and reported');

        is_deeply(titles($dbh), $before, 'no refused write changed anything');
        my $rows = $engine->all($engine->query->select('id')->order_by('id'))->{rows};
        is_deeply([map { $_->[0] } @$rows], [1], 'reads under the association predicate are unaffected');
    };

    subtest 'writes.scope.tenant and the required predicate both hold' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west, tenant => 1, tenant_value => 10);
        is($engine->execute_write(update_id(1))->affected_rows, 1, 'a row in the tenant and the predicate is updated');
        is(code_of(sub { $engine->execute_write(update_id(2)) }), 'cardinality_mismatch',
            'a row in the tenant but outside the predicate is not matched');
        is(code_of(sub { $engine->execute_write(update_id(3)) }), 'cardinality_mismatch',
            'a row in the predicate but another tenant is not matched');
        is_deeply([map { title_of($dbh, $_) } 2 .. 4], ['e1', 'w2', 'e2'], 'rows outside either boundary are untouched');
        like($engine->preview_write(update_id(1))->{sql}, qr/"site_id" = $MARK.*"region" = $MARK/s,
            'the statement carries both conditions');

        is($engine->execute_write(insert_row(id => 20, region => 'west', title => 'scoped'))->affected_rows, 1,
            'an insert inside the predicate is assigned the tenant');
        is($dbh->selectrow_array("SELECT site_id FROM $PROJECTS WHERE id = 20"), 10, 'the trusted tenant was assigned');
        is(code_of(sub { $engine->execute_write(insert_row(id => 21, region => 'east', title => 'out')) }),
            'query_rule_violation', 'an insert outside the predicate is refused under tenant scope');
        is(code_of(sub { $engine->execute_write(insert_row(id => 22, site_id => 20, region => 'west', title => 'x')) }),
            'tenant_mismatch', 'the tenant scope still refuses another tenant');
        my $upsert = command(operation => 'upsert', assignments => {id => 1, region => 'west', title => 'up'},
            metadata => {conflict_target => ['id', 'site_id'], upsert_update_fields => ['title']});
        is(code_of(sub { $engine->execute_write($upsert) }), 'query_enforcement_unsupported_operation',
            'upsert is refused even with writes.scope.tenant');
        is(code_of(sub { engine_for($dbh, undef, tenant => 1, tenant_value => 10)->preview_write($upsert) }), 'ok',
            'a tenant-scoped domain without a required predicate still upserts');

        # The predicate joins after writes.scope.tenant, so a host predicate
        # wider than the tenant narrows to it instead of reading as a
        # caller-named foreign tenant.
        my $wide = engine_for($dbh, $E->in('site_id', [10, 20]), tenant => 1, tenant_value => 10);
        is($wide->execute_write(update_id(2))->affected_rows, 1, 'an IN-list predicate covering the tenant applies');
        is(code_of(sub { $wide->execute_write(update_id(4)) }), 'cardinality_mismatch',
            'and narrows to the trusted tenant');
        is(title_of($dbh, 4), 'e2', "the other tenant's row is untouched");
        is($wide->execute_write(insert_row(id => 23, region => 'east', title => 'wide'))->affected_rows, 1,
            'an insert assigned the trusted tenant satisfies the IN-list predicate');
    };

    subtest 'actions preview and execute the guarded statement' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west);
        my $resolver = sub { 'enabled' };
        my $outside = $engine->plan_action({action => 'close', target => 2});
        my $preview = $engine->preview_action($outside, resolver => $resolver);
        like($preview->{statement}{sql}, qr/"region" = $MARK/, 'the action preview shows the guarded statement');
        is_deeply([grep { defined && $_ eq 'west' } @{$preview->{statement}{params}}], ['west'],
            'the preview binds the predicate value');
        is(code_of(sub { $engine->execute_action($outside, resolver => $resolver) }), 'cardinality_mismatch',
            'an action on a row outside the predicate matches nothing');
        is($dbh->selectrow_array("SELECT state FROM $PROJECTS WHERE id = 2"), 'open', 'the outside row is untouched');
        my $done = $engine->execute_action($engine->plan_action({action => 'close', target => 1}), resolver => $resolver);
        is($done->{result}->affected_rows, 1, 'an action inside the predicate applies');

        is($engine->execute_action($engine->plan_action({action => 'open_west'}))->{result}->affected_rows, 1,
            'an insert action inside the predicate applies');
        is(code_of(sub { $engine->execute_action($engine->plan_action({action => 'open_east'})) }),
            'query_rule_violation', 'an insert action outside the predicate is refused');
        is(code_of(sub { $engine->preview_action($engine->plan_action({action => 'sync'})) }),
            'query_enforcement_unsupported_operation', 'an upsert action is refused at preview');
        is(code_of(sub { $engine->execute_action($engine->plan_action({action => 'sync'})) }),
            'query_enforcement_unsupported_operation', 'an upsert action is refused at execute');
    };

    subtest 'API writes use the engine guard once' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, $west);
        my $handler = Selecto::API::EngineHandler->new;
        my $update = sub { my ($id, %o) = @_; {operation => 'update', assignments => {title => 'api'},
            filters => [{field => 'id', op => 'eq', value => $id}], %o} };

        my $command = $handler->write_command($engine, $update->(1));
        ok(!defined($command->scope_predicate), 'the handler leaves the predicate to the engine');
        is(scalar(() = $engine->preview_write($command)->{sql} =~ /"region"/g), 1,
            'the governed API command carries the predicate exactly once');

        # Capture what the adapter receives from an API write.
        my $adapter_class = ref($engine->adapter);
        my $original = $adapter_class->can('execute_write');
        my @received;
        {
            no strict 'refs';
            no warnings 'redefine';
            local *{"${adapter_class}::execute_write"} = sub { push @received, $_[1]; goto &$original };
            $handler->write($engine, $update->(3));
        }
        is(scalar @received, 1, 'the adapter received one command');
        my $required = $engine->domain->required_predicate;
        is(refaddr($received[0]->scope_predicate), refaddr($required),
            'its scope is the required predicate, applied once by the engine');

        my $api = Selecto::API->new(domain => $engine->domain, base_path => '/api/v1/projects');
        my $write_handler = sub {
            my ($engine) = @_;
            return sub {
                my ($body) = @_;
                my $data = eval { $handler->write($engine, $body) };
                return ['ok', $data] unless $@;
                my $e = $@;
                die $e unless blessed($e) && $e->isa('Selecto::Error');
                return ['error', {code => $e->code, message => $e->message, details => $e->details}];
            };
        };
        my $association = engine_for($dbh, $E->eq('team.region', 'west'));
        my $response = $api->request({method => 'POST', path => '/api/v1/projects/write', body => $update->(1)},
            {write => $write_handler->($association)});
        is($response->{status}, 422, 'an association-predicate API write is a 422');
        my $payload = JSON::PP->new->decode($response->{body});
        is($payload->{error}{code}, 'query_rule_unsupported_field', 'with its error code');
        is_deeply($payload->{error}{details}, {fields => ['team.region']},
            'public field details remain without physical relation metadata');
        is(code_of(sub { $handler->write($engine, $update->(2)) }), 'cardinality_mismatch',
            'an API update outside the predicate matches nothing');
        is(title_of($dbh, 2), 'e1', 'the outside row is untouched');
        is($handler->write($engine, $update->(1))->{affected_rows}, 1, 'an API update inside the predicate applies');
        is(code_of(sub { $handler->write($engine, {operation => 'delete', filters => [{field => 'id', op => 'eq', value => 4}]}) }),
            'cardinality_mismatch', 'an API delete outside the predicate matches nothing');
        is(code_of(sub { $handler->write($engine, {operation => 'insert', assignments => {id => 40, region => 'east', title => 'x'}}) }),
            'query_rule_violation', 'an API insert outside the predicate is refused');
        is(code_of(sub { $handler->write($engine, {operation => 'insert', assignments => {id => 41, region => 'west', title => 'x'}}) }),
            'ok', 'an API insert inside the predicate applies');
        my $error = error_of(sub { $handler->write($engine, {operation => 'upsert',
            assignments => {id => 1, region => 'west', title => 'x'}, conflict_target => ['id'], upsert_update_fields => ['title']}) });
        is($error && $error->code, 'query_enforcement_unsupported_operation', 'an API upsert is refused');
        is($error && $error->message, 'upsert is not supported on a domain with a required predicate',
            'with the engine message');
        is($dbh->selectrow_array("SELECT COUNT(*) FROM $PROJECTS WHERE id = 40"), 0, 'the refused insert was not written');
    };

    subtest 'domains without a required predicate are unchanged' => sub {
        my $dbh = fresh_dbh();
        my $engine = engine_for($dbh, undef);
        is($engine->execute_write(update_id(2))->affected_rows, 1, 'updates reach any row');
        is($engine->execute_write(insert_row(id => 60, region => 'east', title => 'x'))->affected_rows, 1, 'inserts are unchecked');
        is($engine->execute_write(upsert_row())->affected_rows, 1, 'upserts apply');
        is(undef, $engine->required_write_guard('upsert'), 'there is no write guard');
    };
}

{
    local ($ADAPTER, $PROJECTS, $TEAMS, $TASKS) = ('sqlite', 'projects', 'teams', 'project_tasks');
    local $CONNECT = sub { DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1}) };
    subtest 'SQLite' => \&run_suite;
}

SKIP: {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    skip 'SELECTO_PERL_TEST_POSTGRES_URL is not configured', 1 unless defined($url) && $url ne '';
    skip 'DBD::Pg or Selecto::Certification is not installed', 1
        unless eval { require DBD::Pg; require Selecto::Certification; 1 };
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
    my $dbh = DBI->connect($dsn, $username, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
    local ($ADAPTER, $PROJECTS, $TEAMS, $TASKS) = ('postgresql',
        map { "selecto_perl_test_rp_$_" } qw(projects teams tasks));
    local $CONNECT = sub { $dbh };
    subtest 'PostgreSQL' => \&run_suite;
    $dbh->do("DROP TABLE IF EXISTS $_") for $TASKS, $PROJECTS, $TEAMS;
}

done_testing;
