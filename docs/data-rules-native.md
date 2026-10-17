# Portable rules and native write admission

Domains support DataRules v1 operators and six text normalizers, including
`value.compare_path` comparisons against another absolute semantic path in the
current root subject. Related paths participate in dependency and resource
checks even inside logical branches or false binding conditions.
Definitions, binding conditions and normalizer steps are closed
data contracts. Exact comparisons, multiples and sums use bounded arbitrary
precision arithmetic; type and recursive value comparisons do not coerce text,
numbers or booleans. Explicit null is different from a missing semantic path.

`Selecto::Engine` enforces these contracts for public writes, graphs, owned
collections and actions. INPUT is the submitted command's literal assignments,
before trusted tenant injection or physical conversion. Scalar INPUT normalizers
run before prospective native type projection; their actual assignments survive
even when a generated identity remains unavailable to stored rules. ACTION_INPUT includes
declared action defaults; an authored system expression is unknown until the
host can establish its actual value. Graph INPUT applies to each node's own
submitted assignments. The prospective child collection belongs to CANDIDATE.
INPUT and ACTION_INPUT bindings run in sorted-id order. A binding whose rule
or condition reads another root path (`value.compare_path`) is tested again,
without normalizers, against the fully normalized submission, so a
confirmation cannot pass against a value that a later binding normalizes. A
binding that reads only its own path keeps the value it saw at its position.

Applicable INPUT rules do not require a stored candidate. Once submitted
validation succeeds, ordinary writes, batches, graphs and both native SQLite
upsert branches can proceed without a stored-rule provider. CANDIDATE,
TRANSACTION and EVIDENCE bindings retain their stored-stage checks, including
advisory bindings and bindings with false conditions. Operation filters apply
to the actual command. Explicit child deletes validate their submitted INPUT;
implicit owned-collection omission cleanup has no child INPUT submission.

Portable compilation retains private evidence for INPUT evaluated before field
normalization and trusted fills. The receiving native engine checks the exact
compiled command or final graph, domain contract and trusted context before
reusing that evidence. It still applies native governance, field validators,
storage checks and stored-stage rules. Reconstructed commands and graphs have
no compiler evidence; changing an original compiled object refuses it with
`compiled_input_mismatch`. Each native request charges the measured INPUT work,
once within a shared request, and checks the original and normalized subjects
against its current resource ceilings without rerunning INPUT normalizers or
tests. A tighter receiving host cannot borrow the compiler's larger limits.

Stored updates load the complete governed source row. Scalar updates overlay
explicit assignments and INPUT normalization before converting that row into the
prospective candidate. Thus a canonical replacement can repair a stored REAL in
an INTEGER field or TEXT in a BOOLEAN field without fabricating the original
value. Unreplaced noncanonical values still refuse when native projection cannot
establish their policy kind. Collection hydration retains its stricter original
row projection; this scalar replacement slice does not claim collection repairs. Collection rules load
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
request options or command metadata. An accepted action plan retains its measured
ACTION_INPUT work privately; preview and execution carry that work into the
same protected-write ceiling. Plan validation does not replay input normalizers.
The public `action_command` bridge retains the same private receipt through
`governed_write`, `preview_write`, `execute_write`, INSERT batches and graph
nodes. Receipts bind authority-bearing command fields; changing an exact
command refuses it. Command metadata cannot reset measured work. Ordinary
copied commands are independently governed and do not inherit action receipts.
Nested protected scopes import prior planning work once per accepted event;
planning performed inside the current scope has already been charged. Receipt
and scope identities follow object lifetime, without address-reuse acceptance.
Trusted work ceilings may tighten the shared counter. Grant validation retains
its public precedence before action resource admission.
Private evidence is bound to the exact plan and domain contract, and follows
object lifetime through weak keys. A serialized plan with ACTION_INPUT rules
lacks that evidence and remains pending; rebuild it from an original intent.
Changing the plan or contract refuses acceptance. Grants retain their phase,
identity and single-use checks. This does not change ACTION_INPUT's declared
default/coercion semantics or move scalar INPUT ahead of domain governance.
Each text step
charges its current UTF-8 size; NFC output is checked again for expansion. Text is bounded to 4,096 UTF-8 bytes,
logical depth to 16, collection size to 1,000, and exact numbers to 1,024 digits.
Trusted `Selecto::Limits` can tighten these bounds. The ASCII pattern evaluator
uses a finite Thompson NFA rather than native backtracking expressions.

