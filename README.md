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
- validated root and one-hop relationship field resolution;
- deterministic SHA-256 domain fingerprints;
- canonical component policy metadata, including domain-selected private URL
  state for compatible exploration UIs;
- copy-on-write select, filter, group, order, limit, and offset queries;
- field, literal, comparison, null, membership, conjunction, and aggregate
  expressions, plus governed PostgreSQL date/time format expressions;
- PostgreSQL compilation with quoted identifiers and bound `$1` parameters;
  SQLite, DuckDB, MySQL, MariaDB, and Microsoft SQL Server compilation with native
  identifier quoting and DBI `?` parameters;
- DBI execution with stable columns and backend-specific value normalization;
- a versioned `Selecto::Adapter` contract, generic `Selecto::Statement`, and
  runtime adapter registry for independently packaged database support;
- portable insert, update, upsert, delete, expected-cardinality, and atomic
  batch writes;
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
    ->register(sqlite => 'Selecto::SQLite');
```

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

my $preview = $engine->adapter->preview_write($command);
my $result = $engine->execute_write($command);
```

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
my $evidence = $engine->query_enforcement_evidence($eligible);

my $guarded = Selecto::Write::Command->new(
    operation      => 'update',
    relation       => 'orders',
    assignments    => { status => 'archived' },
    predicate      => Selecto::Expression->eq('id', 42),
    query_evidence => $evidence,
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

- CTEs, recursive queries, windows, set operations, rollups, lateral joins,
  JSON rowsets, full-text search, and streaming;
- deeper-than-one-hop relationships;
- nested portable write graphs and adapter-independent mutation expressions;
- additional database adapters beyond PostgreSQL, SQLite, MySQL, MariaDB, and
  Microsoft SQL Server;
- framework-specific integration beyond the DBI handle boundary.

Deferred capabilities fail closed instead of falling back to raw SQL.
