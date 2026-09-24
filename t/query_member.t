use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;

sub code_of {
    my ($code) = @_;
    return eval { $code->(); 'ok' } // do {
        my $error = $@;
        blessed($error) && $error->isa('Selecto::Error') ? $error->code : die $error;
    };
}

sub relation {
    my ($table, %columns) = @_;
    return {
        source_table => $table, primary_key => 'id',
        fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns},
        associations => {},
    };
}

sub contract {
    my (%members) = @_;
    return {
        schema_version => 1, name => 'People',
        source => {
            %{relation('people', id => 'integer', name => 'string', team_id => 'integer', tags => 'array')},
            columns => {id => {type => 'integer'}, name => {type => 'string'},
                team_id => {type => 'integer'}, tags => {type => 'array', items => 'string'}},
        },
        schemas => {
            order => relation('orders', id => 'integer', person_id => 'integer', total => 'decimal', state => 'string'),
            team => relation('teams', id => 'integer', parent_id => 'integer', name => 'string'),
        },
        joins => {},
        query_members => {
            ctes => {
                order_totals => {
                    source => 'order',
                    query => {
                        select => ['person_id', {as => 'orders', aggregate => 'count'},
                            {as => 'spent', aggregate => 'sum', field => 'total'}],
                        filter => ['ne', 'state', 'void'],
                        group_by => ['person_id'],
                    },
                    join => {owner_key => 'id', related_key => 'person_id', type => 'left'},
                },
                team_tree => {
                    kind => 'recursive', source => 'team',
                    base => {select => ['id', 'parent_id', 'name', {as => 'depth', value => ['literal', 0, 'integer']}],
                        filter => ['is_null', 'parent_id']},
                    step => {select => ['id', 'parent_id', 'name',
                        {as => 'depth', value => ['add', ['previous', 'depth'], ['literal', 1]]}]},
                    step_join => {owner_key => 'parent_id', related_key => 'id'},
                    join => {owner_key => 'team_id', related_key => 'id', type => 'inner'},
                },
            },
            laterals => {
                latest_order => {
                    source => 'order',
                    query => {select => ['id', 'total'], order_by => [['id', 'desc']], limit => 1},
                    correlations => {person_id => 'id'},
                    join_type => 'left',
                },
            },
            unnests => {tag_rows => {array_field => 'tags', as => 'tag_rows', ordinality => 'position'}},
            %members,
        },
    };
}

my $domain = Selecto::Domain->parse(contract());
my $offline = bless {}, 'Offline::Handle';
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $offline)));

my $cte = $engine->compile($engine->query->with_member('order_totals')
    ->select('name', 'order_totals.orders', 'order_totals.spent')->order_by('name', 'asc'));
like($cte->sql, qr/\AWITH "order_totals" \("person_id", "orders", "spent"\) AS \(SELECT/, 'a CTE member compiles from data');
like($cte->sql, qr/LEFT JOIN "order_totals" AS "order_totals" ON "s0"\."id" = "order_totals"\."person_id"/,
    'the member join comes from the contract');
is_deeply($cte->params, ['void'], 'member filter values are bound');

my $tree = $engine->compile($engine->query->with_member('team_tree')->select('name', 'team_tree.depth'));
like($tree->sql, qr/WITH RECURSIVE "team_tree"/, 'a recursive member compiles');
like($tree->sql, qr/\("p_team_tree"\."depth" \+ CAST\(\$\d+ AS BIGINT\)\)/, 'previous reads the previous level');

like($engine->compile($engine->query->with_member('latest_order')->select('name', 'latest_order.total'))->sql,
    qr/LEFT JOIN LATERAL \(SELECT .* LIMIT 1\) AS "latest_order"/, 'a lateral member compiles');
like($engine->compile($engine->query->with_member('tag_rows')->select('name', 'tag_rows.value'))->sql,
    qr/UNNEST\("s0"\."tags"\) WITH ORDINALITY AS "tag_rows"/, 'an unnest member compiles');

is(code_of(sub { $engine->compile($engine->query->with_member('missing')->select('name')) }),
    'unknown_query_member', 'undeclared members are rejected');
is(code_of(sub { $engine->query->with_member('tag_rows')->with_member('tag_rows') }),
    'invalid_query', 'a member activates once');

my %bad = (
    'previous outside a recursive step' => {ctes => {bad => {source => 'order',
        query => {select => [{as => 'x', value => ['previous', 'id']}]},
        join => {owner_key => 'id', related_key => 'x'}}}},
    'unknown source' => {ctes => {bad => {source => 'nowhere', query => {select => ['id']},
        join => {owner_key => 'id', related_key => 'id'}}}},
    'unknown member field' => {ctes => {bad => {source => 'order', query => {select => ['missing']},
        join => {owner_key => 'id', related_key => 'missing'}}}},
    'raw sql key' => {ctes => {bad => {source => 'order', query => {select => ['id'], sql => 'now()'},
        join => {owner_key => 'id', related_key => 'id'}}}},
    'computed selection without alias' => {laterals => {bad => {source => 'order',
        query => {select => [{aggregate => 'count'}]}, correlations => {person_id => 'id'}}}},
);
for my $label (sort keys %bad) {
    isnt(code_of(sub { Selecto::Domain->parse(contract(%{$bad{$label}})) }), 'ok', "rejects $label");
}
is(code_of(sub { Selecto::Domain->parse(contract(values => {labels => {rows => []}})) }), 'ok',
    'groups this runtime does not execute are left for their runtime');

isnt(Selecto::Domain->parse(contract())->with_required_predicate(Selecto::Expression->eq('id', 1))->fingerprint,
    Selecto::Domain->parse(do { my $c = contract(); delete $c->{query_members}{unnests}; $c })
        ->with_required_predicate(Selecto::Expression->eq('id', 1))->fingerprint,
    'query members are part of the fingerprint');

done_testing;
