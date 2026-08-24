use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;

my $adapter = Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new);
my $engine = Selecto::Engine->new(
    domain => TestSelecto::orders_domain(),
    adapter => $adapter,
);

my $open = $engine->query
    ->select('id', 'total')
    ->where(Selecto::Expression->eq('total', 10));
my $closed = $engine->query
    ->select('id', 'total')
    ->where(Selecto::Expression->eq('total', 20));
my $held = $engine->query
    ->select('id', 'total')
    ->where(Selecto::Expression->eq('total', 30));
my $set_statement = $engine->compile(
    $open->union_all($closed)->intersect($held)->order_by('id')->limit(10),
);
like(
    $set_statement->sql,
    qr/SELECT \* FROM \(SELECT .* WHERE .* = \$1 UNION ALL SELECT .* WHERE .* = \$2\) AS "__selecto_set_left_2" INTERSECT SELECT .* WHERE .* = \$3 ORDER BY 1 ASC LIMIT 10/,
    'mixed set operations preserve builder order with outer ordering and pagination',
);
is_deeply($set_statement->params, [10, 20, 30],
    'set operands retain deterministic parameter order');
ok($adapter->supports('set_operations'), 'PostgreSQL declares set-operation support');

for my $case (
    [union => 'UNION'],
    [intersect => 'INTERSECT'],
    [except => 'EXCEPT'],
) {
    my ($method, $keyword) = @$case;
    my $statement = $engine->compile($open->$method($closed));
    like($statement->sql, qr/\Q $keyword \E/, "$keyword has a direct portable query operation");
    is_deeply($statement->params, [10, 20], "$keyword retains operand parameter order");
}

eval { $open->except($closed, all => 1) };
is($@->code, 'invalid_query', 'non-portable EXCEPT ALL fails before SQL compilation');

eval { $open->union($closed, raw => 1) };
is($@->code, 'invalid_query', 'unknown set-operation options fail closed');

eval {
    Selecto::Query->new(set_operations => [{
        operation => 'except', all => 1, query => $closed,
    }]);
};
is($@->code, 'invalid_query', 'direct query construction cannot bypass portable set semantics');

eval {
    Selecto::Query->new(set_operations => [{
        operation => 'union', query => $closed->order_by('id'),
    }]);
};
is($@->code, 'invalid_query', 'direct query construction cannot smuggle ordered set operands');

eval { $open->union($closed)->where(Selecto::Expression->eq('id', 7)) };
is($@->code, 'invalid_query', 'structural mutations after a set operation fail closed');

my $wrong_width = $engine->query->select('id');
eval { $engine->compile($open->union($wrong_width)) };
is($@->code, 'invalid_query', 'set operands with different projection widths are rejected');

eval { $open->union($closed->order_by('id')->limit(1)) };
is($@->code, 'invalid_query', 'ordered or paginated set operands fail before ambiguous SQL is emitted');

my $running_total = Selecto::Expression->window_sum(
    'total',
    partition_by => ['person_id'],
    order_by => [['id', 'asc']],
    frame => {
        type => 'rows',
        start => 'unbounded_preceding',
        end => 'current_row',
    },
)->as('running_total');
my $window_statement = $engine->compile(
    $engine->query->select(
        'id',
        Selecto::Expression->row_number(order_by => [['id', 'asc']])->as('row_number'),
        Selecto::Expression->lag('total', 1, undef, order_by => [['id', 'asc']])->as('previous_total'),
        $running_total,
    ),
);
like($window_statement->sql,
    qr/ROW_NUMBER\(\) OVER \(ORDER BY "s0"\."id" ASC\) AS "row_number"/,
    'row-number windows compile from governed order fields');
like($window_statement->sql,
    qr/LAG\("s0"\."total", \$1\) OVER \(ORDER BY "s0"\."id" ASC\) AS "previous_total"/,
    'window function scalar arguments remain parameters');
like($window_statement->sql,
    qr/SUM\("s0"\."total"\) OVER \(PARTITION BY "s0"\."person_id" ORDER BY "s0"\."id" ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW\)/,
    'partitioned framed aggregate windows compile portably');
