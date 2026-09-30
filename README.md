# Selecto

Selecto is a governed data-access layer for Perl applications. You describe a
table and its relationships once, as a *domain*; Selecto then builds immutable
queries against that domain, compiles them to parameterized SQL for your
database, and executes portable writes only when the domain explicitly allows
them. Tenant scope, field visibility and write permissions travel with the
domain instead of being re-checked in every controller. The core is
HTTP-neutral: it takes a DBI handle and returns plain Perl data, so it fits
behind any web framework, job runner or command-line tool.

Selecto is alpha software (version 0.2.0). Its contracts follow the
cross-language Selecto protocol, and the PostgreSQL adapter is certified
against the shared specification suite.

## Installation

Selecto needs Perl 5.34 or newer.

```sh
cpanm Selecto
```

The core does not force any database driver. Install the DBD for each
database you use:

| Database             | Adapter name | Driver                                      |
| -------------------- | ------------ | ------------------------------------------- |
| PostgreSQL           | `postgresql` | `DBD::Pg` 3.016+                            |
| SQLite               | `sqlite`     | `DBD::SQLite` 1.64+                         |
| MySQL                | `mysql`      | `DBD::MariaDB` 1.24+                        |
| MariaDB              | `mariadb`    | `DBD::MariaDB` 1.24+                        |
| Microsoft SQL Server | `mssql`      | `DBD::ODBC` 1.61+ (Unicode build) and an ODBC driver |
| DuckDB               | `duckdb`     | `DBD::DuckDB` 0.16+                         |

To install from a git checkout:

```sh
git clone https://github.com/seeken/selecto-perl.git
cd selecto-perl
cpanm --installdeps .
perl Makefile.PL && make test && make install
```

## Quick start

This complete program uses an in-memory SQLite database (`cpanm DBD::SQLite`).

```perl
use strict;
use warnings;
use DBI;
use Selecto;

# Selecto never opens connections itself: bring any DBI handle.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE suppliers (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
$dbh->do('CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
    supplier_id INTEGER, price DECIMAL(10,2), stock INTEGER NOT NULL)');
$dbh->do(q{INSERT INTO suppliers VALUES (1, 'Acme'), (2, 'Globex')});
$dbh->do(q{INSERT INTO products VALUES
    (1, 'Anvil', 1, 49.99, 3), (2, 'Rope', 1, 9.50, 0), (3, 'Tent', 2, 120.00, 7)});

# 1. Describe what may be read and written: the domain.
my $domain = Selecto::Domain->parse({
    schema_version     => 1,
    domain_version     => '1.0.0',       # published identity; Selecto::API needs
    domain_fingerprint => 'products-v1', # these two, plain queries do not
    name   => 'Products',
    source => {
        source_table => 'products',
        primary_key  => 'id',
        fields  => [qw(id name supplier_id price stock)],
        columns => {
            id          => {type => 'integer'},
            name        => {type => 'string'},
            supplier_id => {type => 'integer'},
            price       => {type => 'decimal'},
            stock       => {type => 'integer'},
        },
        associations => {
            supplier => {queryable => 'suppliers',
                owner_key => 'supplier_id', related_key => 'id'},
        },
    },
    schemas => {
        suppliers => {
            source_table => 'suppliers', primary_key => 'id',
            fields  => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}},
            associations => {},
        },
    },
    joins  => {supplier => {type => 'left'}},
    writes => {
        operations => {update => {enabled => 1}},
        fields     => {stock  => {updatable => 1}},
    },
});

# 2. Pair it with an adapter for your database.
my $engine = Selecto::Engine->new(
    domain  => $domain,
    adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
);

# 3. Build an immutable query and run it.
my $query = $engine->query
    ->select('name', 'supplier.name', 'price')
    ->where(Selecto::Expression->gt('stock', 0))
    ->order_by('name')
    ->limit(10);

my $result = $engine->all($query);
print join(', ', @{$result->{columns}}), "\n";
print join(' | ', @$_), "\n" for @{$result->{rows}};
```

Output:

```text
name, supplier.name, price
Anvil | Acme | 49.99
Tent | Globex | 120
```

The remaining examples in this README continue from this program.

## Core concepts

### Domains

