# Native read rendering plans

The read plan cache is experimental and opt-in. Set
`SELECTO_PERL_PLAN_CACHE=1` to enable it. Set `SELECTO_PERL_PLAN_CACHE=0`
to force the reference renderer, including on an already warmed adapter.
An adapter constructor option `plan_cache => 1` also enables it, and
`plan_cache => 0` disables it. The environment off switch takes precedence.

The cache currently covers native PostgreSQL and SQLite stored-field reads,
with simple scalar comparison, Boolean and null predicates, ordinary
unconditional association joins, ordering and pagination. It caches SQL text,
output names, named relations and selection-resolution obligations. Literal
values are bind slots: the original predicate compiler supplies fresh binds
on each request. Failed compilations are never retained. Every returned
Statement owns new arrays. No prepared DBI handle or result rows are cached.

Computed fields, timezones, grouped queries, advanced sources, members,
retargeting, conditional/tenant joins, row locks, SQL-side canonical
formatting, custom classes and unsupported metadata use the reference
renderer. Canonical-value decoding and export-value handling stay in the
adapter execution phase; they are never captured by a plan.

Each adapter owns an LRU of at most 64 entries, with a 256 KiB accounted
payload budget (SQL, names, relations, obligations, keys and a fixed per-entry
allowance). This bounds retained payload, not Perl allocator overhead or total
process RSS. Oversized plans bypass insertion. Destroying the adapter frees
its cache. There is no process-global plan registry.

For mutable records, the key is a SHA-256 of the current query structure (with literal slots), the
complete native domain/policy records, current engine read authority (tenant,
actor and write context, attached read context, required tenant filters and
strict/permissive mode), current limits, concrete dialect, local reported
server version, adapter canonical-value mode and transaction mode. The key is
rebuilt from current state, independently of the domain's cached public
fingerprint. Reloading a domain or editing a query, alias, policy or trusted
context cannot reuse an old structural key. Plain scalar parameter changes
reuse the SQL and bind their current values. Native metadata snapshots are
bounded by depth and node ceilings; unsupported or cyclic records bypass.

The plan has no dependence on pipeline availability: it contains ordinary SQL
and no execution frame. Every execution re-evaluates driver pipeline admission
and the driver's opt-out. Changing pipeline capability therefore needs no
rendering invalidation. SQL-side canonical mode bypasses the cache entirely.
Export mode and driver result types are consumed afresh at execution, so a
plan cannot carry a decoder or refusal from a previous mode.

The engine still checks tenant scope, query ownership, query policy, resource
limits, write-session authority for locks and required predicates on every
compile. Cache hits repeat source ownership/budget work, current field
resolution and metadata checks, join resolution, predicate compilation,
parameter admission and pagination validation in renderer order. Static
structural refusals belong to pure planning and can only be bypassed after a
successful compile of the identical structure and policy. Canonical/API and
Explorer exposure checks remain above the engine. R55 read-only framing,
R63 statement handling, R65 encoding, R66 host transaction guarantees, R72
session checks and TB007 write authority remain on their original per-request
paths. Write compilation does not use this cache.

## Optional frozen identities

Freezing is also experimental and **off by default**. Use
`SELECTO_PERL_FREEZE_DOMAINS=1`, `Selecto::Domain->new(..., freeze => 1)`,
`Selecto::Domain->parse($document, freeze => 1)`, or `$domain->freeze` after
finishing a builder. Constructor/parse `freeze => 0` overrides the environment.
Freezing is irreversible for that object; reload or derive a new domain to
change it. Turning off the environment does not thaw existing objects.

The final outer parse/constructor freezes hashes and arrays, including
field, association, rules and policy declarations. Missing-key reads still
work. In-place writes, deletion, insertion, clear, splice and resize die with
a frozen-record message. Retained scalar aliases become read-only. Document
and contract getters return ordinary mutable copies. Do not manually untie
records or edit tie implementation objects: freezing is an internal lifecycle
contract, not a security sandbox against trusted Perl code.

Derived predicates, tenant-field changes, action-prerequisite removal, reloads,
retargets and read-prefix domains receive new process-local identities.
Member expansion finalizes authored predicates on its own derived copy.
Lazy association metadata is built from a copy of a frozen schema graph and
then frozen; it cannot modify the shared domain.

An engine configured with a frozen domain also seals its retained read
scope, write context (including actor/roles), attached read context, required
filters and limits. Use the public `with_*`/`require_tenant_filter` transitions
to change authority. These create new sealed records. A host replacing any
record directly with mutable state falls back to the snapshot key.

When the cache first admits an eligible query against a frozen domain, it
seals that query and its expressions. The query has an identity and a
monotonic version; every fluent transformation returns a new query with a
higher version and leaves the original intact. Direct hash/array edits of a
sealed query die, including edits through a previously retained expression.
To keep legacy query edits, use `$engine->query(freeze => 0)` or
`Selecto::Query->new(freeze => 0)`. Copies preserve the opt-out. Such queries
always use live snapshot keys, even on a frozen domain. Explicit `$query->freeze`
also enables integer identity eligibility; otherwise domain-only opt-in
requires query opt-in (the environment enables both).

The frozen key length-prefixes a few scalar components: domain identity,
query identity/version, identities of the sealed authority records plus live
query mode, limits identity, dialect, local server version, canonical value
and transaction modes. Static eligibility is checked once per query/domain
pair. No full metadata snapshot, JSON encoding or SHA-256 runs on a warm
frozen hit. Governance decisions remain per request. Export/decoder options
remain in execution and are not retained by the plan.

A new fluent query has a new key even when it only changes a parameter.
Retain and reuse query objects to benefit from this experiment. Required
query-policy transformations can create fresh composed queries on each
compile and therefore receive no integer-key reuse. The existing snapshot
path still shares literal-slot SQL for mutable queries.

Measure on the target workload before enabling either experiment. Immutable
domain metadata hashes use ties to preserve missing-key reads; query records
and arrays use native read-only protection. These still add read overhead, and per-request obligations
still run; a cheaper key alone does not establish an end-to-end speedup.
