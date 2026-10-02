# Public resource and authority boundaries

`Selecto::Limits` holds trusted host configuration. Request bodies, query parameters, saved-query state and action intents cannot set these limits. Construct an object in the host and pass it as `limits` to Engine, API::EngineHandler or Importer; standalone QueryLibrary application/parameter-normalization methods accept an optional final limits object. `tightened` returns a copy with ceilings reduced (zero disables that bounded input).

| Budget | Default |
|---|---:|
| Public fields / membership values | 100 / 100 |
| Query-library parameter bytes / membership item bytes | 65,536 / 4,096 |
| Action target occurrences | 1,000 |
| Related rows per parent / total requested child rows | 100 / 10,000 |
| Encoded JSON API response, including success envelope | 16 MiB |
| CSV input UTF-8 bytes / total decoded cell bytes | 16 MiB / 32 MiB |
| Total CSV cells, including headers | 1,000,000 |
| State bytes / bucket input bytes / bucket ranges / numeric digits | 131,072 / 16,384 / 100 / 15 |
| Generated selections / parameters / expression nodes | 256 / 1,000 / 10,000 |

Constructor overrides are positive integers no larger than 999,999,999; callers should size them for actual workers. API `max_fields` and `max_filter_values` can further tighten the shared limits. UTF-8 byte checks happen before parameter copying/CSV splitting; list occurrence checks precede normalization. Regular query-library IN lists are subject to the same count and byte budgets as `csv_in` and direct API membership filters.

A transport still needs a receiving-layer body limit before buffering. Hosts should retain database statement/lock timeouts and sensible indexes. The bounded write preflight and Components export paths install temporary database execution budgets; general query execution still uses the host configuration. A response byte check protects returned data, not allocations the database or driver already performed.

## Bounded driver streaming

`stream($query, bounded => 1)` requires an adapter with `bounded_stream_supported`. PostgreSQL with a real DBD::Pg handle declares a `NO SCROLL` server cursor and executes `FETCH FORWARD 1` for every `next`; `fetch_size` does not increase this bound. The driver can buffer one row at a time. An individual row, server sorts/aggregates and transport buffering still require separate byte and execution budgets. Ordinary streams retain their previous driver-dependent buffering semantics.

The PostgreSQL stream opens a read-only transaction on an idle handle and rolls it back at exhaustion, explicit early close, failure or destruction. Inside a host transaction (including raw `BEGIN`), it uses a savepoint: success releases it, failure rolls back only to the stream's start. Earlier host work is neither committed nor discarded. Assign the handle exclusively to the stream until close; interleaved host writes or transaction control are unsupported. Overlapping bounded streams refuse. Close the stream before restoring its query-budget guard, so a failed `FETCH` is recovered before restoration SQL runs. A cleanup failure disables further bounded streams on that handle until the host replaces or deliberately recovers it.

`t/bounded_stream.t` verifies real PostgreSQL cursor existence, parameters, decoding, one-row evaluation through a volatile sequence, early close/exhaustion/destruction, timeout recovery, host transaction preservation and disconnect cleanup. This is a finite driver integration test, not a universal server-memory guarantee.

## Bounded API collections

Existing nested array selections now require PostgreSQL and a public target primary key. The child subquery orders by that key and requests only the configured per-parent cap plus one. A collection exceeding the cap refuses the entire query with `related_collection_limit_exceeded`; the handler does not silently truncate it. Use a separately paged child query for larger collections. Other adapters return `unsupported_feature` until their bounded semantics are implemented and verified; ordinary flat relationship selections continue to work.

Successful `subtables` metadata contains the existing `columns`, plus `limit` and `complete: true`. This response makes no cursor claim. Root limit times the sum of collection limits must fit `max_total_collection_rows` before execution. Each subquery may fetch one extra sentinel row to detect overflow. Raw result bytes are checked before child JSON decoding; the final JSON success envelope is checked again to include escaping, keys and metadata.

Public non-bulk UPDATE/DELETE requires a concrete primary-key equality filter. Other tenant, required and precondition filters remain in effect. Engine and adapter write guards also validate execution; this API restriction does not replace them.

## CSV inspection memory

The inspector checks input bytes before encoding or parsing, counts all cells and decoded bytes including the header, and creates only the final row representation. It no longer retains a second array of all raw records. Existing per-row, column and cell limits still apply. The sample limit controls the returned sample only.

Run `script/with-local-deps <intended-perl> script/importer-memory-check` under the platform's peak-memory recorder for a synthetic fixture saturating the default 16 MiB input and one-million-cell budgets. On October 2, 2026, Perl 5.40.2 on this macOS host used 248,168,448 bytes peak RSS (about 237 MiB), for 49,999 data rows by 20 columns. A 4,999-row by 200-column shape at the same limits used 240,517,120 bytes. These are measured fixtures, not a universal process-memory bound. Allow worker headroom and reduce limits or import concurrency to fit production memory.

## Hidden values and co-domain lookup

`FieldPolicy->resolve` omits `value` for every hidden field, including explicit hidden mode, internal fields and view-capability denial. Authorized visible/read-only values remain available. Co-domain lookup checks all resolved projection/result/search/rank/ordering fields and query-library predicate fields for publication before executing. Trusted internal tenant predicates supplied by the engine/host remain supported.

