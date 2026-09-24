# selecto-perl

`selecto-perl` is the native Perl implementation of Selecto's governed domain,
immutable query, database-adapter, and portable write contracts. Mojolicious
supplies a small object foundation and named adapter registry. The core remains
HTTP-neutral: DBI supplies the execution boundary, while routes, ORMs, and UI
code remain in consumer applications.

This is an alpha library. Its current compatibility target is observation
protocol 1 and certification specifications 2.7.0 and 2.8.0. PostgreSQL is
centrally certified for the 2.8 governed co-domain/computed-eligibility profile
and, with the Elixir reference, for the 2.15 `computed_value_columns` profile
(CV001-CV005: computed value expressions executed from shared fixture data).

## Current surface

- query timezones on raw epoch-datetime fields convert numeric storage to an
  instant before applying the zone on PostgreSQL and DuckDB. Explicit temporal
  expressions and formatted selections are converted only once. Without an
  explicit timezone, raw epoch selections retain their exact numeric storage
  representation. `t/epoch_timezone.t` checks these boundaries with synthetic
  data, alongside UTC fields, NULLs, negative microseconds, DST folds, aliases,
  filters and required scope. PostgreSQL and DuckDB pass the raw-result checks;
- DuckDB uses adapter-owned final-result transport for exact timestamp/decimal
  decoding, normalized scalar booleans, streaming and write RETURNING. Numeric
  input avoids the driver's automatic floating-point inference; governed
  numeric comparisons establish each parameter's own scale. Native relational
  operations precede serialization. See [DuckDB result transport](docs/duckdb-result-transport.md)
  for the implementation boundary and executable coverage;
- DuckDB temporal formatters allocate a bound value for every repeated SQL
  occurrence, including quarters and named-zone RFC3339/offsets. PostgreSQL DATE
  interchange formats explicitly interpret midnight as TIMESTAMP in the
  requested zone, avoiding the session-dependent DATE overload. The live
  `t/temporal_format_bindings.t` compares all 20 formats across four temporal
  types and five zones, with fixed midnight expectations in non-UTC sessions;
- strict simplified and canonical schema-v1 JSON domain parsing;
- validated root and arbitrary-depth relationship field resolution with
  collision-safe SQL aliases and retained relationship lineage;
- canonical relationship cardinality inference and correlated JSON collections
  for to-many child data without multiplying root rows;
- deterministic SHA-256 domain fingerprints;
- deterministic domain overlays, a fluent overlay DSL, and fail-closed named
  domain registries with opaque provenance references;
- canonical component policy metadata, including domain-selected private URL
  state for compatible exploration UIs;
- copy-on-write select, filter, group, order, limit, and offset queries, plus
  CTEs, recursive CTEs, compound set operations, windows, rollups, lateral
  subqueries, and typed JSON rowsets where the selected adapter supports them;
- portable named query-library segments, projections, orderings, and views with
  typed parameters and applied-definition provenance;
- validated portable detail-action metadata with governed required fields and
  safe external-link or iframe-modal URL templates for compatible exploration
  UIs;
- field, literal, comparison, null, membership, conjunction, aggregate,
  window, and PostgreSQL full-text expressions, plus governed PostgreSQL
  date/time format expressions;
- PostgreSQL and DuckDB compilation with quoted identifiers and bound `$1` parameters;
  SQLite, MySQL, MariaDB, and Microsoft SQL Server compilation with native
  identifier quoting and DBI `?` parameters;
- eager and row-streaming DBI execution with stable columns and
  backend-specific value normalization;
- a versioned `Selecto::Adapter` contract, generic `Selecto::Statement`, and
  runtime adapter registry for independently packaged database support;
- portable insert, update, upsert, delete, expected-cardinality, atomic-batch,
  capability-gated arbitrary-depth write graphs, and closed mutation-expression
  AST operations;
- governed row and selected-id bulk action planning with explicit transition
  preconditions and fail-closed preview/execute capability decisions;
- an HTTP-neutral field-policy resolver that intersects public field metadata,
  governed write permissions, form profiles, capabilities, and record-state
  eligibility into hidden, read-only, editable, or action-backed descriptors;
- governed co-domain lookup and boolean-root action selection eligibility with
  fail-closed declaration validation;
- an HTTP-neutral canonical domain API host and governed-engine query/write
  handler with OpenAPI 3.1, byte-stable UTF-8 JSON, CSV, TSV, and XLSX query
  response bodies;
- an initial HTTP-neutral `Selecto::Files` record-and-role facade with hidden
  tenant/storage authority, memory and managed-local publication, bounded
  filehandle streaming, idempotency, holds, and purge;
- adapter capability reporting and an observation-protocol runner for central
  backend certification.

It does not contain HTTP routes, ORM, or UI compatibility code.
The separate `@selecto/api-console` browser package consumes `Selecto::API`
unchanged. Mojolicious applications can use the generated assets and mounting
helper shipped by `selecto-perl-components`, while this core remains
HTTP-neutral.

## Install for development

Perl 5.34 or newer and Mojolicious 9.49 or newer are required. PostgreSQL
execution and certification additionally require `DBD::Pg`; SQLite execution
and certification require `DBD::SQLite`; MySQL and MariaDB use
`DBD::MariaDB`; Microsoft SQL Server uses a Unicode-enabled `DBD::ODBC` build
and an installed ODBC driver. The base distribution does not force any
optional driver.

`Selecto::Files` binds tenant and actor authority in trusted host code, then
projects only authorized display metadata and application-owned content routes.
Its memory profile covers tenant isolation, same-operation idempotency,
download, guarded detach, retention holds, and exact-version purge. Public
values contain no tenant, scope, provider, bucket, object key, or credential.

`Selecto::Files::LocalStorage` is the initial version-1 storage implementation.
`upload_handle` reads caller-owned handles in 64 KiB chunks, checks the declared
size and optional SHA-256, and never closes the input. Local publication uses a
private same-directory staging file, file and parent-directory `fsync`, and a
hard link so an existing final object is never replaced. Cancellation and
failed verification remove staging content. References accept only portable
segments, and reads reject symlink final components where `O_NOFOLLOW` is
available. The current tests cover macOS behavior; directory-swap races,
process or power-loss recovery, other operating systems, and multi-node storage
remain uncertified. DBI metadata, Mojo routes, S3/cloud adapters, workers, and
live-provider evidence remain separate admission work.