SQLite admission uses an actual memory or host connection and the enclosing
write transaction. Every stored-stage write on a native DBD::SQLite handle
(insert, update and upsert, not only UPSERT) requires that transaction to be
open on the adapter's connection when governance starts. A host
`transaction_handler` must open it, as its contract states; a handler that runs
the work in autocommit is refused with `required_data_rule_pending` (reason
`native_transaction_required`) before business DML, because the candidate
proof and the write would not be atomic. Writes without stored-stage rules are
unaffected. Native NUMERIC affinity is evaluated before rules; for
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
INSERT, UPDATE and upsert targets also refuse schema-level `ON CONFLICT REPLACE`
and `ON CONFLICT ROLLBACK`. REPLACE can implicitly delete another row or
substitute a NULL default, effects which are not authorized by the ordinary
command. ROLLBACK can discard the caller's entire transaction and savepoints
when a native constraint fails. An owned savepoint cannot contain that effect.
Bounded stored-DDL
tokenization distinguishes actual policies from quoted names, string values and
comments. The returned catalog name must independently match the target's
canonical physical name; a custom lookup collation cannot supply another
table's DDL. DELETE does not activate these conflict policies, and readonly graph
anchors remain reads; their other physical authority checks still apply.

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
stored UPDATE and DELETE batch deltas require a prospective whole-plan provider
and remain pending here, as does a protected INSERT beside an ordinary
non-INSERT command. Individual SQLite upserts with stored rules use the native unique arbiter
inside the actual transaction to select the insert or conflict branch. Conflict
candidates overlay only the command's exact update mask on the physical stored
row; an empty mask compiles to `DO NOTHING` and retains the command's declared
cardinality. A zero-row no-op still fails an exact-one request. Only this
protected SQLite path admits an empty mask. Other adapters, SQLite engines
without stored UPSERT rules and upsert actions there still refuse it
(`invalid_write`, or `invalid_action_plan` for actions), and the HTTP write
API keeps requiring a non-empty `upsert_update_fields`.

Protected upsert receipts are private and expire when the transaction callback
exits. They bind the actual adapter, connection, command, context, arbiter,
schema and prior physical row, and are rechecked immediately before dispatch.
The engine opens the candidate scope with its live trusted write context. A
receipt is minted only when its request context matches that live context, and
the dispatch recheck compares the receipt with the context of the scope that is
running then, so a nested scope with another context cannot dispatch it.
The strategy reports serializable snapshot protection. It does not claim a
write lock for caller-owned deferred transactions. Native stale-snapshot write
upgrades retain SQLite's failure behavior. That claim needs SQLite's locking
reads: with `PRAGMA read_uncommitted` a shared-cache connection takes no table
read locks, so a peer on the same cache could roll back a row the proof read,
or commit one it did not see, before the business DML. The scope, every
projection and the dispatch recheck therefore refuse a connection whose
`read_uncommitted` is on as `required_data_rule_pending` (reason
`read_uncommitted_isolation`) before business DML, leaving the caller's
transaction, savepoints and pragma unchanged. The adapter cannot observe
whether a cache is or will become shared, so a private connection with the
pragma on refuses too. Shared-cache connections with the default locking reads
keep their table read locks until the transaction ends and remain admitted. Ordinary UNIQUE NULLs select the
insert branch; builtin BINARY, NOCASE and RTRIM arbiters and complete ordinary
unique indexes are supported. Partial/expression arbiters and ambiguous matching
index collations remain pending. Consumed literal defaults are projected through
actual native affinity; consumed generated identities and nonliteral defaults
remain unavailable.

Candidate normalization runs once, then native reprojection tests the realized
values. TRANSACTION and EVIDENCE normalizers must leave those realized values
unchanged; otherwise the upsert remains pending instead of storing a value its
rule never tested. Genuine portable compilation may add permitted normalized fields to its
update mask; an explicit native mask cannot widen. Choice membership uses only
actual persisted fields and the complete final canonical root row. Compilation
defers these callbacks until native branch projection. A no-op consumes no
unused choice provider, and required stored failures prevent external callbacks.
Every dispatch path (write, preview, batch and graph) refuses a genuine
protected portable origin with `compiled_upsert_mismatch` on a host whose
domain, trusted context or stored UPSERT rules differ from the compiler's,
including a host with no stored rules, so deferred membership is never skipped.

A SQLite batch may combine protected UPSERTs with ordinary inserts, updates,
deletes and upserts, and with protected inserts, only when each protected
candidate is proved independent of every other command on its table. Every
candidate was projected before any of the plan's DML, so the proof covers both
orders, and two protected candidates are checked in both directions:

- Another protected candidate's final row must not carry this candidate's
  arbiter key, and the two must not select the same stored row.
- An INSERT's row, with consumed literal defaults, must not carry the key.
- An ordinary UPSERT is projected through its own arbiter and stored branch. It
  must not select the candidate's stored row, its insertion row and its final
  row must not carry the candidate's key, and the candidate's final row must
  not carry the other UPSERT's key (the different-unique-key hazard).
- An UPDATE or DELETE predicate must select neither the stored row the
  candidate chose nor the row it will leave behind; an UPDATE must not write
  every arbiter field to the candidate's key.

Keys and predicates are compared by SQLite, through each column's affinity and
collation; NULL keys never collide. An unknown generated rowid on the protected
arbiter refuses any other same-table command, and an omitted rowid or volatile
default that a comparison needs is unknown. Owned-set cleanup on the same
table, unsupported predicates and operations, and plans beyond 4,096 pair
checks remain pending (`required_data_rule_pending`, reasons
`plan_independence_unavailable`, `ambiguous_candidate_identity` or
`generated_identity_unavailable`) before business DML. Unique constraints other
than the arbiters compared here keep their native errors, which roll back the
whole batch. Protected UPSERTs in write graphs still refuse as pending.
External evidence requires its exact
authoritative stage. Unknown defaults or generated fields consumed by a rule,
database-computed assignments and unmaterialized normalizer changes remain
explicit refusals. Caller completeness flags do not supply authority.

Native regressions use `:memory:` only and inspect actual stored rows and
business-DML traces. `script/verify-rules-package` builds the CPAN archive,
installs it into a temporary staging prefix and runs a public consumer against
the installed modules. Its log binds source HEAD, clean status and archive hash.
