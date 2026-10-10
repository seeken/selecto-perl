use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::Operation ();
use Selecto::Write::Multi ();
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }

{
    package InputOnlyAdapter;
    use parent 'Selecto::SQLite';
    sub write_capabilities { ++$_[0]{providers}; shift->SUPER::write_capabilities(@_) }
    sub execute_query { ++$_[0]{hydrations}; shift->SUPER::execute_query(@_) }
    sub rule_project_subject { ++$_[0]{projections}; shift->SUPER::rule_project_subject(@_) }
    sub rule_upsert_candidate { ++$_[0]{upsert_projections}; shift->SUPER::rule_upsert_candidate(@_) }
    sub _execute_compiled_write_in_transaction {
        my ($self, $command, @rest) = @_;
        my $metadata = $command->metadata;
        push @{$self->{dispatched}}, {operation => $command->operation, relation => $command->relation,
            assignment_fields => [sort keys %{$command->assignments}],
            metadata => {upsert_update_fields => $metadata->{upsert_update_fields}}};
        return $self->SUPER::_execute_compiled_write_in_transaction($command, @rest);
    }
}
sub copy { Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value} }
sub document {
    my ($table) = @_; $table //= 'items';
    return {name => 'Native INPUT-only rules', source => {source_table => $table, primary_key => 'id',
        fields => [qw(id tenant_id name secret allowed parent_id)],
        columns => {map { $_ => {type => $_ eq 'name' || $_ eq 'secret' ? 'string' : 'integer'} }
            qw(id tenant_id name secret allowed parent_id)}, associations => {}}, schemas => {},
        writes => {operations => {map { $_ => {enabled => JSON::PP::true,
            ($_ eq 'upsert' ? (conflict_targets => [['id'], ['id', 'tenant_id']]) : ())} } qw(insert update delete upsert)},
            fields => {map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} }
                qw(id tenant_id name secret allowed)}},
        rules => {schema => 'selecto.data_rules.v1', definitions => {
            nonblank => {version => 1, test => {op => 'text.length', unit => 'unicode_scalar', min => 1}}},
            normalizers => {trim => {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]}},
            bindings => {z_trim => {subject => {scope => 'input', path => ['name']}, operations => [qw(insert update upsert)],
                rule => {id => 'nonblank', version => 1}, normalizer => {id => 'trim', version => 1}}}}};
}
sub strict_order {
    my ($raw) = @_;
    $raw->{source}{columns}{name}{text_case} = 'uppercase';
    $raw->{writes}{fields}{name}{validators} = [['inclusion', [qw(MIXED FIRST SECOND ROOT CHILD KEPT ACT)]]];
    $raw->{rules}{definitions}{raw} = {version => 1, test => {op => 'text.pattern', profile => 'ascii_v1',
        pattern => '[a-z ]+', match => 'full', flags => []}};
    $raw->{rules}{bindings}{a_raw} = {subject => {scope => 'input', path => ['name']}, operations => [qw(insert update upsert)],
        rule => {id => 'raw', version => 1}};
    return $raw;
}
sub stored_binding {
    my ($raw, $stage, %extra) = @_;
    $raw->{rules}{definitions}{stored} = {version => 1, test => {op => 'text.nonblank'}};
    $raw->{rules}{bindings}{stored} = {subject => {scope => $stage, path => ['name']},
        operations => ['upsert'], rule => {id => 'stored', version => 1}, %extra};
    return $raw;
}
sub upsert {
    my ($id, $name, %opts) = @_;
    return Selecto::Write::Command->new(operation => 'upsert', relation => $opts{table} // 'items',
        assignments => {id => $id, name => $name, %{$opts{values} // {}}},
        metadata => {conflict_target => $opts{target} // ['id'], upsert_update_fields => ['name']});
}
sub command {
    my ($op, $table, $values, $id) = @_;
    return Selecto::Write::Command->new(operation => $op, relation => $table, assignments => $values,
        (defined($id) ? (predicate => Selecto::Expression->eq('id', $id)) : ()));
}
sub memory {
    my ($work, %options) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    for my $table (qw(items children)) {
        my $id = $options{tenant_primary} && $table eq 'items' ? 'id INTEGER NOT NULL' : 'id INTEGER PRIMARY KEY';
        my $identity = $options{tenant_primary} && $table eq 'items' ? 'PRIMARY KEY(id,tenant_id)' : 'UNIQUE(id,tenant_id)';
        $db->do("CREATE TABLE $table($id,tenant_id INTEGER NOT NULL DEFAULT 7,name TEXT NOT NULL,secret TEXT NOT NULL DEFAULT 'generated',allowed INTEGER NOT NULL DEFAULT 1,parent_id INTEGER,$identity)");
    }
    $db->do(q{INSERT INTO items VALUES(1,7,'before','private',1,NULL),(2,8,'sentinel','caller',1,NULL),(4,7,'blocked','retained',0,NULL)});
    my $adapter = InputOnlyAdapter->new(dbh => $db);
    my $engine = sub { Selecto::Engine->new(domain => Selecto::Domain->parse($_[0]), adapter => $adapter,
        ($_[1] ? (write_context => $_[1]) : ())) };
    my (@sql, @prepare, @hooks, @db_errors);
    $db->{HandleError} = sub { push @db_errors, $_[0]; return 0 };
    $db->sqlite_trace(sub { push @sql, $_[0] });
    $db->sqlite_set_authorizer(sub { push @prepare, [@_]; 0 });
    $db->sqlite_update_hook(sub { push @hooks, [@_] });
    my $snapshot = sub { +{map { $_ => $db->selectall_arrayref("SELECT * FROM $_ ORDER BY id,tenant_id") } qw(items children)} };
    my $observe = sub {
        my ($run) = @_;
        @sql = (); @prepare = (); @hooks = (); @db_errors = ();
        @$adapter{qw(providers hydrations projections upsert_projections)} = (0, 0, 0, 0); $adapter->{dispatched} = [];
        my ($result, $error); my $ok = eval { $result = $run->(); 1 }; $error = $@ unless $ok;
        die "untyped native failure: $error" if !$ok && ref($error) ne 'Selecto::Error';
        return {code => $ok ? 'ok' : $error->code, result => $result, error => $error,
            sql => [@sql], prepare => [@prepare], hooks => [@hooks], db_errors => [@db_errors],
            providers => $adapter->{providers}, hydrations => $adapter->{hydrations}, projections => $adapter->{projections},
            upsert_projections => $adapter->{upsert_projections},
            dispatched => copy($adapter->{dispatched})};
    };
    my $zero = sub {
        my ($label, $code, $run) = @_;
        my $before = $snapshot->(); my $seen = $observe->($run);
        is($seen->{code}, $code, $label);
        is(scalar @{$seen->{sql}}, 0, "$label: no SQL execution");
        is(scalar @{$seen->{prepare}}, 0, "$label: no native prepare");
        is(scalar @{$seen->{hooks}}, 0, "$label: no physical mutation hook");
        is($seen->{providers}, 0, "$label: no capability provider");
        is($seen->{hydrations}, 0, "$label: no stored hydration");
        is($seen->{projections}, 0, "$label: no candidate projection");
        is_deeply($snapshot->(), $before, "$label: complete business rows unchanged");
        return $seen;
    };
    $work->($db, $adapter, $engine, $snapshot, $observe, $zero);
    ok($db->{AutoCommit}, 'native operation restores caller autocommit');
    is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP stays in memory');
    is_deeply([grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'all attached SQLite databases stay in memory');
    $db->sqlite_trace(undef); $db->sqlite_set_authorizer(undef); $db->sqlite_update_hook(undef); $db->disconnect;
}

subtest 'native existing and new upserts preserve submitted-only intent' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $raw = strict_order(document()); my $e = $engine->($raw);
    for my $id (1, 3) {
        my $before = $snapshot->(); my $input = upsert($id, '  mixed  ');
        my $preview = $observe->(sub { $e->preview_write($input) });
        is($preview->{code}, 'ok', "INPUT-only upsert $id previews without stored-branch proof");
        like($preview->{result}{sql} // '', qr/ON CONFLICT/i, 'preview is the real native upsert statement');
        ok(grep({ defined($_) && !ref($_) && $_ eq 'MIXED' } @{$preview->{result}{params} // []}), 'preview binds the normalized validated submitted value');
        is_deeply($snapshot->(), $before, 'preview leaves every business row intact');
        is($preview->{hydrations}, 0, 'INPUT-only preview does not hydrate a stored candidate');
        is($preview->{projections}, 0, 'INPUT-only preview does not project a native candidate');
        my $seen = $observe->(sub { $e->execute_write($input) });
        is($seen->{code}, 'ok', "INPUT-only upsert $id executes the actual branch");
        is($seen->{result} ? $seen->{result}->affected_rows : 0, 1, 'one physical row is affected');
        is_deeply($db->selectrow_arrayref('SELECT name,secret,allowed FROM items WHERE id=?', undef, $id),
            ['MIXED', $id == 1 ? 'private' : 'generated', 1], 'normalized value stores; unassigned secret/default remain exact');
        is_deeply($seen->{dispatched}[0]{metadata}{upsert_update_fields}, ['name'], 'actual dispatched upsert keeps its exact authored update whitelist');
        is_deeply($seen->{dispatched}[0]{assignment_fields}, ['id', 'name'], 'stored/default fields are not added to submitted assignments');
        is($seen->{hydrations}, 0, 'INPUT-only execution does not hydrate a stored candidate');
        is($seen->{projections}, 0, 'INPUT-only execution does not project a candidate');
        is($input->assignments->{name}, '  mixed  ', 'caller command remains unchanged');
    }
    is_deeply($db->selectrow_arrayref('SELECT * FROM items WHERE id=2'), [2,8,'sentinel','caller',1,undef], 'other tenant sentinel remains unchanged');
    for my $id (1, 5) {
        $zero->("blank INPUT refuses upsert branch $id", 'data_rule_failed', sub { $e->execute_write(upsert($id, '   ')) });
        $zero->("legacy-invalid normalized value refuses branch $id", 'data_rule_failed', sub { $e->execute_write(upsert($id, 'wrong')) });
    }
}) };

subtest 'stored-stage dependencies remain protected and operation-filtered' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe) = @_;
    for my $stage (qw(candidate transaction evidence)) {
        for my $enforcement ('required', 'advisory') {
            my $raw = stored_binding(document(), $stage, enforcement => $enforcement);
            my $e = $engine->($raw); my $before = $snapshot->();
            my $seen = $observe->(sub { $e->execute_write(upsert(1, 'mixed')) });
            my $expected_code = $stage eq 'evidence' && $enforcement eq 'required'
                ? 'required_data_rule_pending' : 'ok';
            my $allowed = $expected_code eq 'ok';
            is($seen->{code}, $expected_code, "$enforcement $stage upsert respects actual native stage authority");
            is(scalar(grep {$_->[1] eq 'main'} @{$seen->{hooks}}), $allowed ? 1 : 0,
                'protected branch has exactly the admitted MAIN mutation count');
            is(scalar @{$seen->{dispatched}}, $allowed ? 1 : 0,
                'only admitted branch dispatches its business statement');
            my $expected = copy($before);
            $expected->{items}[0][2] = 'mixed' if $allowed;
            is_deeply($snapshot->(), $expected, 'full rows change only the admitted conflict name');
            is($db->selectrow_array('SELECT name FROM items WHERE id=1'),
                $allowed ? 'mixed' : $before->{items}[0][2], 'actual stored name agrees with stage outcome');
            cmp_ok($seen->{upsert_projections}, '>=', 2,
                'active stored binding uses native initial and final candidate proof');
        }
        my $filtered = stored_binding(document(), $stage, operations => ['delete']);
        my $seen = $observe->(sub { $engine->($filtered)->execute_write(upsert(1, 'filtered')) });
        is($seen->{code}, 'ok', "$stage binding for delete does not invent an upsert dependency");
        is($db->selectrow_array('SELECT name FROM items WHERE id=1'), 'filtered', 'filtered positive actually stores');
        is($seen->{hydrations}, 0, 'filtered stored binding performs no candidate hydration');
        is($seen->{projections}, 0, 'filtered stored binding performs no candidate projection');
        is($seen->{upsert_projections}, 0, 'filtered binding performs no protected UPSERT candidate proof');
    }
}) };

subtest 'atomic native batch validates all INPUT before any prefix' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $e = $engine->(strict_order(document()));
    my $good = Selecto::Write::Batch->new(upsert(1, ' first '), upsert(3, ' second '));
    my $seen = $observe->(sub { $e->execute_batch($good) });
    is($seen->{code}, 'ok', 'actual existing/new upsert batch succeeds atomically with INPUT-only rules');
    is_deeply($db->selectall_arrayref('SELECT id,name,secret FROM items WHERE id IN (1,3) ORDER BY id'),
        [[1,'FIRST','private'],[3,'SECOND','generated']], 'batch stores actual normalized branches without rewriting secrets');
    $zero->('later invalid INPUT refuses the entire native prefix', 'data_rule_failed', sub {
        $e->execute_batch(Selecto::Write::Batch->new(upsert(1, ' mixed '), upsert(5, '   ')));
    });
    $zero->('later invalid legacy field refuses the entire native prefix', 'data_rule_failed', sub {
        $e->execute_batch(Selecto::Write::Batch->new(upsert(1, ' mixed '), upsert(5, 'wrong')));
    });
    my $protected = $engine->(stored_binding(document(), 'candidate'));
    my $before = $snapshot->(); my $blocked = $observe->(sub { $protected->execute_batch($good) });
    is($blocked->{code}, 'required_data_rule_pending', 'active stored-stage batch retains whole-plan refusal');
    is(scalar @{$blocked->{hooks}}, 0, 'protected batch has no native mutation prefix');
    is_deeply($snapshot->(), $before, 'protected batch leaves all rows intact');
}) };