## File hold callback migration

The files service now calls `authorize` with `place_hold` or `release_hold`, replacing the ambiguous `hold` action. Arguments are `(operation, actor, owner, role, context)`; `context` contains normalized `operation`, `version_id` and `authority`. The host supplies actor and owner through its trusted bound facade. Migrate policies that previously recognized only `hold`.

Each hold records the actor who placed it. A boolean allow decision permits only that actor to replace/release its hold. Releasing another actor's hold requires a trusted callback result `{allowed => 1, hold_admin => 1}` or an explicit authority delegation `{allowed => 1, release_authority => 1}`. Neither flag is a request argument. The default callback and a generic boolean grant never confer these powers. Legacy ownerless records also require explicit delegation/admin.

An optional `audit` callback receives an event containing operation, version, authority and actor and must return true. A false return or exception raises `audit_failed` before changing hold state, preserving the purge block. Without an external audit callback, this experimental in-memory service retains only the version's last event; production hosts need durable audit storage. Multiple holds continue to block purge until each is legitimately released.

## Regression evidence

- `t/security_boundaries.t`: byte/count thresholds, Unicode, hidden serialization, CSV aggregate budgets, pre-execution rejection, response escaping, hold ownership/audit failure, and co-domain role checks.
- `t/security_boundaries_live.t`: optional disposable PostgreSQL test for inner child limits, stable per-parent order, tenant preservation and pre-execution hidden-field refusal.
- Existing query-library/importer/field-policy/co-domain/files/API tests remain part of the required suite; DuckDB's integration test explicitly covers refusal of unsupported API nested collections while preserving flat queries.

Changes to public API metadata, file authorization context and adapter support need corresponding central contract/certification updates. Passing these regressions does not imply unrestricted cross-database certification.

## Write identity and bounded mutation

Governed upserts require a nonempty, duplicate-free conflict target that exactly matches an ordered entry in `writes.operations.upsert.conflict_targets`. Declare every intended target explicitly; omission no longer means any unique key is allowed. Public API, direct engine, batch, graph and action paths share this check. Action plans retain the resolved variant/case identity and bind it into their grant digest. MySQL and MariaDB currently refuse upserts with `unsupported_upsert_conflict_target`, because their general duplicate-key operation cannot guarantee the requested identity when another unique constraint collides.

Every governed UPDATE/DELETE has a trusted finite row ceiling from the engine's `max_action_targets` (default 1,000). Primary-key equality and bounded IN predicates provide an intrinsic row bound. PostgreSQL and SQLite can also handle broad predicates: within the mutation transaction, a five-second preflight selects at most the allowed count plus one, rejects excess matches before DML, and reapplies all original predicates while restricting mutation to the verified keys. PostgreSQL locks the selected rows. SQLite's transaction prevents upgrading a stale read snapshot into a successful write. Other adapters refuse broad writes with `write_capability_missing`. Explicit adapter methods ending in `_unsafe` remain trusted internal escape hatches.

A supplied `expected_count` must fit the ceiling. Mismatch errors retain the expected count but never disclose actual matched counts. Limits bound the selected/mutated root rows; indexes and host trigger policies still matter for scan cost and downstream trigger work. The post-write count check and transaction rollback remain in place. Host transactions remain open after the adapter's savepoint is released.

Action target ceilings apply to raw occurrences before deduplication and are rechecked at execution. Scalar action inputs cannot carry arbitrary references. Authored `system-now` values are represented separately from caller literals, so JSON arrays remain data. Hosts must not grant request code access to mutable plan or authorization objects.

## Database execution budgets

SQL adapters expose `query_budget_supported` and `begin_query_budget(timeout_ms => N)`. Keep the returned guard alive throughout execution and fetch; call `check` between application operations and `close` during cleanup. The guard preserves a stricter existing timeout, refuses overlapping guards on one handle, and restores host settings. PostgreSQL uses its server statement timeout and SQLite a VM progress callback plus busy timeout. MySQL/MariaDB timeout configuration and ODBC query-timeout support are available when the connected driver/server accepts them, but that alone does not prove bounded result buffering. DuckDB currently refuses an enforceable execution-budget claim.

SQLite has no getter for an existing progress callback. Use a dedicated handle, or pass the host callback explicitly as adapter option `query_budget_progress_handler => {opcodes => N, callback => sub { ... }}` so it is invoked during the budget and restored afterward. Do not change the callback while a budget is active. A restoration failure raises `query_budget_restore_failed` and marks the handle unusable for further budgets until the host replaces or deliberately recovers it.

`t/bounded_write.t` exercises real PostgreSQL/SQLite trigger counters, concurrent PostgreSQL inserts, selected-row lock retention, stricter host deadlines and recovery. `t/query_budget.t` interrupts an actual recursive SQLite query and a blocking PostgreSQL query. `t/security_sql_boundaries.t` checks direct and through-join binding order on six dialects and executes the anonymous-placeholder case on SQLite. Live MySQL, MariaDB and MSSQL evidence requires separately configured disposable services and their drivers; compiler checks do not substitute for it.
