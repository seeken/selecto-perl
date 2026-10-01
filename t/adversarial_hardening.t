use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::CannedPage ();
use Selecto::API::EngineHandler ();

# Regression coverage for the 2026-10-01 adversarial survey. Subtest names
# carry the catalog IDs from selecto-adversarial-api-and-backend-test-scenarios.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $E = 'Selecto::Expression';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $e = $@;
    return blessed($e) && $e->isa('Selecto::Error') ? $e->code : "died: $e";
}

sub relation {
    my ($table, %cols) = @_;
    return {
        source_table => $table, primary_key => 'id', fields => [sort keys %cols],
        columns => {map { ($_ => (ref $cols{$_} ? $cols{$_} : {type => $cols{$_}})) } keys %cols},
        associations => {},
    };
}

# A host-written engine decorator: it answers domain and all by delegation
# but is not a Selecto::Engine.
package AdvTest::DelegatingEngine {
    sub new { my ($class, $inner) = @_; return bless {inner => $inner}, $class }
    sub domain { $_[0]{inner}->domain }
    sub query { $_[0]{inner}->query }
    sub all { my ($self, $query) = @_; return $self->{inner}->all($query) }
}
package AdvTest::BoundaryDelegatingEngine {
    our @ISA = ('AdvTest::DelegatingEngine');
    sub assert_tenant_boundary { my ($self, %args) = @_; $self->{inner}->assert_tenant_boundary(%args); $self }
}
package main;

sub work_order_domain {
    return Selecto::Domain->parse({
        schema_version => 1, name => 'Work Orders', domain_version => '1',
        domain_fingerprint => 'sha256:adversarial-hardening',
        source => {%{relation('work_orders', id => 'integer', site_id => 'integer', title => 'string',
            state => 'string')}, tenant_field => 'site_id'},
        schemas => {}, joins => {},
    });
}

sub work_order_dbh {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE work_orders (id integer primary key, site_id integer not null, title text not null, state text)');
    $dbh->do(q{INSERT INTO work_orders VALUES (1, 10, 'mine', 'done'), (2, 20, 'theirs', 'done'), (3, 10, 'mine too', 'done')});
    return $dbh;
}

subtest 'S14/TR-04: canned pages require the tenant boundary from every engine' => sub {
    my $dbh = work_order_dbh();
    my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
    my $domain = work_order_domain();
    my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    my $page = Selecto::CannedPage->new(
        id => 'work_orders', domain => $domain,
        dataset => {query => $unscoped->query, entity_key => ['id']},
        views => [{id => 'list', kind => 'detail', query => $unscoped->query->select('id', 'title')->order_by('id')}],
        controls => [{id => 'state', kind => 'facet', field => 'state'}],
    );

    is(code_of(sub { $page->run($unscoped, {}) }), 'missing_tenant_scope',
        'a Selecto::Engine without a tenant is refused');
    my $result;
    is(code_of(sub { $result = $page->run(AdvTest::DelegatingEngine->new($unscoped), {}) }),
        'missing_tenant_scope', 'a delegating engine that cannot assert the boundary is refused');
    ok(!$result, 'no rows reached the caller through the delegating engine');
    is(code_of(sub { $page->run(AdvTest::BoundaryDelegatingEngine->new($unscoped), {}) }),
        'missing_tenant_scope', 'a delegating engine is held to the boundary it asserts');

    my $scoped = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 10});
    my $rows = $page->run(AdvTest::BoundaryDelegatingEngine->new($scoped), {})->{rows};
    is_deeply($rows, [[1, 'mine'], [3, 'mine too']], 'a scoped engine behind a boundary-aware decorator reads its tenant');
    is_deeply($page->run($unscoped, {}, $E->eq('site_id', 10))->{rows}, [[1, 'mine'], [3, 'mine too']],
        'a host tenant predicate is still a read boundary');

    my $plain_contract = $domain->as_contract;
    delete $plain_contract->{source}{tenant_field};
    my $plain = Selecto::Domain->parse($plain_contract);
    my $plain_engine = Selecto::Engine->new(domain => $plain, adapter => $adapter);
    my $plain_page = Selecto::CannedPage->new(
        id => 'work_orders', domain => $plain,
        dataset => {query => $plain_engine->query, entity_key => ['id']},
        views => [{id => 'list', kind => 'detail', query => $plain_engine->query->select('id')->order_by('id')}],
    );
    is(scalar @{$plain_page->run(AdvTest::DelegatingEngine->new($plain_engine), {})->{rows}}, 3,
        'a domain without tenant_field still runs through a decorator');
};