subtest 'native graph prepares parent and child once before dispatch' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $child = strict_order(document('children')); my $parent = strict_order(document());
    $parent->{writes}{relationships}{children} = {writable => JSON::PP::true, allowed_ops => ['insert'],
        table => 'children', parent_key => 'id', child_key => 'parent_id', domain => $child};
    my $e = $engine->($parent);
    my $graph = sub { Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => upsert(1, ' root ')},
        {id => 'child', command => command('insert', 'children', {id => $_[0], name => $_[1]}),
            bindings => [{from => 'root', key => 'id', field => 'parent_id'}]}]) };
    my $seen = $observe->(sub { $e->execute_graph($graph->(10, ' child ')) });
    is($seen->{code}, 'ok', 'INPUT-only graph executes upsert parent and generated child binding');
    is_deeply($db->selectrow_arrayref('SELECT p.name,c.name,c.parent_id,c.secret FROM items p JOIN children c ON c.parent_id=p.id'),
        ['ROOT','CHILD',1,'generated'], 'actual graph stores normalized values, generated ownership and child default');
    is($seen->{hydrations}, 0, 'INPUT-only graph has no stored candidate hydration');
    is($seen->{projections}, 0, 'INPUT-only graph has no candidate projection');
    $zero->('later child INPUT failure refuses root prefix', 'data_rule_failed', sub { $e->execute_graph($graph->(11, '   ')) });
    $zero->('later child legacy failure refuses root prefix', 'data_rule_failed', sub { $e->execute_graph($graph->(11, 'wrong')) });
}) };