```sh
cpanm --installdeps .
cpanm DBD::Pg # only when using the PostgreSQL adapter
cpanm DBD::SQLite # only when using the SQLite adapter
cpanm DBD::DuckDB # only when using the DuckDB adapter
cpanm DBD::MariaDB # when using MySQL or MariaDB
cpanm DBD::ODBC # only when using the Microsoft SQL Server adapter
perl Makefile.PL
make test
```

The repository also pins a development Perl with mise:

```sh
mise install
mise run verify
```

## Query example

```perl
use Selecto;
use DBI;

my $domain = product_domain();
my $dbh = DBI->connect($dsn, undef, undef, {
    RaiseError => 1,
    PrintError => 0,
    AutoCommit => 1,
});
my $engine = Selecto::Engine->new(
    domain  => $domain,
    adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
);

my $query = $engine->query
    ->select(
        Selecto::Expression->field('id')->as('order_id'),
        Selecto::Expression->field('customer.company_name')->as('customer'),
        Selecto::Expression->sum('freight')->as('total_freight'),
    )
    ->where(Selecto::Expression->gte('freight', '10.00'))
    ->group_by('id', 'customer.company_name')
    ->order_by('id')
    ->limit(25);

my $result = $engine->all($query);
```

An HTTP host can expose the canonical API query format without reimplementing
its validation. The host must supply an engine whose domain already contains
every required scope and policy restriction:

```perl
use Selecto::API;
use Selecto::API::EngineHandler;

my $api = Selecto::API->new(
    domain => $engine->domain,
    base_path => '/api/v1/products',
);
my $handler = Selecto::API::EngineHandler->new(
    default_limit => 100,
    max_limit => 1000,
);
$handler->describe_openapi($api);

my $result = $handler->query($engine, {
    projection => 'summary',
    segments => ['available'],
    filters => [{field => 'stock', op => 'gte', value => 1}],
    ordering => 'by_name',
});
```

`EngineHandler` does not construct an engine, authenticate users, choose a
tenant, or modify the domain. It validates every field and query-library name
against the supplied engine's governed domain, so internal fields and
host-pruned definitions remain unavailable.

Query responses default to canonical JSON. HTTP hosts can pass the request's
`Accept` header as `accept`, or an explicit `?format=` value as
`response_format`, to `Selecto::API::request`. Supported representations are
`json`, `csv`, `tsv`, and `xlsx`; the explicit format takes precedence. CSV and
TSV include the selected column names as their first row, encode nested
subtables as canonical JSON cells, and guard formula-leading spreadsheet
values. XLSX returns an attachment-safe workbook and writes textual values as
strings rather than formulas. The governed query limit still bounds every
representation. A host may pass a `filename` query parameter through as
`download_filename`; it must be a safe basename of at most 160 characters and
end in the extension required by the chosen CSV, TSV, or XLSX format.

The same handler accepts the canonical governed-write body. The domain must
explicitly enable the operation and field permissions under `writes`.
Update/delete requests always require caller filters in addition to the
engine's trusted required predicate, and `expected_count` is enforced by the
adapter transaction:

```perl
my $result = $handler->write($engine, {
    operation => 'update',
    assignments => {status => 'closed'},
    filters => [{field => 'id', op => 'eq', value => 17}],
    expected_count => 1,
    returning => ['id', 'status'],
});
```

Hosts that need to compose an application-specific transaction can call
`write_command($engine, $body)` to normalize the same API payload without
executing it. The returned `Selecto::Write::Command` must still be executed
through a governed engine; preparing it does not bypass the engine's operation,
field, scope, or cardinality checks.

Write fields may declare `required => 1`. The engine enforces these fields for
`insert` and `upsert` operations and reports all omissions as
`missing_required_write_fields`, with `fields` and `missing_fields` arrays in
the error details. If an undeclared requirement instead comes from an enforced
query scope, `query_rule_not_evaluable` identifies the missing insert field.
Date assignments are validated before execution and must use `YYYY-MM-DD` or
JSON `null`; database execution failures cannot be misreported as missing
`RETURNING` rows.

Only public root fields can be assigned, filtered, or returned. Upserts also
require explicit `conflict_target` and `upsert_update_fields` arrays. A count
greater than one is accepted only when that operation publishes `bulk`.

An API caller explicitly requests a subtable by grouping fields from one direct
to-many association in a nested selection array. This preserves one row per
root record. The collection column uses the association name, while its object
keys use each selected field's full dotted path unless an alias was supplied:

```perl
my $result = $handler->query($engine, {
    select => ['id', [
        'load_det.vin',
        {field => 'load_det.created', alias => 'created_day', format => 'day'},
    ]],
});
```

All entries in a nested array must belong to the same direct to-many
association. Ordinary top-level selections remain flat and may therefore
return multiple rows for one root record.

`row_format` controls both levels consistently. Its default, `arrays`, returns
root rows and subtable rows as ordered arrays; the response's `columns` and
`subtables.<association>.columns` lists describe those positions. Set
`row_format` to `objects` to return both root rows and subtable rows as JSON
objects keyed by those same column names.

`order_by` may be repeated to build a stable multi-column order. For governed
date/time projection or grouping, use an allowlisted expression such as
`Selecto::Expression->datetime_format('occurred_on', 'month')` consistently in
`select`, `group_by`, or `order_by`; arbitrary database format strings are not
accepted. Portable comparison intents include `eq`, `ne`, `gt`, `gte`, `lt`,
`lte`, and `between`; their values compile as adapter-bound parameters.

For a PostgreSQL eligibility read that must stay valid through a host-owned
write transaction, call `for_share` on the governed query. It locks only the
domain root rows returned by that query. Use the same DBI connection for the
read and write with `transaction_mode => 'external'`; the lock lasts until the
host commits or rolls back. Other adapters reject this query before execution.

Relationship paths are not limited to one join. If the domain declares the
lineage, the same dotted path works in selections, predicates, grouping, and
ordering:

```perl
my $query = $engine->query
    ->select('id', 'customer.region.name')
    ->where(Selecto::Expression->eq('customer.region.active', 1))
    ->order_by('customer.region.name');
```

Both canonical nested schemas and constructor-domain nested `associations`
retain the full lineage. Contract promotion for overlays preserves those
nested relationships as canonical schemas.

Canonical domains may also expose an internal SQL-computed boolean using the
same governed filter AST as query-library segments. This is useful for action
eligibility and other row-state decisions that should travel with the primary
query instead of triggering per-row application calls:

```perl
ready_for_dispatch => {
    type => 'boolean',
    internal => 1,
    computed => {
        kind => 'predicate',
        expression => ['and', [
            ['in', 'status', [qw(A O)]],
            ['eq', 'has_payload', 1],
        ]],
    },
},
```

