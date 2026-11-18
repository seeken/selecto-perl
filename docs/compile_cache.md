# Pure-Perl read render cache

Native PostgreSQL and SQLite adapters cache up to 256 flat-read render plans
per adapter. Set `compile_cache => 0` to disable it or `compile_cache_size => N`
to change the LRU bound. Engine accepts the same options as overrides. This is
independent of DBI/server prepared statements and contains no native code.

## Identity and immutability

Domain and Query state is immutable through the public API. Accessors provide
copies; changes go through Domain `with_*`/derivation methods and Query
builders/`_copy`, returning new objects. Editing their internal hash fields,
including nested metadata or expressions, is **not supported** and does not
invalidate cached plans. Construct a new domain or use a derivation method.
Runtime monkeypatching of compiler methods also requires disabling the cache.
Adapter subclasses always retain the ordinary compiler.

The domain key combines its logical identity (name, relation and declared
version) with a private render fingerprint. Domains without required predicates
reuse their existing fingerprint. Otherwise, once per immutable domain object,
a shallow private copy is fingerprinted using the complete derived-domain
fingerprint logic, with only `required_predicate` removed. The live public
`fingerprint` is unchanged and still covers required values. The required
predicate's masked structure is keyed separately on every call; required and
optional parameters are collected anew. Thus equivalent tenant-scoped domains
share plans without retaining tenant values or reusing admission decisions.
Eligibility and the render digest are memoized in a private fieldhash; warmed
lookups do not serialize or hash domains. Equivalent fresh declarations share
an adapter's plans too.

`_refresh_fingerprint` covers fields and their metadata, recursive associations,
root/related/bridge relations, tenant fields, required expressions, and derived
contract declarations including required query policy and schemas. Derived
runtime tenant-family/carry, write scope, prefix and authored-predicate metadata
also participate. `with_required_predicate`, `with_tenant_field`, prerequisite
removal, composition/parsing, and scoped Engine read domains refresh identity.
Prefix/member/retarget derivations refresh it when they attach runtime metadata.
Canonical schema 1/2 parsing retains its document fingerprint in the ordinary
case; derived domains fingerprint their effective governed state.

A single small pure-Perl grammar walk builds a length-delimited structural key
and collects primitive bind values together. It includes aliases, selection,
group/order structure, pagination, operator kinds and IN arity. Literal values
are excluded from the query shape. Concrete adapter/dialect, contract/library
version and supported SQL options complete the key. No Storable, JSON encoder,
B flag inspection or domain hash calculation is used on a warmed lookup.

## Cached work and live checks

The audited grammar covers stored fields, direct physical associations (and
explicitly constructed nested associations), scalar predicates/IN, basic
aggregates, aliases, plain grouping, ordering and pagination. Computed fields,
canonical nested schema graphs, callbacks/advanced sources, set operations,
retargeting, rollups, timezones, locks, tenant prefixes, association fixed
predicates, tenanted association hops, custom adapters/budgets/limits and
PostgreSQL canonical SQL formatting use the ordinary compiler. Every feature
remains available through fallback. Capability-dependent SQL is not cached.

A miss renders with opaque slot markers instead of request values. A candidate
is accepted only when every emitted parameter is one of those markers; an
unexpected bind or speculative failure falls back without charging the real
request's source budget. Plans contain SQL, columns, slot indexes, generated
physical-relation evidence and source-proof work counts. Each return constructs
a fresh Statement with copied columns and current binds. A hand-built Statement
never acquires generated relation evidence. Normal execution owns decoding.

Configured domain identity, tenant/scope/actor policy, QueryBinding, query policy
application, tree resource admission and parameter admission all stay live.
Engine tenant validation and OperationBudget are unchanged. The flat query's
normal owner/QueryBinding checks from render expansion and physical-source proof
are also replayed. Combined required/query predicates still undergo their
normal Expression admission. Source-proof node/depth charges run through the
original OperationBudget/Limit methods on every return, preserving current
limits, cumulative counters and refusal details. Read-session, transaction,
encoding and hand-built SQL checks remain in normal execution.

Entries retain no query, domain, engine, Statement, application bind value,
tenant/actor identity or authorization outcome. Domain fingerprints are opaque
digests. Storage is adapter-local and bounded by entries, not bytes. The child
clears inherited plans on first lookup after fork; the parent is unaffected.
This does not make inherited DBI handles safe. Use handles only in their owning
process/interpreter. Ithreads have interpreter-private state; threaded execution
has not been tested. Cold misses and ineligible shapes may pay lookup overhead.