A `Selecto::Domain` is the contract for one root table: its columns and
types, its relationships to other tables, which fields are internal, and which
writes are allowed. Every field path a query names (`name`,
`supplier.name`, `supplier.region.code`) is resolved against the domain; an
unknown path is an error, not a guess. Domains are plain data, so they can be
stored as JSON, generated from a schema, composed from overlays, and
fingerprinted. See `perldoc Selecto::Domain` for the full format, including
computed columns, many-to-many "through" associations and inline value lists.

### Queries and expressions

`Selecto::Query` objects are immutable: every builder method returns a new
query. Filters, selections and aggregates are `Selecto::Expression` values,
and every literal becomes a bound parameter.

```perl
my $totals = $engine->all(
    $engine->query
        ->select('supplier.name',
            Selecto::Expression->count->as('products'),
            Selecto::Expression->sum('stock')->as('units'))
        ->where(Selecto::Expression->any(
            Selecto::Expression->text_contains('name', 'n'),
            Selecto::Expression->between('price', 100, 200)))
        ->group_by('supplier.name')
        ->order_by('supplier.name'));
print join(' | ', @$_), "\n" for @{$totals->{rows}};

# Look at the SQL without running it.
my $statement = $engine->compile($query);
print $statement->sql, "\n";
print join(', ', @{$statement->params}), "\n";   # the bound values
```

Filters can also be written as a portable array AST, which is how they
usually arrive from a client:

```perl
my $filter = Selecto::Expression->from_filter_ast(
    ['and', [['gte', 'stock', 1], ['starts_with', 'supplier.name', 'Ac']]]);
my $rows = $engine->all($engine->query->select('name')->where($filter))->{rows};
```

`perldoc Selecto::Query` covers CTEs, recursive CTEs, set operations, window
functions, rollups and streaming; `perldoc Selecto::Expression` lists every
expression constructor.

### Engines and adapters

A `Selecto::Engine` binds one domain to one adapter and is the object your
code talks to. Adapters are looked up by name with `Selecto->adapter`, and each
wraps a DBI handle you own. Adapters report what they support
(`$engine->adapter->supports('rollup')`), and a query that needs an
unsupported feature fails before any SQL is sent.

Large results can be read row by row:

```perl
my $stream = $engine->stream($engine->query->select('id', 'name')->order_by('id'),
    fetch_size => 500);
while (my $row = $stream->next) {
    print "$row->[0] $row->[1]\n";
}
$stream->close;
```

### Portable writes

Writes are commands checked against the domain's `writes` contract before the
adapter sees them. The default write policy is strict: an operation or field
the domain does not grant is refused. `expected_count` is enforced inside the
transaction, and a mismatch rolls back.

```perl
my $command = $engine->write_command(
    operation      => 'update',
    assignments    => {stock => 10},
    filter         => ['eq', 'id', 2],
    expected_count => 1,
);
print $engine->preview_write($command)->{sql}, "\n";   # compile only
my $written = $engine->execute_write($command);
print $written->affected_rows, " row updated\n";

# price is not writable in this domain, so this is refused.
eval { $engine->write_command(operation => 'update',
    assignments => {price => 1}, filter => ['eq', 'id', 2]) };
print $@->code, "\n";                                  # write_field_not_writable
```

Batches, multi-table write graphs, arithmetic assignments and query-guarded
writes are described in `perldoc Selecto::Write`.

### Tenant scope

When one table holds several tenants' rows, declare the tenant field and give
the engine the tenant from your authenticated session. Reads are then scoped
automatically, inserts receive the tenant, and a command that names another
tenant fails.

```perl
$dbh->do('CREATE TABLE notes (id INTEGER PRIMARY KEY, shop_id INTEGER NOT NULL, body TEXT)');
$dbh->do(q{INSERT INTO notes VALUES (1, 7, 'ours'), (2, 8, 'theirs')});

my $notes = Selecto::Domain->parse({
    schema_version => 1,
    name   => 'Notes',
    source => {
        source_table => 'notes', primary_key => 'id', tenant_field => 'shop_id',
        fields  => [qw(id shop_id body)],
        columns => {id => {type => 'integer'}, shop_id => {type => 'integer'},
                    body => {type => 'string'}},
        associations => {},
    },
    writes => {
        scope      => {tenant => {field => 'shop_id', satisfied_by => ['trusted_context']}},
        operations => {insert => {enabled => 1}, update => {enabled => 1}},
        fields     => {body => {insertable => 1, updatable => 1}},
    },
});

# The tenant comes from your authenticated session, never from the request body.
my $shop7 = Selecto::Engine->new(
    domain  => $notes,
    adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
    scope   => {tenant => 7},
);

my $rows = $shop7->all($shop7->query->select('id', 'body'))->{rows};
print scalar(@$rows), " visible note(s)\n";                   # 1 visible note(s)

$shop7->execute_write($shop7->write_command(
    operation => 'insert', assignments => {body => 'new'}));   # shop_id 7 is added

eval { $shop7->execute_write($shop7->write_command(
    operation => 'update', assignments => {body => 'x'},
    filter => ['eq', 'shop_id', 8])) };
print $@->code, "\n";                                         # tenant_mismatch
```

