# Domain catalog

`Selecto::DomainCatalog` combines trusted code factories, JSON files and a
host-owned revisioned store. It describes declarations and validates them
without running queries. Hosts decide visibility and privileges before exposing
catalog metadata. Catalog IDs are independent of the authorization-aware
`Selecto::Domain::Registry`; this catalog does not grant registry access.

```perl
use Selecto::DomainCatalog;
use Selecto::DomainCatalog::Source::Code;
use Selecto::DomainCatalog::Source::File;
use Selecto::DomainCatalog::Source::Store;
use Selecto::Expression;

my $catalog = Selecto::DomainCatalog->new(
    adapter => 'sqlite',
    sources => [
        Selecto::DomainCatalog::Source::Code->new(
            domains => {orders => sub { orders_domain() }}, label => 'orders registry'),
        Selecto::DomainCatalog::Source::File->new(directory => '/contracts'),
        Selecto::DomainCatalog::Source::Store->new(store => $store, label => 'contracts'),
    ],
    allowed_sources => [qw(orders notes customers accounts)],
    scope_policies => {by_account => sub {
        my ($domain, $entry) = @_;
        return {required_predicate => Selecto::Expression->eq('account_id', $account_id),
            tenant_field => 'account_id'};
    }},
    checks => [sub {
        my ($domain, $entry) = @_;
        return [];  # or [{status => 'warning', code => 'review', message => 'Review', path => '$.actions'}]
    }],
);
my $entries = $catalog->list;
my $domain = $catalog->get('orders');
my $json = $catalog->document('orders');
my $report = $catalog->report('orders');
```

Use distinct IDs across these sources. Construction and subsequent refreshes
refuse duplicates with `duplicate_domain`; error details identify both source
references. A file/store document declares its own identity and scope key:

```json
{"extensions":{"catalog":{"id":"orders","adapter":"sqlite","scope_policy":"by_account"}}}
```

These are ordinary domain extension metadata; no parser keys or domain schema
versions were added. Code IDs come from the factory map. A code source's
`adapter` overrides the extension; otherwise the extension overrides the
catalog default. Adapter names resolve through the existing registry, optionally
supplied as `registry`. An absent/unknown adapter fails engine admission.

`list` returns a sorted array of `{id, name, version, fingerprint, adapter,
source, status, validation_status}`. Version is `domain_version`. Source is
`{kind: "code", ref: {label}}`, `{kind: "file", ref: {path, commit?}}`, or
`{kind: "store", ref: {key, revision, label?}}`. Listing strictly parses metadata
but builds no engine, calls no host validation checks and executes no SQL.
`validation_status` on a list entry describes parsing only; use `report` for the
complete checks. Code factories run once per source instance. Files and store
current pointers are reread on each public operation. Malformed JSON and missing
IDs remain reportable under their file path/store key and cannot be served.
A file source accepts an optional host-supplied `commit`; it does not infer that
a potentially dirty working tree corresponds to HEAD.

`get` strictly parses each distinct document once, caches successful and failed
parses by content identity, runs validation, and serves a cached domain object.
Treat returned domains as immutable, as with existing configured domains.
`document` serializes the served domain's portable document using the existing
canonical encoder (`as_document`, which uses `as_contract` for schema 1).
This preserves schema 2 and schema 1 fingerprint semantics, including schema 1's
authored numeric/boolean representations; converting legacy numeric flags to
JSON booleans would change existing fingerprints. `contract_json` supplies the
existing fallback for code-built runtime-predicate domains. Such a document
represents the portable declaration, not an executable host predicate.

## Scope and source admission

File/store domains must name a known scope policy. Missing policies fail closed.
They cannot declare `required_predicate`, `required_filters`, `tenant`,
`tenant_required`, `require_tenant`, relation `tenant_field`, or `writes.scope`.
The same checks apply to nested write relationship domains. Code domains retain
their existing required predicates and tenant declarations.