sub action_engine {
    my ($dbh, %scope) = @_;
    my $domain = Selecto::Domain->parse({
        schema_version => 1, name => 'Work Orders', domain_version => '1',
        domain_fingerprint => 'sha256:adversarial-actions',
        source => {%{relation('work_orders', id => 'integer', site_id => 'integer', title => 'string',
            state => 'string', ($scope{other_domain} ? (priority => 'integer') : ()))}, tenant_field => 'site_id'},
        schemas => {}, joins => {},
        writes => {
            operations => {update => {enabled => 1}},
            fields => {state => {updatable => 1}},
            transitions => {state => {done => ['archived']}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
        },
        actions => {archive => {
            type => 'transition', scope => 'row', capability => 'work_orders.archive',
            transition => {field => 'state', from => 'done', to => 'archived'},
            execution => {kind => 'updato', operation => 'update', set => {state => 'archived'}},
        }},
        capabilities => {'work_orders.archive' => {operations => ['action', 'update'], action => 'archive'}},
    });
    return Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
        scope => {tenant => $scope{tenant} // 10});
}

subtest 'S22/AC-02/AC-04: action grants expire by default and a mismatched use revokes them' => sub {
    my $dbh = work_order_dbh();
    my $engine = action_engine($dbh);
    my $alice = {actor => {id => 'alice'}};
    my $resolver = sub { 'enabled' };
    my $plan = $engine->plan_action({action => 'archive', target => 1});
    my $now = Time::HiRes::time();
    my $at = sub {
        my ($offset, $code) = @_;
        no warnings 'redefine';
        local *Time::HiRes::time = sub { $now + $offset };
        return $code->();
    };
    my $grant = $at->(0, sub { $engine->grant_action($plan, phase => 'preview', resolver => $resolver,
        context => $alice) });
    is($at->(3600, sub { code_of(sub { $engine->preview_action($plan, grant => $grant, context => $alice) }) }),
        'action_grant_invalid', 'a grant issued without expires_in expires within the hour');
    my $fresh = $at->(0, sub { $engine->grant_action($plan, phase => 'preview', resolver => $resolver,
        context => $alice) });
    is($at->(299, sub { code_of(sub { $engine->preview_action($plan, grant => $fresh, context => $alice) }) }),
        'ok', 'the default lifetime covers a confirmation step');
    my $stale = $at->(0, sub { $engine->grant_action($plan, phase => 'preview', resolver => $resolver,
        context => $alice) });
    is($at->(301, sub { code_of(sub { $engine->preview_action($plan, grant => $stale, context => $alice) }) }),
        'action_grant_invalid', 'the default lifetime is five minutes');
    is(code_of(sub { $engine->grant_action($plan, resolver => $resolver, context => $alice,
        expires_in => 86_400) }), 'invalid_action_grant', 'a grant cannot outlive the one-hour ceiling');
    is(code_of(sub { $engine->grant_action($plan, resolver => $resolver, context => $alice,
        expires_in => 3600) }), 'ok', 'a grant may live for the full hour when the host asks');

    # Every binding mismatch revokes the grant, the domain included.
    my $probe = $engine->grant_action($plan, phase => 'execute', resolver => $resolver, context => $alice);
    my $other_domain = action_engine($dbh, other_domain => 1);
    is(code_of(sub { $other_domain->execute_action($plan, grant => $probe, context => $alice) }),
        'action_grant_mismatch', 'a grant is bound to its domain');
    is(code_of(sub { $engine->execute_action($plan, grant => $probe, context => $alice) }),
        'action_grant_invalid', 'a grant presented to another domain is revoked');
    is($dbh->selectrow_array('SELECT state FROM work_orders WHERE id = 1'), 'done', 'no revoked grant wrote');
};

subtest 'PE :123/FV-03: library orderings and segments cannot read internal fields; choice filters keep to their choices' => sub {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE accounts (id integer primary key, name text, backup_code integer, secret_code integer, vip integer)');
    $dbh->do(q{INSERT INTO accounts VALUES (1, 'a', 10, 300, 1), (2, 'b', 20, 100, NULL), (3, 'c', 30, 200, 1)});
    my $domain = Selecto::Domain->parse({
        schema_version => 1, name => 'Accounts', domain_version => '1',
        source => {%{relation('accounts', id => 'integer', name => 'string', backup_code => 'integer',
            secret_code => {type => 'integer', internal => 1}, vip => {type => 'integer', internal => 1})}},
        schemas => {}, joins => {},
        components => {filter_choices => {
            either_code => {label => 'Code', choices => [{value => '10', label => '10'}],
                conditional => {when_field => 'vip', present_field => 'backup_code', absent_field => 'backup_code'}},
            code_or_backup => {label => 'Code', choices => [{value => '100', label => '100'}],
                conditional => {when_field => 'name', present_field => 'secret_code', absent_field => 'backup_code'}},
        }},
        query_library => {
            orderings => {
                by_secret => {order_by => [['secret_code', 'asc']]},
                by_name => {order_by => [['name', 'asc']]},
            },
            segments => {
                secret_at_least => {parameters => {min => {type => 'integer'}},
                    filters => [['gte', 'secret_code', ['param', 'min']]]},
                vip_only => {filters => [['not_null', 'vip']]},
                secret_reference => {filters => [['gt', 'backup_code', ['field', 'secret_code']]]},
                named => {filters => [['not_null', 'name']]},
            },
            projections => {listing => {fields => ['id']}},
            views => {
                secret_listing => {projection => 'listing', ordering => 'by_secret'},
                vip_listing => {projection => 'listing', segments => ['vip_only']},
            },
        },
    });
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my $handler = Selecto::API::EngineHandler->new;
    my $ids = sub { my $out = $handler->query($engine, {select => ['id'], %{$_[0]}}); [map { $_->[0] } @{$out->{rows}}] };
    my %refused = (
        'a named ordering on an internal field' => {ordering => 'by_secret'},
        'a view ordering on an internal field' => {view => 'secret_listing', select => undef},
        'a parameterized segment on an internal field' => {segments => ['secret_at_least'], parameters => {min => 150}},
        'a fixed segment on an internal field' => {segments => ['vip_only']},
        'a view segment on an internal field' => {view => 'vip_listing', select => undef},
        'a segment comparing to an internal field' => {segments => ['secret_reference']},
        'an undeclared value on a conditional filter switching on an internal field' =>
            {filters => [{field => 'either_code', op => 'eq', value => 20}]},
        'an undeclared value on a conditional filter reading an internal field' =>
            {filters => [{field => 'code_or_backup', op => 'eq', value => 300}]},
        'an undeclared value among declared ones' =>
            {filters => [{field => 'code_or_backup', op => 'in', value => [100, 300]}]},
        'a null test on a conditional filter reading an internal field' =>
            {filters => [{field => 'code_or_backup', op => 'not_null'}]},
    );
    for my $name (sort keys %refused) {
        my %body = (select => ['id'], %{$refused{$name}});
        delete $body{select} unless defined $body{select};
        is(code_of(sub { $handler->query($engine, \%body) }), 'field_not_public', "$name is refused");
    }
    is_deeply($ids->({ordering => 'by_name'}), [1, 2, 3], 'a named ordering on public fields still applies');
    is_deeply($ids->({segments => ['named'], order_by => [{field => 'id'}]}), [1, 2, 3],
        'a segment on public fields still applies');
    is_deeply($ids->({filters => [{field => 'code_or_backup', op => 'in', value => [100]}]}), [2],
        'a declared choice still filters through an internal field');
    is_deeply($ids->({filters => [{field => 'either_code', op => 'eq', value => '10'}]}), [1],
        'a declared choice still switches on an internal field');
    is(code_of(sub { $handler->query($engine, {select => ['id'], order_by => [{field => 'secret_code'}]}) }),
        'field_not_public', 'a direct order_by on the internal field stays refused');
};

sub order_domain {
    my (%o) = @_;
    return Selecto::Domain->parse({
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation('orders', id => 'integer', site_id => 'integer', code => 'string', title => 'string',
            customer_id => 'integer')}, tenant_field => 'site_id',
            associations => {customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id',
                ($o{scope_keys} ? (source_scope_key => 'site_id', target_scope_key => 'site_id') : ())}}},
        schemas => {customer => {%{relation('customers', id => 'integer', site_id => 'integer', name => 'string')},
            tenant_field => 'site_id'}},
        joins => {customer => {type => 'left'}},
        writes => {
            operations => {insert => {enabled => 1}, update => {enabled => 1},
                upsert => {enabled => 1, conflict_targets => [[qw(site_id code)]]}},
            fields => {id => {insertable => 1}, code => {insertable => 1}, title => {insertable => 1, updatable => 1},
                customer_id => {insertable => 1, updatable => 1}, site_id => {insertable => 1, updatable => 1}},
            ($o{unscoped} ? () : (scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}})),
        },
    });
}

