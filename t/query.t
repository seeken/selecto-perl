use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();

my $dbh = TestSelecto::DBH->new;
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $engine = Selecto::Engine->new(domain => TestSelecto::people_domain(), adapter => $adapter);
ok(!$engine->query->can('from'), 'query API has no root-level from operation');
eval { Selecto::Query->new(from => 'other_people') };
is($@->code, 'invalid_query', 'query constructor rejects a root override');

my $other_domain = Selecto::Domain->new(
    name => 'Archived people',
    table => 'archived_people',
    fields => { id => 'integer', name => 'string' },
);
my $other_engine = Selecto::Engine->new(domain => $other_domain, adapter => $adapter);
my $rootless_query = Selecto::Query->new->select('id');
like($engine->compile($rootless_query)->sql, qr/FROM "people" AS "s0"/,
    'compiler reads the first root from its domain');
like($other_engine->compile($rootless_query)->sql, qr/FROM "archived_people" AS "s0"/,
    'the same query intent takes a different root from a different domain');

my $base = $engine->query->select('id', 'name');
my $filtered = $base->where(Selecto::Expression->eq('name', q{O'Brien}));
ok(!defined($base->predicate), 'query builder leaves the original query unchanged');
my $statement = $engine->compile($filtered);
like($statement->sql, qr/"s0"\."name" = \$1/, 'predicate is compiled with a PostgreSQL placeholder');
unlike($statement->sql, qr/O'Brien/, 'value is not interpolated into SQL');
is_deeply($statement->params, [q{O'Brien}], 'value is carried separately');

my $active_domain = Selecto::Domain->new(
    name => 'Active people',
    table => 'people',
    fields => { id => 'integer', status => 'string' },
    required_predicate => Selecto::Expression->eq('status', 'active'),
);
my $active_engine = Selecto::Engine->new(domain => $active_domain, adapter => $adapter);
my $active_statement = $active_engine->compile(
    $active_engine->query->select('id')->where(Selecto::Expression->eq('id', 7)));
like($active_statement->sql, qr/"s0"\."status" = \$1/,
    'domain-required predicate constrains the compiled read');
like($active_statement->sql, qr/"s0"\."id" = \$2/,
    'caller predicate remains part of the compiled read');
is_deeply($active_statement->params, ['active', 7],
    'required and caller predicates preserve deterministic parameter order');

my $comparisons = $engine->query
    ->select('name')
    ->where(Selecto::Expression->all([
        Selecto::Expression->ne('name', 'Retired'),
        Selecto::Expression->lt('id', 100),
        Selecto::Expression->lte('id', 99),
        Selecto::Expression->between('id', 10, 20),
    ]));
my $comparison_statement = $engine->compile($comparisons);
like($comparison_statement->sql, qr/"s0"\."name" <> \$1/, 'not-equal comparison is governed');
like($comparison_statement->sql, qr/"s0"\."id" < \$2/, 'less-than comparison is governed');
like($comparison_statement->sql, qr/"s0"\."id" <= \$3/,
    'less-than-or-equal comparison is governed');
like($comparison_statement->sql, qr/"s0"\."id" BETWEEN \$4 AND \$5/,
    'between comparison is governed');
is_deeply($comparison_statement->params, ['Retired', 100, 99, 10, 20],
    'all comparison values remain bound separately');

my $join_engine = Selecto::Engine->new(domain => TestSelecto::orders_domain(), adapter => $adapter);
my $grouped = $join_engine->query->select(
    Selecto::Expression->field('person.name')->as('person_name'),
    Selecto::Expression->count->as('order_count'),
)->group_by('person.name')->order_by('person.name');
my $grouped_statement = $join_engine->compile($grouped);
like($grouped_statement->sql, qr/LEFT JOIN "people" AS "j_person"/, 'referenced association creates one join');
like($grouped_statement->sql, qr/COUNT\(\*\)/, 'aggregate is compiled');
like($grouped_statement->sql, qr/GROUP BY "j_person"\."name"/, 'joined group is validated and compiled');
is_deeply($grouped_statement->columns, ['person_name', 'order_count'], 'stable result columns use aliases');

my $deep_domain = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Deep orders',
    source => {
        source_table => 'orders', primary_key => 'id',
        fields => [qw(id person_id)],
        columns => {id => {type => 'integer'}, person_id => {type => 'integer'}},
        associations => {
            person => {queryable => 'people', owner_key => 'person_id', related_key => 'id'},
        },
    },
    schemas => {
        people => {
            source_table => 'people', primary_key => 'id', fields => [qw(id region_id name)],
            columns => {
                id => {type => 'integer'}, region_id => {type => 'integer'},
                name => {type => 'string'},
            },
            associations => {
                region => {queryable => 'regions', owner_key => 'region_id', related_key => 'id'},
            },
        },
        regions => {
            source_table => 'regions', primary_key => 'id', fields => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}},
            associations => {},
        },
    },
    joins => {person => {type => 'left'}, 'person.region' => {type => 'inner'}},
});
my $deep_engine = Selecto::Engine->new(domain => $deep_domain, adapter => $adapter);
my $deep_statement = $deep_engine->compile(
    $deep_engine->query
        ->select('id', Selecto::Expression->field('person.region.name')->as('region'))
        ->where(Selecto::Expression->eq('person.region.name', 'Mountain'))
        ->order_by('person.region.name')
);
like($deep_statement->sql,
    qr/LEFT JOIN "people" AS "j_person" ON "s0"\."person_id" = "j_person"\."id"/,
    'deep paths join their first relationship exactly once');
like($deep_statement->sql,
    qr/INNER JOIN "regions" AS "j_person__region" ON "j_person"\."region_id" = "j_person__region"\."id"/,
    'deep paths join each later relationship from its exact parent alias');
like($deep_statement->sql,
    qr/WHERE "j_person__region"\."name" = \$1 ORDER BY "j_person__region"\."name" ASC/,
    'deep relationship fields work consistently in predicates and ordering');
is_deeply($deep_statement->params, ['Mountain'],
    'deep relationship predicates remain parameterized');

my $collision_domain = Selecto::Domain->new(
    name => 'Collision-safe deep aliases',
    table => 'roots',
    fields => {id => 'integer', a_id => 'integer', direct_id => 'integer'},
    associations => {
        a => {
            table => 'as', fields => {id => 'integer', b_id => 'integer'},
            owner_key => 'a_id', related_key => 'id',
            associations => {
                b => {
                    table => 'bs', fields => {id => 'integer', name => 'string'},
                    owner_key => 'b_id', related_key => 'id',
                },
            },
        },
        a__b => {
            table => 'direct_bs', fields => {id => 'integer', name => 'string'},
            owner_key => 'direct_id', related_key => 'id',
        },
    },
);
my $collision_engine = Selecto::Engine->new(domain => $collision_domain, adapter => $adapter);
my $collision_sql = $collision_engine->compile(
    $collision_engine->query->select('a.b.name', 'a__b.name')
)->sql;
like($collision_sql, qr/AS "j_path_1_a_1_b"/, 'deep alias collisions use an injective path encoding');
like($collision_sql, qr/AS "j_path_4_a__b"/, 'single-hop aliases cannot collide with encoded deep paths');
unlike($collision_sql, qr/AS "j_a__b"/, 'the ambiguous alias is never emitted');

my $rollup = $join_engine->query->select(
    Selecto::Expression->field('person.name')->as('person_name'),
    Selecto::Expression->field('total')->as('total'),
    Selecto::Expression->count->as('order_count'),
    Selecto::Expression->grouping('person.name', 'total')->as('__selecto_rollup_grouping'),
)->group_by_rollup('person.name', 'total')
    ->order_by('person.name')
    ->order_by('total');
my $joined_rollup_statement = $join_engine->compile($rollup);
like(
    $joined_rollup_statement->sql,
    qr/GROUPING\("j_person"\."name", "s0"\."total"\).*GROUP BY ROLLUP \("j_person"\."name", "s0"\."total"\)/,
    'governed rollup compiles grouping metadata and hierarchical grouping sets',
);
like(
    $joined_rollup_statement->sql,
    qr/\ASELECT \* FROM \(SELECT .*\) AS rollupfix ORDER BY 1 ASC NULLS FIRST, 2 ASC NULLS FIRST\z/,
    'PostgreSQL 17-and-older rollups use the positional outer-sort compatibility wrapper',
);
is_deeply(
    $joined_rollup_statement->columns,
    [qw(person_name total order_count __selecto_rollup_grouping)],
    'rollup grouping metadata has a stable result alias',
);
ok($adapter->supports('rollup'), 'PostgreSQL reports its implemented rollup capability');

my $line_domain = Selecto::Domain->new(
    name => 'Invoices',
    table => 'invoices',
    fields => {id => 'integer', reference => 'string'},
    associations => {
        lines => {
            table => 'invoice_lines',
            fields => {id => 'integer', invoice_id => 'integer', sku => 'string'},
            owner_key => 'id',
            related_key => 'invoice_id',
            target_primary_key => 'id',
            cardinality => 'many',
            join_type => 'left',
        },
    },
);
my $line_engine = Selecto::Engine->new(domain => $line_domain, adapter => $adapter);
my $line_statement = $line_engine->compile(
    $line_engine->query->select(
        'id',
        Selecto::Expression->related_collection('lines', ['sku'])->as('lines'),
    )
);
like $line_statement->sql,
    qr{COALESCE\(\(SELECT JSON_AGG\(JSON_BUILD_OBJECT\('sku', "c_lines"\."sku"\) ORDER BY "c_lines"\."id"\) FROM "invoice_lines" AS "c_lines" WHERE "c_lines"\."invoice_id" = "s0"\."id"\), '\[\]'::json\)},
    'a to-many selection compiles as a correlated ordered JSON collection';
unlike $line_statement->sql, qr{JOIN "invoice_lines"},
    'a related collection does not multiply outer result rows';

my $flag_domain = Selecto::Domain->parse({
    schema_version => 1,
    domain_version => '1.0.0',
    name => 'Flagged invoices',
    source => {
        source_table => 'invoices', primary_key => 'id',
        fields => [qw(id rush)],
        columns => {
            id => {type => 'integer'},
            rush => {
                type => 'boolean',
                computed => {kind => 'association_exists', association => 'rush_flags'},
            },
        },
        associations => {
            rush_flags => {
                queryable => 'flags', owner_key => 'id', related_key => 'invoice_id',
                cardinality => 'many', where => {type => 'R'},
            },
        },
    },
    schemas => {
        flags => {
            source_table => 'invoice_flags', primary_key => 'id',
            fields => [qw(id invoice_id type)],
            columns => {
                id => {type => 'integer'}, invoice_id => {type => 'integer'},
                type => {type => 'string'},
            },
            associations => {},
        },
    },
    joins => {rush_flags => {type => 'left'}},
}, strict => 1);
my $flag_engine = Selecto::Engine->new(domain => $flag_domain, adapter => $adapter);
my $flag_statement = $flag_engine->compile(
    $flag_engine->query->select('id', 'rush')->where(
        Selecto::Expression->eq('rush', 1)
    ),
);
like $flag_statement->sql,
    qr{SELECT "s0"\."id", EXISTS \(SELECT 1 FROM "invoice_flags" AS "e_rush_flags" WHERE "e_rush_flags"\."invoice_id" = "s0"\."id" AND "e_rush_flags"\."type" = \$1\).*WHERE EXISTS \(SELECT 1 FROM "invoice_flags" AS "e_rush_flags" WHERE "e_rush_flags"\."invoice_id" = "s0"\."id" AND "e_rush_flags"\."type" = \$2\) = \$3}s,
    'association-exists computed fields compile for both display and filtering';
unlike $flag_statement->sql, qr{LEFT JOIN "invoice_flags"},
    'association-exists fields do not denormalize root rows';
is_deeply $flag_statement->params, ['R', 'R', 1],
    'association-exists constants and filter values remain bound parameters';

my $through_domain = Selecto::Domain->new(
    name => 'Tenant invoice tags',
    table => 'invoices',
    primary_key => 'id',
    tenant_field => 'tenant_id',
    fields => {id => 'integer', tenant_id => 'integer', reference => 'string'},
    associations => {
        tags => {
            table => 'tags',
            fields => {id => 'integer', tenant_id => 'integer', label => 'string'},
            owner_key => 'id',
            related_key => 'id',
            target_primary_key => 'id',
            cardinality => 'many',
            join_type => 'left',
            through => {
                table => 'invoice_tags',
                owner_key => 'invoice_id',
                related_key => 'tag_id',
                source_scope_key => 'tenant_id',
                through_scope_key => 'tenant_id',
                target_scope_key => 'tenant_id',
                where => {type => 'E'},
                target_key_cast => 'string',
            },
        },
        notes => {
            table => 'invoice_notes',
            fields => {
                id => 'integer', invoice_id => 'integer', tenant_id => 'integer',
                event_id => 'integer', body => 'string',
            },
            owner_key => 'id', related_key => 'invoice_id', target_primary_key => 'id',
            cardinality => 'many', join_type => 'left',
            source_scope_key => 'tenant_id', target_scope_key => 'tenant_id',
            where => {event_id => 6},
        },
    },
);
my $through_engine = Selecto::Engine->new(domain => $through_domain, adapter => $adapter);
my $through_join = $through_engine->compile(
    $through_engine->query->select('id', 'tags.label')
);
like(
    $through_join->sql,
    qr{LEFT JOIN \("invoice_tags" AS "t_tags" INNER JOIN "tags" AS "j_tags" ON "t_tags"\."tag_id" = CAST\("j_tags"\."id" AS VARCHAR\) AND "t_tags"\."tenant_id" = "j_tags"\."tenant_id"\) ON "s0"\."id" = "t_tags"\."invoice_id" AND "t_tags"\."type" = \$1 AND "s0"\."tenant_id" = "t_tags"\."tenant_id"},
    'a through association preserves roots while enforcing bridge-to-target scope',
);
is_deeply($through_join->params, ['E'],
    'through association constants remain bound parameters');
my $through_collection = $through_engine->compile(
    $through_engine->query->select(
        'id',
        Selecto::Expression->related_collection('tags', ['label'])->as('tags'),
    )
);
like(
    $through_collection->sql,
    qr{FROM "invoice_tags" AS "ct_tags" INNER JOIN "tags" AS "c_tags" ON "ct_tags"\."tag_id" = CAST\("c_tags"\."id" AS VARCHAR\) AND "ct_tags"\."tenant_id" = "c_tags"\."tenant_id" WHERE "ct_tags"\."invoice_id" = "s0"\."id" AND "ct_tags"\."tenant_id" = "s0"\."tenant_id" AND "ct_tags"\."type" = \$1},
    'a related collection traverses its keyless bridge without multiplying roots',
);
is_deeply($through_collection->params, ['E'],
    'related through collection constants remain bound parameters');
my $direct_scoped_join = $through_engine->compile(
    $through_engine->query->select('id', 'notes.body')
);
like(
    $direct_scoped_join->sql,
    qr{LEFT JOIN "invoice_notes" AS "j_notes" ON "s0"\."id" = "j_notes"\."invoice_id" AND "j_notes"\."event_id" = \$1 AND "s0"\."tenant_id" = "j_notes"\."tenant_id"},
    'a direct association enforces source-to-target scope in its join',
);
is_deeply($direct_scoped_join->params, [6],
    'direct association constants remain bound parameters');
my $direct_scoped_collection = $through_engine->compile(
    $through_engine->query->select(
        'id', Selecto::Expression->related_collection('notes', ['body'])->as('notes'),
    )
);
like(
    $direct_scoped_collection->sql,
    qr{FROM "invoice_notes" AS "c_notes" WHERE "c_notes"\."invoice_id" = "s0"\."id" AND "c_notes"\."tenant_id" = "s0"\."tenant_id" AND "c_notes"\."event_id" = \$1},
    'a direct related collection enforces source-to-target scope',
);
is_deeply($direct_scoped_collection->params, [6],
    'direct related collection constants remain bound parameters');

my $dimension_display = Selecto::Expression->dimension_display('person.name', 'person_id');
my $dimension_rollup = $join_engine->query->select(
    $dimension_display->as('person'),
    Selecto::Expression->field('person_id')->as('__person_key'),
    Selecto::Expression->count->as('order_count'),
    Selecto::Expression->grouping('person_id')->as('__selecto_rollup_grouping'),
)->group_by_rollup('person_id')->order_by($dimension_display);
my $dimension_statement = $join_engine->compile($dimension_rollup);
like $dimension_statement->sql,
    qr/CASE WHEN GROUPING\("s0"\."person_id"\) = 1 THEN NULL ELSE MIN\("j_person"\."name"\) END AS "person"/,
    'a star-dimension label is null only when its key is rolled up';
like $dimension_statement->sql, qr/GROUP BY ROLLUP \("s0"\."person_id"\)/,
    'a star-dimension query groups by the stable fact key';
like $dimension_statement->sql,
    qr/ORDER BY 4 DESC, 1 ASC NULLS LAST\z/,
    'a one-dimension rollup sorts its total first and names alphabetically';

{
    package TestSelecto::PG18DBH;
    our @ISA = ('TestSelecto::DBH');
    sub selectrow_array { return 180000 }
}
my $pg18_adapter = Selecto::PostgreSQL->new(dbh => TestSelecto::PG18DBH->new);
my $pg18_engine = Selecto::Engine->new(
    domain => TestSelecto::orders_domain(), adapter => $pg18_adapter
);
my $pg18_rollup_statement = $pg18_engine->compile($rollup);
unlike($pg18_rollup_statement->sql, qr/rollupfix/,
    'PostgreSQL 18 disables the compatibility wrapper');
like($pg18_rollup_statement->sql, qr/ORDER BY 1 ASC NULLS FIRST, 2 ASC NULLS FIRST\z/,
    'PostgreSQL 18 rollups retain positional NULLS FIRST hierarchy ordering');

my $forced_fix_adapter = Selecto::PostgreSQL->new(
    dbh => TestSelecto::PG18DBH->new, rollup_sort_fix => 1
);
my $forced_fix_engine = Selecto::Engine->new(
    domain => TestSelecto::orders_domain(), adapter => $forced_fix_adapter
);
like($forced_fix_engine->compile($rollup)->sql, qr/\) AS rollupfix ORDER BY/,
    'rollup_sort_fix can force the compatibility wrapper on');

my $disabled_fix_adapter = Selecto::PostgreSQL->new(
    dbh => TestSelecto::DBH->new, rollup_sort_fix => 0
);
my $disabled_fix_engine = Selecto::Engine->new(
    domain => TestSelecto::orders_domain(), adapter => $disabled_fix_adapter
);
unlike($disabled_fix_engine->compile($rollup)->sql, qr/rollupfix/,
    'rollup_sort_fix can explicitly disable the compatibility wrapper');

eval { Selecto::Query->new(grouping_mode => 'cube') };
is($@->code, 'invalid_query', 'unsupported grouping modes fail closed');

my $dated_domain = Selecto::Domain->new(
    name => 'Events',
    table => 'events',
    fields => { id => 'integer', occurred_on => 'date', name => 'string' },
);
my $dated_engine = Selecto::Engine->new(domain => $dated_domain, adapter => $adapter);
my $month = Selecto::Expression->datetime_format('occurred_on', 'month');
my $dated_statement = $dated_engine->compile(
    $dated_engine->query
        ->select($month->as('month'), Selecto::Expression->count->as('event_count'))
        ->group_by($month, 'name')
        ->order_by($month, 'asc')
        ->order_by('name', 'desc')
);
like($dated_statement->sql, qr/TO_CHAR\("s0"\."occurred_on", 'YYYY-MM'\) AS "month"/,
    'governed date format compiles in a selection');
like($dated_statement->sql, qr/GROUP BY TO_CHAR\("s0"\."occurred_on", 'YYYY-MM'\)/,
    'the same governed expression compiles for aggregate grouping');
like($dated_statement->sql,
    qr/ORDER BY TO_CHAR\("s0"\."occurred_on", 'YYYY-MM'\) ASC, "s0"\."name" DESC/,
    'ordered query intent retains multiple expressions and directions');

my $formatted_filter_statement = $dated_engine->compile(
    $dated_engine->query
        ->select('id')
        ->where(Selecto::Expression->eq($month, '2026-08'))
);
like($formatted_filter_statement->sql,
    qr/TO_CHAR\("s0"\."occurred_on", 'YYYY-MM'\) = \$1/,
    'comparison predicates accept governed expressions as their operand');

my $epoch_domain = Selecto::Domain->new(
    name => 'Epoch events',
    table => 'epoch_events',
    fields => { id => 'integer', occurred_at => 'epoch_datetime' },
);
my $epoch_engine = Selecto::Engine->new(domain => $epoch_domain, adapter => $adapter);
my $epoch_time = Selecto::Expression->epoch_datetime('occurred_at');
my $epoch_month = Selecto::Expression->datetime_format($epoch_time, 'month');
my $epoch_statement = $epoch_engine->compile(
    $epoch_engine->query
        ->select($epoch_month->as('month'))
        ->where(Selecto::Expression->gte($epoch_time, '2026-08-01T00:00')),
);
like $epoch_statement->sql,
    qr/TO_CHAR\(TO_TIMESTAMP\("s0"\."occurred_at"\), 'YYYY-MM'\) AS "month"/,
    'epoch datetime fields format through PostgreSQL timestamps';
like $epoch_statement->sql,
    qr/TO_TIMESTAMP\("s0"\."occurred_at"\) >= \$1/,
    'epoch datetime filters compare against a timestamp expression';
is_deeply $epoch_statement->params, ['2026-08-01T00:00'],
    'epoch datetime filter values remain bound parameters';

my $numeric_domain = Selecto::Domain->new(
    name => 'Inventory',
    table => 'inventory',
    fields => { category => 'string', quantity => 'integer', active => 'boolean' },
);
my $numeric_engine = Selecto::Engine->new(domain => $numeric_domain, adapter => $adapter);
my $quantity_bucket = Selecto::Expression->bucket('quantity', {
    kind => 'numeric_ranges',
    ranges => [
        { minimum => 0, maximum => 9, label => '0-9' },
        { minimum => 10, maximum => undef, label => '10+' },
    ],
});
my $bucket_statement = $numeric_engine->compile(
    $numeric_engine->query->select(
        $quantity_bucket->as('quantity_band'),
        Selecto::Expression->avg('quantity')->as('average_quantity'),
        Selecto::Expression->count_distinct('quantity')->as('distinct_quantities'),
        Selecto::Expression->count_bucket('quantity', 0, 9)->as('low_quantity'),
        Selecto::Expression->true_count('active')->as('active_count'),
    )->group_by($quantity_bucket)
);
like($bucket_statement->sql, qr/CASE WHEN "s0"\."quantity" >= \$1 AND "s0"\."quantity" <= \$2 THEN \$3/,
    'governed numeric range bucket compiles as a CASE expression');
like($bucket_statement->sql, qr/AVG\("s0"\."quantity"\)/, 'average aggregate compiles');
like($bucket_statement->sql, qr/COUNT\(DISTINCT "s0"\."quantity"\)/,
    'count-distinct aggregate compiles');
like($bucket_statement->sql, qr/COUNT\(CASE WHEN "s0"\."quantity" >= \$7 AND "s0"\."quantity" <= \$8 THEN 1 END\)/,
    'numeric measure bucket compiles as a governed conditional count');
like($bucket_statement->sql, qr/COUNT\(CASE WHEN "s0"\."active" = TRUE THEN 1 END\)/,
    'boolean true-count aggregate compiles');
is_deeply([@{$bucket_statement->params}[0 .. 5]], [0, 9, '0-9', 10, '10+', 'Other'],
    'bucket boundaries and labels remain bound values');
is scalar(@{$bucket_statement->params}), 8,
    'an identical grouped bucket reuses its compiled selection placeholders';

my $rollup_statement = $numeric_engine->compile(
    $numeric_engine->query->select(
        $quantity_bucket->as('quantity_band'),
        Selecto::Expression->count->as('inventory_count'),
        Selecto::Expression->grouping($quantity_bucket)->as('rollup_grouping'),
    )->group_by_rollup($quantity_bucket)->order_by($quantity_bucket, 'asc')->limit(25)
);
like($rollup_statement->sql,
    qr/\ASELECT \* FROM \(SELECT .* GROUP BY ROLLUP \(CASE .*\)\) AS rollupfix ORDER BY 3 DESC, 1 ASC NULLS LAST LIMIT 25\z/s,
    'one-level rollups order the grand-total marker before values and real NULL buckets');
is scalar(@{$rollup_statement->params}), 6,
    'grouping metadata and positional rollup ordering reuse selected expression parameters';

my $age_bucket = Selecto::Expression->bucket('occurred_on', {
    kind => 'elapsed_days_ranges',
    ranges => [{ minimum => 0, maximum => 30, label => '0-30' }],
});
my $age_statement = $dated_engine->compile(
    $dated_engine->query->select(
        $age_bucket->as('age_band'),
        Selecto::Expression->count_bucket('occurred_on', 0, 30, 'elapsed_days')->as('recent_count'),
    )->group_by($age_bucket)
);
like($age_statement->sql, qr/CURRENT_DATE - DATE\("s0"\."occurred_on"\)/,
    'elapsed-day buckets remain a governed temporal expression');

my $bad_bucket = eval {
    $numeric_engine->compile($numeric_engine->query->select(
        Selecto::Expression->bucket('quantity', { kind => 'raw_sql', ranges => [] })
    ));
    1;
};
ok(!$bad_bucket, 'arbitrary bucket kinds fail closed');
is($@->code, 'invalid_query', 'rejected bucket kind uses the governed query error');

my $bad_format = eval {
    $dated_engine->compile($dated_engine->query->select(
        Selecto::Expression->datetime_format('occurred_on', q{YYYY'); DROP TABLE events; --})
    ));
    1;
};
ok(!$bad_format, 'arbitrary datetime formats fail closed');
is($@->code, 'invalid_query', 'rejected datetime format uses the governed query error');

my $values = ['open'];
my $membership = Selecto::Expression->in('name', $values);
push @$values, 'closed';
my $arguments = $membership->arguments;
push @{$arguments->[1]}, 'mutated-copy';
my $membership_statement = $engine->compile($engine->query->select('id')->where($membership));
is_deeply($membership_statement->params, ['open'], 'expression values are isolated from caller and accessor mutation');

eval { $engine->query->select('id')->order_by('id', 'sideways') };
is($@->code, 'invalid_query', 'invalid order direction fails closed');

done_testing;
