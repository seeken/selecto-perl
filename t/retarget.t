use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Retarget ();
use lib 't/lib';
use TestSelecto;

my $E = 'Selecto::Expression';

sub code_of {
    my ($code) = @_;
    return eval { $code->(); 'ok' } // do {
        my $error = $@;
        blessed($error) && $error->isa('Selecto::Error') ? $error->code : die $error;
    };
}

sub relation {
    my ($table, $columns, %extra) = @_;
    return {
        source_table => $table, primary_key => 'id',
        fields => [sort keys %$columns],
        columns => {map { ($_ => {type => $columns->{$_}}) } keys %$columns},
        associations => {},
        %extra,
    };
}

sub contract {
    my (%extra) = @_;
    return {
        schema_version => 1, name => 'Events',
        source => relation('events',
            {id => 'integer', name => 'string', region => 'string', tenant_id => 'integer',
                status_code => 'string'},
            tenant_field => 'tenant_id',
            associations => {
                attendees => {queryable => 'attendee', owner_key => 'id', related_key => 'event_id'},
                active_attendees => {queryable => 'attendee', owner_key => 'id',
                    related_key => 'event_id', where => {active => 1}},
                status => {queryable => 'status', owner_key => 'status_code', related_key => 'code'},
            },
        ),
        schemas => {
            attendee => relation('attendees',
                {id => 'integer', event_id => 'integer', name => 'string', active => 'boolean',
                    tenant_id => 'integer'},
                tenant_field => 'tenant_id',
                associations => {
                    orders => {queryable => 'order', owner_key => 'id', related_key => 'attendee_id'},
                },
            ),
            order => relation('orders',
                {id => 'integer', attendee_id => 'integer', product_id => 'integer',
                    total => 'decimal', secret => 'string', tenant_id => 'integer'},
                tenant_field => 'tenant_id',
                associations => {
                    product => {queryable => 'product', owner_key => 'product_id', related_key => 'id'},
                },
            ),
            product => relation('products', {id => 'integer', name => 'string'}),
            status => {
                primary_key => 'code', fields => ['code', 'label'],
                columns => {code => {type => 'string'}, label => {type => 'string'}},
                values => [{code => 'open', label => 'Open'}],
            },
        },
        joins => {attendees => {type => 'left', joins => {orders => {type => 'inner'}}}},
        redact_fields => ['attendees.orders.secret'],
        %extra,
    };
}

my $domain = Selecto::Domain->parse(contract());
my $offline = bless {}, 'Offline::Handle';
my $pg = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $offline)));

subtest 'query state' => sub {
    my $query = $pg->query->select('name')->where($E->eq('region', 'west'))
        ->order_by('name')->limit(5)->retarget('attendees.orders');
    is_deeply($query->selections, [], 'retarget clears selections');
    is_deeply($query->orders, [], 'retarget clears ordering');
    is($query->limit_value, undef, 'retarget clears pagination');
    is($query->predicate, undef, 'the predicate moves into the context');
    my $spec = $query->retarget_spec;
    is($spec->{path}, 'attendees.orders', 'the path is kept');
    is($spec->{strategy}, 'in', 'in is the default strategy');
    is($spec->{context}->kind, 'eq', 'the earlier predicate is the context');
    is($pg->query->retarget_spec, undef, 'an ordinary query has no retarget');
    is(code_of(sub { $query->retarget('attendees') }), 'invalid_query', 'a query retargets once');
    is(code_of(sub { $pg->query->retarget('attendees', strategy => 'join') }), 'invalid_query',
        'only in and exists are strategies');
    is(code_of(sub { $pg->query->retarget('attendees', preserve_filters => 0) }), 'invalid_query',
        'the context cannot be switched off');
    is(code_of(sub { $pg->query->retarget('no such path!') }), 'invalid_query',
        'the path must be an association path');
    is(code_of(sub { $pg->query->with_member('x')->retarget('attendees') }), 'invalid_query',
        'root query sources must follow the retarget');
    is(code_of(sub { $pg->query->for_share->retarget('attendees') }), 'invalid_query',
        'a row-locked query cannot be retargeted');
};