Domains that express the boundary as a required predicate instead are covered
under `with_required_predicate` in `perldoc Selecto::Domain`.

### Governed actions

Actions are named, declared state changes such as "archive" or "restock". A
caller asks for an action by name and target; the domain decides the
operation, the assignments and the preconditions, and your policy callback
decides whether the caller may run it. Without a callback the action is
refused.

```perl
# Domains are data: derive one that also declares a "restock" action.
my $shop = Selecto::Domain->parse({
    %{$domain->contract},
    actions => {
        restock => {
            type => 'row_action', scope => 'row', capability => 'products.restock',
            preconditions => [['stock', 0]],
            execution => {kind => 'updato', operation => 'update', set => {stock => 25}},
        },
    },
    capabilities => {
        'products.restock' => {operations => ['action', 'update'], action => 'restock'},
    },
});
my $shop_engine = Selecto::Engine->new(domain => $shop, adapter => $engine->adapter);

# Your policy decides; it returns 'enabled', 'disabled' or 'hidden'.
my $policy = sub {
    my ($request, $context) = @_;
    return $context->{role} eq 'manager' ? 'enabled' : 'hidden';
};

my $plan = $shop_engine->plan_action({action => 'restock', target => 2});
my $done = $shop_engine->execute_action($plan,
    resolver => $policy, context => {role => 'manager'});
print $done->{result}->affected_rows, " product restocked\n";

# Product 1 still has stock, so the precondition matches no row.
eval { $shop_engine->execute_action(
    $shop_engine->plan_action({action => 'restock', target => 1}),
    resolver => $policy, context => {role => 'manager'}) };
print $@->code, "\n";                                  # cardinality_mismatch
```

`perldoc Selecto::Action` covers inputs, variants, bulk targets and
single-use grants for confirm-then-execute flows.

### Errors

Every failure Selecto raises is a `Selecto::Error` exception with a stable
`code`, a human-readable `message` and a `details` hash. Match on `code`, not
on the message text.

```perl
my $ok = eval { $engine->all($engine->query->select('cost_price')); 1 };
if (!$ok) {
    my $error = $@;
    print $error->code, ': ', $error->message, "\n";   # unknown_field: ...
}
```

Database errors are wrapped as `query_error` without the driver's message, so
connection strings and SQL fragments do not leak into responses.

## Integration

### Web applications

The core has no routes or templates. `Selecto::API` implements the canonical
Selecto HTTP contract as a pure function from a request hash to a response
hash, and `Selecto::API::EngineHandler` turns API query and write bodies into
governed engine calls. Your framework maps its request onto that hash and
sends back `status`, `headers` and `body`:

```perl
use Scalar::Util qw(blessed);
use Selecto::API;
use Selecto::API::EngineHandler;

my $api = Selecto::API->new(domain => $engine->domain, base_path => '/api/products');
my $handler = Selecto::API::EngineHandler->new(default_limit => 50, max_limit => 500);
$handler->describe_openapi($api);

# Turn a Selecto::Error into the ['error', ...] shape Selecto::API expects.
my $guard = sub {
    my ($code) = @_;
    my $data = eval { $code->() };
    return ['ok', $data] unless $@;
    my $e = $@;
    die $e unless blessed($e) && $e->isa('Selecto::Error');
    return ['error', {status => 422, code => $e->code,
        message => $e->message, details => $e->details}];
};

# In a real app these come from your router; $engine from your auth layer.
my $response = $api->request(
    {method => 'POST', path => '/api/products/query',
     body => {select => ['name', 'stock'], order_by => [{field => 'name'}],
              filters => [{field => 'stock', op => 'gt', value => 0}]},
     accept => 'application/json'},
    {query => sub { my ($body) = @_; $guard->(sub { $handler->query($engine, $body) }) },
     write => sub { my ($body) = @_; $guard->(sub { $handler->write($engine, $body) }) }},
);
print "$response->{status} $response->{headers}{'content-type'}\n";
print $response->{body}, "\n";   # UTF-8 encoded canonical JSON bytes
```