subtest 'portable nested and named Multi use real native INPUT-only paths' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $raw = document();
    my $multi = Selecto::Write::Multi->new->append('existing', Selecto::Write::Operation->new($raw)->upsert({id => 1, name => ' first '})->conflict_target(['id']))
        ->append('new', Selecto::Write::Operation->new($raw)->upsert({id => 3, name => ' second '})->conflict_target(['id']));
    my $seen = $observe->(sub { $multi->run($engine->($raw)) });
    is($seen->{code}, 'ok', 'genuine named Multi executes both INPUT-only upsert branches');
    is_deeply([sort keys %{$seen->{result} // {}}], ['existing', 'new'], 'named results are returned by actual native batch');
    is_deeply($db->selectall_arrayref('SELECT id,name,secret FROM items WHERE id IN (1,3) ORDER BY id'),
        [[1,'first','private'],[3,'second','generated']], 'Multi stores submitted normalized values and preserves unassigned secrets');
    my $child = document('children'); $raw->{writes}{relationships}{children} = {
        cardinality => 'many', ownership => 'composition', domain => $child, child_key => 'parent_id', identity_fields => ['id'],
        write => {modes => ['append_only'], create => JSON::PP::true}};
    my $op = Selecto::Write::Operation->new($raw)->insert({id => 5, name => ' root ', children => [{name => ' child '}]});
    my $compiled = $op->compile;
    my $nested = $observe->(sub { $engine->($raw)->execute_graph($compiled->{command}) });
    is($nested->{code}, 'ok', 'public nested compiler graph executes actual INPUT-only parent and child');
    is_deeply($db->selectrow_arrayref('SELECT p.name,c.name,c.parent_id FROM items p JOIN children c ON c.parent_id=p.id WHERE p.id=5'),
        ['root','child',5], 'nested native rows and generated binding are genuine');
}) };

