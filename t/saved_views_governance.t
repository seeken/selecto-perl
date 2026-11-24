use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestPostgreSQL ();
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::Write::Operation ();

sub error (&) { my ($work) = @_; return undef if eval { $work->(); 1 }; my $e = $@; die $e unless blessed($e) && $e->isa('Selecto::Error'); return $e }
sub refuses {
    my ($code, $work, $label) = @_;
    my $e = error { $work->() };
    is($e ? $e->code : 'ok', $code, $label);
    return $e;
}
sub declaration {
    my (%options) = @_;
    my %types = (id => 'integer', owner_id => 'integer', parent_id => 'integer', name => 'string',
        url => 'string', created_by => 'integer', modified_by => 'integer', version => 'integer', memo => 'string');
    return {name => 'SavedPanels', source => {source_table => 'sv_panels', primary_key => 'id',
        fields => [sort keys %types], columns => {map { $_ => {type => $types{$_}} } keys %types}, associations => {}},
        schemas => {parent => {source_table => 'sv_parents', primary_key => 'id', tenant_field => 'company_id',
            fields => [qw(id company_id)], columns => {id => {type => 'integer'}, company_id => {type => 'integer'}}, associations => {}}},
        writes => {operations => {map { $_ => {enabled => JSON::PP::true, returning => 'all'} } qw(insert update delete)},
            fields => {map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} }
                grep { !/\A(?:owner_id|created_by|modified_by)\z/ } keys %types},
            row_revision => $options{revision} // {columns => [qw(name url memo version modified_by)]},
            host_bound_fields => {
                owner_id => {mode => 'owner', source => ['context', 'user_id']},
                created_by => {mode => 'created_by', source => ['context', 'actor_id']},
                modified_by => {mode => 'modified_by', source => ['context', 'actor_id']}},
            unique_keys => {sv_owner_name => [qw(owner_id name)]},
            constraints => {foreign_keys => {parent_id => {source => ['context', 'writable_parent'], required => JSON::PP::true,
                references => {relation => 'sv_parents', field => 'id', tenant_field => 'company_id'}}}}}};
}
use TestSavedViews ();
my @backends = TestSavedViews->backends;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "saved views governance on $name" => sub {
        my $dbh = $connect->();
        $dbh->do('CREATE TABLE sv_parents (id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL)');
        $dbh->do('INSERT INTO sv_parents VALUES (1, 7), (2, 8)');
        $dbh->do('CREATE TABLE sv_panels (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, parent_id INTEGER,
            name VARCHAR(100) NOT NULL, url VARCHAR(200), created_by INTEGER, modified_by INTEGER,
            version INTEGER NOT NULL, memo VARCHAR(100), CONSTRAINT sv_owner_name UNIQUE(owner_id, name))');
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $engine = sub {
            my (%options) = @_;
            Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(declaration(%options)),
                scope => {tenant => 7}, write_context => {user_id => $options{user} // 11,
                    actor_id => $options{actor} // 101, writable_parent => $options{parent} // 1});
        };
        my $e = $engine->();
        my $command = sub {
            my ($op, $id, $values, @revision) = @_;
            Selecto::Write::Command->new(operation => $op, relation => 'sv_panels', assignments => $values // {},
                ($op ne 'insert' ? (predicate => Selecto::Expression->eq('id', $id)) : ()),
                metadata => {@revision ? (row_revision => $revision[0]) : ()});
        };
        my $read = sub { my ($eng, $id) = @_; $eng->all($eng->query->select(qw(id name url))->where(Selecto::Expression->eq('id', $id))) };
        my $insert = $command->('insert', 1, {id => 1, name => 'First', url => '/panels?fields=name', version => 1, memo => 'kept'});
        is($e->execute_write($insert)->affected_rows, 1, 'governed insert');
        is_deeply($dbh->selectrow_arrayref('SELECT owner_id,created_by,modified_by,parent_id FROM sv_panels WHERE id=1'),
            [11, 101, 101, 1], 'host and context-bound parent fields set on insert');
        my $initial = $read->($e, 1);
        like($initial->{row_revisions}[0], qr/\Asha256:[0-9a-f]{64}\z/, 'computed revision returned alongside native rows');
        is_deeply($initial->{columns}, [qw(id name url)], 'revision inputs are not exposed');
        is_deeply($initial->{rows}, [[1, 'First', '/panels?fields=name']], 'requested projection preserved');
        my $token = $initial->{row_revisions}[0];
        is($read->($e, 1)->{row_revisions}[0], $token, 'token is stable');
        my $handler = Selecto::API::EngineHandler->new(bounded_results => 0);
        my $resource = $handler->resource($e, {id => 1, fields => ['name']});
        is($resource->{row_revision}, $token, 'resource returns the same row revision');
        my $api = $handler->query($e, {select => ['name'], row_format => 'objects', limit => 1});
        is($api->{rows}[0]{row_revision}, $token, 'API run_query objects carry row_revision');
        is(scalar(@{$api->{row_revisions}}), 1, 'API row revision vector follows pagination');
        if ($name eq 'sqlite' || $name eq 'postgresql') {
            my $bounded = Selecto::API::EngineHandler->new;
            is($bounded->resource($e, {id => 1, fields => ['name']})->{row_revision}, $token,
                'bounded resource returns revision from the same row read');
        }
        my $aliased = $e->all($e->query->select(Selecto::Expression->field('name')->as('__selecto_row_revision_1')));
        is_deeply($aliased->{columns}, ['__selecto_row_revision_1'], 'internal inputs avoid caller alias collisions');
        ok(!exists($e->all($e->query->select(Selecto::Expression->count))->{row_revisions}), 'aggregate results have no row revision');
        ok(!exists($e->all($e->query->select(Selecto::Expression->sum_zero('version')))->{row_revisions}), 'null-safe sums retain aggregate grain');
        ok(!exists($e->all($e->query->select(Selecto::Expression->ratio_of_sums('version', 'version')))->{row_revisions}), 'ratio aggregates retain aggregate grain');
        my $updated = $engine->(actor => 102);
        is($updated->execute_write($command->('update', 1, {name => 'Changed'}, $token))->affected_rows, 1, 'fresh revision updates');
        is_deeply($dbh->selectrow_arrayref('SELECT owner_id,created_by,modified_by,memo FROM sv_panels WHERE id=1'),
            [11, 101, 102, 'kept'], 'owner and creator pinned; modifier refreshed; unmapped field preserved');
        for my $op (qw(update delete)) {
            my $err = refuses('stale_revision', sub { $e->execute_write($command->($op, 1, $op eq 'update' ? {name => 'Lost'} : {}, $token)) }, "stale $op refused");
            is($err->details->{reason}, 'changed', 'stale reason is changed');
            $err = refuses('stale_revision', sub { $e->execute_write($command->($op, 999, $op eq 'update' ? {name => 'Lost'} : {}, $token)) }, "missing $op refused");
            is($err->details->{reason}, 'missing', 'missing reason is missing');
        }
        is($e->execute_write($command->('update', 1, {url => '/changed'}))->affected_rows, 1, 'optional token preserves existing writes');
        my $required = $engine->(revision => {columns => ['name'], required => JSON::PP::true});
        refuses('row_revision_required', sub { $required->execute_write($command->('update', 1, {name => 'No token'})) }, 'required token update refused');
        refuses('row_revision_required', sub { $required->execute_write($command->('delete', 1, {})) }, 'required token delete refused');
        for my $field (qw(owner_id created_by modified_by)) {
            for my $op (qw(insert update)) {
                refuses('host_bound_field', sub { $e->execute_write($command->($op, 1,
                    {id => 2, name => 'Spoof', version => 1, $field => 11})) }, "$field cannot be supplied on $op");
            }
        }
        refuses('host_bound_field', sub { $handler->write($e, {operation => 'update', assignments => {owner_id => 11}, filters => [{field => 'id', op => 'eq', value => 1}]}) }, 'API assignment gets named host-bound refusal');
        refuses('cardinality_mismatch', sub { $engine->(user => 12)->execute_write($command->('update', 1, {name => 'Other owner'})) }, 'owner scope pins update');
        refuses('cardinality_mismatch', sub { $engine->(user => 12)->execute_write($command->('delete', 1, {})) }, 'owner scope pins delete');
        refuses('foreign_key_source_mismatch', sub { $e->execute_write($command->('update', 1, {parent_id => 2})) }, 'child cannot choose a parent outside trusted destination');
        refuses('cardinality_mismatch', sub { $engine->(parent => 2)->execute_write($command->('update', 1, {parent_id => 2})) }, 'existing foreign-key tenant guard refuses another company parent');
        my $err = refuses('database_unique_violation', sub { $e->execute_write($command->('insert', 2,
            {id => 2, name => 'Changed', version => 1})) }, 'duplicate key has common error');
        is_deeply($err->details->{fields}, [qw(owner_id name)], 'unique conflict identifies key fields');
        is($err->details->{key}, 'sv_owner_name', 'unique conflict identifies declared key');
        unlike(JSON::PP->new->encode($err->to_hash), qr/Changed|DBD::|INSERT|password/, 'conflict diagnostics contain no values or driver messages');
        my $portable = Selecto::Write::Operation->new(declaration())->update({memo => 'portable'})
            ->filter(['id', 1])->row_revision($read->($e, 1)->{row_revisions}[0])->compile(context => $e->write_context);
        is($e->execute_write($portable->{command})->affected_rows, 1, 'portable command retains revision and trusted fills through governance');
        refuses('host_bound_field', sub { $e->execute_write($portable->{command}->with_assignments({%{$portable->{command}->assignments}, modified_by => 999})) }, 'editing compiler-generated fields cannot forge trusted origin');
        my $column = $engine->(revision => {column => 'version'});
        is($read->($column, 1)->{row_revisions}[0], '1', 'single-column token is its exact stored value');
        is($column->execute_write($command->('update', 1, {version => 2}, '1'))->affected_rows, 1, 'single-column comparison updates atomically');
        for my $op (qw(update delete)) {
            refuses('stale_revision', sub { $column->execute_write($command->($op, 1, {name => 'Old version'}, '1')) }, "column revision refuses stale $op");
            my $missing = refuses('stale_revision', sub { $column->execute_write($command->($op, 999, {name => 'Missing'}, '1')) }, "column revision refuses missing $op");
            is($missing->details->{reason}, 'missing', 'single-column missing reason');
        }
        is($column->execute_write($command->('delete', 1, {}, '2'))->affected_rows, 1, 'fresh column revision deletes');
        $dbh->do('DROP TABLE sv_panels');
        $dbh->do('DROP TABLE sv_parents');
        $dbh->disconnect;
    };
}

done_testing;
