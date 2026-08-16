# selecto-perl

`selecto-perl` is the native Perl implementation of Selecto's governed domain,
immutable query, database-adapter, and portable write contracts. Mojolicious
supplies a small object foundation and named adapter registry. The core remains
HTTP-neutral: DBI supplies the execution boundary, while routes, ORMs, and UI
code remain in consumer applications.

This is an alpha library. Its current compatibility target is observation
protocol 1 and certification specification 1.2.0.

## Current surface

- strict simplified and canonical schema-v1 JSON domain parsing;
- validated root and one-hop relationship field resolution;
- deterministic SHA-256 domain fingerprints;
- copy-on-write select, filter, group, order, limit, and offset queries;
- field, literal, comparison, null, membership, conjunction, and aggregate
  expressions;
- PostgreSQL compilation with quoted identifiers and bound `$1` parameters;
- DBI execution with stable columns and normalized PostgreSQL values;
- a versioned `Selecto::Adapter` contract, generic `Selecto::Statement`, and
  runtime adapter registry for independently packaged database support;
- portable insert, update, upsert, delete, expected-cardinality, and atomic
  batch writes;
- governed row and selected-id bulk action planning with explicit transition
  preconditions and fail-closed preview/execute capability decisions;
- adapter capability reporting and an observation-protocol runner for central
  backend certification.

It does not contain HTTP routes, ORM, or UI compatibility code.

## Install for development

Perl 5.34 or newer and Mojolicious 9.40 or newer are required. PostgreSQL
execution and certification additionally require `DBD::Pg`; the base
distribution can be installed for another adapter without that driver.

```sh
cpanm --installdeps .
cpanm DBD::Pg # only when using the PostgreSQL adapter
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

my $domain = Selecto::Domain->parse($domain_json, strict => 1);
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
release registers only `postgresql`; the contract and registry are the stable
extension seam, not a claim that other dialects already work.

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

Update and delete predicates are deliberately limited to equality in protocol
1. Identifiers are validated separately from bound values. Each write and every
batch executes transactionally; an expected-cardinality mismatch rolls back.

## Governed actions

Actions project a declared domain action into a constrained write plan; callers
do not supply arbitrary operations or assignments:

```perl
my $plan = Selecto::Action->plan($domain, {
    action => 'archive',
    target => 42,
});

my $preview_decision = Selecto::Action->authorize(
    $plan,
    'preview',
    resolver => sub ($request) { return 'enabled' },
);
```

Row and concrete selected-ID bulk targets have exact cardinality. Transitions
add source-state preconditions. Missing resolvers and hidden or disabled policy
decisions fail closed in both preview and execute phases. The library currently
returns the governed plan; applying it through a host execution adapter and
issuing or consuming opaque authorization grants remain separate future
boundaries.

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

Certification is controlled differential evidence for the enumerated query,
write, and domain-action cases. Action certification currently covers planning,
target scope, transition preconditions, and capability decisions. It does not
yet certify opaque authorization grants, host action execution adapters, audit
delivery, or replay resistance. The broader certificate is not proof of
arbitrary schemas, SQL, data, driver settings, concurrency, security, or
performance.

## Explicitly deferred

- CTEs, recursive queries, windows, set operations, rollups, lateral joins,
  JSON rowsets, full-text search, and streaming;
- deeper-than-one-hop relationships;
- nested portable write graphs and adapter-independent mutation expressions;
- concrete non-PostgreSQL adapters (the registration contract is implemented);
- framework-specific integration beyond the DBI handle boundary.

Deferred capabilities fail closed instead of falling back to raw SQL.