subtest 'trusted tenant conflict identity and required predicate refusals stay enforced' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    $db->do(q{INSERT INTO items VALUES(1,8,'same id other tenant','other private',1,NULL)});
    my $raw = document();
    $raw->{writes}{scope}{tenant} = {required => JSON::PP::true, field => 'tenant_id', satisfied_by => ['trusted_context']};
    my $e = $engine->($raw, {tenant_id => 7});
    $zero->('tenant-scoped upsert refuses incomplete conflict identity', 'tenant_scope_conflict_target', sub { $e->execute_write(upsert(1, 'mixed')) });
    my $seen = $observe->(sub { $e->execute_write(upsert(1, 'mixed', target => ['id','tenant_id'])) });
    is($seen->{code}, 'ok', 'declared tenant-complete conflict target succeeds with INPUT-only rules');
    is_deeply($db->selectrow_arrayref('SELECT tenant_id,name,secret FROM items WHERE id=1 AND tenant_id=7'), [7,'mixed','private'], 'trusted tenant and original secret remain exact');
    is_deeply($db->selectrow_arrayref('SELECT tenant_id,name,secret FROM items WHERE id=1 AND tenant_id=8'), [8,'same id other tenant','other private'], 'same authored id in another tenant is not the conflict row');
    $zero->('explicit caller tenant cannot replace trusted write context', 'tenant_mismatch', sub {
        $e->execute_write(upsert(2, 'mixed', target => ['id','tenant_id'], values => {tenant_id => 8}));
    });
    my $filtered = copy($raw); $filtered->{required_filters} = [['allowed', 1]];
    my $restricted = $engine->($filtered, {tenant_id => 7});
    $zero->('INPUT-only routing cannot erase unsupported required upsert predicate', 'query_enforcement_unsupported_operation', sub {
        $restricted->execute_write(upsert(4, 'mixed', target => ['id','tenant_id']));
    });
    my $compiled = Selecto::Write::Operation->new($raw)->upsert({id => 1, name => ' mixed '})
        ->conflict_target(['id','tenant_id'])->compile(context => {tenant_id => 7})->{command};
    my $accepted = $observe->(sub { $e->execute_write($compiled) });
    is($accepted->{code}, 'ok', 'compiler INPUT receipt is usable with matching actual trusted tenant');
    diag(explain($accepted->{error}->details)) if $accepted->{error};
    $zero->('compiler acceptance cannot replace a different actual trusted tenant', 'tenant_mismatch', sub {
        $engine->($raw, {tenant_id => 8})->execute_write($compiled);
    });
}, tenant_primary => 1) };