`scope_policies` maps keys to trusted host callbacks. Each callback receives
`($parsed_domain, $entry_copy)` and returns
`{required_predicate => $expression, tenant_field => $optional_root_field}`.
The required predicate must be a `Selecto::Expression`. The catalog uses existing
`with_tenant_field` and `with_required_predicate` methods; the resulting domain
therefore enforces the predicate through normal engine reads and write guards.
The callback cannot replace the table/fields or return arbitrary engine options.
Exceptions are redacted, and missing predicates refuse serving. Policies execute
once per ID/fingerprint within this catalog. Create a catalog per trusted scope
context; never share an account-specific catalog between accounts. Pin identity
and entry fingerprint describe the portable document; the scoped runtime
domain's fingerprint also includes its trusted obligation and can differ.
The exported JSON intentionally does not contain account bindings.

`allowed_sources` is an exact list of permitted SQL table identities, including
schema-qualified names when used. There are no wildcards or implicit default
schemas: `orders` and `reporting.orders` are distinct permissions. Omission means
no table is allowed for JSON domains. Root, all schema relations (even unused
ones), association through tables, FTS index tables and nested write-domain
sources are checked. Existing strict parsing requires repeated join sources to
agree with the target schema. Inline VALUES relations name no SQL table.

## Stores and pins

A host store implements:

- `list()` returns `[{key, revision}, ...]`, one current revision per key.
- `fetch($key, $revision)` returns the exact contract hash or JSON string.

Revisions must be immutable. A list must identify current revisions consistently;
a fetched revision must remain available while pinned. Publish the immutable
revision before advancing current. Missing revisions throw; fetch never falls
back to a newer revision. `Selecto::DomainCatalog::MemoryStore` provides `new`,
`put($key, $revision, $document)`, `list`, and `fetch` as a **non-durable** reference
for tests. `put` selects current and refuses to overwrite a revision.

```perl
pins => {
    orders => {fingerprint => $expected, document => $earlier_contract},
    notes => {fingerprint => $expected_notes, revision => 'revision-7'},
}
```

All pins require a computed fingerprint, never the opaque authored
`domain_fingerprint` label. For files and code, supply the matching earlier
`document` when starting against already changed content. If current initially
matches, the catalog retains that snapshot in memory for its lifetime. It never
loads arbitrary Git history. A store pin may supply `revision`, fetched through
the exact-revision interface; a matching `document` is also accepted. The pin's
fingerprint must match the supplied/fetched document. A mismatch or absent
snapshot yields `catalog_pin_unavailable` on `get`/`document`; it never serves
current as a substitute. Pinned documents undergo the same current host safety,
adapter and validation checks as unpinned documents.

`list` and `report` describe current, and use `status: "changed"` when current
no longer matches a pin, even if current is also invalid. `validation_status`
retains the independent validation result. `diff` compares current against the
retained pin. If the pinned baseline is unavailable, `diff` is null and the
report includes `pin / catalog_pin_unavailable`; serving fails closed. `get` and
`document` continue to serve the validated pin, and its original source revision,
as long as the ID remains in the source. Removing an ID makes it unavailable.

## Reports and diffs

`report($id, against => $earlier_contract_or_retained_fingerprint)` and
`report_all` return data-only results. Fingerprint baselines must have been seen
by this catalog; unknown ones throw `catalog_baseline_missing`. They are not
fetched from a global registry. An explicit `against` selects the diff baseline;
pin mismatch still determines `changed` status.

