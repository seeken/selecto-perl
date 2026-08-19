use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;

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
            priority_at_least => {
                filters => [['gte', 'priority', ['param', 'minimum']]],
                parameters => {minimum => {type => 'integer', required => 1}},
            },
            active_priority => {
                segment_groups => [{operator => 'and', segments => [qw(active priority_at_least)]}],
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

done_testing;
