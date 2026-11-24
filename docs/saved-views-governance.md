# Governed saved-view rows

These declarations belong to one domain per host table. They do not require a
new schema or a database view. They are additive to the unreleased 0.5.0 write
contract. All ordinary operation, field, capability, tenant and parent-reference
checks still apply. Host bindings are a Perl-only extension pending agreement
with the other runtimes.

Row-revision and host-bound-field writes are supported on SQLite, PostgreSQL,
MySQL and MariaDB. Saved-view storage belongs in the host's database or SQLite.
DuckDB permits reads of these domains, including revision read metadata, but
refuses every write when either `writes.row_revision` or
`writes.host_bound_fields` is declared (even an empty binding map). The error is
`write_capability_missing`, with a message explicitly naming DuckDB and
`details.adapter = duckdb` plus `details.missing` listing the declarations.
The refusal happens at first write-contract admission, before trusted fills or
revision checks. Fluent compilation, previews, batches and nested graph domains
follow the same refusal. Engine construction and reads remain available.
Ordinary DuckDB domains retain their existing write path and the common unique
error contract below.

## Row revisions

Declare exactly one form:

```perl
writes => {
    row_revision => {column => 'version', required => JSON::PP::true},
    # Or, commonly for existing host tables:
    # row_revision => {columns => [qw(name url parent_id)], required => JSON::PP::true},
    # ... explicit operations and field grants ...
}
```

`column` names a stored version/timestamp field, including a declared backend
system field such as PostgreSQL `xmin`. Its token is the exact canonical storage
text. The host/database is responsible for advancing this column when the row
changes. Selecto does not invent a counter. A timestamp advances only when the database/host
maintains it or the field also declares the `modified_at` binding below.

`columns` is a nonempty list of distinct stored root fields. Its token is
`sha256:` followed by 64 lowercase hexadecimal digits. The hash covers ordered
field names, declared types and canonical values: null remains distinct from
empty text; numeric text is normalized without binary floating conversion;
JSON object keys are sorted. Database adapters select exact scalar storage text
before hashing. Timestamps retain fractional precision. SQLite REAL uses
26-digit alternate-form output so adjacent stored doubles remain distinct.
Tokens are opaque and backend/domain-specific; they are not authentication or
capability grants. Include every column whose change should invalidate a save.

`Engine->all` and `BoundedQuery->all` return a `row_revisions` array aligned with
`rows`, while preserving the requested `columns` and cells. Revision inputs are
selected in that same statement and removed before transport, including inputs
that are hidden from the public projection. API query responses carry the same
array; object rows additionally contain `row_revision`. Resource reads contain
`row_revision` automatically. Grouped, aggregate, window, set-operation, retargeted and
alternate-source results have no individual root row revision. The Explorer
feature `revision` retains its separate name.

### One version at the API surface

Without a host `versioner`, a domain declaring `writes.row_revision` also
publishes the virtual, read-only `aggregate_version`. Queries may select it,
including `{field => 'aggregate_version', alias => 'version'}`. Resource reads
return it automatically alongside `row_revision`. Its value is the exact same
token already read by that SELECT, with no second lookup. It appears in the
published domain and OpenAPI fields and cannot be filtered, sorted or written.
Grouped results cannot publish an individual root-row version.

The resource response quotes `aggregate_version` as its `ETag` using the
existing character rule: a nonempty scalar containing only ASCII `!` and
`#` through `~` (no double quote, whitespace or control characters). Null or
other stored tokens still appear in JSON but have no ETag; use the body's
`row_revision` for them. Computed SHA-256 tokens meet the ETag rule.

A configured host `versioner` still wins on reads. Its `aggregate_version`
and ETag remain opt-in, just as before. The resource still returns its
`row_revision`, and writes check only that token. These two tokens differ on
purpose: a host version may cover a larger aggregate than the root row. Such
hosts must use body `row_revision` for writes; `If-Match` is refused as
`if_match_not_supported` (HTTP 422), even if its value looks like a row token.
Domains with neither declaration nor versioner keep their previous reads and
writes; they also refuse `If-Match` as `if_match_not_supported`.

### Conditional API writes