subtest 'compiler to native handoff does not replay accepted INPUT' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $raw = strict_order(document()); my $e = $engine->($raw);
    my $compiled = Selecto::Write::Operation->new($raw)->upsert({id => 1, name => ' mixed '})->conflict_target(['id'])->compile;
    is($compiled->{command}->assignments->{name}, 'MIXED', 'public compiler really accepts raw lowercase then emits normalized uppercase');
    my $before = $snapshot->(); my $preview = $observe->(sub { $e->preview_write($compiled->{command}) });
    is($preview->{code}, 'ok', 'native preview consumes accepted compiler INPUT without testing normalized value as original INPUT');
    is_deeply($snapshot->(), $before, 'compiler/native preview preserves complete storage');
    my $seen = $observe->(sub { $e->execute_write($compiled->{command}) });
    is($seen->{code}, 'ok', 'native execute consumes accepted compiler INPUT exactly once');
    is($db->selectrow_array('SELECT name FROM items WHERE id=1'), 'MIXED', 'accepted compiled command actually reaches storage');
    my $multi = Selecto::Write::Multi->new->append('accepted',
        Selecto::Write::Operation->new($raw)->upsert({id => 3, name => ' second '})->conflict_target(['id']));
    my $named = $observe->(sub { $multi->run($e) });
    is($named->{code}, 'ok', 'one public Multi run preserves once-INPUT across compile and native batch');
    is($db->selectrow_array('SELECT name FROM items WHERE id=3'), 'SECOND', 'named compiled/native branch stores accepted normalization');
    is($observe->(sub { $e->execute_write($compiled->{command}) })->{code}, 'ok', 'same immutable compiled command is reusable in a fresh native execution');
    my $metadata = $compiled->{command}->metadata;
    $metadata->{input_prepared} = JSON::PP::true; $metadata->{_submitted_prepared} = JSON::PP::true;
    my $raw_copy = Selecto::Write::Command->new(operation => 'upsert', relation => 'items',
        assignments => $compiled->{command}->assignments, metadata => $metadata);
    $zero->('raw metadata lookalike cannot skip original INPUT', 'data_rule_failed', sub { $e->execute_write($raw_copy) });
    $zero->('public command copies cannot acquire compiler proof', 'data_rule_failed', sub {
        $e->execute_write($compiled->{command}->with_metadata($compiled->{command}->metadata));
    });
    my $changed = copy($raw); $changed->{writes}{fields}{name}{updatable} = JSON::PP::false;
    $zero->('compiler proof cannot grant writes in a changed host domain', 'write_field_not_writable', sub {
        $engine->($changed)->execute_write($compiled->{command});
    });
    my $retargeted = copy($raw); $retargeted->{source}{source_table} = 'children';
    $zero->('compiler proof cannot retarget an independently configured source', 'write_relation_mismatch', sub {
        $engine->($retargeted)->execute_write($compiled->{command});
    });
    my $idempotent = document();
    my $plain = Selecto::Write::Operation->new($idempotent)->upsert({id => 1, name => ' first '})->conflict_target(['id'])->compile->{command};
    my $rejecting = copy($idempotent); $rejecting->{writes}{fields}{name}{validators} = [['exclusion', ['first']]];
    $zero->('changed host legacy contract cannot borrow accepted INPUT', 'compiled_input_mismatch', sub {
        $engine->($rejecting)->execute_write($plain);
    });
    my $native_legacy_checks = 0;
    my $validate_values = \&Selecto::Write::FieldValidators::validate_values;
    {
        no warnings 'redefine';
        local *Selecto::Write::FieldValidators::validate_values = sub { ++$native_legacy_checks; goto &$validate_values };
        is($observe->(sub { $e->execute_write($compiled->{command}) })->{code}, 'ok', 'matching compiled command executes through fresh native field validation');
    }
    is($native_legacy_checks, 1, 'accepted INPUT does not suppress the actual native legacy validation stage');
    my $tampered = Selecto::Write::Operation->new($raw)->upsert({id => 1, name => ' mixed '})->conflict_target(['id'])->compile->{command};
    $tampered->{assignments}{name} = 'BAD';
    my $before_tamper = $snapshot->(); my $altered = $observe->(sub { $e->execute_write($tampered) });
    isnt($altered->{code}, 'ok', 'mutating the actual compiled object invalidates acceptance');
    is(scalar @{$altered->{prepare}}, 0, 'mutated compiler object refuses before native prepare');
    is($altered->{providers}, 0, 'mutated compiler object refuses before provider discovery');
    is_deeply($snapshot->(), $before_tamper, 'mutated compiler object leaves complete business state unchanged');
    my $tight = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => $a,
        limits => Selecto::Limits->new(max_rule_work => 20));
    $zero->('accepted compiler work cannot escape tighter actual native limits', 'evaluation_limit', sub {
        $tight->execute_write($compiled->{command});
    });
    my $child = strict_order(document('children')); my $nested_domain = copy($raw);
    $nested_domain->{writes}{relationships}{children} = {cardinality => 'many', ownership => 'composition',
        domain => $child, child_key => 'parent_id', identity_fields => ['id'], write => {modes => ['append_only'], create => JSON::PP::true}};
    my $graph = Selecto::Write::Operation->new($nested_domain)->insert({id => 6, name => ' root ',
        children => [{name => ' child '}]})->compile->{command};
    my $nested = $observe->(sub { $engine->($nested_domain)->execute_graph($graph) });
    is($nested->{code}, 'ok', 'genuine compiled nested graph preserves successful INPUT for every actual node');
    is_deeply($db->selectrow_arrayref('SELECT p.name,c.name,c.parent_id FROM items p JOIN children c ON c.parent_id=p.id WHERE p.id=6'),
        ['ROOT','CHILD',6], 'once-INPUT compiler graph physically stores normalized parent and child');
    my $unicode_domain = document();
    $unicode_domain->{rules}{definitions}{nonblank}{test} = {op => 'text.length', unit => 'unicode_scalar', exact => 1};
    my $unicode = chr(0xe9); utf8::upgrade($unicode);
    my $unicode_command = Selecto::Write::Operation->new($unicode_domain)->insert({id => 7, name => $unicode})->compile->{command};
    is($observe->(sub { $engine->($unicode_domain)->execute_write($unicode_command) })->{code}, 'ok',
        'one Unicode scalar accepted by compiler INPUT executes through the native host');
    is($db->selectrow_array('SELECT hex(name) FROM items WHERE id=7'), 'C3A9', 'native storage contains the accepted Unicode character');
    my $unicode_mutation = Selecto::Write::Operation->new($unicode_domain)->insert({id => 8, name => $unicode})->compile->{command};
    $unicode_mutation->{assignments}{name} = pack('C*', 0xc3, 0xa9);
    $zero->('same encoded bytes cannot disguise changed Unicode INPUT identity', 'compiled_input_mismatch', sub {
        $engine->($unicode_domain)->execute_write($unicode_mutation);
    });
    $db->do(q{INSERT INTO items VALUES(42,7,'parent','parent secret',1,NULL)});
    my $fk_domain = strict_order(document());
    $fk_domain->{writes}{fields}{parent_id} = {insertable => JSON::PP::true};
    $fk_domain->{writes}{constraints}{foreign_keys}{parent_id} = {source => ['context','parent_id'], required => JSON::PP::true,
        references => {relation => 'items', field => 'id', tenant_field => JSON::PP::false}};
    my $fk_command = Selecto::Write::Operation->new($fk_domain)->insert({id => 9, name => ' mixed '})
        ->compile(context => {parent_id => 42})->{command};
    is($observe->(sub { $engine->($fk_domain, {parent_id => 42})->execute_write($fk_command) })->{code}, 'ok',
        'accepted INPUT and a genuine context-owned numeric foreign key survive native governance');
    is_deeply($db->selectrow_arrayref('SELECT name,parent_id,secret FROM items WHERE id=9'), ['MIXED',42,'generated'],
        'native context-owned foreign key and once-INPUT normalization are physically stored');
    my $nodes = $graph->nodes;
    for my $node (@$nodes) {
        my $metadata = $node->{command}->metadata; my $returning = $graph->public_returning($node->{id});
        if (defined($returning)) { $metadata->{returning} = $returning } else { delete $metadata->{returning} }
        $node->{command} = $node->{command}->with_metadata($metadata);
    }
    my $rebuilt = Selecto::Write::Graph->new(nodes => $nodes, owned_sets => $graph->owned_sets, metadata => {input_prepared => JSON::PP::true});
    $zero->('reconstructed graph metadata cannot manufacture accepted INPUT', 'data_rule_failed', sub {
        $engine->($nested_domain)->execute_graph($rebuilt);
    });
}) };