sub order_dbh {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do('CREATE TABLE customers (id integer primary key, site_id integer not null, name text not null)');
    $dbh->do('CREATE TABLE orders (id integer primary key, site_id integer not null, code text not null, title text,
        customer_id integer references customers(id), UNIQUE (site_id, code))');
    $dbh->do(q{INSERT INTO customers VALUES (1, 10, 'Ours'), (2, 20, 'Theirs')});
    $dbh->do(q{INSERT INTO orders VALUES (1, 10, 'A', 'mine', 1), (2, 20, 'A', 'theirs', 2)});
    return $dbh;
}

sub order_rows { $_[0]->selectall_arrayref('SELECT id, site_id, code, title, customer_id FROM orders ORDER BY id') }

my $handler = Selecto::API::EngineHandler->new;

subtest 'TW-05 (S3 analog): a tenant write may not reference another tenant\'s parent row' => sub {
    my $dbh = order_dbh();
    my $engine = Selecto::Engine->new(domain => order_domain(), adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
        scope => {tenant => 10});
    # The association is the only declaration: no writes.constraints.
    is(code_of(sub { $handler->write($engine, {operation => 'insert',
        assignments => {id => 3, code => 'B', title => 'x', customer_id => 2}}) }), 'cardinality_mismatch',
        "an insert may not reference another tenant's parent");
    is(code_of(sub { $handler->write($engine, {operation => 'update', assignments => {customer_id => 2},
        filters => [{field => 'id', op => 'eq', value => 1}]}) }), 'cardinality_mismatch',
        "an update may not repoint a row at another tenant's parent");
    is_deeply(order_rows($dbh), [[1, 10, 'A', 'mine', 1], [2, 20, 'A', 'theirs', 2]], 'no row changed');
    is_deeply($handler->query($engine, {select => ['id', 'customer.name'], order_by => [{field => 'id'}]})->{rows},
        [[1, 'Ours']], "another tenant's parent is never read through the association");
};