Predicate computations accept the portable comparison, null, membership, and
boolean operators, reference only governed root fields, and bind every literal
through the adapter. Raw SQL is not accepted. They may compose other computed
root fields, including `association_exists` fields, provided the dependency
graph is acyclic.

Computed value fields return strings, numbers, dates, or extracted JSON text.
They are written in a closed, typed AST (`Selecto::ValueExpression`), never as
SQL text:

```perl
effective_location => {
    type => 'string', label => 'Effective location',
    computed => {kind => 'expression', expression => [
        'coalesce', ['field', 'site.name'], ['field', 'location_text'],
        ['literal', 'Location unknown'],
    ]},
},
attention_state => {
    type => 'string',
    computed => {kind => 'expression', expression => [
        'case',
        [['not_null', 'retired_at'], ['literal', 'Retired']],
        [['in', 'status', ['maintenance', 'missing']], ['literal', 'Needs attention']],
        ['else', ['literal', 'Ready to reserve']],
    ]},
},
hourly_rate_dollars => {
    type => 'decimal',
    computed => {kind => 'expression',
        expression => ['divide', ['field', 'hourly_rate_cents'], ['literal', 100]]},
},
manufacturer => {
    type => 'string',
    computed => {kind => 'expression', expression => ['json_text', 'metadata', ['manufacturer']]},
},
```

The node set is `field`, `literal` (optionally typed), `coalesce`, `case`
(conditions use the portable filter AST), `add`, `subtract`, `multiply`,
`divide`, `cast` (to `string`, `integer`, `decimal`, `boolean`, `date`, or
`utc_datetime`), `json_text` (path segments of letters, digits, and
underscores), `lower`, `upper`, and `concat`. Anything else is rejected when the
domain is parsed.

- Fields may cross associations (`site.name`); selecting, filtering, grouping,
  or ordering by a computed field introduces the joins its expression reads.
- Computed fields may build on other computed fields; cycles are rejected.
- The expression is type-checked against the finished domain and must match the
  declared column type (an integer result satisfies a declared `decimal`).
- Literals are bound and cast to their type; JSON path segments are bound;
  `divide` is always decimal so integer operands never truncate; `concat` casts
  each operand to text and treats NULL as empty.
- Computed fields are read-only: write contracts cannot mark them insertable or
  updatable, and governed writes reject assignments to them.
- The same AST is available per query as
  `Selecto::Expression->value([...])->as('name')`, type-checked against the
  engine's domain.

PostgreSQL and DuckDB declare the `value_expressions` and `json_text`
capabilities. Other adapters fail closed with `unsupported_feature` until they
implement and certify the node set.

A canonical string column can expose a joined display value with a root-field
fallback, and that same value is available for selection and filtering:

```perl
customer_display_name => {
    type => 'string',
    computed => {kind => 'coalesce_fields',
        fields => ['customer.co_name', 'cust_name']},
},
```

The preferred field must belong to a direct, left-joined one-to-one association;
the fallback must be a physical root column of the same declared type. Selecto
adds the governed join when this computed field is used. If the joined value is
null or the association is absent, SQL `COALESCE` returns the root fallback.

## Advanced queries and streaming

Advanced sources remain domain-owned. A CTE or lateral subquery receives its
own domain and immutable query plus an explicit key contract; callers cannot
inject a table or SQL fragment. For example:

```perl
my $event_query = Selecto::Query->new
    ->select(qw(order_id kind))
    ->where(Selecto::Expression->eq('kind', 'status'));

my $query = $engine->query
    ->with_cte(
        recent_events => $events_domain, $event_query,
        columns => [qw(order_id kind)],
        join => {owner_key => 'id', related_key => 'order_id', type => 'left'},
    )
    ->select('id', 'recent_events.kind');
```

`with_recursive_cte` takes separate anchor and recursive-member queries plus
an explicit inner `recursive_join`. The recursive member cannot use a left
join. `union`, `union_all`, `intersect`, and `except` build compound queries;
chained operations are evaluated from left to right consistently across SQL
dialects, and outer ordering and pagination apply after the compound result.
Set operands with their own outer ordering or pagination are rejected as
ambiguous. `ALL` is portable through `union_all`; `INTERSECT ALL` and
`EXCEPT ALL` are rejected because supported adapters disagree on them.

Window expressions use an allowlisted function set and validated frames:

```perl
my $running_total = Selecto::Expression->window_sum(
    'total',
    partition_by => ['customer_id'],
    order_by => [['id', 'asc']],
    frame => {
        type => 'rows',
        start => 'unbounded_preceding',
        end => 'current_row',
    },
)->as('running_total');
```

PostgreSQL additionally implements correlated `lateral_join`, typed
`json_rowset`, and `text_search`/`text_rank`. JSON column types and full-text
configurations and modes are allowlisted; search strings and JSON paths remain
bound parameters. Rollups continue to use `group_by_rollup` and grouping
metadata as described below.

PostgreSQL also governs array columns and JSON containment. An array column
declares its element type (`{type => 'array', items => 'string'}`; items are
`string`, `integer`, `decimal`, `boolean`, `date`, or `uuid`):

```perl
my $query = $engine->query
    ->array_rowset('legacy_tags', 'tag_rows', ordinality => 'position')   # UNNEST ... WITH ORDINALITY
    ->select('asset_tag', 'tag_rows.value', 'tag_rows.position')
    ->where(Selecto::Expression->all(
        Selecto::Expression->array_overlap('legacy_tags', ['three-phase', 'dust-collection']),
        Selecto::Expression->json_contains('metadata', {power => 'three_phase'}),
    ))
    ->order_by('asset_tag', 'asc')->order_by('tag_rows.position', 'asc');
```

`array_contains` (every value present), `array_contained` (every element is a
value), and `array_overlap` (any value present) bind each value and cast the
list to the declared element type; NULL arrays never match. `json_contains`
binds the document as canonical JSON. `array_rowset` exposes `value` and,
when requested, the 1-based ordinality column; `type` is `cross` (default),
`inner`, or `left` (keeps rows with empty or NULL arrays). The filter AST
accepts `['array_overlap', field, [values]]` and `['json_contains', field,
{...}]`. Other adapters report `array_predicates`, `array_rowset`, and
`json_contains` as unsupported and fail before SQL is built.

### Query members declared in the domain

