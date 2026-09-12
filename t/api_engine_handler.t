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
use Selecto::Write ();

{
    package TestAPIEngineHandler::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;

    sub execute_query ($self, $statement) {
        $self->{last_statement} = $statement;
        return {
            columns => $statement->columns,
            rows => [[map {
                $_ eq 'id' ? 7
                    : $_ eq 'lines'
                        ? '[{"lines.sku":"ABC","line_day":"2026-09-11"}]'
                        : "value:$_"
            } @{$statement->columns}]],
        };
    }

    sub execute_write ($self, $command) {
        $self->{last_write} = $self->preview_write($command);
        return Selecto::Write::Result->new(
            operation => $command->operation,
            affected_rows => $command->expected_count,
            values => {id => 7},
        );
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
        associations => {
            lines => {
                queryable => 'record_lines', owner_key => 'id',
                related_key => 'record_id', cardinality => 'many',
            },
        },
    },
    schemas => {
        record_lines => {
            source_table => 'record_lines', primary_key => 'id',
            fields => [qw(id record_id sku occurred_at)],
            columns => {
                id => {type => 'integer'},
                record_id => {type => 'integer'},
                sku => {type => 'string'},
                occurred_at => {type => 'epoch_datetime'},
            },
            associations => {},
        },
    },
    joins => {lines => {type => 'left'}},
    writes => {
        operations => {
            insert => {enabled => JSON::PP::true},
            update => {enabled => JSON::PP::true, bulk => JSON::PP::true},
            delete => {enabled => JSON::PP::true},
        },
        fields => {
            name => {insertable => JSON::PP::true, updatable => JSON::PP::true},
            status => {insertable => JSON::PP::true, updatable => JSON::PP::true},
            tenant_id => {insertable => JSON::PP::true},
        },
    },
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

my $write_result = $handler->write($engine, {
    operation => 'update',
    assignments => {status => 'closed'},
    filters => [{field => 'id', op => 'eq', value => 7}],
    expected_count => 1,
    returning => ['id'],
});
is_deeply $write_result, {
    operation => 'update', affected_rows => 1, values => {id => 7},
}, 'API writes return the canonical write result';
like $adapter->{last_write}{sql}, qr/UPDATE "records" SET "status" = \$1/,
    'API assignments compile through the governed write engine';
like $adapter->{last_write}{sql}, qr/"id" = \$2/,
    'API write filters are compiled as bound root-field predicates';
like $adapter->{last_write}{sql}, qr/"tenant_id" = \$3/,
    'API writes retain the trusted domain scope';
is_deeply $adapter->{last_write}{params}, ['closed', 7, 41],
    'API write values and scope remain bound parameters';

my $write_error = eval {
    $handler->write($engine, {
        operation => 'update', assignments => {status => 'closed'},
    });
    undef;
} // $@;
is $write_error->code, 'invalid_api_write',
    'update API writes require an explicit caller filter';

$write_error = eval {
    $handler->write($engine, {
        operation => 'delete',
        filters => [{field => 'id', op => 'eq', value => 7}],
        expected_count => 2,
    });
    undef;
} // $@;
is $write_error->code, 'invalid_api_write',
    'non-bulk write operations cannot opt into a larger cardinality';

$write_error = eval {
    $handler->write($engine, {
        operation => 'update', assignments => {name => 'unsafe'},
        filters => [{field => 'lines.sku', op => 'eq', value => 'ABC'}],
    });
    undef;
} // $@;
is $write_error->code, 'invalid_api_write',
    'API write predicates cannot cross relationships';

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

$result = $handler->query($engine, {
    select => [
        'id', [
            'lines.sku',
            {field => 'lines.occurred_at', format => 'day', alias => 'line_day'},
        ],
    ],
});
is_deeply $result->{columns}, [qw(id lines)],
    'a sub-array returns its to-many fields as one nested collection';
is_deeply $result->{rows}, [[
    7, [['ABC', '2026-09-11']],
]], 'array row format is applied to the root and its related collection';
is_deeply $result->{subtables}, {
    lines => {columns => ['lines.sku', 'line_day']},
}, 'array-form subtables publish their ordered child columns';
like $adapter->{last_statement}->sql,
    qr/JSON_BUILD_OBJECT\('lines\.sku', "c_lines"\."sku", 'line_day', TO_CHAR\(TO_TIMESTAMP\("c_lines"\."occurred_at"\), 'YYYY-MM-DD'\)\)/,
    'nested fields retain full path names, aliases, and governed formats';
unlike $adapter->{last_statement}->sql, qr/JOIN "record_lines"/,
    'an explicit subtable does not multiply root rows';

$result = $handler->query($engine, {
    select => ['id', 'lines.sku'],
});
is_deeply $result->{columns}, ['id', 'lines.sku'],
    'an ordinary to-many field remains in the flat result';
like $adapter->{last_statement}->sql, qr/LEFT JOIN "record_lines" AS "j_lines"/,
    'a flat to-many selection uses the governed relationship join';

$result = $handler->query($engine, {
    select => ['id', [
        'lines.sku',
        {field => 'lines.occurred_at', format => 'day', alias => 'line_day'},
    ]],
    row_format => 'objects',
});
is_deeply $result->{rows}, [{
    id => 7,
    lines => [{'lines.sku' => 'ABC', line_day => '2026-09-11'}],
}], 'object row format is applied to the root and its related collection';
is $result->{row_format}, 'objects', 'the response reports its effective row format';

my $subtable_error = eval {
    $handler->query($engine, {select => ['id', ['lines.sku', 'name']]});
    undef;
} // $@;
is $subtable_error->code, 'invalid_api_query',
    'subtables reject fields outside their one direct to-many association';

$result = $handler->query($engine, {
    select => [
        {field => 'occurred_at', format => 'month'},
        {field => 'occurred_at', format => 'day', alias => 'occurred_day'},
    ],
});
is_deeply $result->{columns}, [qw(occurred_at occurred_day)],
    'formatted API fields use a path name by default and accept an explicit alias';
like $adapter->{last_statement}->sql,
    qr/TO_CHAR\(TO_TIMESTAMP\("s0"\."occurred_at"\), 'YYYY-MM'\) AS "occurred_at"/,
    'epoch datetime API fields use the governed temporal formatter';

$result = $handler->query($engine, {
    select => [{field => 'occurred_at', format => 'iso8601'}],
});
like $adapter->{last_statement}->sql,
    qr/TO_CHAR\(\(TO_TIMESTAMP\("s0"\."occurred_at"\) AT TIME ZONE 'UTC'\), 'YYYY-MM-DD"T"HH24:MI:SS'\) \|\| 'Z'/,
    'the API gives epoch fields an RFC 3339 UTC representation';

my $format_error = eval {
    $handler->query($engine, {
        select => [{field => 'name', format => 'month'}],
    });
    undef;
} // $@;
is $format_error->code, 'invalid_api_query',
    'API formats cannot be applied to non-temporal fields';

$format_error = eval {
    $handler->query($engine, {
        select => [{field => 'occurred_at', format => q{YYYY'); DROP TABLE records; --}}],
    });
    undef;
} // $@;
is $format_error->code, 'invalid_api_query',
    'API formats are selected from the governed catalog';

$result = $handler->query($engine, {
    select => [{field => 'occurred_at', format => 'month'}],
    filters => [{field => 'occurred_at', op => 'gte', value => '2026-09-01T00:00:00'}],
    timezone => 'America/New_York',
});
is_deeply $result->{columns}, ['occurred_at'],
    'a timezone-aware formatted selection keeps its stable result name';
like $adapter->{last_statement}->sql,
    qr/TO_CHAR\(\(TO_TIMESTAMP\("s0"\."occurred_at"\) AT TIME ZONE \$1\), 'YYYY-MM'\)/,
    'the requested timezone governs formatted epoch fields';
like $adapter->{last_statement}->sql,
    qr/\(TO_TIMESTAMP\("s0"\."occurred_at"\) AT TIME ZONE \$3\) >= \$4/,
    'the requested timezone also governs temporal filters';
is_deeply $adapter->{last_statement}->params,
    ['America/New_York', 41, 'America/New_York', '2026-09-01T00:00:00'],
    'timezone names and filter values remain bound parameters';

my $timezone_error = eval {
    $handler->query($engine, {
        select => ['id'], timezone => 'Not/A_Real_Zone',
    });
    undef;
} // $@;
is $timezone_error->code, 'invalid_api_query',
    'unknown IANA timezone names fail during API validation';

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
$error = eval {
    Selecto::API::EngineHandler->new(max_write_count => 0);
    undef;
} // $@;
is $error->code, 'invalid_api_handler',
    'write cardinality configuration must allow at least one row';

my $api = Selecto::API->new(domain => $domain, base_path => '/api/v1/records');
is $handler->describe_openapi($api), $api,
    'OpenAPI decoration returns the same API object';
my $schema = $api->openapi_document->{components}{schemas}{SelectoQuery};
is $schema->{properties}{select}{maxItems}, 4,
    'OpenAPI field limits come from handler configuration';
is_deeply $schema->{properties}{select}{items}{oneOf}[1],
    {'$ref' => '#/components/schemas/SelectoSelection'},
    'OpenAPI select entries advertise explicit field aliases';
is_deeply $schema->{properties}{select}{items}{oneOf}[2],
    {'$ref' => '#/components/schemas/SelectoSubtableSelection'},
    'OpenAPI select entries advertise explicit subtable arrays';
is_deeply $api->openapi_document->{components}{schemas}{SelectoSelection}{required},
    ['field'],
    'OpenAPI selection objects require a field while alias and format stay optional';
my @formats = @{$api->openapi_document->{components}{schemas}{SelectoSelection}{properties}{format}{enum}};
ok grep($_ eq 'iso8601', @formats),
    'OpenAPI advertises the standard API date format';
ok grep($_ eq 'day_of_week', @formats),
    'OpenAPI advertises day names';
ok grep($_ eq 'day_of_week_num', @formats),
    'OpenAPI advertises ISO day numbers separately';
for my $format (qw(
    rfc3339_millis epoch_seconds epoch_milliseconds iso_week iso_week_date
    day_of_year timezone_offset
)) {
    ok grep($_ eq $format, @formats),
        "OpenAPI advertises the $format format";
}
is $schema->{properties}{filters}{maxItems}, 3,
    'OpenAPI filter limits come from handler configuration';
is $schema->{properties}{limit}{maximum}, 50,
    'OpenAPI result limits come from handler configuration';
is $schema->{properties}{limit}{default}, 12,
    'OpenAPI default result limit comes from handler configuration';
is $schema->{properties}{timezone}{example}, 'America/New_York',
    'OpenAPI advertises the query timezone contract';
is_deeply $schema->{properties}{row_format}{enum}, [qw(arrays objects)],
    'OpenAPI advertises both consistent row representations';
ok !exists($schema->{properties}{'no-normal'}),
    'the superseded no-normal flag is not part of the API contract';
my $filter_schema = $api->openapi_document->{components}{schemas}{SelectoFilter};
ok grep($_ eq 'date_shortcut', @{$filter_schema->{properties}{op}{enum}}),
    'OpenAPI advertises semantic date-shortcut filters';
is $filter_schema->{'x-selecto-date-shortcuts'}[3]{id}, 'this_week',
    'OpenAPI publishes the shared date-shortcut catalog';
my $write_schema = $api->openapi_document->{components}{schemas}{SelectoWrite};
is_deeply $write_schema->{properties}{operation}{enum}, [qw(insert update upsert delete)],
    'OpenAPI publishes the portable governed write operations';
is $write_schema->{properties}{expected_count}{maximum}, 1000,
    'OpenAPI publishes the bounded write cardinality';
is_deeply $api->openapi_document->{paths}{'/api/v1/records/write'}{post}{requestBody}
    {content}{'application/json'}{schema},
    {'$ref' => '#/components/schemas/SelectoWrite'},
    'OpenAPI binds the write endpoint to the governed write request schema';
ok !exists($api->openapi_document->{security}),
    'generic OpenAPI decoration does not invent host authentication';

done_testing;
