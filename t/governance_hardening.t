use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();

# Regression coverage for the 2026-09-24 security review of the query and
# write governance boundary.

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

package Capture::PG {
    use parent -norequire, 'Selecto::PostgreSQL';
    sub execute_query { my ($s, $st) = @_; $s->{last} = $st; return {columns => $st->columns, rows => []} }
}
package main;
require Selecto::PostgreSQL;
@Capture::PG::ISA = ('Selecto::PostgreSQL');

my $handler = Selecto::API::EngineHandler->new;

subtest 'internal columns stay private at every association depth' => sub {
    my $domain = Selecto::Domain->parse({
        schema_version => 1, name => 'People',
        source => {
            %{relation('people', id => 'integer', name => 'string', tenant_id => 'integer')},
            associations => {orders => {queryable => 'order', owner_key => 'id', related_key => 'person_id', cardinality => 'many'}},
        },
        schemas => {
            order => {
                %{relation('orders', id => 'integer', person_id => 'integer', customer_id => 'integer',
                    secret_note => {type => 'string', internal => 1})},
                associations => {customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id'}},
            },
            customer => relation('customers', id => 'integer', name => 'string', ssn => {type => 'string', internal => 1}),
        },
        joins => {},
    });
    ok(!$domain->field_is_public('orders.secret_note'), 'two-segment internal column is private');
    ok(!$domain->field_is_public('orders.customer.ssn'), 'three-segment internal column is private');
    ok($domain->field_is_public('orders.customer.name'), 'three-segment public column stays public');
    my $engine = Selecto::Engine->new(
        domain => $domain->with_required_predicate(Selecto::Expression->eq('tenant_id', 7)),
        adapter => Capture::PG->new(dbh => bless({}, 'Offline::DBH')),
    );
    is(code_of(sub { $handler->query($engine, {select => ['id', 'orders.customer.ssn']}) }),
        'field_not_public', 'API select refuses the deep internal column');
    is(code_of(sub { $handler->query($engine, {select => ['id'],
        filters => [{field => 'orders.customer.ssn', op => 'eq', value => 'x'}]}) }),
        'field_not_public', 'API filter refuses the deep internal column');
    is(code_of(sub { $handler->query($engine, {select => ['id'], order_by => [{field => 'orders.customer.ssn'}]}) }),
        'field_not_public', 'API order_by refuses the deep internal column');
    is(code_of(sub { $handler->query($engine, {select => ['id', 'orders.customer.name']}) }),
        'ok', 'deep public columns remain queryable');
};

subtest 'redact_fields withhold columns from untrusted surfaces' => sub {
    my $domain = Selecto::Domain->parse({
        schema_version => 1, name => 'People',
        source => {
            %{relation('people', id => 'integer', ssn => 'string', dob => 'string', name => 'string', team_id => 'integer')},
            redact_fields => ['dob'],
            associations => {team => {queryable => 'team', owner_key => 'team_id', related_key => 'id'}},
        },
        schemas => {team => {%{relation('teams', id => 'integer', budget => 'decimal', name => 'string')}, redact_fields => ['budget']}},
        joins => {},
        redact_fields => ['ssn'],
    });
    ok(!$domain->field_is_public('ssn'), 'top-level redact_fields entry is private');
    ok(!$domain->field_is_public('dob'), 'source redact_fields entry is private');
    ok(!$domain->field_is_public('team.budget'), 'schema redact_fields entry is private');
    ok($domain->field_is_public('team.name'), 'unredacted schema column stays public');
    ok($domain->field_metadata('ssn')->{redacted}, 'metadata records the redaction');
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Capture::PG->new(dbh => bless({}, 'Offline::DBH')));
    is(code_of(sub { $handler->query($engine, {select => ['id', 'ssn']}) }), 'field_not_public', 'API select refuses redacted field');
    is(code_of(sub { $handler->query($engine, {select => ['id'], filters => [{field => 'team.budget', op => 'gt', value => 1}]}) }),
        'field_not_public', 'API filter refuses redacted association field');
};