subtest 'TW-05: association scope keys keep a foreign-key match inside the tenant' => sub {
    my $dbh = order_dbh();
    $dbh->do(q{UPDATE orders SET customer_id = 2 WHERE id = 1});
    my $engine = Selecto::Engine->new(domain => order_domain(scope_keys => 1),
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)), scope => {tenant => 10});
    is_deeply($handler->query($engine, {select => ['id', 'customer.name']})->{rows}, [[1, undef]],
        "a cross-tenant reference reads as no parent, not as the other tenant's row");
};

subtest 'TW-04/BD-07 (S9 analog): scoped upserts stay inside the tenant' => sub {
    my $dbh = order_dbh();
    my $engine = Selecto::Engine->new(domain => order_domain(), adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
        scope => {tenant => 10});
    my $upsert = sub { my (%assignments) = @_; code_of(sub { $handler->write($engine, {operation => 'upsert',
        assignments => \%assignments, conflict_target => [qw(site_id code)], upsert_update_fields => ['title']}) }) };
    isnt($upsert->(id => 2, code => 'Z', title => 'stolen'), 'ok',
        "a primary-key collision with another tenant's row is not resolved as a conflict");
    is($upsert->(id => 9, code => 'A', title => 'upserted'), 'ok', 'a conflict on the tenant target updates our row');
    is(code_of(sub { $handler->write($engine, {operation => 'upsert', assignments => {id => 9, code => 'A', title => 'x'},
        conflict_target => ['code'], upsert_update_fields => ['title']}) }), 'tenant_scope_conflict_target',
        'a conflict target without the tenant field is refused');
    is_deeply(order_rows($dbh), [[1, 10, 'A', 'upserted', 1], [2, 20, 'A', 'theirs', 2]],
        "another tenant's row is untouched");

    # MySQL resolves ON DUPLICATE KEY on every unique key, so a scoped
    # upsert could update another tenant's row through its primary key.
    for my $name (qw(mysql mariadb)) {
        my $scoped = Selecto::Engine->new(domain => order_domain(),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)), scope => {tenant => 10});
        is(code_of(sub { $handler->write($scoped, {operation => 'upsert', assignments => {id => 2, code => 'Z', title => 'x'},
            conflict_target => [qw(site_id code)], upsert_update_fields => ['title']}) }), 'unsupported_scope_predicate',
            "$name refuses a tenant-scoped upsert");
    }
};