is_deeply($window_statement->params, [1], 'window offsets are not interpolated');
ok($adapter->supports('window_functions'), 'PostgreSQL declares window support');

my $count_window = $engine->compile(
    $engine->query->select(
        Selecto::Expression->window('count', [], partition_by => ['person_id'])->as('partition_count'),
    ),
);
like($count_window->sql, qr/COUNT\(\*\) OVER \(PARTITION BY "s0"\."person_id"\)/,
    'zero-argument window count emits portable COUNT star syntax');

eval {
    $engine->compile($engine->query->select(
        Selecto::Expression->window('rank', [1], order_by => ['id']),
    ));
};
is($@->code, 'invalid_query', 'window function arity is validated before SQL execution');

eval {
    $engine->compile($engine->query->select(
        Selecto::Expression->window_sum(
            'total', order_by => ['id'],
            frame => {type => 'rows', start => {following => 2}, end => 'current_row'},
        ),
    ));
};
is($@->code, 'invalid_query', 'window frame boundaries must be in semantic order');

eval { Selecto::Expression->row_number(partion_by => ['id']) };
is($@->code, 'invalid_query', 'unknown window options fail instead of being silently ignored');

my $search_statement = $engine->compile(
    $engine->query
        ->select(
            'id',
            Selecto::Expression->text_rank(['person.name'], 'urgent order',
                configuration => 'english', mode => 'websearch')->as('rank'),
        )
        ->where(Selecto::Expression->text_search(['person.name'], 'urgent order',
            configuration => 'english', mode => 'websearch'))
        ->order_by(Selecto::Expression->text_rank(['person.name'], 'urgent order',
            configuration => 'english', mode => 'websearch'), 'desc'),
);
like($search_statement->sql,
    qr/TS_RANK\(TO_TSVECTOR\('english', COALESCE\(CAST\("j_person"\."name" AS TEXT\), ''\)\), WEBSEARCH_TO_TSQUERY\('english', \$1\)\)/,
    'PostgreSQL full-text ranking uses only governed fields and allowlisted functions');
like($search_statement->sql,
    qr/TO_TSVECTOR\('english'.*\) @@ WEBSEARCH_TO_TSQUERY\('english', \$2\)/,
    'PostgreSQL full-text predicates remain parameterized');
is_deeply($search_statement->params, ['urgent order', 'urgent order', 'urgent order'],
    'selection, predicate, and ordering text-search values are independently bound');
ok($adapter->supports('text_search'), 'PostgreSQL declares full-text-search support');

