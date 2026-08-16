# selecto-perl

`selecto-perl` is the native Perl implementation of Selecto's governed domain,
immutable query, PostgreSQL adapter, and portable write contracts. The core is
framework-neutral: DBI supplies the execution boundary, while web frameworks,
ORMs, and UI code remain in consumer applications.

This is an alpha library. Its current compatibility target is observation
protocol 1 and certification specification 1.1.0.

## Current surface

- strict simplified and canonical schema-v1 JSON domain parsing;
- validated root and one-hop relationship field resolution;
- deterministic SHA-256 domain fingerprints;
- copy-on-write select, filter, group, order, limit, and offset queries;
- field, literal, comparison, null, membership, conjunction, and aggregate
  expressions;
- PostgreSQL compilation with quoted identifiers and bound `$1` parameters;
- DBI execution with stable columns and normalized PostgreSQL values;
- portable insert, update, upsert, delete, expected-cardinality, and atomic
  batch writes;
- adapter capability reporting and an observation-protocol runner for central
  backend certification.

It does not contain HTTP, PSGI, ORM, or UI compatibility code.

## Install for development

Perl 5.34 or newer is required. PostgreSQL execution and certification require
`DBD::Pg`; compilation and the unit suite do not open a database.

```sh
cpanm --installdeps .
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
    adapter => Selecto::PostgreSQL->new(dbh => $dbh),
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

Certification is controlled live differential evidence for the 37 enumerated
cases. It is not proof of arbitrary schemas, SQL, data, driver settings,
concurrency, security, or performance.

## Explicitly deferred

- CTEs, recursive queries, windows, set operations, rollups, lateral joins,
  JSON rowsets, full-text search, and streaming;
- deeper-than-one-hop relationships;
- nested portable write graphs and adapter-independent mutation expressions;
- non-PostgreSQL adapters;
- framework-specific integration beyond the DBI handle boundary.

Deferred capabilities fail closed instead of falling back to raw SQL.