Reusable CTE, recursive CTE, lateral, and array-expansion sources can be
declared as data under `query_members` and activated by name. A member query is
rooted at a relation in the domain's own `schemas` section and is written as
data: `select` entries are field names, `{as => ..., value => VALUE_AST}`, or
`{as => ..., aggregate => 'count'|'sum'|'avg'|'min'|'max', field => ...}`;
`filter` is the filter AST; `group_by`, `order_by` (`[[field, 'asc']]`), and
`limit` are optional.

```perl
query_members => {
    ctes => {
        usage_totals => {source => 'usage_session',
            query => {select => ['equipment_id', {as => 'sessions', aggregate => 'count'}],
                      group_by => ['equipment_id']},
            join => {owner_key => 'id', related_key => 'equipment_id', type => 'left'}},
        category_tree => {kind => 'recursive', source => 'category',
            base => {select => ['id', 'code', {as => 'depth', value => ['literal', 0, 'integer']}],
                     filter => ['is_null', 'parent_id']},
            step => {select => ['id', 'code',
                     {as => 'depth', value => ['add', ['previous', 'depth'], ['literal', 1]]}]},
            step_join => {owner_key => 'parent_id', related_key => 'id'},
            join => {owner_key => 'category_id', related_key => 'id', type => 'inner'}},
    },
    laterals => {latest_ticket => {source => 'ticket',
        query => {select => ['summary'], order_by => [['opened_at', 'desc']], limit => 1},
        correlations => {equipment_id => 'id'}, join_type => 'left'}},
    unnests => {legacy_tags => {array_field => 'legacy_tags', as => 'tag_rows', ordinality => 'position'}},
},

my $query = $engine->query->with_member('category_tree')->select('name', 'category_tree.depth');
```

`['previous', column]` reads the previous level's row and is accepted only in a
recursive `step`; its type comes from the base selection in the same position.
Members are validated when the domain is parsed, are part of the fingerprint,
and fail with `unknown_query_member` when a query names one the domain does not
declare. The same data runs in the Elixir runtime. Groups Perl does not execute
(for example `values`) are left for the runtime that does.

PostgreSQL and DuckDB reuse the parameter identities of governed grouping
expressions in selections, `GROUPING` metadata, and ordering. This includes
timezone-adjusted fields and date formats; equal values bound under different
parameter names do not identify the same SQL grouping expression. DuckDB uses
native numbered parameters (also for writes and nested queries). Anonymous DBI
adapters retain separate parameter occurrences instead of copying bound SQL
without its values. Formatter-local timezone suppression and nested query roots
remain separate compilation contexts.

For result sets that should not be accumulated into an array by Selecto, use
the row-streaming API and close it early when iteration stops:

```perl
my $stream = $engine->stream($query, fetch_size => 500);
while (my $row = $stream->next) {
    consume($row);
}
$stream->close;
```

This keeps Selecto itself row-wise. Actual driver and server buffering remains
a DBI-driver concern rather than a promise of a server-side cursor.

## Canned pages and facets

`Selecto::CannedPage` plans a programmer-defined search page without HTTP or
browser dependencies. The host supplies a request-authorized `Selecto::Engine`.
Its dataset query carries fixed scope; detail and aggregate view queries carry
selections, grouping, and ordering. Every selected control predicate is added
to the dataset predicate explicitly. A facet's own selection is excluded only
from that facet's count query.

```perl
use Selecto::CannedPage;

my $page = Selecto::CannedPage->new(
    id => 'products', domain => $domain,
    dataset => {
        query => $engine->query->where(Selecto::Expression->eq('visible', 1)),
        entity_key => ['id'],
    },
    views => [
        {id => 'list', kind => 'detail',
            query => $engine->query->select('id', 'name', 'brand')->order_by('id')},
        {id => 'categories', kind => 'aggregate',
            query => $engine->query->select('category',
                Selecto::Expression->count_distinct('id')->as('items'))
                ->group_by('category')},
    ],
    controls => [
        {id => 'brand', kind => 'facet', field => 'brand',
            values => {source => 'dataset', limit => 30, searchable => 1}},
        {id => 'price', kind => 'range', field => 'price'},
        {id => 'name', kind => 'text', field => 'name', ignore_case => 1},
    ],
    initial_state => {view => 'list', filters => {}},
);

my $result = $page->run($authorized_engine, {
    view => 'list', filters => {brand => ['Acme', 'North']},
}, $request_scope_predicate);
```

`plan` returns the selected view, total, and facet queries without executing
them. `run` returns rows, matching-entity total, bounded facet options, and
pagination state. An aggregate row can drill into a detail view with
`drilldown => {view => 'categories', values => ['Shoes']}`; the group predicate
is added to the existing dataset and control predicates. Fixed options use
`values => {source => 'fixed', options =>
[{value => 'A', label => 'A'}]}`. Facet values within a control use OR; controls
combine with AND. Dataset and Domain restrictions remain in every query.
Detail views may also select an aliased, direct to-many
`Selecto::Expression->related_collection(...)`. Like Explorer's nested detail
columns, it returns child records without multiplying parent rows or changing
the exact entity count used for pagination.
The optional request scope predicate is applied to results, totals, facets,
and drilldowns; excluding a facet's own selection never excludes that scope.

The first profile requires one root primary key as entity identity. Detail
selections are entity-grain fields; aggregate selections are group fields or a distinct
count of the entity key. Text controls use literal-prefix `starts_with` matching;
`ignore_case => 1` applies case-insensitive matching to that control without
turning `%` or `_` in user input into wildcards. Null facet buckets,
composite identities, ordinary sums across many-valued joins, and snapshot
consistency across the separate queries are not yet supported. Use the
Components plugin's `pages` option for a rendered page.

The executable facet fixtures run on SQLite. The Northwind Components example
has also been exercised against a local PostgreSQL database. MySQL, MariaDB,
MSSQL, and DuckDB have not had live canned-page fixture runs. A response
executes one bounded query per facet plus results and total, with an extra
bounded selected-value lookup
when that facet has selections. Separate statements may observe different data
under concurrent writes unless the host gives them a suitable transaction.

## Query libraries

Domains may own reusable query intent under `query_library`. A view composes
named segments, a projection, and an ordering; values supplied to segment
parameters are type-checked and remain adapter-bound.

```perl
my $domain = Selecto::Domain->new(
    name => 'Products',
    table => 'products',
    fields => { id => 'integer', name => 'string', stock => 'integer' },
    query_library => {
        segments => {
            low_stock => {
                filters => [['lt', 'stock', ['param', 'threshold']]],
                parameters => {threshold => {type => 'integer', required => 1}},
            },
        },
        projections => {summary => {fields => [qw(id name stock)]}},
        orderings => {stock_first => {order_by => [['stock', 'asc']]}},
        views => {
            replenishment => {
                segments => ['low_stock'],
                projection => 'summary',
                ordering => 'stock_first',
            },
        },
    },
);

my $query = $engine->apply_view(
    $engine->query,
    'replenishment',
    {threshold => '8'},
);
my $applied = $query->applied_query_library;
```

