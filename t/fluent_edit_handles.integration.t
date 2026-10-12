use 5.034;
use strict;
use warnings;
use Test::More;
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
use JSON::PP ();
use DBI ();
use Selecto;

my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined $url;
plan skip_all => 'DBD::Pg and certification connection parser required'
    unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $connect = sub { DBI->connect($dsn, $user, $password,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1}) };
my $db = $connect->();
my $observer = $connect->();
my $parents = 'selecto_helper_parents_' . $$;
my $children = 'selecto_helper_children_' . $$;
my $compound = 'selecto_helper_compound_' . $$;
$db->do("CREATE TABLE $parents(id BIGSERIAL PRIMARY KEY, tenant_id INTEGER NOT NULL, name TEXT UNIQUE NOT NULL, UNIQUE(tenant_id,id))");
$db->do("CREATE TABLE $children(id BIGSERIAL PRIMARY KEY, tenant_id INTEGER NOT NULL, parent_id BIGINT NOT NULL REFERENCES $parents(id), name TEXT UNIQUE NOT NULL)");
$db->do("CREATE TABLE $compound(tenant_id INTEGER NOT NULL, id BIGINT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(tenant_id,id))");
END {
    if ($db) {
        eval { $db->rollback unless $db->{AutoCommit}; $db->do("DROP TABLE IF EXISTS $compound"); $db->do("DROP TABLE IF EXISTS $children"); $db->do("DROP TABLE IF EXISTS $parents") };
    }
}
sub domain {
    my ($table, @fields) = @_;
    return {name => $table,
        source => {source_table => $table, primary_key => 'id', tenant_field => 'tenant_id', fields => \@fields,
            columns => {map { $_ => {type => $_ eq 'name' ? 'string' : 'integer'} } @fields}, associations => {}},
        schemas => {}, joins => {}, writes => {
            operations => {map { $_ => {enabled => JSON::PP::true, returning => 'all'} } qw(insert update delete)},
            fields => {name => {insertable => JSON::PP::true, updatable => JSON::PP::true},
                tenant_id => {insertable => JSON::PP::true, immutable => JSON::PP::true, required_on => ['insert']}},
            scope => {tenant => {field => 'tenant_id', required => JSON::PP::true, satisfied_by => ['trusted_context']}}}};
}
my $raw = domain($parents, qw(id tenant_id name));
$raw->{writes}{operations}{upsert} = {enabled => JSON::PP::true, returning => 'all', conflict_targets => [['tenant_id','id']]};
$raw->{writes}{fields}{id} = {insertable => JSON::PP::true, immutable => JSON::PP::true};
$raw->{writes}{relationships}{items} = {writable => JSON::PP::true, ownership => 'owned', cardinality => 'many',
    allowed_ops => ['insert'], child_key => 'parent_id', identity_fields => ['id'],
    write => {modes => ['append_only'], create => JSON::PP::true},
    domain => domain($children, qw(id tenant_id parent_id name))};
my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw),
    adapter => Selecto->adapter(postgresql => (dbh => $db)))->with_tenant(8);