subtest 'INPUT-only generated owned cleanup preserves every independent scope' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe) = @_;
    $db->do(q{INSERT INTO children VALUES(10,7,'kept','a',1,1),(11,7,'omitted','b',1,1),(12,7,'other parent','c',1,2),(13,8,'other tenant','d',1,1),(14,7,'outside predicate','e',0,1)});
    my $child = strict_order(document('children')); $child->{required_filters} = [['allowed', 1]];
    my $parent = strict_order(document());
    for my $raw ($parent, $child) {
        $raw->{writes}{scope}{tenant} = {required => JSON::PP::true, field => 'tenant_id', satisfied_by => ['trusted_context']};
    }
    $parent->{writes}{relationships}{children} = {writable => JSON::PP::true, ownership => 'owned', strategy => 'sync',
        parent_key => 'id', child_key => 'parent_id', identity_fields => ['id'], allowed_ops => [qw(insert update delete)],
        delete_missing => JSON::PP::true, domain => $child};
    my $graph = Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => command('update', 'items', {name => ' root '}, 1)},
        {id => 'kept', command => command('update', 'children', {name => ' kept '}, 10),
            bindings => [{from => 'root', key => 'id', field => 'parent_id'}]}],
        owned_sets => [{parent => 'root', relationship => 'children', nodes => ['kept'], delete_missing => JSON::PP::true}]);
    my $seen = $observe->(sub { $engine->($parent, {tenant_id => 7})->execute_graph($graph) });
    is($seen->{code}, 'ok', 'INPUT-only owned graph performs actual generated deletion without stored candidate obligations');
    is_deeply($db->selectall_arrayref('SELECT id,tenant_id,name,secret,allowed,parent_id FROM children ORDER BY id'),
        [[10,7,'KEPT','a',1,1],[12,7,'other parent','c',1,2],[13,8,'other tenant','d',1,1],[14,7,'outside predicate','e',0,1]],
        'cleanup removes only omitted owned row and preserves other parent, tenant, required predicate and secrets');
    is($db->selectrow_array('SELECT name FROM items WHERE id=1'), 'ROOT', 'actual parent INPUT runs once before owned cleanup');
    is_deeply($seen->{result} ? $seen->{result}->metadata->{cleanup_affected_rows} : undef, [1], 'public cleanup count comes from the real native deletion');
}) };