`segment_picker_groups` declares mutually exclusive choices without changing
the segment IDs used by saved views and API requests. Each group offers an
implicit Off choice (customizable with `off_label`); only one listed segment
may be applied, including when segments come from a named view:

```perl
segment_picker_groups => {
    pdf_sent_to_customer => {
        label => 'PDF sent to customer',
        description => 'Filter by whether a PDF-sent event exists. Off includes both.',
        choices => [
            {segment => 'pdf_sent', label => 'Yes'},
            {segment => 'pdf_not_sent', label => 'No'},
        ],
    },
},
```

For an ordinary field filter backed by a known option catalog, declare
`components.filter_choices` instead of a parameterized segment. The key is
the queryable field path; each choice pairs a stable stored value with its
display name. Hosts can use this to render a multi-select while keeping the
same governed `in` filter and canonical query URL:

```perl
components => {
    filter_choices => {
        'billing_class.option_item_id' => {
            label => 'Billing Class',
            choices => [
                {value => 191, label => 'Corporate'},
                {value => 192, label => 'Retail'},
            ],
        },
    },
},
```

When a value lives on one of two relationships, a virtual choice filter may
declare `conditional` with a root `when_field`, plus `present_field` and
`absent_field`. The selected field is chosen solely by whether `when_field`
is null; a missing value on the chosen side does not fall back to the other.
For example, Quote Billing Class uses the customer's option when `cust_id`
exists, otherwise the quote's option. `filter_picker_hidden_paths` can remove
older physical fields from the Available list without invalidating saved
queries that use them:

```perl
components => {
    filter_choices => {
        lhf_billing_class => {
            label => 'Billing Class',
            choices => [{value => 14, label => 'Private'}],
            conditional => {
                when_field => 'cust_id',
                present_field => 'lhf_customer_option_2.option_item_id',
                absent_field => 'lhf_option_2.option_item_id',
            },
        },
    },
    filter_picker_hidden_paths => [
        'lhf_customer_option_2.', 'lhf_option_2.',
    ],
},
```

Explorer's column and aggregate pickers prefer descriptive relationship fields
over numeric IDs. The root record ID and `client_profile` IDs remain visible;
other ID paths and star-dimension keys remain queryable for existing views but
are hidden from new selections. A domain can explicitly expose an ID with
`components => {picker_visible_id_paths => ['association.id']}`.

A segment may use `['starts_with', 'name', ['param', 'value']]` for a
bound text prefix. The empty prefix matches non-null text; `%`, `_`, and the
SQL escape character in user input remain literal characters. Matching follows
the database collation.

Co-domains let one domain declare a bounded lookup owned and governed by
another domain. The portable contract names the target domain, its reusable
view or projection, searchable fields, and the result mapping; the host still
owns target-engine resolution and request-specific authorization scope:

```perl
co_domains => {
    carriers => {
        domain => 'client',
        view => 'carrier_lookup',
        search => {
            fields => [qw(id co_name cl_key city state)],
            mode => 'prefix', rank => 1,
        },
        result => {
            value_field => 'id', label_field => 'co_name',
            description_fields => [qw(id cl_key city state)],
        },
    },
}

my $result = Selecto::CoDomain->lookup(
    source_domain => $load_domain,
    co_domain => 'carriers',
    engine => $tenant_scoped_client_engine,
    query => $search_text,
    predicate => $selection_specific_scope,
    limit => 20,
);
```

The target engine's mandatory tenant predicate is preserved. The optional
predicate can only further restrict the lookup, which is useful when an action
selection determines eligibility. Co-domain contracts never carry connection
details, raw SQL, or a client-selected target engine.

Definitions are data rather than SQL fragments. Segment composition supports
AND, OR, NOT, NOR, and two-input XOR groups; projection associations become
validated dotted field paths in the Perl runtime. Several named segments can
be applied together with `apply_segments`, which validates their combined
parameter contract before changing the query. Built-in portable parameter
types are validated; application-specific type names pass their values through
for the host boundary to interpret. Query-library `capability` values are
descriptive metadata and do not replace application authorization or database
row-level security.

## Domain overlays and registries

Application-owned customization can remain separate from generated or shared
domain contracts. Overlays are ordinary portable data; the DSL is a fluent
builder for that data rather than a second runtime configuration format.

```perl
my $overlay = Selecto::Domain::DSL->define(sub {
    my ($domain) = @_;
    $domain
        ->source_column(total => {label => 'Order total', format => 'currency'})
        ->source_redact_fields('internal_margin')
        ->write_field(status => {updatable => 1})
        ->capability('orders.export' => {operations => ['read']});
});

my ($orders, $diagnostics) = Selecto::Domain->compose(
    $generated_orders_contract,
    $overlay,
);
```

Composition is deterministic and validates the final strict domain. Maps
deep-merge; `redact_fields` and `extensions` append uniquely; other lists and
scalar values are replaced by later overlays. Updates to existing `actions`,
`capabilities`, `source_relationships`, and `choice_sources` entries produce
structured collision warnings. Invalid overlay shapes and invalid composed
domains fail with typed `Selecto::Error` exceptions.

A registry keeps name-to-domain resolution under server ownership and attaches
provenance without embedding a domain in a caller-controlled reference:

```perl
my $registry = Selecto->domain_registry(name => 'MyApp::Domains')
    ->register(orders => $orders)
    ->register_provider(tenant_orders => sub {
        my ($id, $context) = @_;
        return Selecto::Domain::Registry->forbidden
            unless $context->{can_read_orders};
        return Selecto::Domain::Registry->ok(
            tenant_orders_domain($context->{tenant_id}),
            {version => '2026-08', tenant_id => $context->{tenant_id}},
        );
    });

my ($domain, $ref) = $registry->resolve(
    tenant_orders => {can_read_orders => 1, tenant_id => 42},
);
my $same_domain = $registry->resolve_ref($ref);

my $engine = Selecto->engine_registered(
    domain => $ref,
    adapter => $adapter,
);
```

Provider callbacks must return an explicit `ok`, `not_found`, or `forbidden`
result. Bare hashes, invalid contracts, invalid contexts, registry substitution,
and provider exceptions all fail closed; raw provider exception text is not
exposed. Registry-backed engines retain the resolved reference through
`domain_ref`, so downstream consumers can inspect provenance without accepting
a caller-supplied domain map.