subtest 'related collection keys must be identifier paths' => sub {
    for my $key ("a\\", "a'b", ')) FROM secrets --', 'a b', '1abc') {
        is(code_of(sub {
            Selecto::Expression->related_collection('lines', [{key => $key, expression => Selecto::Expression->field('lines.sku')}]);
        }), 'invalid_query', "key rejected: $key");
    }
    is(code_of(sub {
        Selecto::Expression->related_collection('lines', [{key => 'line.sku_code', expression => Selecto::Expression->field('lines.sku')}]);
    }), 'ok', 'identifier path keys are accepted');
};

subtest 'API query offset is bounded' => sub {
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'People',
        source => relation('people', id => 'integer'), schemas => {}, joins => {}});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Capture::PG->new(dbh => bless({}, 'Offline::DBH')));
    is(code_of(sub { $handler->query($engine, {select => ['id'], offset => 100_000}) }), 'ok', 'offset at the cap is accepted');
    is(code_of(sub { $handler->query($engine, {select => ['id'], offset => 100_001}) }), 'invalid_api_query', 'offset past the cap is refused');
    is(code_of(sub { $handler->query($engine, {select => ['id'], offset => '1000000000000000'}) }), 'invalid_api_query', 'huge offset is refused');
    my $tight = Selecto::API::EngineHandler->new(max_offset => 10);
    is(code_of(sub { $tight->query($engine, {select => ['id'], offset => 11}) }), 'invalid_api_query', 'max_offset is configurable');
};

sub member_contract {
    my (%o) = @_;
    return {
        schema_version => 1, name => 'People',
        source => {%{relation('people', id => 'integer', name => 'string', tenant_id => 'integer', team_id => 'integer')},
            tenant_field => 'tenant_id'},
        schemas => {
            order => {%{relation('orders', id => 'integer', person_id => 'integer', total => 'decimal', tenant_id => 'integer')},
                ($o{untenanted_orders} ? () : (tenant_field => 'tenant_id'))},
            team => relation('teams', id => 'integer', parent_id => 'integer', name => 'string'),
        },
        joins => {},
        query_members => {
            ctes => {
                order_totals => {
                    source => 'order',
                    query => {select => ['person_id', {as => 'spent', aggregate => 'sum', field => 'total'}], group_by => ['person_id']},
                    join => {owner_key => 'id', related_key => 'person_id', type => 'left'},
                },
                team_tree => {
                    kind => 'recursive', source => 'team',
                    base => {select => ['id', 'parent_id', 'name'], filter => ['is_null', 'parent_id']},
                    step => {select => ['id', 'parent_id', 'name']},
                    step_join => {owner_key => 'parent_id', related_key => 'id'},
                    join => {owner_key => 'team_id', related_key => 'id', type => 'inner'},
                    (defined($o{max_depth}) ? (max_depth => $o{max_depth}) : ()),
                },
            },
            laterals => {
                latest_order => {
                    source => 'order', query => {select => ['id', 'total'], order_by => [['id', 'desc']], limit => 1},
                    correlations => {person_id => 'id'}, join_type => 'left',
                },
            },
        },
    };
}

sub member_engine {
    my ($contract, $predicate) = @_;
    my $domain = Selecto::Domain->parse($contract);
    $domain = $domain->with_required_predicate($predicate) if $predicate;
    return Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => bless({}, 'Offline::DBH'))));
}