subtest 'TW-02 (S2 analog): an update cannot move a row to another tenant' => sub {
    my $dbh = order_dbh();
    my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
    my $move = sub { my ($engine, $value) = @_; code_of(sub { $handler->write($engine, {operation => 'update',
        assignments => {site_id => $value}, filters => [{field => 'id', op => 'eq', value => 1}]}) }) };
    my $scoped = Selecto::Engine->new(domain => order_domain(), adapter => $adapter, scope => {tenant => 10});
    is($move->($scoped, 30), 'tenant_mismatch', 'writes.scope.tenant refuses a tenant SET to another tenant');
    is($move->($scoped, 10), 'ok', 'writes.scope.tenant accepts restating the trusted tenant');
    is(code_of(sub { $scoped->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'orders',
        assignments => {site_id => 30}, predicate => Selecto::Expression->eq('id', 1))) }), 'tenant_mismatch',
        'the engine refuses it outside the API handler too');

    my $guarded = Selecto::Engine->new(adapter => $adapter,
        domain => order_domain(unscoped => 1)->with_required_predicate($E->eq('site_id', 10)));
    is($move->($guarded, 30), 'tenant_mismatch', 'a required tenant predicate refuses a tenant SET to another tenant');
    is(code_of(sub { $guarded->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'orders',
        assignments => {site_id => Selecto::Write::Expression->add(Selecto::Write::Expression->field('site_id'), 20)},
        predicate => $E->eq('id', 1))) }), 'tenant_mismatch', 'a computed tenant value is refused');
    is($move->($guarded, 10), 'ok', 'a required tenant predicate accepts the tenant it names');
    my $listed = Selecto::Engine->new(adapter => $adapter,
        domain => order_domain(unscoped => 1)->with_required_predicate($E->in('site_id', [10, 11])));
    is($move->($listed, 11), 'ok', 'a tenant the predicate lists is accepted');
    is($move->($listed, 30), 'tenant_mismatch', 'a tenant outside the list is refused');
    is_deeply(order_rows($dbh), [[1, 11, 'A', 'mine', 1], [2, 20, 'A', 'theirs', 2]],
        'no row reached a tenant outside its boundary');
};