subtest 'compiled shape' => sub {
    my $statement = $pg->compile($pg->query->where($E->eq('region', 'west'))
        ->retarget('attendees.orders')
        ->select('id', 'total', 'product.name')->where($E->gt('total', 10))
        ->order_by('total', 'desc')->limit(2));
    my $sql = $statement->sql;
    like($sql, qr/\ASELECT .* FROM "orders" AS "s0" LEFT JOIN "products" AS "j_product"/,
        'the target is the root and its own associations join from it');
    like($sql, qr/"s0"\."id" IN \(SELECT "j_attendees__orders"\."id" AS "attendees\.orders\.id" FROM "events" AS "r0" LEFT JOIN "attendees" AS "j_attendees" ON "r0"\."id" = "j_attendees"\."event_id" INNER JOIN "orders" AS "j_attendees__orders"/,
        'the context selects the target key through the declared path');
    like($sql, qr/WHERE \("s0"\."total" > \$1\) AND \("s0"\."id" IN \(.* WHERE "r0"\."region" = \$2\)\)/,
        'target filters and the context are both applied');
    like($sql, qr/ORDER BY "s0"\."total" DESC LIMIT 2\z/, 'ordering and pagination are kept');
    is_deeply($statement->params, [10, 'west'], 'parameters follow their placeholders');

    my $exists = $pg->compile($pg->query->where($E->eq('region', 'west'))
        ->retarget('attendees.orders', strategy => 'exists')->select('id'));
    like($exists->sql,
        qr/WHERE EXISTS \(SELECT .* WHERE \("r0"\."region" = \$1\) AND \("j_attendees__orders"\."id" = "s0"\."id"\)\)\z/,
        'exists correlates the context with the target key');

    my $hop_where = $pg->compile($pg->query->retarget('active_attendees')->select('id'));
    like($hop_where->sql, qr/LEFT JOIN "attendees" AS "j_active_attendees" ON .* AND "j_active_attendees"\."active" = \$1/,
        'a hop keeps its join conditions');

    my $grouped = $pg->compile($pg->query->retarget('attendees.orders')
        ->select('product.name', $E->count->as('orders'))->group_by('product.name'));
    like($grouped->sql, qr/GROUP BY "j_product"\."name"\z/, 'grouping applies to the target');
};

subtest 'governance and target requirements' => sub {
    is(code_of(sub { $pg->compile($pg->query->retarget('status')->select('code')) }),
        'unsupported_feature', 'a values relation cannot be a target');
    is(code_of(sub { $pg->compile($pg->query->retarget('attendees.nowhere')->select('id')) }),
        'unknown_association', 'an unknown path is rejected');

    my $governed = Selecto::Domain->parse(contract(retarget => {
        targets => {'attendees.orders' => {label => 'Orders', default_selected => ['id', 'total']}},
        default_target => 'attendees.orders',
    }));
    is_deeply($governed->retarget_config->{targets}{'attendees.orders'}{default_selected}, ['id', 'total'],
        'the retarget section is readable');
    my $engine = Selecto::Engine->new(domain => $governed,
        adapter => Selecto->adapter(postgresql => (dbh => $offline)));
    is(code_of(sub { $engine->compile($engine->query->retarget('attendees.orders')->select('id')) }),
        'ok', 'a declared target compiles');
    is(code_of(sub { $engine->compile($engine->query->retarget('attendees')->select('id')) }),
        'retarget_not_allowed', 'an undeclared target is refused when targets are declared');

    is(code_of(sub { Selecto::Domain->parse(contract(retarget => {default_target => 'attendees'})) }),
        'ok', 'a default target alone is accepted');
    my %bad = (
        'an unknown key' => {preserve_filters => 0},
        'a default outside the targets' => {targets => {attendees => {}}, default_target => 'attendees.orders'},
        'an unknown target field' => {targets => {attendees => {default_selected => ['missing']}}},
        'an unknown target path' => {targets => {nowhere => {}}},
        'a values target' => {targets => {status => {}}},
        'a non-string label' => {targets => {attendees => {label => ['x']}}},
    );
    for my $label (sort keys %bad) {
        isnt(code_of(sub { Selecto::Domain->parse(contract(retarget => $bad{$label})) }), 'ok',
            "the domain rejects $label");
    }
};

subtest 'derived target domain' => sub {
    my $target = Selecto::Retarget->target($domain, 'attendees.orders');
    my $orders = Selecto::Retarget->target_domain($domain, $target);
    is($orders->table, 'orders', 'the target relation is the root');
    is($orders->tenant_field, 'tenant_id', 'the target keeps its tenant field');
    ok($orders->field_metadata('secret')->{redacted}, 'path redactions are re-rooted');
    ok(!$orders->field_metadata('total')->{redacted}, 'other fields stay public');
    is($orders->resolve('product.name')->{association}->table, 'products',
        'the target keeps its own associations');

    my $legacy = TestSelecto::orders_domain();
    my $engine = Selecto::Engine->new(domain => $legacy,
        adapter => Selecto->adapter(postgresql => (dbh => $offline)));
    like($engine->compile($engine->query->where($E->gt('total', 5))->retarget('person')->select('name'))->sql,
        qr/\ASELECT "s0"\."name" FROM "people" AS "s0" WHERE "s0"\."id" IN \(SELECT "j_person"\."id" AS "person\.id" FROM "orders" AS "r0" LEFT JOIN "people" AS "j_person"/,
        'a directly constructed domain retargets through its associations');
};

subtest 'tenant scope' => sub {
    my $scoped = Selecto::Engine->new(domain => $domain, scope => {tenant => 7},
        adapter => Selecto->adapter(postgresql => (dbh => $offline)));
    my $statement = $scoped->compile($scoped->query->retarget('attendees.orders')->select('id'));
    like($statement->sql, qr/WHERE \("s0"\."tenant_id" = \$1\) AND \("s0"\."id" IN \(.* WHERE "r0"\."tenant_id" = \$2\)\)/,
        'the root tenant applies to the context and to a tenant-scoped target');
    is_deeply($statement->params, [7, 7], 'both tenant conditions bind the trusted tenant');

    my $product = $scoped->compile($scoped->query->retarget('attendees.orders.product')->select('name'));
    like($product->sql, qr/FROM "products" AS "s0" WHERE "s0"\."id" IN \(.* WHERE "r0"\."tenant_id" = \$1\)\z/,
        'a target without a tenant field is bounded by the scoped context');

    my $host = Selecto::Engine->new(
        domain => $domain->with_required_predicate($E->eq('region', 'west')),
        adapter => Selecto->adapter(postgresql => (dbh => $offline)),
    );
    is(code_of(sub { $host->compile($host->query->retarget('attendees.orders')->select('id')) }),
        'missing_tenant_scope', 'a scope that cannot reach a tenant-scoped target fails closed');
    is(code_of(sub { Selecto::QueryEnforcement->capture($domain,
        $pg->query->where($E->eq('id', 1))->retarget('attendees')) }),
        'invalid_query', 'query-enforced writes refuse a retargeted query');
};

SKIP: {
    skip 'DBD::SQLite is not installed', 1 unless eval { require DBD::SQLite; 1 };
    subtest 'executed results' => sub {
        my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do($_) for (
            'CREATE TABLE events (id integer primary key, name text, region text, tenant_id integer, status_code text)',
            'CREATE TABLE attendees (id integer primary key, event_id integer, name text, active boolean, tenant_id integer)',
            'CREATE TABLE orders (id integer primary key, attendee_id integer, product_id integer, total decimal, secret text, tenant_id integer)',
            'CREATE TABLE products (id integer primary key, name text)',
            q{INSERT INTO events VALUES (1, 'Expo', 'west', 1, 'open'), (2, 'Summit', 'east', 1, 'open'),
                (3, 'Elsewhere', 'west', 2, 'open')},
            q{INSERT INTO attendees VALUES (10, 1, 'Ann', 1, 1), (11, 1, 'Bob', 0, 1),
                (12, 2, 'Cy', 1, 1), (13, 3, 'Dee', 1, 2)},
            q{INSERT INTO orders VALUES (100, 10, 1, 25, 'a', 1), (101, 10, 2, 5, 'b', 1),
                (102, 11, 1, 40, 'c', 1), (103, 12, 1, 60, 'd', 1), (104, 13, 1, 70, 'e', 2),
                (105, 10, 2, 1, 'f', 2)},
            q{INSERT INTO products VALUES (1, 'Widget'), (2, 'Gadget')},
        );
        my $engine = Selecto::Engine->new(domain => $domain, scope => {tenant => 1},
            adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        my $ids = sub {
            my ($query) = @_;
            return [map { $_->[0] } @{$engine->all($query)->{rows}}];
        };
        my $west = $engine->query->where($E->eq('region', 'west'));
        for my $strategy (qw(in exists)) {
            is_deeply($ids->($west->retarget('attendees.orders', strategy => $strategy)
                ->select('id')->order_by('id')), [100, 101, 102],
                "$strategy: the context, the tenant, and the target tenant all apply");
            is_deeply($ids->($west->retarget('attendees.orders.product', strategy => $strategy)
                ->select('id')->order_by('id')), [1, 2],
                "$strategy: a target reached from several root rows appears once");
        }
        is_deeply($ids->($engine->query->where($E->eq('attendees.name', 'Ann'))
            ->retarget('attendees.orders')->select('id')->order_by('id')), [100, 101],
            'a filter on a path hop constrains that hop, as in the joined read');
        is_deeply($ids->($engine->query->where($E->any($E->eq('name', 'Summit'), $E->gt('attendees.orders.total', 30)))
            ->retarget('attendees.orders')->select('id')->order_by('id')), [102, 103],
            'the context accepts any predicate');
        is_deeply($ids->($west->retarget('active_attendees.orders')->select('id')->order_by('id')),
            [100, 101], 'hop conditions restrict reachability');
        is_deeply($ids->($west->retarget('attendees.orders')->select('id')->where($E->gt('total', 10))
            ->order_by('total', 'desc')->limit(1)), [102],
            'target filters, ordering, and pagination apply after the retarget');
        is_deeply($engine->all($west->retarget('attendees.orders')
            ->select('product.name', $E->count->as('orders'))->group_by('product.name')
            ->order_by('product.name'))->{rows}, [['Gadget', 1], ['Widget', 2]],
            'the target groups through its own associations');
    };
}

done_testing;