For API update/delete on a domain whose ETag comes from `row_revision`, send
the resource's strong quoted ETag in `If-Match`, the unquoted token in the
body's `row_revision`, or both. Both must agree exactly after removing the
header's enclosing quotes; a mismatch is `row_revision_mismatch` (HTTP 422).
The header becomes ordinary revision metadata on the existing governed write
command. It adds no separate check or mutation path. Insert/upsert with
`If-Match` is `if_match_not_supported` (HTTP 422).

One strong quoted tag is accepted. Header names are case-insensitive and
surrounding HTTP space/tab is ignored. Reject wildcard `*`, weak `W/"..."`,
tag lists, repeated headers and malformed values as `invalid_if_match`
(HTTP 422). A wildcard only tests existence and cannot prevent a lost update;
a weak tag cannot establish the exact revision needed for this comparison.
Lists are refused rather than guessing a revision. Opaque punctuation inside
one tag is preserved without unescaping, under the same ETag character rule.

An obsolete token or missing/inaccessible target is `stale_revision` (HTTP
412), for header and body tokens alike. If the domain requires a token and
neither source supplies one, `row_revision_required` maps to HTTP 428. Optional
omission preserves ordinary governed writes. Existing identity, scope, field
and capability requirements continue to apply.

The HTTP-neutral host forwards headers and handler parameters explicitly:

```perl
my $response = $api->request({
    method => 'POST', path => '/api/panels/write', body => $body,
    headers => {'If-Match' => $if_match}, # omit the entry if absent
}, {
    write => sub {
        my ($body, $params) = @_;
        # Wrap expected Selecto::Error exceptions as ['error', {code => ...,
        # message => ..., details => ...}], as for other API handlers.
        return ['ok', $handler->write($engine, $body, $params)];
    },
});
```

`Selecto::API` passes the raw header as `$params->{if_match}`. Hosts must forward
the second callback argument to `EngineHandler->write` or `write_command` to
enable header validation. Existing body-only calls remain valid. Direct
handler callers can supply `{if_match => '"..."'}` as the third argument.

Pass the token on any supported write surface:

```perl
$engine->write->update->assignments(name => 'Revised panel')
    ->filter(['id', 42])->row_revision($token)->execute;

my $command = Selecto::Write::Command->new(
    operation => 'delete', relation => 'panels',
    predicate => Selecto::Expression->eq('id', 42),
)->row_revision($token);
$engine->execute_write($command);

my $compiled = Selecto::Write::Operation->new($contract)
    ->update({name => 'Revised panel'})->filter(['id', 42])
    ->row_revision($token)->compile(context => $engine->write_context);
```

API write bodies accept `row_revision` alongside `operation`, `assignments` and
`filters`. Tokens apply to update/delete and require a concrete primary-key
identity. They cannot turn a broad write into a row write. A command cannot
supply its own revision declaration or disable the domain's required flag.

A changed row gives `stale_revision` with `details.reason = changed`. An absent
or out-of-scope target gives `stale_revision` with `details.reason = missing`.
No stored values are returned in either error. Omitted tokens retain existing
write behavior unless `required` is true, when `row_revision_required` refuses
the mutation. Invalid tokens or undeclared/unsupported token use give
`invalid_row_revision`; a broad target gives `row_revision_requires_identity`.

Column tokens are compared in the UPDATE/DELETE WHERE clause. Only zero-row
failures perform a follow-up scoped read to distinguish missing from changed;
that read does not authorize a mutation. Computed tokens use a protected read
inside the write transaction: PostgreSQL/MySQL/MariaDB use `FOR UPDATE`; SQLite
uses an immediate transaction (and reserves the writer before reading even in
a host-opened deferred transaction). These write features are not supported on
DuckDB; it does not run a computed-revision check or map writer conflicts to
`stale_revision`.

## Fields bound by the host

```perl
writes => {
    host_bound_fields => {
        owner_id => {mode => 'owner', source => ['context', 'user_id']},
        created_by => {mode => 'created_by', source => ['context', 'actor_id']},
        modified_by => {mode => 'modified_by', source => ['context', 'actor_id']},
        create_timestamp => {mode => 'created_at'},
        modify_timestamp => {mode => 'modified_at'},
    },
    # ... explicit operations and field grants ...
}
```