subtest 'planned action filters ACTION_INPUT and then validates native submitted INPUT' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe) = @_;
    my $raw = strict_order(document());
    $raw->{actions}{save} = {type => 'create', inputs => {id => {type => 'integer'}, name => {type => 'string'}},
        execution => {kind => 'updato', operation => 'upsert', conflict_target => ['id'],
            set => {id => ['input','id'], name => ['input','name']}}};
    $raw->{actions}{other} = copy($raw->{actions}{save});
    $raw->{rules}{definitions}{selected} = {version => 1, test => {op => 'text.nonblank'}};
    $raw->{rules}{definitions}{other} = {version => 1, test => {op => 'value.eq', value => 'never'}};
    $raw->{rules}{bindings}{selected_action} = {subject => {scope => 'action_input', action => 'save', path => ['name']},
        operations => ['upsert'], rule => {id => 'selected', version => 1}};
    $raw->{rules}{bindings}{other_action} = {subject => {scope => 'action_input', action => 'other', path => ['name']},
        operations => ['upsert'], rule => {id => 'other', version => 1}};
    my $e = $engine->($raw); my $plan = $e->plan_action({action => 'save', inputs => {id => 1, name => ' act '}});
    my $before = $snapshot->(); my $preview = $observe->(sub { $e->preview_action($plan) });
    is($preview->{code}, 'ok', 'selected action preview ignores another action INPUT binding and accepts native INPUT');
    is_deeply($snapshot->(), $before, 'planned action preview leaves all physical rows unchanged');
    my $seen = $observe->(sub { $e->execute_action($plan) });
    is($seen->{code}, 'ok', 'genuine planned upsert action executes INPUT-only normalization and legacy validation');
    is_deeply($db->selectrow_arrayref('SELECT name,secret FROM items WHERE id=1'), ['ACT','private'], 'planned action stores only its normalized submitted change');
    my $wrong = $observe->(sub { $e->plan_action({action => 'other', inputs => {id => 3, name => ' act '}}) });
    isnt($wrong->{code}, 'ok', 'selected failing ACTION_INPUT remains enforced during planning');
    is(scalar @{$wrong->{prepare}}, 0, 'failed action planning makes no native prepare');
    is(scalar @{$wrong->{hooks}}, 0, 'failed action planning makes no mutation hook');
}) };