subtest 'query members inherit the root tenant scope' => sub {
    my $engine = member_engine(member_contract(), Selecto::Expression->eq('tenant_id', 7));
    my $cte = $engine->compile($engine->query->with_member('order_totals')->select('name', 'order_totals.spent'));
    like($cte->sql, qr/WITH "order_totals" .* FROM "orders" AS "s0" WHERE "s0"\."tenant_id" = \$1 GROUP BY/,
        'CTE body is tenant-scoped');
    is_deeply($cte->params, [7, 7], 'CTE and root both bind the tenant');
    my $lateral = $engine->compile($engine->query->with_member('latest_order')->select('name', 'latest_order.total'));
    like($lateral->sql, qr/LEFT JOIN LATERAL \(SELECT .*"l_latest_order"\."tenant_id" = \$\d+/,
        'lateral body is tenant-scoped');

    my $mixed = member_engine(member_contract(),
        Selecto::Expression->all(Selecto::Expression->eq('tenant_id', 7), Selecto::Expression->eq('name', 'x')));
    like($mixed->compile($mixed->query->with_member('order_totals')->select('name'))->sql,
        qr/FROM "orders" AS "s0" WHERE "s0"\."tenant_id" = \$1 GROUP BY/, 'only the tenant conjunct is carried over');

    my $untenanted = member_engine(member_contract(), Selecto::Expression->eq('name', 'x'));
    is(code_of(sub { $untenanted->compile($untenanted->query->with_member('order_totals')->select('name')) }),
        'missing_tenant_scope', 'a scope without a tenant condition fails closed for a tenant-scoped member');

    my $plain = member_engine(member_contract(untenanted_orders => 1), Selecto::Expression->eq('tenant_id', 7));
    unlike($plain->compile($plain->query->with_member('order_totals')->select('name'))->sql,
        qr/"orders" AS "s0" WHERE/, 'members without a tenant_field are unchanged');
};

subtest 'recursive members are depth-bounded' => sub {
    my $engine = member_engine(member_contract());
    my $sql = $engine->compile($engine->query->with_member('team_tree')->select('name'))->sql;
    like($sql, qr/"team_tree" \("id", "parent_id", "name", "selecto_depth"\)/, 'depth column is declared');
    like($sql, qr/1 AS "selecto_depth"/, 'anchor starts at level 1');
    like($sql, qr/\("p_team_tree"\."selecto_depth" \+ 1\) AS "selecto_depth"/, 'step increments the level');
    like($sql, qr/AND "p_team_tree"\."selecto_depth" < 100\)/, 'default bound is applied');
    my $bounded = member_engine(member_contract(max_depth => 7));
    like($bounded->compile($bounded->query->with_member('team_tree')->select('name'))->sql,
        qr/"selecto_depth" < 7\)/, 'declared max_depth is applied');
    for my $bad (0, -1, 'x', 10_001) {
        is(code_of(sub { my $e = member_engine(member_contract(max_depth => $bad));
            $e->compile($e->query->with_member('team_tree')->select('name')) }),
            'invalid_query_member', "max_depth $bad is rejected");
    }

    SKIP: {
        skip 'DBD::SQLite is not installed', 1 unless eval { require DBD::SQLite; 1 };
        my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, AutoCommit => 1});
        $dbh->do('CREATE TABLE teams(id integer primary key, parent_id integer, name text)');
        $dbh->do('CREATE TABLE people(id integer primary key, name text, tenant_id integer, team_id integer)');
        $dbh->do(q{INSERT INTO teams VALUES (1, 2, 'a'), (2, 1, 'b')});
        $dbh->do(q{INSERT INTO people VALUES (1, 'p', 1, 1)});
        my $contract = member_contract(max_depth => 6);
        $contract->{query_members}{ctes}{team_tree}{base}{filter} = ['eq', 'id', 1];
        my $sqlite = Selecto::Engine->new(domain => Selecto::Domain->parse($contract), adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        my $rows = $sqlite->all($sqlite->query->with_member('team_tree')->select('id', 'team_tree.selecto_depth'))->{rows};
        is_deeply([sort map { $_->[1] } @$rows], [1, 3, 5], 'a cyclic hierarchy stops at max_depth');
    }
};

sub work_order_domain {
    my (%o) = @_;
    return Selecto::Domain->parse({
        schema_version => 1, name => 'Work Orders', domain_version => '1', domain_fingerprint => 'sha256:governance-hardening',
        source => {%{relation('work_orders', id => 'integer', site_id => 'integer', title => 'string', state => 'string')},
            tenant_field => 'site_id'},
        schemas => {}, joins => {},
        writes => {
            operations => {map { ($_ => {enabled => 1, ($_ eq 'update' ? (bulk => 1) : ())}) } qw(insert update upsert delete)},
            fields => {title => {insertable => 1, updatable => 1}, state => {insertable => 1, updatable => 1}},
            ($o{scoped} ? (scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}) : ()),
        },
    });
}

sub work_order_dbh {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE work_orders (id integer primary key, site_id integer not null, title text not null, state text)');
    $dbh->do(q{INSERT INTO work_orders VALUES (1, 10, 'mine', 'done'), (2, 20, 'theirs', 'done'), (3, 10, 'mine too', 'done')});
    return $dbh;
}

