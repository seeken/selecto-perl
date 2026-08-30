use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::PostgreSQL ();

my $domain = Selecto::Domain->parse({
    schema_version => 1,
    domain_version => '1.0.0',
    name => 'Projects',
    source => {
        source_table => 'projects',
        primary_key => 'id',
        fields => [qw(id name status priority)],
        columns => {
            id => {type => 'integer'}, name => {type => 'string'},
            status => {type => 'string'}, priority => {type => 'integer'},
        },
        associations => {},
    },
    schemas => {},
    joins => {},
    query_library => {
        segments => {
            active => {filters => [['eq', 'status', 'active']]},
            matching_fields => {filters => [['eq', 'id', ['field', 'priority']]]},
            priority_at_least => {
                filters => [['gte', 'priority', ['param', 'minimum']]],
                parameters => {minimum => {type => 'integer', required => 1}},
            },
            active_priority => {
                segment_groups => [{operator => 'and', segments => [qw(active priority_at_least)]}],
            },
            unconstrained => {},
            active_or_all => {
                segment_groups => [{operator => 'or', segments => [qw(active unconstrained)]}],
            },
            status_code => {
                filters => [['eq', 'status', ['param', 'code']]],
                parameters => {code => {type => 'application/status', required => 1}},
            },
            conflicting_minimum => {
                filters => [['gte', 'priority', ['param', 'minimum']]],
                parameters => {minimum => {type => 'float', required => 1}},
            },
        },
        projections => {
            identity => {fields => [qw(id name)]},
            summary => {projections => ['identity'], fields => [qw(status priority)]},
        },
        orderings => {
            priority => {order_by => [['priority', 'desc'], ['id', 'asc']]},
        },
        views => {
            active_projects => {
                segments => ['active_priority'], projection => 'summary', ordering => 'priority',
                label => 'Active projects',
            },
            direct_active_projects => {
                segments => [qw(active priority_at_least)],
                projection => 'summary',
            },
        },
    },
}, strict => 1);

is_deeply [sort keys %{$domain->query_library->{views}}],
    [qw(active_projects direct_active_projects)],
    'strict domains retain the portable query library';

my $adapter = Selecto::PostgreSQL->new(dbh => bless({}, 'QueryLibraryDBH'));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $query = $engine->apply_view($engine->query, 'active_projects', {minimum => '3'});
my $statement = $engine->compile($query);

like $statement->sql, qr/SELECT "s0"\."id", "s0"\."name", "s0"\."status", "s0"\."priority"/,
    'named projections compose into governed selections';
like $statement->sql, qr/\("s0"\."status" = \$1\) AND \("s0"\."priority" >= \$2\)/,
    'named segments compose into a bound predicate';
like $statement->sql, qr/ORDER BY "s0"\."priority" DESC, "s0"\."id" ASC/,
    'named ordering replaces optional query ordering';
is_deeply $statement->params, ['active', 3], 'segment values remain bound parameters';
is_deeply $query->applied_query_library, {
    segments => [qw(active priority_at_least active_priority)],
    projections => [qw(identity summary)], projection => 'summary',
    ordering => 'priority', views => ['active_projects'],
}, 'query-library provenance records composed definitions';

eval { $engine->apply_view($engine->query, 'active_projects', {minimum => 'nope'}) };
like "$@", qr/must be integer/, 'typed segment parameters fail before SQL compilation';

my $direct = $engine->apply_view(
    $engine->query, 'direct_active_projects', {minimum => '4'},
);
is_deeply $engine->compile($direct)->params, ['active', 4],
    'view parameters are partitioned across multiple direct segments';

my $combined = $engine->apply_segments(
    $engine->query->select('id'), [qw(active priority_at_least)], {minimum => '5'},
);
is_deeply $engine->compile($combined)->params, ['active', 5],
    'multiple segments share one validated parameter set';
is_deeply $combined->applied_query_library->{segments}, [qw(active priority_at_least)],
    'combined segment application records stable provenance';

eval {
    $engine->apply_segments(
        $engine->query,
        [qw(priority_at_least conflicting_minimum)],
        {minimum => '5'},
    );
};
like "$@", qr/conflicting segment parameter minimum/,
    'combined segments reject conflicting shared parameter definitions';

my $unconstrained_or = $engine->apply_segment(
    $engine->query->select('id'), 'active_or_all',
);
unlike $engine->compile($unconstrained_or)->sql, qr/\bWHERE\b/,
    'OR with an unconstrained segment correctly leaves the query unconstrained';
is_deeply $unconstrained_or->applied_query_library->{segments},
    [qw(active unconstrained active_or_all)],
    'an unconstrained OR still records every applied definition';

my $custom_typed = $engine->apply_segment(
    $engine->query->select('id'), 'status_code', {code => 'review'},
);
is_deeply $engine->compile($custom_typed)->params, ['review'],
    'application-specific parameter types pass through as portable bound values';

my $matching_fields = $engine->apply_segment(
    $engine->query->select('id'), 'matching_fields',
);
my $matching_fields_statement = $engine->compile($matching_fields);
like $matching_fields_statement->sql, qr/"s0"\."id" = "s0"\."priority"/,
    'segment filters may compare two declared fields without treating the right side as a literal';
is_deeply $matching_fields_statement->params, [],
    'field-to-field segment comparisons do not create bound values';

done_testing;