sub error { my ($work) = @_; return eval { $work->(); 1 } ? undef : $@ }
my ($result, $row, $delayed, $id);
subtest 'generated identity, owned child and one transaction' => sub {
    $result = $engine->transaction(sub {
        my ($tx) = @_;
        my $w = $tx->write->insert->assignments(name => 'parent')->return_for_update(qw(id name));
        my $preview = $w->preview;
        like($preview->{sql}, qr/RETURNING/, 'preview exposes SQL without an edit handle');
        my $created = $w->execute;
        $row = $created->row;
        $id = $created->values->{id};
        ok(defined($id), 'actual generated identity');
        my $child = $row->related_write('items')->insert->assignments(name => 'first child')->returning(qw(id parent_id tenant_id));
        my $child_preview = $child->preview;
        ok(@{$child_preview->{statements}}, 'related preview uses native graph statements');
        my $res = $child->execute;
        is($res->values->{parent_id}, $id, 'parent key derived from native handle');
        is($res->values->{tenant_id}, 8, 'child tenant filled from same trusted context');
        is($observer->selectrow_array("SELECT count(*) FROM $parents"), 0, 'parent not independently committed');
        is($observer->selectrow_array("SELECT count(*) FROM $children"), 0, 'child not independently committed');
        $delayed = $row->write->update->assignments(name => 'expired');
        return $created;
    });
    is($observer->selectrow_array("SELECT count(*) FROM $parents"), 1, 'parent committed with callback');
    is($observer->selectrow_array("SELECT count(*) FROM $children"), 1, 'child committed with parent');
    is($result->values->{name}, 'parent', 'ordinary result values survive commit');
    is(error(sub { $result->row })->code, 'edit_handle_expired', 'result handle expires after callback');
    is(error(sub { $delayed->execute })->code, 'edit_handle_expired', 'previously made builder also expires');
};
subtest 'child failure rolls back parent even if application catches it' => sub {
    my $e = error(sub { $engine->transaction(sub {
        my ($tx) = @_;
        my $created = Selecto::Write->new($tx)->insert->assignments(name => 'rollback parent')->return_for_update('id')->execute;
        my $caught = error(sub { $created->row->related_write('items')->insert->assignments(name => 'first child')->execute });
        isa_ok($caught, 'Selecto::Error', 'duplicate child refuses');
        return $created;
    }) });
    isa_ok($e, 'Selecto::Error', 'transaction retains failure');
    is($observer->selectrow_array("SELECT count(*) FROM $parents WHERE name = 'rollback parent'"), 0, 'parent rolled back');
    is($observer->selectrow_array("SELECT count(*) FROM $children"), 1, 'no extra child committed');
};
subtest 'read lock contends on a second connection and updates exact identity' => sub {
    $observer->do("SET lock_timeout = '100ms'");
    $engine->transaction(sub {
        my ($tx) = @_;
        my $input = $tx->query->filter(Selecto::Expression->eq('id', $id));
        my $q = $input->select_for_update(qw(id name));
        $input->{predicate} = Selecto::Expression->eq('id', 999); # The locked query owns its snapshot.
        like($q->preview->{sql}, qr/FOR UPDATE OF "s0"/, 'preview locks only declared root');
        ok($observer->do("UPDATE $parents SET name = 'preview unlocked' WHERE id = ?", undef, $id), 'preview does not acquire a business row lock');
        my $editable = $q->execute;
        is($editable->values->{id}, $id, 'later mutation of original query cannot change snapshot identity');
        my $locked = error(sub { $observer->do("UPDATE $parents SET name = 'contender' WHERE id = ?", undef, $id) });
        ok($locked, 'second connection actually times out on row lock');
        is($observer->state, '55P03', 'PostgreSQL lock timeout, not unrelated query error');
        $editable->row->write->update->assignments(name => 'updated')->execute;
    });
    is($observer->selectrow_array("SELECT name FROM $parents WHERE id = ?", undef, $id), 'updated', 'follow-up committed');
    isa_ok(error(sub { $engine->query->filter(Selecto::Expression->eq('id', $id))->select_for_update('id') }), 'Selecto::Error', 'read outside callback refuses');
};
subtest 'identity, provenance and capability refusals' => sub {
    my $failure = error(sub { $engine->transaction(sub {
        my ($tx) = @_;
        isa_ok(error(sub { Selecto::Write->new($tx)->delete->filter(['id', $id])->return_for_update('id')->execute }), 'Selecto::Error', 'delete cannot return edit handle');
        isa_ok(error(sub { $tx->query->select_for_update('id')->execute }), 'Selecto::Error', 'missing exact key refuses');
        isa_ok(error(sub { $tx->query->filter(Selecto::Expression->eq('id', $id))->limit(0)->select_for_update('id') }),
            'Selecto::Error', 'zero-page query cannot silently become a row-locking read');
        isa_ok(error(sub { bless({}, 'Selecto::Write::Editable::Row')->write }), 'Selecto::Error', 'forged row refuses');
        my $editable = $tx->query->where(Selecto::Expression->all(Selecto::Expression->eq('id', $id), Selecto::Expression->eq('name', 'updated')))
            ->select_for_update(qw(id name))->execute;
        isa_ok(error(sub { $editable->row->write->with_tenant(9) }), 'Selecto::Error', 'live handle cannot change tenant');
        my $configured = $tx->domain;
        my $table = $configured->{table};
        $configured->{table} = 'different_domain';
        my $changed_domain = error(sub { $editable->row->write });
        $configured->{table} = $table;
        is($changed_domain->code, 'domain_modified_after_configuration', 'changed domain cannot reuse issued identity');
        isa_ok(error(sub { $editable->row->related_write('items')->insert->assignments(parent_id => 999, name => 'bad')->execute }), 'Selecto::Error', 'parent reassignment refuses');
    }) });
    isa_ok($failure, 'Selecto::Error', 'caught parent-binding failure poisons transaction');
};
subtest 'host and nested transactions retain independent handle lifetimes' => sub {
    $db->begin_work;
    my $host_result = $engine->transaction(sub {
        my ($tx) = @_;
        return Selecto::Write->new($tx)->insert->assignments(name => 'host parent')->return_for_update('id')->execute;
    });
    ok(!$db->{AutoCommit}, 'callback did not commit host transaction');
    is($observer->selectrow_array("SELECT count(*) FROM $parents WHERE name = 'host parent'"), 0, 'host row still uncommitted');
    is(error(sub { $host_result->row })->code, 'edit_handle_expired', 'callback handle expires even with live host transaction');
    $db->rollback;
    is($db->selectrow_array("SELECT count(*) FROM $parents WHERE name = 'host parent'"), 0, 'host owns rollback');
    $engine->transaction(sub {
        my ($outer) = @_;
        my $parent = Selecto::Write->new($outer)->insert->assignments(name => 'nested parent')->return_for_update('id')->execute;
        my $nested = $outer->transaction(sub {
            my ($inner) = @_;
            return $inner->query->filter(Selecto::Expression->eq('id', $parent->values->{id}))->select_for_update('id')->execute;
        });
        is(error(sub { $nested->row })->code, 'edit_handle_expired', 'inner handle expires on savepoint exit');
        $parent->row->write->update->assignments(name => 'outer still live')->execute;
    });
    is($observer->selectrow_array("SELECT count(*) FROM $parents WHERE name = 'outer still live'"), 1, 'outer handle remains live until its own callback ends');
};
subtest 'changed server transaction identity expires issued handles' => sub {
    my $failure = error(sub { $engine->transaction(sub {
        my ($tx) = @_;
        my $editable = $tx->query->filter(Selecto::Expression->eq('id', $id))->select_for_update('id')->execute;
        $db->rollback; # Simulate a host breaking its connection lease.
        $db->begin_work;
        my $expired = error(sub { $editable->row->write });
        is($expired->code, 'edit_handle_expired', 'a new transaction on same connection cannot reuse row identity');
        die $expired;
    }) });
    isa_ok($failure, 'Selecto::Error', 'scope exits with native expiry error');
};
subtest 'edit-result modes preserve exact identity and refuse unavailable identities before DML' => sub {
    my $large = 9007199254740993;
    $engine->transaction(sub {
        my ($tx) = @_;
        for my $name ('upsert created', 'upsert changed') {
            my $editable = Selecto::Write->new($tx)->upsert->assignments(id => $large, name => $name)
                ->conflict_target(qw(tenant_id id))->upsert_update_fields('name')->return_for_update(qw(id name))->execute;
            is("" . $editable->values->{id}, "$large", 'large native identity retained through upsert result');
            $editable->row->write->update->assignments(name => $name . ' follow-up')->execute;
        }
        isa_ok(error(sub { Selecto::Write->new($tx)->insert->assignments(name => 'missing identity')
            ->return_for_update('name')->execute }), 'Selecto::Error', 'projection without granted identity refuses');
        isa_ok(error(sub { Selecto::Write->new($tx)->insert->assignments(name => 'mixed modes')
            ->returning('id')->return_for_update('id') }), 'Selecto::Error', 'return modes cannot mix');
        isa_ok(error(sub { Selecto::Write->new($tx)->update->assignments(name => 'bulk handle')
            ->filter(['id', $id])->expected_cardinality('many')->return_for_update('id')->execute }), 'Selecto::Error', 'multi-row handle request refuses');
        isa_ok(error(sub { $tx->query->filter(Selecto::Expression->eq('id', $id))
            ->group_by('id')->select_for_update('id') }), 'Selecto::Error', 'grouped projection refuses');
    });
    is($observer->selectrow_array("SELECT name FROM $parents WHERE id = ?", undef, $large), 'upsert changed follow-up', 'both upsert branches support exact-key follow-up');
    is($observer->selectrow_array("SELECT count(*) FROM $parents WHERE name IN ('missing identity','mixed modes','bulk handle')"), 0, 'all invalid result modes left no target mutation');
};
subtest 'changing the connection lease expires issued row handles' => sub {
    my $replacement = $connect->();
    $replacement->begin_work;
    $engine->transaction(sub {
        my ($tx) = @_;
        my $editable = $tx->query->filter(Selecto::Expression->eq('id', $id))->select_for_update('id')->execute;
        $tx->adapter->dbh($replacement);
        my $expired = error(sub { $editable->row->write });
        $tx->adapter->dbh($db);
        is($expired->code, 'edit_handle_expired', 'another active connection cannot reuse the original row lease');
    });
    $replacement->rollback;
    $replacement->disconnect;
};
subtest 'compound identities bind every component for writes and locked reads' => sub {
    my $contract = domain($compound, qw(tenant_id id name));
    $contract->{source}{primary_key} = [qw(tenant_id id)];
    $contract->{writes}{fields}{id} = {insertable => JSON::PP::true, immutable => JSON::PP::true};
    $contract->{writes}{operations}{upsert} = {enabled => JSON::PP::true, returning => 'all', conflict_targets => [[qw(tenant_id id)]]};
    my $host = Selecto::Engine->new(domain => Selecto::Domain->parse($contract), adapter => $engine->adapter,
        write_context => {tenant_id => 8});
    my $key = $host->domain->primary_key;
    $key->[0] = 'name';
    is_deeply($host->domain->primary_keys, [qw(tenant_id id)], 'primary-key accessor cannot mutate configured identity');
    my $large = '9007199254740993';
    $db->do("INSERT INTO $compound VALUES(9, ?, 'other tenant')", undef, $large);
    my $saved = $host->transaction(sub {
        my ($tx) = @_;
        isa_ok(error(sub { Selecto::Write->new($tx)->insert->assignments(id => 1, name => 'incomplete')
            ->return_for_update(qw(id name))->execute }), 'Selecto::Error', 'missing returned component refuses before insert');
        my $created = $tx->write->insert->assignments(id => $large, name => 'compound')
            ->return_for_update(qw(tenant_id id name))->execute;
        is_deeply([map { "" . $created->values->{$_} } qw(tenant_id id)], ['8', $large], 'complete native large identity retained');
        for my $field (qw(tenant_id id)) {
            isa_ok(error(sub { $created->row->write->update->assignments($field => 10) }), 'Selecto::Error', 'each identity component is immutable');
        }
        my $change = $created->row->write->update->assignments(name => 'changed');
        like($change->preview->{sql}, qr/"tenant_id".*"id"/s, 'follow-up preview contains compound identity');
        $change->execute;
        is($observer->selectrow_array("SELECT count(*) FROM $compound WHERE tenant_id = 8"), 0, 'compound insert and follow-up share transaction');
        return $created;
    });
    is($db->selectrow_array("SELECT name FROM $compound WHERE tenant_id = 8 AND id = ?", undef, $large), 'changed', 'exact compound write committed');
    is($db->selectrow_array("SELECT name FROM $compound WHERE tenant_id = 9 AND id = ?", undef, $large), 'other tenant', 'same second key in other tenant unchanged');
    is(error(sub { $saved->row })->code, 'edit_handle_expired', 'compound handle expires after callback');
    $host->transaction(sub {
        my ($tx) = @_;
        isa_ok(error(sub { $tx->query->filter(Selecto::Expression->eq('id', $large))->select_for_update(qw(tenant_id id name)) }),
            'Selecto::Error', 'partial compound read filter refuses');
        my $query = $tx->query->where(Selecto::Expression->all(
            Selecto::Expression->eq('tenant_id', 8), Selecto::Expression->eq('id', $large)));
        isa_ok(error(sub { $query->select_for_update(qw(id name)) }), 'Selecto::Error', 'partial compound projection refuses');
        my $editable = $query->select_for_update(qw(tenant_id id name))->execute;
        my $locked = error(sub { $observer->do("UPDATE $compound SET name = 'blocked' WHERE tenant_id = 8 AND id = ?", undef, $large) });
        ok($locked, 'second connection contends on compound row lock');
        is($observer->state, '55P03', 'actual compound lock timeout');
        $editable->row->write->update->assignments(name => 'read follow-up')->execute;
    });
    $host->transaction(sub {
        my ($tx) = @_;
        my $editable = Selecto::Write->new($tx)->upsert->assignments(id => $large, name => 'upserted')
            ->conflict_target(qw(tenant_id id))->upsert_update_fields('name')->return_for_update(qw(tenant_id id name))->execute;
        $editable->row->write->update->assignments(name => 'upsert follow-up')->execute;
    });
    is($db->selectrow_array("SELECT name FROM $compound WHERE tenant_id = 8 AND id = ?", undef, $large), 'upsert follow-up', 'compound upsert retains exact identity');
};
done_testing;
