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
stages, false conditions, and all logical branches. All bindings share a
2,000,000-unit evaluation budget. Each text step charges its current UTF-8 size;
NFC output is checked again for expansion. Text is bounded to 4,096 UTF-8 bytes,
logical depth to 16, collection size to 1,000, and exact numbers to 1,024 digits.
Trusted `Selecto::Limits` can tighten these bounds. The ASCII pattern evaluator
uses a finite Thompson NFA rather than native backtracking expressions.

SQLite admission uses an actual memory or host connection and the enclosing
write transaction. Native NUMERIC affinity is evaluated before rules; for
example `1e-400` becomes zero and fails required positivity. Protected storage
refuses temporary shadows, virtual/view/shadow tables, triggers, generated
columns and unsupported scalar types. Incoming automatic foreign-key updates
are refused for original and normalizer-added assignments. Declared graph and
owned-set edges must prove matching actual key affinity and builtin collation,
complete single-column parent uniqueness, and every present foreign-key group.
An omitted FK target resolves only to a single primary key. Schemas without a
physical FK still require exact comparator and uniqueness proof.
Graph and owned-sync capability gates require SQLite 3.37 for this catalog.

Protected insert batches preflight every member before any dispatch. Protected
stored batch deltas and upserts require a prospective whole-plan or selected
branch provider and remain pending here. External evidence requires its exact
authoritative stage. Unknown defaults or generated fields consumed by a rule,
database-computed assignments and unmaterialized normalizer changes remain
explicit refusals. Caller completeness flags do not supply authority.

Native regressions use `:memory:` only and inspect actual stored rows and
business-DML traces. `script/verify-rules-package` builds the CPAN archive,
installs it into a temporary staging prefix and runs a public consumer against
the installed modules. Its log binds source HEAD, clean status and archive hash.
