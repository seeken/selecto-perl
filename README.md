# selecto-perl

`selecto-perl` is the native Perl implementation of Selecto's governed domain,
immutable query, database-adapter, and portable write contracts. Mojolicious
supplies a small object foundation and named adapter registry. The core remains
HTTP-neutral: DBI supplies the execution boundary, while routes, ORMs, and UI
code remain in consumer applications.

This is an alpha library. Its current compatibility target is observation
protocol 1 and certification specification 2.3.0.

## Current surface

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
- field, literal, comparison, null, membership, conjunction, aggregate,
  window, and PostgreSQL full-text expressions, plus governed PostgreSQL
  date/time format expressions;
- PostgreSQL compilation with quoted identifiers and bound `$1` parameters;
  SQLite, DuckDB, MySQL, MariaDB, and Microsoft SQL Server compilation with native
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
- an HTTP-neutral canonical domain API host with OpenAPI 3.1 and byte-stable
  UTF-8 JSON response bodies;
- adapter capability reporting and an observation-protocol runner for central
  backend certification.

It does not contain HTTP routes, ORM, or UI compatibility code.

## Install for development

Perl 5.34 or newer and Mojolicious 9.40 or newer are required. PostgreSQL
execution and certification additionally require `DBD::Pg`; SQLite execution
and certification require `DBD::SQLite`; MySQL and MariaDB use
`DBD::MariaDB`; Microsoft SQL Server uses a Unicode-enabled `DBD::ODBC` build
and an installed ODBC driver. The base distribution does not force any
optional driver.

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

`order_by` may be repeated to build a stable multi-column order. For governed
date/time projection or grouping, use an allowlisted expression such as
`Selecto::Expression->datetime_format('occurred_on', 'month')` consistently in
`select`, `group_by`, or `order_by`; arbitrary database format strings are not
accepted. Portable comparison intents include `eq`, `ne`, `gt`, `gte`, `lt`,
`lte`, and `between`; their values compile as adapter-bound parameters.

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
adapter dispatch. Direct adapter calls are the low-level compiler and execution
boundary and do not replace Engine governance.

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
fail closed in both preview and execute phases. Applying the plan through a host
execution adapter and issuing or consuming opaque authorization grants remain
separate future boundaries.

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

## Explicitly deferred

- additional database adapters beyond PostgreSQL, SQLite, DuckDB, MySQL,
  MariaDB, and Microsoft SQL Server;
- framework-specific integration beyond the DBI handle boundary.

Unavailable adapter capabilities fail closed instead of falling back to raw
SQL.