SKIP: {
    skip 'DBD::SQLite is not installed', 3 unless eval { require DBD::SQLite; 1 };

    subtest 'engine writes honor the domain required predicate' => sub {
        my $dbh = work_order_dbh();
        my $domain = work_order_domain()->with_required_predicate(Selecto::Expression->eq('site_id', 10));
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        my $update = sub {
            my ($id) = @_;
            return Selecto::Write::Command->new(operation => 'update', relation => 'work_orders',
                assignments => {title => 'changed'}, predicate => Selecto::Expression->eq('id', $id));
        };
        is(code_of(sub { $engine->execute_write($update->(2)) }), 'cardinality_mismatch', 'row outside the predicate is not updated');
        is($dbh->selectrow_array('SELECT title FROM work_orders WHERE id = 2'), 'theirs', 'other site row is intact');
        is(code_of(sub { $engine->execute_write($update->(1)) }), 'ok', 'row inside the predicate is updated');
        is(code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'delete', relation => 'work_orders',
            predicate => Selecto::Expression->eq('id', 2))) }), 'cardinality_mismatch', 'delete outside the predicate fails');
        is(code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'upsert', relation => 'work_orders',
            assignments => {id => 2, title => 'x', site_id => 10},
            metadata => {conflict_target => ['id'], upsert_update_fields => ['title']})) }),
            'query_enforcement_unsupported_operation', 'upsert is refused under a required predicate');

        # Without a tenant_field the required predicate is a read scope only;
        # writes stay governed by the write contract, as the shared protocol
        # specifies.
        my $plain_contract = work_order_domain()->as_contract;
        delete $plain_contract->{source}{tenant_field};
        my $read_scoped = Selecto::Domain->parse($plain_contract)
            ->with_required_predicate(Selecto::Expression->eq('site_id', 10));
        my $plain = Selecto::Engine->new(domain => $read_scoped, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        is(code_of(sub { $plain->execute_write($update->(2)) }), 'ok', 'a read scope without tenant_field does not govern writes');
    };

    subtest 'API writes accept an engine-held tenant scope' => sub {
        my $dbh = work_order_dbh();
        my $engine = Selecto::Engine->new(domain => work_order_domain(scoped => 1),
            adapter => Selecto->adapter(sqlite => (dbh => $dbh)), scope => {tenant => 10});
        is(code_of(sub { $handler->write($engine, {operation => 'update', assignments => {title => 'api'},
            filters => [{field => 'id', op => 'eq', value => 1}]}) }), 'ok', 'engine-scoped write is accepted');
        is(code_of(sub { $handler->write($engine, {operation => 'update', assignments => {title => 'api'},
            filters => [{field => 'id', op => 'eq', value => 2}]}) }), 'cardinality_mismatch', 'other tenant row is not matched');
        my $unscoped = Selecto::Engine->new(domain => work_order_domain(scoped => 1),
            adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        is(code_of(sub { $handler->write($unscoped, {operation => 'update', assignments => {title => 'api'},
            filters => [{field => 'id', op => 'eq', value => 1}]}) }), 'missing_tenant_scope', 'an engine without a tenant still fails closed');
    };

    subtest 'API cardinality errors do not report matched row counts' => sub {
        my $dbh = work_order_dbh();
        my $engine = Selecto::Engine->new(domain => work_order_domain(scoped => 1),
            adapter => Selecto->adapter(sqlite => (dbh => $dbh)), scope => {tenant => 10});
        my $api = Selecto::API->new(domain => $engine->domain);
        my $write = sub {
            my ($body) = @_;
            my $out;
            return eval { $out = $handler->write($engine, $body); 1 } ? ['ok', $out]
                : ['error', {code => $@->code, message => $@->message, details => $@->details, status => 422}];
        };
        my $response = $api->request({method => 'POST', path => '/api/v1/selecto/write',
            body => {operation => 'update', assignments => {title => 'x'},
                filters => [{field => 'state', op => 'eq', value => 'done'}], expected_count => 1}},
            {write => $write});
        my $body = JSON::PP->new->decode($response->{body});
        is($body->{error}{code}, 'cardinality_mismatch', 'mismatch is reported');
        ok(!exists $body->{error}{details}{actual}, 'actual row count is withheld');
        is($body->{error}{details}{expected}, 1, 'expected count is still reported');
    };
}

done_testing;
