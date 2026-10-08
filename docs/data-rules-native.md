# Portable rules and native write admission

Domains support the complete DataRules v1 catalog of 27 operators and six
normalizers. Definitions, binding conditions and normalizer steps are closed
data contracts. Exact comparisons, multiples and sums use bounded arbitrary
precision arithmetic; type and recursive value comparisons do not coerce text,
numbers or booleans. Explicit null is different from a missing semantic path.

`Selecto::Engine` enforces these contracts for public writes, graphs, owned
collections and actions. INPUT is the submitted command's literal assignments,
before trusted tenant injection or physical conversion. ACTION_INPUT includes
declared action defaults; an authored system expression is unknown until the
host can establish its actual value. Graph INPUT applies to each node's own
submitted assignments. The prospective child collection belongs to CANDIDATE.

Stored updates load the complete governed source row. Collection rules load
actual child rows under the original ownership, tenant and required predicates,
then apply submitted deltas and child normalizers before parent validation.
Snapshots share a 1,000-row hydration ceiling; each read uses limit plus one.
An incomplete provider result or exhausted ceiling remains
`required_data_rule_pending` before business DML.

Rule dependency analysis includes every logical branch and binding condition,
sum and unique paths, and whole-value comparisons. A consumed generated child
key remains unknown even when another `any` branch passes or an advisory
condition is false. Known missing INPUT can satisfy `presence.absent`. Unknown
generated CANDIDATE values cannot. Normalizers run once; after native scalar
projection, only conditions and tests are repeated. Normalizer assignments
reenter the original write grants, tenant and reference checks.

Ordinary advisory validation failures allow an otherwise governed operation.
Resource errors remain errors in advisory bindings, unavailable authoritative
stages, false conditions, and all logical branches. The native engine owns one
2,000,000-unit evaluation budget for each protected write, preview, INSERT batch
or graph, shared by INPUT, native candidate and transaction stages, test-only
projection checks, child candidates and cleanup rules. Separate operations get
fresh counters, including after a resource refusal. Callers cannot reset it with
request options or command metadata. ACTION_INPUT planning remains a separate
evaluation and is not claimed in this protected-write ceiling. Each text step
charges its current UTF-8 size; NFC output is checked again for expansion. Text is bounded to 4,096 UTF-8 bytes,
logical depth to 16, collection size to 1,000, and exact numbers to 1,024 digits.
Trusted `Selecto::Limits` can tighten these bounds. The ASCII pattern evaluator
uses a finite Thompson NFA rather than native backtracking expressions.

SQLite admission uses an actual memory or host connection and the enclosing
write transaction. Native NUMERIC affinity is evaluated before rules; for
example `1e-400` becomes zero and fails required positivity. Protected storage
refuses temporary shadows, virtual/view/shadow tables, triggers, generated
columns and unsupported scalar types. Every mutating ordinary write, preview,
batch, graph and owned cleanup checks its physical targets before the first business statement. Readonly graph anchors
are excluded. This proof also applies when the domain has no data rules. It
refuses main and temporary target triggers and hidden or generated columns.
Automatic incoming foreign-key updates are refused for original and
normalizer-added key assignments and the actual upsert update fields. Automatic
CASCADE, SET NULL and SET DEFAULT deletes remain pending, including an empty
child relation. NO ACTION and RESTRICT retain native constraint behavior.
Catalog scans have ceilings of 1,024 main tables and 4,096 FK components.

A single exact INTEGER primary key in an ordinary rowid table is a generated
identity only if SQLite has no primary-key index. An explicit NULL submitted for
that alias remains unknown to stored rules and guarded insert predicates. An
indexed INTEGER PRIMARY KEY DESC retains its actual known NULL. Omitted native
defaults remain unknown; the adapter does not fabricate a generated identity.

Declared graph and owned-set edges must prove matching actual key affinity and builtin collation,
complete single-column parent uniqueness, and every present foreign-key group.
An omitted FK target resolves only to a single primary key. Schemas without a
physical FK still require exact comparator and uniqueness proof.
Graph and owned-sync capability gates require SQLite 3.37 for this catalog.

Protected insert batches preflight every member before any dispatch. Ordinary
known stored-rule failures are retained while later available stages and graph
or INSERT-batch candidates finish their resource checks. The first ordinary
failure then refuses the plan if no later resource error occurs. Refused INPUT,
unknown prospective values and unavailable storage still stop admission. Protected
stored batch deltas and upserts require a prospective whole-plan or selected
branch provider and remain pending here. External evidence requires its exact
authoritative stage. Unknown defaults or generated fields consumed by a rule,
database-computed assignments and unmaterialized normalizer changes remain
explicit refusals. Caller completeness flags do not supply authority.

Native regressions use `:memory:` only and inspect actual stored rows and
business-DML traces. `script/verify-rules-package` builds the CPAN archive,
installs it into a temporary staging prefix and runs a public consumer against
the installed modules. Its log binds source HEAD, clean status and archive hash.
