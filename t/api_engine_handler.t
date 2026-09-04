use 5.034;
use strict;
use warnings;

use Test::More;
use JSON::PP ();
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();

{
    package TestAPIEngineHandler::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;

    sub execute_query ($self, $statement) {
        $self->{last_statement} = $statement;
        return {
            columns => $statement->columns,
            rows => [[map { $_ eq 'id' ? 7 : "value:$_" } @{$statement->columns}]],
        };
    }
}

my $domain = Selecto::Domain->parse({
    schema_version => 1,
    domain_version => '1.0.0',
    domain_fingerprint => 'sha256:api-engine-handler-test-v1',
    name => 'API Engine Handler Test',
    source => {
        source_table => 'records',
        primary_key => 'id',
        fields => [qw(id name status occurred_at tenant_id)],
        columns => {
            id => {type => 'integer'},
            name => {type => 'string'},
            status => {type => 'string'},
            occurred_at => {type => 'epoch_datetime'},
            tenant_id => {type => 'integer', internal => 1},
        },
        associations => {},
    },
    schemas => {},
    joins => {},
    query_library => {
        segments => {
            active => {filters => [['eq', 'status', 'A']]},
        },
        projections => {
            directory => {fields => [qw(id name status)]},
        },
        orderings => {
            by_name => {order_by => [['name', 'asc'], ['id', 'asc']]},
        },
        views => {
            active_directory => {
                segments => ['active'],
                projection => 'directory',
                ordering => 'by_name',
            },
        },
    },
}, strict => 1)->with_required_predicate(
    Selecto::Expression->eq('tenant_id', 41),
);

my $adapter = TestAPIEngineHandler::Adapter->new(
    dbh => bless({}, 'TestAPIEngineHandler::DBH'),
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $handler = Selecto::API::EngineHandler->new(
    max_fields => 4,
    max_filters => 3,
    max_filter_values => 4,
    max_orders => 2,
    max_segments => 2,
    max_limit => 50,
    default_limit => 12,
);

my $result = $handler->query($engine, {
    select => [qw(id name)],
    filters => [
        {field => 'status', op => 'in', value => [qw(A P)]},
        {
            field => 'occurred_at', op => 'between',
            value => '2026-01-01', end => '2026-02-01',
        },
    ],
    order_by => [{field => 'name', direction => 'DESC'}],
    limit => 20,
    offset => 5,
});

is_deeply $result->{columns}, [qw(id name)],
    'handler returns adapter columns';
is $result->{returned}, 1, 'handler reports the returned row count';
is $result->{limit}, 20, 'handler reports the effective limit';
is $result->{offset}, 5, 'handler reports the effective offset';
like $adapter->{last_statement}->sql, qr/"s0"\."tenant_id" = \$1/,
    'the engine required predicate survives API query construction';
like $adapter->{last_statement}->sql,
    qr/TO_TIMESTAMP\("s0"\."occurred_at"\) BETWEEN \$4 AND \$5/,
    'epoch datetime filters use the domain-aware temporal expression';
like $adapter->{last_statement}->sql, qr/ORDER BY "s0"\."name" DESC/,
    'explicit ordering is compiled through the engine';
is_deeply $adapter->{last_statement}->params,
    [41, qw(A P), '2026-01-01', '2026-02-01'],
    'all predicate values remain bound parameters';

my ($shortcut_start, $shortcut_end) = Selecto::DateShortcut->bounds('this_week');
$handler->query($engine, {
    select => ['id'],
    filters => [{field => 'occurred_at', op => 'date_shortcut', value => 'this_week'}],
});
like $adapter->{last_statement}->sql,
    qr/TO_TIMESTAMP\("s0"\."occurred_at"\) >= \$2\) AND \(TO_TIMESTAMP\("s0"\."occurred_at"\) < \$3/,
    'date shortcuts compile as a half-open temporal range';
is_deeply $adapter->{last_statement}->params,
    [41, $shortcut_start, $shortcut_end],
    'date shortcut intent resolves to server-local bound parameters';

my $recurring_plan = Selecto::DateShortcut->plan('ytd_all_years');
$handler->query($engine, {
    select => ['id'],
    filters => [{field => 'occurred_at', op => 'date_shortcut', value => 'ytd_all_years'}],
});
like $adapter->{last_statement}->sql,
    qr/TO_CHAR\(TO_TIMESTAMP\("s0"\."occurred_at"\), 'MM-DD'\) >= \$2\).*TO_CHAR\(TO_TIMESTAMP\("s0"\."occurred_at"\), 'MM-DD'\) <= \$3/,
    'all-years date shortcuts compare recurring calendar positions';