The same routes serve `GET .../domain` and `GET .../openapi.json`, and query
responses can be negotiated as CSV, TSV or XLSX. For a ready-made
Mojolicious user interface (an explorer, saved views, action dialogs), see the
separate [Selecto::Components](https://github.com/seeken/selecto-perl-components)
distribution, which builds on this core.

### Adapters

Pick an adapter by name and pass it a DBI handle you configured. Adapters own
transactions by default; if your application already has a unit-of-work
transaction open, construct the adapter with `transaction_mode => 'external'`
and an `AutoCommit => 0` handle, and commit or roll back yourself. To support
another database, subclass `Selecto::SQL` (or `Selecto::Adapter` for non-SQL
stores) and register it under a lowercase name; see `perldoc Selecto::Adapter`.

### Security checklist

- Build the engine per request from trusted context. Take the tenant from
  your session and pass it as `scope => {tenant => ...}`, or narrow the domain
  with `with_required_predicate`; never read either from the request body.
- The public surfaces (`Selecto::API::EngineHandler`, `Selecto::CannedPage`,
  `Selecto::CoDomain`) fail closed with `missing_tenant_scope` when a domain
  declares a tenant field but the engine carries no tenant boundary.
  `$engine->all` is deliberately usable for trusted, cross-tenant host code.
- Never build SQL from client input. Field names are resolved against the
  domain, values are always bound, and there is no raw-SQL escape hatch;
  anything an adapter cannot express fails with an error.
- Mark columns `internal` or list them in `redact_fields` to keep them out of
  API selections, filters and catalogs.
- Keep the default strict write policy. `write_policy => 'permissive'` and the
  adapters' `execute_*_unsafe` methods exist for trusted tooling and tests.
- Keep credentials in the DBI handle. Selecto's errors and JSON output do not
  include connection details, and yours should not either.

## More features and documentation

After installing, `perldoc Selecto` gives an overview and a map of every
module. Beyond the core pages named above, these features each have their
own manual page:

- `Selecto::QueryLibrary` - named, parameterized segments, projections,
  orderings and views declared in the domain.
- `Selecto::CannedPage` - faceted search pages with counts and drill-down.
- `Selecto::CoDomain` - governed lookups into another domain.
- `Selecto::Domain::DSL` and `Selecto::Domain::Registry` - overlays for
  customizing shared domains, and server-owned name-to-domain resolution.
- `Selecto::Importer` - CSV inspection and governed import previews.
- `Selecto::Files` - an HTTP-neutral attachment facade (experimental).
- `Selecto::FieldPolicy` - resolve which form fields are hidden, read-only or
  editable.

Longer design notes live in [docs/](docs/):
[action preconditions](docs/action-preconditions.md),
[analytics units](docs/analytics-units.md) and
[DuckDB result transport](docs/duckdb-result-transport.md).

## Certification

In a git checkout, `bin/selecto-certify` runs the Selecto observation protocol
against an adapter for the central cross-language certification harness. It is
not installed from CPAN: it needs the sibling `selecto-perl-certification`
checkout (or `SELECTO_LIVE_SELECTO_PERL_CERTIFICATION` pointing at one); see
`perldoc bin/selecto-certify`.

## Development

```sh
cpanm --installdeps .
prove -lr t
perl Makefile.PL && make test
```

Tests that need a live server are skipped unless you provide a disposable
database: `SELECTO_PERL_TEST_POSTGRES_URL`, `SELECTO_PERL_TEST_MYSQL_URL`,
`SELECTO_PERL_TEST_MARIADB_URL` or `SELECTO_PERL_TEST_MSSQL_URL`. SQLite and
DuckDB tests run in memory when their drivers are installed. Test data must be
synthetic, and credentials must never appear in fixtures or output.

Issues and pull requests are welcome at
<https://github.com/seeken/selecto-perl>.

## License

Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under the Artistic License 2.0 (GPL
compatible). See [LICENSE](LICENSE).