subtest 'independent accepted INPUT proofs share one native batch budget' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $raw = document(); my $value = 'x' x 4000;
    my @compiled = map { Selecto::Write::Operation->new($raw)->upsert({id => $_, name => $value})
        ->conflict_target(['id'])->compile->{command} } (1, 3);
    my $e = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => $a,
        limits => Selecto::Limits->new(max_rule_work => 40_000));
    for my $command (@compiled) {
        is($observe->(sub { $e->execute_write($command) })->{code}, 'ok', 'one independently accepted INPUT proof fits the actual native ceiling');
    }
    is($db->selectrow_array('SELECT length(name) FROM items WHERE id=1'), 4000, 'standalone budget control really stores the accepted value');
    $zero->('independent compiler proofs cannot reset one native batch budget', 'evaluation_limit', sub {
        $e->execute_batch(Selecto::Write::Batch->new(@compiled));
    });
}) };

subtest 'INPUT-only existing and new branches preserve the caller transaction' => sub { memory(sub {
    my ($db, $a, $engine, $snapshot, $observe, $zero) = @_;
    my $initial = $snapshot->(); my $e = $engine->(strict_order(document()));
    $db->begin_work;
    $db->do(q{INSERT INTO items(id,name,secret) VALUES(9,'caller outer work','outer private')});
    for my $pair ([1, ' first '], [3, ' second ']) {
        is($observe->(sub { $e->execute_write(upsert(@$pair)) })->{code}, 'ok', 'INPUT-only branch executes inside the actual caller transaction');
        ok(!$db->{AutoCommit}, 'successful branch keeps caller transaction open');
    }
    $zero->('invalid INPUT preserves caller work and transaction', 'data_rule_failed', sub { $e->execute_write(upsert(5, '   ')) });
    ok(!$db->{AutoCommit}, 'invalid submitted value leaves caller transaction open');
    is_deeply($db->selectrow_arrayref('SELECT name,secret FROM items WHERE id=9'), ['caller outer work','outer private'], 'outer caller row survives native success and refusal');
    $db->rollback;
    is_deeply($snapshot->(), $initial, 'caller rollback restores both upsert branches and removes only caller-owned outer work');
}) };
done_testing;