Canonical domains can mark a fact-to-reference join as a star dimension. The
dimension key must be the association's root `owner_key`; `display_field`
names the descriptive field on the joined schema:

```perl
joins => {
    ref_status => {
        type => 'star_dimension',
        name => 'Status',
        display_field => 'description',
        dimension_key => 'status_id',
    },
},
```

The runtime retains both the physical left-join behavior and the semantic
dimension metadata. Aggregate consumers can therefore present the description
while grouping and filtering by the stable fact-table key.

Small reference sets that do not have a physical database table can use a
canonical `values` schema. Each row must provide every declared field, and a
schema must declare exactly one of `source_table` or `values`:

```perl
schemas => {
    status_names => {
        values => [
            {id => 'at', description => 'Active'},
            {id => 'm',  description => 'Maintenance'},
        ],
        primary_key => 'id',
        fields => [qw(id description)],
        columns => {
            id => {type => 'string'},
            description => {type => 'string'},
        },
        associations => {},
    },
},
```

Selecto compiles a referenced values schema as a generated CTE and binds every
cell through the adapter. It can be used by an ordinary association or by a
`star_dimension`; unreferenced values schemas add no SQL to the query.

Canonical associations infer `cardinality => 'one'` when `related_key` targets
the joined schema's primary key and `cardinality => 'many'` otherwise. Domains
can override that inference explicitly. A detail consumer can keep one root row
while selecting child data with a correlated collection:

```perl
Selecto::Expression->related_collection('load_det', [qw(vin)])
    ->as('load_details')
```

The adapter emits a native JSON array of child objects, ordered by the child
primary key where supported, without adding the association to the outer query.
`related_sum('load_det', 'quantity')` and `related_count('load_det', 'id')`
produce separate correlated scalar aggregates over the authorized child set.
They can appear beside a limited JSON collection without changing its rows or
being multiplied by nested associations.

Keyless bridge tables are modeled explicitly rather than pretending the bridge
has an identity. Add `through` to a to-many association with the bridge table's
root and target foreign keys. Tenant-sensitive bridges can also declare all
three scope keys; partial scope metadata fails closed:

```perl
through => {
    table => 'invoice_tags',
    owner_key => 'invoice_id',
    related_key => 'tag_id',
    source_scope_key => 'tenant_id',
    through_scope_key => 'tenant_id',
    target_scope_key => 'tenant_id',
}
```

Selecto joins root to bridge and bridge to target, enforcing both scope
equalities in ordinary association queries and correlated related collections.

Direct associations whose child rows repeat the tenant key can declare
`source_scope_key` and `target_scope_key` on the association itself. Both keys
are required together, validated against their respective schemas, included in
the domain fingerprint, and compiled into ordinary joins and related
collections. This prevents a foreign-key match from bypassing tenant scope.

For a PostgreSQL direct table association whose filtered lookup is badly
misplanned as a repeated table scan, `join_strategy => 'lateral_lookup'` keeps
the owner-key equality, constant `where` predicates, and optional tenant scope
inside a parameterized lookup. PostgreSQL can then use an index on the related
key and constant filter columns. This is an explicit, PostgreSQL-only plan hint:
it does not limit matching rows or change cardinality, and it should be used
only after checking the query plan and providing the supporting index. Through
and inline-values associations cannot use this strategy.

PostgreSQL hierarchical aggregates use `group_by_rollup`. Select the same
governed group expressions first, then add `Selecto::Expression->grouping(...)`
when the caller needs to distinguish detail, subtotal, and grand-total rows:

```perl
my $status = Selecto::Expression->field('status');
my $rollup = $engine->query
    ->select(
        $status->as('status'),
        Selecto::Expression->count->as('order_count'),
        Selecto::Expression->grouping($status)->as('grouping_mask'),
    )
    ->group_by_rollup($status)
    ->order_by($status);
```

Detail-row actions support governed `external_link` destinations and reusable
`iframe_modal` previews, plus native `record_editor` dialogs backed by the
domain's update contract. Modal payloads can declare a templated title, size,
referrer policy, optional iframe permissions, and whether the host should offer
previous/next navigation. Applications still resolve and authorize each action
before rendering it.

An `editors` entry is an explicit allowlist of public root fields already
declared `updatable` under `writes.fields`. It may also name published actions
that should be offered as separate row-targeted workflows. A matching
`record_editor` detail action names the editor and a required target field.
Strict parsing rejects unknown, internal, non-updatable, or duplicated fields
and references to unpublished editors or actions.

Rollup ordering follows Selecto's PostgreSQL compatibility behavior and uses
selected-column positions. A one-group rollup sorts its grouping marker first,
placing the grand total before values while leaving a real NULL bucket last;
multi-group hierarchy ordering uses `NULLS FIRST`. PostgreSQL 17 and older put
that ordering and pagination around a `rollupfix` subquery. The adapter probes
`server_version_num` once and disables the wrapper on PostgreSQL 18+. Pass
`rollup_sort_fix => 1` or `rollup_sort_fix => 0` to the PostgreSQL adapter to
override automatic detection.

## Database adapters

Applications select a registered adapter by stable name. They do not need to
construct a dialect class directly:

```perl
my $adapter = Selecto->adapter($database_name => (dbh => $dbh));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
```

An additional database implementation subclasses `Selecto::Adapter`,
implements the seven required compile/execution methods, returns generic
`Selecto::Statement` values, and registers its package:

```perl
Selecto::Adapter::Registry->default
    ->register(futuredb => 'MyApp::Selecto::FutureDB', contract_version => 1);
```

An independently distributed adapter can register itself when its module is
loaded. `use MyApp::Selecto::FutureDB` is then the only import-time setup the
application needs; `Selecto->adapter('futuredb', ...)` resolves it through the
same lazy registry as built-in adapters. Adapter names are unique and the
registry rejects contract versions other than
`$Selecto::Adapter::CONTRACT_VERSION`. Built-in implementations remain lazily
loaded and the core entrypoint does not import concrete adapter modules.

