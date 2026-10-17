use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use B ();
use Selecto;
use Selecto::SQLite;
use Selecto::Write::Operation ();
BEGIN { eval {require DBI; require DBD::SQLite;1} or plan skip_all => 'DBD::SQLite is optional' }

sub domain {
    return {name => 'Native UPSERT rule flow', source => {source_table => 'ranges', primary_key => 'id',
        fields => [qw(id start finish name)], columns => {id => {type => 'integer'}, start => {type => 'integer'},
            finish => {type => 'integer'}, name => {type => 'string'}}, associations => {}}, schemas => {},
        writes => {operations => {upsert => {enabled => JSON::PP::true, conflict_targets => [['id']]}}, fields => {
            id => {insertable => JSON::PP::true, immutable => JSON::PP::true},
            start => {insertable => JSON::PP::true, immutable => JSON::PP::true},
            finish => {insertable => JSON::PP::true, updatable => JSON::PP::true},
            name => {insertable => JSON::PP::true, updatable => JSON::PP::true}}},
        rules => {schema => 'selecto.data_rules.v1', definitions => {
            ordered => {version => 1, test => {op => 'value.compare_path', comparison => 'gt', path => ['start']}}},
            normalizers => {}, bindings => {ordered => {subject => {scope => 'candidate', path => ['finish']},
                operations => ['upsert'], rule => {id => 'ordered', version => 1}}}}};
}
sub memory {
    my ($work, $numeric) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    my $type = $numeric ? 'NUMERIC' : 'INTEGER';
    $db->do("CREATE TABLE ranges(id INTEGER PRIMARY KEY,start $type,finish $type,name TEXT)");
    $db->do(q{INSERT INTO ranges VALUES(1,5,7,'before'),(2,10,11,'sentinel')});
    $db->do('CREATE TABLE caller(id INTEGER PRIMARY KEY,value TEXT)');
    $db->do(q{INSERT INTO caller VALUES(1,'committed')});
    $db->begin_work;
    $db->do(q{INSERT INTO caller VALUES(2,'outer')});
    $db->do('SAVEPOINT caller_owned');
    $work->($db);
    ok(!$db->sqlite_get_autocommit, 'caller transaction remains open');
    is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), [[1,'committed'],[2,'outer']], 'complete caller rows survive');
    $db->do('ROLLBACK TO caller_owned');
    is_deeply($db->selectall_arrayref('SELECT * FROM ranges ORDER BY id'), [[1,5,7,'before'],[2,10,11,'sentinel']], 'caller savepoint can restore all business rows');
    $db->do('RELEASE caller_owned');
    $db->rollback;
    ok($db->sqlite_get_autocommit, 'caller rollback restores idle native transaction state');
    is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), [[1,'committed']], 'caller rollback restores committed rows');
    is(scalar($db->selectrow_array('PRAGMA temp_store')), 2, 'TEMP stays in memory');
    ok(!grep({length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}), 'all databases are in memory');
    $db->disconnect;
}
sub attempt {
    my ($work) = @_;
    my $result;
    return ($result, undef) if eval {$result = $work->();1};
    my $error = $@;
    die "untyped native error: $error" unless ref($error) eq 'Selecto::Error';
    return (undef, $error->code);
}
for my $case (
    ['existing valid', {id => 1, start => 100, finish => 6, name => 'after'}, undef, [[1,5,6,'after'],[2,10,11,'sentinel']]],
    ['existing invalid', {id => 1, start => 0, finish => 4, name => 'after'}, 'data_rule_failed', [[1,5,7,'before'],[2,10,11,'sentinel']]],
    ['new valid', {id => 3, start => 20, finish => 21, name => 'new'}, undef, [[1,5,7,'before'],[2,10,11,'sentinel'],[3,20,21,'new']]],
    ['new invalid', {id => 3, start => 20, finish => 19, name => 'new'}, 'data_rule_failed', [[1,5,7,'before'],[2,10,11,'sentinel']]]) {
    subtest $case->[0] => sub { memory(sub {
        my ($db) = @_;
        my $raw = domain();
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
        my @hooks;
        $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my ($result, $error) = attempt(sub {
            my $command = Selecto::Write::Operation->new($raw)->upsert($case->[1])->conflict_target(['id'])->compile->{command};
            return $engine->execute_write($command);
        });
        $db->sqlite_update_hook(undef);
        is($error, $case->[2], 'real public operation has branch-correct rule outcome');
        is_deeply($db->selectall_arrayref('SELECT * FROM ranges ORDER BY id'), $case->[3], 'actual persisted rows respect conflict whitelist');
        is(scalar(grep {$_->[1] eq 'main'} @hooks), $error ? 0 : 1, 'refusal performs zero main DML; success changes one row');
    })};
}
subtest 'DO NOTHING retains caller cardinality and stored candidate' => sub { memory(sub {
    my ($db) = @_;
    my $raw = domain();
    $raw->{writes}{operations}{upsert}{expected_cardinality} = ['at_most', 1];
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
    my $command = Selecto::Write::Command->new(operation => 'upsert', relation => 'ranges',
        assignments => {id => 1, start => 100, finish => 0, name => 'ignored'},
        metadata => {conflict_target => ['id'], upsert_update_fields => []});
    my (undef, $error) = attempt(sub {$engine->execute_write($command)});
    is($error, 'cardinality_mismatch', 'default exact-one cardinality refuses no-op honestly');
    $command = $command->_with(expected_count => undef,
        metadata => {%{$command->metadata}, expected_cardinality => ['at_most', 1]});
    my ($result, $allowed_error) = attempt(sub {$engine->execute_write($command)});
    is($allowed_error, undef, 'explicit at-most-one permits actual no-op');
    is($result ? $result->affected_rows : undef, 0, 'actual DO NOTHING affects zero rows');
    is_deeply($db->selectall_arrayref('SELECT * FROM ranges ORDER BY id'), [[1,5,7,'before'],[2,10,11,'sentinel']], 'ignored submitted values cannot replace stored candidate');
})};
subtest 'INPUT and candidate normalize exactly once' => sub { memory(sub {
    my ($db) = @_;
    my $raw = domain();
    $raw->{rules}{definitions}{name} = {version => 1, test => {op => 'text.nonblank'}};
    $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
    for my $stage (qw(input candidate)) {
        $raw->{rules}{bindings}{$stage} = {subject => {scope => $stage, path => ['name']}, operations => ['upsert'],
            normalizer => {id => 'trim', version => 1}, rule => {id => 'name', version => 1}};
    }
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
    my %calls;
    my $evaluate = \&Selecto::DataRules::evaluate;
    no warnings 'redefine';
    local *Selecto::DataRules::evaluate = sub {my ($self, %request) = @_;++$calls{$request{stage}};return $evaluate->($self, %request)};
    my ($result, $error) = attempt(sub {
        my $command = Selecto::Write::Operation->new($raw)->upsert({id => 1, start => 100, finish => 6, name => ' after '})->conflict_target(['id'])->compile->{command};
        return $engine->execute_write($command);
    });
    is($error, undef, 'once-only INPUT plus native candidate path succeeds');
    is($calls{input}, 1, 'INPUT evaluate is not replayed at dispatch');
    is($calls{candidate}, 1, 'candidate normalizer is not replayed at final projection');
    is(scalar($db->selectrow_array('SELECT name FROM ranges WHERE id=1')), 'after', 'normalized name actually persists');
})};
for my $case (['transaction', 6, undef], ['transaction', 4, 'data_rule_failed'],
    ['evidence', 6, 'required_data_rule_pending']) {
    subtest "final $case->[0] obligation finish $case->[1]" => sub { memory(sub {
        my ($db) = @_;
        my $raw = domain();
        $raw->{rules}{bindings}{ordered}{subject}{scope} = $case->[0];
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
        my @hooks;
        $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my ($result, $error) = attempt(sub {
            my $command = Selecto::Write::Operation->new($raw)->upsert({id => 1, start => 100, finish => $case->[1], name => 'after'})->conflict_target(['id'])->compile->{command};
            return $engine->execute_write($command);
        });
        $db->sqlite_update_hook(undef);
        is($error, $case->[2], 'final obligation uses actual stored comparison operand');
        is(scalar(grep {$_->[1] eq 'main'} @hooks), $error ? 0 : 1, 'unavailable/failed obligation performs zero main DML');
        is_deeply($db->selectall_arrayref('SELECT * FROM ranges ORDER BY id'),
            $error ? [[1,5,7,'before'],[2,10,11,'sentinel']] : [[1,5,6,'after'],[2,10,11,'sentinel']],
            'full rows agree with final obligation outcome');
    })};
}
subtest 'native explicit mask does not widen for normalization' => sub { memory(sub {
    my ($db) = @_;
    $db->do(q{UPDATE ranges SET name=' before ' WHERE id=1});
    my $raw = domain();
    $raw->{rules}{definitions}{name} = {version => 1, test => {op => 'text.nonblank'}};
    $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
    $raw->{rules}{bindings}{trim} = {subject => {scope => 'candidate', path => ['name']}, operations => ['upsert'],
        normalizer => {id => 'trim', version => 1}, rule => {id => 'name', version => 1}};
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
    my $command = Selecto::Write::Command->new(operation => 'upsert', relation => 'ranges',
        assignments => {id => 1, start => 0, finish => 6, name => 'insert-only'},
        metadata => {conflict_target => ['id'], upsert_update_fields => ['finish']});
    my (undef, $error) = attempt(sub {$engine->execute_write($command)});
    is($error, 'required_data_rule_pending', 'normalizer cannot change explicitly excluded stored field');
    is(scalar($db->selectrow_array('SELECT name FROM ranges WHERE id=1')), ' before ', 'excluded stored field stays exact');
    $db->do(q{UPDATE ranges SET name='before' WHERE id=1});
})};
for my $case (
    ['existing', 1, '5.5', 'passed'], ['existing', 1, '4.5', 'failed'],
    ['new', 3, '20.5', 'passed'], ['new', 3, '19.5', 'failed']) {
    subtest "native NUMERIC $case->[0] $case->[3]" => sub { memory(sub {
        my ($db) = @_;
        $db->do('UPDATE ranges SET start=5.25 WHERE id=1');
        my $raw = domain();
        $raw->{source}{columns}{$_}{type} = 'decimal' for qw(start finish);
        $raw->{rules}{definitions}{ordered}{test} = {op => 'all', rules => [
            {op => 'type.is', type => 'decimal'},
            {op => 'value.compare_path', comparison => 'gt', path => ['start']}]};
        # Independent text normalization must not invalidate the protected
        # decimal subset while the complete candidate retains its native NVs.
        $raw->{rules}{definitions}{name} = {version => 1, test => {op => 'text.nonblank'}};
        $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
        $raw->{rules}{bindings}{a_trim} = {subject => {scope => 'candidate', path => ['name']}, operations => ['upsert'],
            normalizer => {id => 'trim', version => 1}, rule => {id => 'name', version => 1}};
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
        my $command = Selecto::Write::Operation->new($raw)->upsert({id => $case->[1], start => '20.25', finish => $case->[2], name => ' after '})->conflict_target(['id'])->compile->{command};
        my $command_identity = Selecto::Write::PortableCommand::_receipt_digest($command);
        my $before = $db->selectall_arrayref('SELECT * FROM ranges ORDER BY id');
        my @hooks;
        $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my (undef, $preview_error) = attempt(sub {$engine->preview_write($command)});
        is($preview_error, $case->[3] eq 'passed' ? undef : 'data_rule_failed', 'preview verifies native projected decimal comparison');
        is_deeply($db->selectall_arrayref('SELECT * FROM ranges ORDER BY id'), $before, 'preview changes no business rows');
        is(scalar(grep {$_->[1] eq 'main'} @hooks), 0, 'preview performs zero main DML');
        @hooks = ();
        my ($result, $error) = attempt(sub {$engine->execute_write($command)});
        $db->sqlite_update_hook(undef);
        is($error, $case->[3] eq 'passed' ? undef : 'data_rule_failed', 'execute has the same branch-correct decimal outcome');
        is(scalar(grep {$_->[1] eq 'main'} @hooks), $result ? 1 : 0, 'failed decimal proof performs zero main DML; success writes once');
        if ($result) {
            my ($value) = $db->selectrow_array('SELECT finish FROM ranges WHERE id=?', undef, $case->[1]);
            ok(B::svref_2object(\$value)->FLAGS & B::SVf_NOK(), 'actual stored fraction remains native numeric');
            is(pack('F', $value), pack('F', 0 + $case->[2]), 'stored native NV bytes match intended value');
            my ($related) = $db->selectrow_array('SELECT start FROM ranges WHERE id=?', undef, $case->[1]);
            ok(B::svref_2object(\$related)->FLAGS & B::SVf_NOK(), 'actual related operand remains native numeric');
            is(pack('F', $related), pack('F', $case->[1] == 1 ? 5.25 : 20.25), 'branch-correct related NV is preserved');
            is(scalar($db->selectrow_array('SELECT name FROM ranges WHERE id=?', undef, $case->[1])), 'after', 'independent candidate text normalization persists');
        } else { is_deeply($db->selectall_arrayref('SELECT * FROM ranges ORDER BY id'), $before, 'failed decimal comparison preserves every row') }
        is(Selecto::Write::PortableCommand::_receipt_digest($command), $command_identity,
            'preview and execution preserve exact submitted command scalar identity');
        my $raw_result = $engine->domain->rules->evaluate(stage => 'candidate', operation => 'upsert',
            subject => {finish => unpack('F', pack('F', 5.5)), start => unpack('F', pack('F', 5.25)), name => 'after'});
        is($raw_result->{code}, 'invalid_related_value_type', 'native decimal permission does not leak into a subsequent public rule request');
    }, 1)};
}
subtest 'complete header is canonical true only' => sub { memory(sub {
    my ($db) = @_;
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(domain()), adapter => Selecto::SQLite->new(dbh => $db));
    for my $flag (1, JSON::PP::true) {
        my ($state, $error) = attempt(sub {Selecto::WriteRules::_upsert_state($engine,
            {values => {finish => 7}, prior_values => {}, branch => 'insert', effect => 'insert', complete => $flag,
                protection => 'serializable', receipt => \(my $token = 0)}, ['finish'])});
        is($error, undef, 'canonical true native state header is accepted');
        is($state ? $state->{effect} : undef, 'insert', 'accepted header retains actual branch effect');
    }
    for my $flag ('false', 'true', '1', 0, 1.0, JSON::PP::false) {
        my (undef, $error) = attempt(sub {Selecto::WriteRules::_upsert_state($engine,
            {values => {finish => 7}, prior_values => {}, branch => 'insert', effect => 'insert', complete => $flag,
                protection => 'serializable', receipt => \(my $token = 0)}, ['finish'])});
        is($error, 'required_data_rule_pending', 'truthy text/float/false cannot claim complete native state');
    }
})};
done_testing;
