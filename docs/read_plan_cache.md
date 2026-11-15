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

The key is a SHA-256 of the current query structure (with literal slots), the
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

Key construction deliberately favors mutation detection over speed. Measure
on the target workload before enabling this experiment: full metadata
snapshots can cost more than the SQL rendering saved on small queries.