```json
{
  "id":"orders",
  "status":"changed",
  "validation_status":"ok",
  "entry":{"id":"orders","name":"Orders","version":"2","fingerprint":"sha256:...","adapter":"sqlite","source":{"kind":"file","ref":{"path":"/contracts/orders.json"}}},
  "checks":[
    {"stage":"strict_parse","status":"ok","code":"strict_parse_ok","message":"Check passed","path":"$"},
    {"stage":"scope_policy","status":"ok","code":"scope_policy_ok","message":"Check passed","path":"$"},
    {"stage":"allowed_sources","status":"ok","code":"allowed_sources_ok","message":"Check passed","path":"$"},
    {"stage":"query_library","status":"ok","code":"query_library_ok","message":"Check passed","path":"$.query_library"},
    {"stage":"engine_admission","status":"ok","code":"engine_admission_ok","message":"Check passed","path":"$"}
  ],
  "diff":{"fields":{"added":[{"name":"priority","path":"$.source.columns.priority"}],"removed":[],"changed":[]}}
}
```

The abbreviated example's `diff` is shown in full shape below. Check statuses
are `ok`, `warning`, `refused`, or `skipped`. Aggregate validation is `refused`
if any check refuses, otherwise `warning` if any warns, otherwise `ok`.
`changed` is a separate visible pin state. Checks always include stage, status,
code, message and JSON path. Native structured diagnostic paths are retained;
errors without a native member path use the stage root. Parse failures skip
engine admission. Query-library/segment declarations also use the existing
pure declaration validator, so they can produce findings despite a parse
failure. Parsing itself already validates executable library declarations;
consequently a library error can appear in both parse and library stages.

Engine admission uses `Selecto::Engine->admit_domain`, reusing engine construction,
write validator admission and adapter static write checks. A handle that refuses
all database methods is supplied to the registered adapter. No query is compiled
or executed. This proves declaration acceptance only, not storage existence,
column types, database privileges, runtime action success or custom callback
behavior. There is no dependency on an MCP package.

Host `checks` receive `($scoped_domain, $entry_copy)` and return an array of
`{status, code, message, path}`. An empty array passes. Invalid returns and
exceptions refuse with `host_check_failed`. These callbacks are trusted host
code: keep them static and keep their public findings free of secrets and row
values. Native exception messages/details and driver strings are never copied
into catalog findings. A warning permits serving; a refusal does not.

```json
{
  "fields":{"added":[{"name":"priority","path":"$.source.columns.priority"}],"removed":[],"changed":[]},
  "associations":{"added":[],"removed":[],"changed":[]},
  "joins":{"added":[],"removed":[],"changed":[]},
  "actions":{"added":[],"removed":[{"name":"finish","path":"$.actions.finish"}],"changed":[]},
  "writes":{"added":[],"removed":[],"changed":[]},
  "segments":{"added":[],"removed":[],"changed":[]},
  "authorization":{"added":[],"removed":[],"changed":[{"name":"field_groups.account","path":"$.extensions.authorization.field_groups.account","changes":["$.extensions.authorization.field_groups.account.tag"]}]}
}
```

Diffs name declarations and changed member paths; they contain no old/new
values, SQL or text patches. Arrays are reported at their member path. Field
names in schema relations are qualified with `schemas.<name>`. These are
structural changes, not backward compatibility judgments.

## Authorization description

`$domain->authorization_surface` describes the declaration without deciding
whether any actor is authorized:

```json
{
  "surfaces":[{"kind":"read"},{"kind":"write","operations":["update"]},{"kind":"action"}],
  "actions":[{"id":"finish","label":"Finish","capability":"orders.finish","scope":"bulk"}],
  "field_groups":[{"key":"account","tag":"orders.account","label":"Account","fields":["account_id"]}],
  "fields":{"hidden":["private_note"],"internal":["secret"],"redacted":["secret"]}
}
```

Field groups come from the map at `extensions.authorization.field_groups` and
require scalar `tag`, scalar `label`, and an array of field names. Invalid group
shapes throw `invalid_authorization_surface`. Groups are descriptive extension
metadata and do not grant field access. Marked field names use existing public
field metadata, including dotted association paths and the effective internal
flag on redacted fields. Read is always present; write lists only enabled
operations; action appears when the action registry is nonempty.