`Selecto->available_adapters` exposes the names currently registered. This
release registers `postgresql`, `sqlite`, `duckdb`, `mysql`, `mariadb`, and `mssql`. All
inherit portable compilation, execution, and transaction behavior from
`Selecto::SQL`; the MySQL-family pair shares `Selecto::MySQLFamily` DBI
mechanics while retaining separate public classes and target identities. Each concrete package
owns its identity, placeholders, type normalization, capability declarations,
upsert syntax, and dialect-only expressions. SQLite and the MySQL-family
adapters fail closed for PostgreSQL-only bucket and date/time formatting
expressions until native translations are implemented. SQL Server uses guarded
native `MERGE`, bracket-quoted identifiers, and ordered `OFFSET`/`FETCH`
pagination; pagination without an order fails closed.

Document databases use the separate `Selecto::Document::Engine` contract. An
approved `Selecto::Document::ShapeRelease` publishes fields, relations, and
named access patterns; `Selecto::Document::Plan` binds trusted tenant scope and
rejects undeclared projections, predicates, ordering, and unbounded limits.
External document adapters still inherit `Selecto::Adapter`, but may override
the DBI requirement and accept an explicitly injected native client. The first
external consumer is `Selecto::DB::MongoDB`; it remains fixture-only until live
MongoDB certification is recorded.

Application values never enter the SQL string. The compiler emits placeholders
and carries values separately in the statement's `params` array.

## Portable writes

```perl
my $command = Selecto::Write::Command->new(
    operation   => 'update',
    relation    => 'orders',
    assignments => { state => 'closed' },
    predicate   => Selecto::Expression->eq('id', 42),
);

my $preview = $engine->preview_write($command);
my $result = $engine->execute_write($command);
```

The command is portable data; Engine preview and execution validate its table,
fields, and any declared `writes.*` policy against the governing domain before
adapter dispatch. Predicate fields resolve through the domain too: an undeclared
field, an association path, or a computed field in a write predicate fails with
`unknown_field`. Direct adapter calls are the low-level compiler and execution
boundary and do not replace Engine governance.

### Tenant scope

A domain that declares `writes.scope.tenant` cannot be written without a
trusted tenant, and the tenant always comes from the host that builds the
engine, never from the command:

```perl
writes => {
    scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
    ...
},

my $engine = Selecto::Engine->new(
    domain => $domain, adapter => $adapter,
    scope => {tenant => $session->site_id},    # or $engine->with_scope(tenant => ...)
);
```

`field` defaults to `source.tenant_field`, `required` may only be true, and
`satisfied_by` lists the sources the contract accepts. Perl satisfies scope from
`trusted_context` only; a contract that omits it cannot be written here. For
every single write, batch command, and graph node governed by a scoped domain:

- update and delete add `field = tenant` to their scope predicate;
- insert and upsert are assigned the trusted tenant (the tenant field needs no
  `insertable` grant);
- a caller may restate the trusted tenant, but naming another tenant in an
  assignment or predicate, or comparing the tenant field any other way, fails
  with `tenant_mismatch`;
- an upsert must resolve conflicts on a target that includes the tenant field
  (`tenant_scope_conflict_target`);
- an engine without a trusted tenant fails with `missing_tenant_scope`, and so
  does a graph under a scoped root that reaches a nested domain storing the
  tenant field without declaring its own `writes.scope.tenant`.

A scoped engine cannot be re-scoped to another tenant.

Assignments may use an adapter-independent mutation AST. Literal operands stay
bound, identifiers are checked separately, and field references are validated
against the governing domain:

```perl
my $command = Selecto::Write::Command->new(
    operation => 'update',
    relation => 'inventory',
    assignments => {
        quantity => Selecto::Write::Expression->decrement('quantity', 1),
        updated_at => Selecto::Write::Expression->current_timestamp,
    },
    predicate => Selecto::Expression->eq('id', 42),
);
```

The closed AST supports literals, root-field references, addition,
subtraction, multiplication, division, `COALESCE`, `CURRENT_TIMESTAMP`, and a
typed `DEFAULT` node. Field references are update-only because an inserted row
does not yet exist. Dialects that cannot express an individual `DEFAULT`
assignment fail with a typed error.

Write graphs execute ordered nodes in one transaction and feed generated keys
through explicit bindings. Graph construction rejects missing, forward, or
disconnected dependencies, duplicate binding targets, and bindings that would
overwrite authored assignments before an adapter runs. Keys required by later
nodes are added to their source node's internal `RETURNING` shape
automatically. Engine execution also checks each child against the exact
writable relationship and nested domain declared by its parent:

```perl
my $graph = Selecto::Write::Graph->new(nodes => [
    {id => 'order', command => $insert_order_returning_id},
    {
        id => 'line', command => $insert_line_returning_id,
        bindings => [{field => 'order_id', from => 'order', key => 'id'}],
    },
    {
        id => 'allocation', command => $insert_allocation,
        bindings => [{field => 'line_id', from => 'line', key => 'id'}],
    },
]);
my $result = $engine->execute_graph($graph);
```

PostgreSQL and DuckDB advertise native-returning graph execution. SQLite does
so when its runtime library is 3.35 or newer; older SQLite versions fail the
capability check rather than emulating generated-key behavior unsafely.

Adapters own transactions by default. A host that already owns a request or
unit-of-work transaction may opt into `transaction_mode => 'external'` when it
constructs the adapter. External mode requires a DBI handle with `AutoCommit`
disabled and deliberately performs no begin, commit, or rollback; the host must
commit success and roll back every exception. This mode fails closed rather than
silently running an uncommitted write under `AutoCommit`.

Identifiers are validated separately from bound values. Each write and every
batch executes transactionally; an expected-cardinality mismatch rolls back.

The query that selected a row can also guard its later write. Capture immutable
evidence at read time, then attach it to the command at the write boundary:

```perl
my $eligible = $engine->query->where(
    Selecto::Expression->all(
        Selecto::Expression->eq('id', 42),
        Selecto::Expression->eq('status', 'active'),
    ),
);
my $guarded = $engine->enforce_query(
    Selecto::Write::Command->new(
        operation   => 'update',
        relation    => 'orders',
        assignments => { status => 'archived' },
        predicate   => Selecto::Expression->eq('id', 42),
    ),
    $eligible,
);
my $result = $engine->execute_write($guarded);
```

The adapter combines the command predicate, trusted scope, and captured query
predicate in the same database statement. Inserts evaluate the candidate row
against that same effective predicate before opening a transaction. SQL
three-valued logic is preserved, missing root fields and domain drift fail
closed, nested relationship predicates are rejected, and guarded upserts are
unsupported because their insert/update eligibility cannot be expressed by a
single portable rule.

## Governed actions

Domain actions support arbitrary declared update/delete prerequisite filters.
See [the contract and host execution obligations](docs/action-preconditions.md).

Actions project a declared domain action into a constrained write plan; callers
do not supply arbitrary operations or assignments:

```perl
my $plan = Selecto::Action->plan($domain, {
    action => 'archive',
    target => 42,
    inputs => { reason => 'completed', urgent => 'false' },
});

my $preview_decision = Selecto::Action->authorize(
    $plan,
    'preview',
    resolver => sub ($request) { return 'enabled' },
);
```

Row and concrete selected-ID bulk targets have exact cardinality. Transitions
add source-state preconditions. Input declarations normalize booleans and
defaults before deterministic variant or execution-case selection; selected
variants can bind collection-patch metadata and input-backed assignments into
the returned plan. Missing resolvers and hidden or disabled policy decisions
fail closed in both preview and execute phases.

The engine executes update and delete plans itself:

```perl
my $plan = $engine->plan_action({action => 'archive', target => 42});
my $preview = $engine->preview_action($plan, resolver => $policy, context => $ctx);
# {phase => 'preview', action => 'archive', decision => {...}, statement => {sql, params}}
my $done = $engine->execute_action($plan, resolver => $policy, context => $ctx);
# {phase => 'execute', action => 'archive', decision => {...}, result => Selecto::Write::Result}
```

Both phases authorize through the same capability path and build the command
from the plan once (`$engine->action_command($plan)`): plan filters, including
the target, transition source state, and declared preconditions, become the
predicate; changes become assignments (`['system', 'now']` becomes
`CURRENT_TIMESTAMP`); and the planned cardinality becomes the expected row
count. The command then passes through the same governance and tenant scope as
any other write. Insert and upsert plans, collection patches, and opaque
single-use authorization grants remain host responsibilities.

An action can further constrain selected-ID requests with domain metadata:

```perl
selection => {
    mode => 'rows',
    min_rows => 1,
    max_rows => 1,
    presentation => 'row_dialog', # toolbar, row_dialog, or row_inline
},
```

The portable planner enforces `min_rows` and `max_rows` for array targets.
`presentation` is a consumer hint; row presentations require a rows selection
with `max_rows => 1`, while the default `toolbar` presentation supports any
valid row cardinality.

The observation-protocol runner is the sibling `selecto-perl-certification`
package. `bin/selecto-certify` in this repository is a workspace wrapper that
loads that runner so existing certification targets can keep using this
directory as their working tree.

## Verification

```sh
prove -lr t
perl Makefile.PL
make test
```

To run the bounded, live PostgreSQL certificate through the central sibling
harness after installing `DBD::Pg`:

```sh
cd ../selecto_backend_certification
SELECTO_CERT_PERL_POSTGRESQL_URL='postgres://...' \
  mise exec -- mix selecto.certify --targets perl_postgresql,elixir_postgresql
```

SQLite uses an in-memory database by default and needs no service URL:

```sh
cd ../selecto_backend_certification
mise exec -- mix selecto.certify \
  --targets perl_sqlite,elixir_sqlite \
  --profiles capability_truth,core_query,portable_write
```

MySQL and MariaDB require separate live services and certificates even though
both use `DBD::MariaDB`:

```sh
SELECTO_CERT_PERL_MYSQL_URL='mysql://...' \
  mise exec -- mix selecto.certify \
  --targets perl_mysql,elixir_mysql \
  --profiles capability_truth,core_query,portable_write

SELECTO_CERT_PERL_MARIADB_URL='mysql://...' \
  mise exec -- mix selecto.certify \
  --targets perl_mariadb,elixir_mariadb \
  --profiles capability_truth,core_query,portable_write
```

For MSSQL comparisons against domain-resolved decimal/numeric fields, parameters
retain their own exact scale through generated DECIMAL casts. Equality, range,
BETWEEN and IN predicates keep values separately bound; numeric-looking text
fields remain text. Precision beyond 38 digits fails explicitly. This does not
establish coverage for domainless write expressions or unresolved derived-field
types; those paths require separate typed compilation and execution evidence.

Microsoft SQL Server uses `DBD::ODBC`. The default driver name is
`ODBC Driver 18 for SQL Server`; set `SELECTO_PERL_MSSQL_ODBC_DRIVER` when the
installed driver has a different name or when supplying a FreeTDS driver path:

```sh
SELECTO_PERL_MSSQL_ODBC_DRIVER='/path/to/libtdsodbc.so' \
SELECTO_CERT_PERL_MSSQL_URL='mssql://user:password@host:1433/database' \
  mise exec -- mix selecto.certify \
  --targets perl_mssql,elixir_mssql \
  --profiles capability_truth,core_query,portable_write
```

The runner converts that URL to a credential-free ODBC DSN and passes the
decoded username and password separately to DBI. Application code may instead
construct and own any compatible DBI handle and pass it to `Selecto->adapter`.

Certification is controlled differential evidence for the enumerated query,
write, `domain_actions`, and `action_variants` cases. Action certification
covers planning, target scope, transition preconditions, capability decisions,
normalized variant selection, collection-patch binding, and execution-case
assignments. It does not yet certify opaque authorization grants, host action
execution adapters, audit delivery, or replay resistance. The broader
certificate is not proof of arbitrary schemas, SQL, data, driver settings,
concurrency, security, or performance.

## Query-enforced candidate admission

Query-enforced INSERT admission now compares finite decimal/exponent scalars
exactly, using compact significands and arbitrary-integer exponents rather than
native floating point. NaN/infinity operands fail as `query_rule_not_evaluable`
instead of producing undefined-comparison warnings or accidental equality.
IN evaluates all comparable operands, so an earlier match cannot hide a later
non-finite value. NULL comparison still yields SQL unknown. Trusted tenant
scope requires a positive equality or IN over defined, non-reference scalars;
NULL, query-only filters and OR/NOT branches cannot provide that authority.
The shared 239-case scalar fixture is packaged in `t/fixtures/` and executed by
`t/query_enforcement_scalar.t`. This is pure candidate-admission evidence, not
execution of every rule against every database or database-collation emulation.

## Explicitly deferred

- additional database adapters beyond PostgreSQL, SQLite, DuckDB, MySQL,
  MariaDB, and Microsoft SQL Server;
- framework-specific integration beyond the DBI handle boundary.

Unavailable adapter capabilities fail closed instead of falling back to raw
SQL.

Document metadata and plans now use private copied state. Engines reject plans
from another source or tenant before dispatch. Integer document predicates use
`Selecto::Document::Integer`, whose decimal string preserves signed Int64 exactly.
The separate MongoDB adapter must receive the same release and trusted tenant
at construction. Compiled pipeline access is by detached inspection copy.