eval {
    $engine->compile($engine->query->select(
        Selecto::Expression->text_rank(['person.name'], 'x',
            configuration => q{english'); DROP TABLE orders; --}),
    ));
};
is($@->code, 'invalid_query', 'arbitrary text-search configurations fail closed');

eval {
    $engine->compile($engine->query->select(
        Selecto::Expression->text_rank(['person.name'], []),
    ));
};
is($@->code, 'invalid_query', 'non-scalar full-text queries fail closed');

eval { Selecto::Expression->text_search(['person.name'], 'open', config => 'english') };
is($@->code, 'invalid_query', 'unknown full-text options fail instead of changing semantics');

my $sqlite = Selecto::SQLite->new(dbh => TestSelecto::DBH->new);
my $sqlite_engine = Selecto::Engine->new(domain => TestSelecto::orders_domain(), adapter => $sqlite);
eval {
    $sqlite_engine->compile(
        $sqlite_engine->query->select('id')->group_by_rollup('id'),
    );
};
is($@->code, 'unsupported_feature', 'unsupported dialect rollups fail at capability gating');
eval {
    $sqlite_engine->compile($sqlite_engine->query->select('id')->where(
        Selecto::Expression->text_search(['person.name'], 'open'),
    ));
};
is($@->code, 'invalid_query', 'unsupported dialect full-text search fails closed');

my $orders_domain = Selecto::Domain->new(
    name => 'JSON orders', table => 'orders',
    fields => {
        id => 'integer', customer_id => 'integer', payload => 'jsonb',
    },
);
my $events_domain = Selecto::Domain->new(
    name => 'Order events', table => 'order_events',
    fields => {id => 'integer', order_id => 'integer', kind => 'string'},
);
my $advanced_engine = Selecto::Engine->new(domain => $orders_domain, adapter => $adapter);
my $event_query = Selecto::Query->new
    ->select('order_id', 'kind')
    ->where(Selecto::Expression->eq('kind', 'status'));
my $cte_query = $advanced_engine->query
    ->with_cte(
        'recent_events', $events_domain, $event_query,
        columns => [qw(order_id kind)],
        join => {owner_key => 'id', related_key => 'order_id', type => 'left'},
    )
    ->select('id', 'recent_events.kind');
my $cte_statement = $advanced_engine->compile($cte_query);
like($cte_statement->sql,
    qr/\AWITH "recent_events" \("order_id", "kind"\) AS \(SELECT .* FROM "order_events" AS "s0" WHERE "s0"\."kind" = \$1\) SELECT/,
    'a governed CTE compiles before the domain-owned root query');
like($cte_statement->sql,
    qr/LEFT JOIN "recent_events" AS "recent_events" ON "s0"\."id" = "recent_events"\."order_id"/,
    'CTE output joins through an explicit governed key contract');
is_deeply($cte_statement->params, ['status'], 'CTE parameters precede main-query parameters');
ok($adapter->supports('cte'), 'PostgreSQL declares CTE support');
my $cte_state = $cte_query->ctes;
$cte_state->[0]{columns}[0] = 'mutated';
$cte_state->[0]{join}{owner_key} = 'mutated';
is_deeply($cte_query->ctes->[0]{columns}, [qw(order_id kind)],
    'CTE accessors do not expose mutable column state');
is($cte_query->ctes->[0]{join}{owner_key}, 'id',
    'CTE accessors do not expose mutable join contracts');

eval {
    $advanced_engine->compile(
        $advanced_engine->query
            ->with_cte(
                's0', $events_domain, $event_query,
                columns => [qw(order_id kind)],
                join => {owner_key => 'id', related_key => 'order_id'},
            )
            ->select('id', 's0.kind'),
    );
};
is($@->code, 'invalid_query', 'query sources cannot shadow the compiler root alias');

my $employees = Selecto::Domain->new(
    name => 'Employees', table => 'employees',
    fields => {id => 'integer', manager_id => 'integer', name => 'string'},
);
my $anchor = Selecto::Query->new
    ->select(qw(id manager_id name))
    ->where(Selecto::Expression->is_null('manager_id'));
my $member = Selecto::Query->new->select(qw(id manager_id name));
my $employee_engine = Selecto::Engine->new(domain => $employees, adapter => $adapter);
my $recursive_statement = $employee_engine->compile(
    $employee_engine->query
        ->with_recursive_cte(
            'employee_tree', $employees, $anchor, $member,
            columns => [qw(id manager_id name)],
            join => {owner_key => 'id', related_key => 'id'},
            recursive_join => {owner_key => 'manager_id', related_key => 'id', type => 'inner'},
        )
        ->select('id', 'employee_tree.name'),
);
like($recursive_statement->sql, qr/\AWITH RECURSIVE "employee_tree"/,
    'recursive CTEs use the explicit recursive form');
like($recursive_statement->sql,
    qr/UNION ALL SELECT .* FROM "employees" AS "r_employee_tree" INNER JOIN "employee_tree" AS "p_employee_tree" ON "r_employee_tree"\."manager_id" = "p_employee_tree"\."id"/,
    'recursive members join the prior CTE row through governed identifiers');
ok($adapter->supports('recursive_cte'), 'PostgreSQL declares recursive CTE support');

eval {
    $employee_engine->query->with_recursive_cte(
        'bad_tree', $employees, $anchor, $member,
        columns => [qw(id manager_id name)],
        join => {owner_key => 'id', related_key => 'id'},
        recursive_join => {owner_key => 'manager_id', related_key => 'id', type => 'left'},
    );
};
is($@->code, 'invalid_query', 'recursive traversal cannot use a non-terminating left join');

my $lateral_statement = $advanced_engine->compile(
    $advanced_engine->query
        ->lateral_join(
            'events', $events_domain, $event_query,
            columns => [qw(order_id kind)],
            correlations => {order_id => 'id'},
            type => 'left',
        )
        ->select('id', 'events.kind')
        ->where(Selecto::Expression->eq('id', 7)),
);
like($lateral_statement->sql,
    qr/LEFT JOIN LATERAL \(SELECT .* FROM "order_events" AS "l_events" WHERE \("l_events"\."kind" = \$1\) AND \("l_events"\."order_id" = "s0"\."id"\)\) AS "events" ON TRUE/,
    'lateral subqueries correlate through explicit child-to-parent fields');
like($lateral_statement->sql, qr/WHERE "s0"\."id" = \$2\z/,
    'lateral parameters retain textual order before the outer predicate');
is_deeply($lateral_statement->params, ['status', 7],
    'lateral and outer values remain independently bound');
ok($adapter->supports('lateral_join'), 'PostgreSQL declares lateral-join support');
my $lateral_copy_query = $advanced_engine->query
    ->lateral_join(
        'events_copy', $events_domain, $event_query,
        columns => [qw(order_id kind)], correlations => {order_id => 'id'},
    );
my $lateral_state = $lateral_copy_query->lateral_joins;
$lateral_state->[0]{columns}[0] = 'mutated';
$lateral_state->[0]{correlations}{order_id} = 'mutated';
my $fresh_lateral_state = $lateral_copy_query->lateral_joins;
is_deeply($fresh_lateral_state->[0]{columns}, [qw(order_id kind)],
    'lateral accessors do not expose mutable projection state');
is($fresh_lateral_state->[0]{correlations}{order_id}, 'id',
    'lateral accessors do not expose mutable correlation state');

my $json_path = q{$.items[*]};
my $json_statement = $advanced_engine->compile(
    $advanced_engine->query
        ->json_rowset(
            'payload', 'items', {sku => 'string', quantity => 'integer'},
            path => $json_path,
        )
        ->select('id', 'items.sku', 'items.quantity')
        ->where(Selecto::Expression->eq('id', 9)),
);
like($json_statement->sql,
    qr/LEFT JOIN LATERAL JSONB_TO_RECORDSET\(JSONB_PATH_QUERY_ARRAY\("s0"\."payload"::jsonb, \$1::jsonpath\)\) AS "items" \("quantity" BIGINT, "sku" TEXT\) ON TRUE/,
    'JSON rowsets expose declared typed columns through a lateral source');
is_deeply($json_statement->params, [$json_path, 9],
    'JSON paths and outer predicates are bound in SQL order');
ok($adapter->supports('json_rowset'), 'PostgreSQL declares JSON-rowset support');
my $json_copy_query = $advanced_engine->query
    ->json_rowset('payload', 'items_copy', {sku => 'string'});
my $json_state = $json_copy_query->json_rowsets;
$json_state->[0]{columns}{sku} = 'hostile';
is(
    $json_copy_query->json_rowsets->[0]{columns}{sku},
    'string',
    'JSON-rowset accessors do not expose mutable type declarations',
);

eval {
    $advanced_engine->query->with_cte(
        'missing_child', $events_domain, $event_query,
        columns => [qw(order_id kind)],
        join => {owner_key => 'id', related_key => 'order_id'},
        depends_on => ['not_registered'],
    );
};
is($@->code, 'invalid_query', 'missing CTE dependencies fail before query mutation');

eval {
    $advanced_engine->query->json_rowset(
        'payload', 'bad_options', {sku => 'string'}, json_path => '$[*]',
    );
};
is($@->code, 'invalid_query', 'unknown advanced-source options fail at construction');

done_testing;