The host supplies `write_context => {user_id => 11, actor_id => 101}` when it
constructs the engine. Request assignments cannot supply these fields, even
when they restate the correct value: `host_bound_field` names the field.
Missing/null/nonscalar trusted values give `missing_host_context`.

`owner` fills inserts and pins update/delete to the trusted owner. Multiple
owner fields are allowed. This calls the same assignment/predicate code as
`writes.scope.tenant`, with independent trusted context values. `created_by`
fills inserts and is unchanged on updates. `modified_by` fills inserts and
updates; delete requires actor context but removes the row without a separate
audit UPDATE. Host fills do not require caller write grants on these fields.
Rules/validators still apply, and operation/capability grants remain required.
Bindings govern writes; hosts configure owner/company read scopes separately.

`created_at` fills inserts only. `modified_at` fills inserts and every row
changed by an update, including an authorized bulk update. These modes have
no `source` entry and require no clock value in trusted context. Each fill is
the backend's `CURRENT_TIMESTAMP` expression in the INSERT/UPDATE statement,
using the backend's clock, session timezone, transaction semantics and column
precision. They do not promise a strictly increasing value: writes within one
clock tick (or one PostgreSQL transaction) can share a timestamp. Delete does
not perform an audit update. A `created_at` field is unchanged on update.

Timestamp bindings use the same host-bound assignment refusal, private command
provenance and upsert refusal as the context modes. Even a caller-supplied
`CURRENT_TIMESTAMP` expression is refused as `host_bound_field`. Generated
clocks need no caller field grants; validators requiring a submitted literal
remain pending for these database expressions. Native, fluent, portable and API
writes use the same lifecycle. Published domain columns and OpenAPI field
metadata mark all host-bound fields `read_only`, including context bindings.

SQLite, PostgreSQL, MySQL and MariaDB share this expression contract. DuckDB
continues to refuse writes on any host-bound declaration. SQL Server is an
optional external adapter, not shipped or registered here; no SQL Server
implementation is changed by this addition. Domains without timestamp modes
retain their existing clock behavior.

Portable/native generated values retain private in-process provenance through
unchanged command copies. Serialized metadata cannot forge that provenance;
reconstructed commands should omit host-bound assignments and let the current
engine fill them. Changing a generated field or replaying it under different
trusted context is refused. Graph bindings cannot assign a host-bound field.
Host-bound upserts are refused as `host_bound_upsert_unsupported`: creator and
modifier behavior on both branches needs an explicit future contract.

## A child stays in its parent's scope

Use the existing foreign-key context source and tenant guard:

```perl
constraints => {foreign_keys => {
    parent_id => {
        source => ['context', 'writable_parent'], required => JSON::PP::true,
        references => {relation => 'panel_folders', field => 'id', tenant_field => 'company_id'},
    },
}},
```

Trusted context names the authorized destination parent. A different submitted
parent gives `foreign_key_source_mismatch`. The existing SQL EXISTS guard also
checks the referenced parent's `company_id` against the engine tenant. A
nonexistent/out-of-tenant parent refuses with `cardinality_mismatch`. The host
must authorize `writable_parent` before putting it in context. No foreign-key
guard extension or second lookup/write path is needed.

## Unique conflicts

```perl
writes => {
    unique_keys => {owner_name => [qw(owner_id name)]},
    # ...
}
```

The database must enforce the key; this metadata does not create an index or
perform a race-prone uniqueness precheck. Every backend reports
`database_unique_violation`, with `details.constraint = unique` and the key's
`fields` when identified. A matching declaration adds `details.key`. Backend
fields or constraint names resolve the declaration; an ambiguous/unknown key
is not guessed. No conflicting values, SQL or driver messages are exposed.

The integration fixtures are invented domains. Interleaving tests use two
independent connections, insert writer B precisely after A's computed locked
read (or before A's column-checked DML), and verify that only one committed
value survives. A blocked B retries after A commits and receives stale_revision.
Revision/host-field/interleaving tests run on SQLite and PostgreSQL, with
MySQL/MariaDB gated on configured URLs. SQLite uses in-memory connections.
Separate in-memory DuckDB tests cover reads, the write refusal and ordinary
unique conflicts; they need no FFI or second connection.