subtest 'PE #11/DOS-03: filter ASTs are capped at 64 levels of nesting' => sub {
    my $engine = Selecto::Engine->new(domain => order_domain(unscoped => 1),
        adapter => Selecto->adapter(sqlite => (dbh => order_dbh())));
    my $nested = sub { my ($depth) = @_; my $ast = ['eq', 'id', 1]; $ast = ['not', $ast] for 1 .. $depth; $ast };
    is(code_of(sub { $engine->write_command(operation => 'update', assignments => {title => 'x'},
        filter => $nested->(64)) }), 'ok', 'a filter nested 64 levels deep compiles');
    is(code_of(sub { $engine->write_command(operation => 'update', assignments => {title => 'x'},
        filter => $nested->(65)) }), 'invalid_query', 'one level deeper is refused');
    is(code_of(sub { Selecto::Expression->from_filter_ast(['and', [['or', [$nested->(64)]]]]) }), 'invalid_query',
        'and/or levels count toward the cap');
    is(code_of(sub { Selecto::Expression->from_filter_ast($nested->(20_000)) }), 'invalid_query',
        'a very deep filter fails fast');
};

subtest 'PE #11/DOS-03: read compile time grows with expression size, not depth' => sub {
    require Time::HiRes;
    # Expressions built in code are not capped like filter ASTs.
    local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /Deep recursion/ };
    my $engine = Selecto::Engine->new(domain => order_domain(unscoped => 1),
        adapter => Selecto->adapter(postgresql => (dbh => TestSelecto::DBH->new)));
    my $chain = sub { my ($depth, $id) = @_; my $x = $E->eq('id', $id); $x = $E->not($x) for 1 .. $depth; $x };
    my $seconds = sub {
        my ($predicate, $grouped) = @_;
        my $query = $grouped
            ? $engine->query->select('title', $E->count_field('id')->as('n'))->group_by('title')->where($predicate)
            : $engine->query->select('id')->where($predicate);
        my $started = Time::HiRes::time();
        $engine->compile($query);
        return Time::HiRes::time() - $started;
    };
    my $flat = $E->all([map { $E->eq('id', $_) } 1 .. 5_000]);
    my $deep = $chain->(7_500, 1);
    my $capped = $E->all([map { $chain->(60, $_) } 1 .. 250]);
    for my $grouped (0, 1) {
        my $mode = $grouped ? 'grouped' : 'ungrouped';
        my $flat_seconds = $seconds->($flat, $grouped);
        my $deep_seconds = $seconds->($deep, $grouped);
        ok($flat_seconds < 1.5, sprintf('a 5,000-term AND compiles %s in %.3fs', $mode, $flat_seconds));
        ok($deep_seconds < 1.5, sprintf('a 7,500-deep chain compiles %s in %.3fs', $mode, $deep_seconds));
        ok($deep_seconds < 4 * $flat_seconds + 0.25,
            "depth costs no more per node than breadth ($mode)");
        my $capped_seconds = $seconds->($capped, $grouped);
        ok($capped_seconds < 1.5, sprintf('250 terms 60 deep compile %s in %.3fs', $mode, $capped_seconds));
    }
    my $sql = $engine->compile($engine->query->select('title', $E->count_field('id')->as('n'))->group_by('title')
        ->where($E->all([$chain->(3, 1), $E->eq('title', 'x')])))->sql;
    like($sql, qr/NOT \(NOT \(NOT \(.*"id" = \$1\)\)\).*"title" = \$2.*GROUP BY/s,
        'a grouped compile still renders every node');
};

done_testing;