is_deeply $adapter->{last_statement}->params,
    [41, $recurring_plan->{start}, $recurring_plan->{end}],
    'recurring date shortcut boundaries remain bound parameters';

my $shortcut_error = eval {
    $handler->query($engine, {
        select => ['id'],
        filters => [{field => 'occurred_at', op => 'date_shortcut', value => 'forever'}],
    });
    undef;
} // $@;
is $shortcut_error->code, 'invalid_api_query',
    'unknown semantic date shortcuts fail closed';

$shortcut_error = eval {
    $handler->query($engine, {
        select => ['id'],
        filters => [{field => 'status', op => 'date_shortcut', value => 'this_week'}],
    });
    undef;
} // $@;
is $shortcut_error->code, 'invalid_api_query',
    'date shortcuts cannot be applied to non-temporal fields';

$result = $handler->query($engine, {view => 'active_directory'});
is_deeply $result->{columns}, [qw(id name status)],
    'a view applies its named projection';
is_deeply $result->{query_library}, {
    segments => ['active'],
    projections => ['directory'],
    projection => 'directory',
    ordering => 'by_name',
    views => ['active_directory'],
}, 'the response reports every applied query-library component';
like $adapter->{last_statement}->sql, qr/"s0"\."status" = \$2/,
    'a view applies its segment after the required predicate';

$result = $handler->query($engine, {
    projection => ['directory'],
    segments => ['active', 'active'],
    limit => 0,
});
is_deeply $result->{query_library}{segments}, ['active'],
    'duplicate requested segments are applied once';
is $result->{limit}, 0, 'a caller may explicitly request a zero-row result';

my $error = eval {
    $handler->query($engine, {select => ['tenant_id']});
    undef;
} // $@;
is $error->code, 'field_not_public',
    'internal domain dependencies cannot be selected through the handler';

$error = eval {
    $handler->query($engine, {
        select => ['id'], filters => [
            {field => 'status', op => 'in', value => [qw(A B C D E)]},
        ],
    });
    undef;
} // $@;
is $error->code, 'invalid_api_query', 'configured filter-value limits are enforced';
like $error->message, qr/Too many in filter values/,
    'limit errors identify the rejected query shape';

$error = eval {
    $handler->query($engine, {select => ['id'], surprise => 1});
    undef;
} // $@;
is_deeply $error->details, {properties => ['surprise']},
    'unknown request properties fail closed with stable details';

$error = eval {
    Selecto::API::EngineHandler->new(max_limit => 5, default_limit => 6);
    undef;
} // $@;
is $error->code, 'invalid_api_handler',
    'an inconsistent handler limit configuration is rejected';

my $api = Selecto::API->new(domain => $domain, base_path => '/api/v1/records');
is $handler->describe_openapi($api), $api,
    'OpenAPI decoration returns the same API object';
my $schema = $api->openapi_document->{components}{schemas}{SelectoQuery};
is $schema->{properties}{select}{maxItems}, 4,
    'OpenAPI field limits come from handler configuration';
is $schema->{properties}{filters}{maxItems}, 3,
    'OpenAPI filter limits come from handler configuration';
is $schema->{properties}{limit}{maximum}, 50,
    'OpenAPI result limits come from handler configuration';
is $schema->{properties}{limit}{default}, 12,
    'OpenAPI default result limit comes from handler configuration';
my $filter_schema = $api->openapi_document->{components}{schemas}{SelectoFilter};
ok grep($_ eq 'date_shortcut', @{$filter_schema->{properties}{op}{enum}}),
    'OpenAPI advertises semantic date-shortcut filters';
is $filter_schema->{'x-selecto-date-shortcuts'}[3]{id}, 'this_week',
    'OpenAPI publishes the shared date-shortcut catalog';
ok !exists($api->openapi_document->{security}),
    'generic OpenAPI decoration does not invent host authentication';

done_testing;
