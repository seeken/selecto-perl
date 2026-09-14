# DuckDB exact result transport

DBD::DuckDB 0.16 decodes fractional timestamps by truncating epoch seconds,
losing correctness before the epoch and leading fractional zeroes. It renders
timestamptz using the process timezone rather than the database session. Its
automatic input inference also treats numeric-looking scalars as DOUBLE.
Selecto does not patch the installed driver or depend on its private FFI state.

## Query and stream results

The compiled `Selecto::Statement` remains the native relational query with its
original parameters and logical column names. Immediately before preparation,
the DuckDB adapter adds a single-source final projection. Each result column is
carried in a typed STRUCT containing its server-reported kind, an exact text
slot, and an ordinary native-value slot. DATE, TIMESTAMP variants and DECIMAL
use server-rendered text with a NULL native slot; other values use their native
slot. This prevents the driver from first decoding and corrupting the affected
scalar. There is no JSON numeric conversion and no inspection of user strings
to guess their type. User structs are nested values, not transport metadata.

Filtering, joins, CTEs, grouping, aggregates, windows, set operations, sorting
and pagination stay inside the relational query, before transport. In
particular, numeric sorting does not become lexical sorting, and UNION compares
native operands. DuckDB documents order preservation for a single-source SELECT:
[Order preservation](https://duckdb.org/docs/current/sql/dialect/order_preservation).
The wrapper neither imposes order on unordered queries nor strengthens the
ordering guarantees of the original query.

Timestamp normalization uses `T` as the date/time separator and removes a zero
UTC suffix, matching PostgreSQL's scalar result normalization. Nonzero offsets
remain intact; without an explicit query zone, raw timestamptz follows the
database session. Exact decimals trim insignificant trailing fractional zeroes.
Scalar booleans become 0/1, with NULL preserved. Streaming uses the same decoder;
fetch or decode failure closes the handle and crosses the normalized error
boundary. Write RETURNING projects and decodes the same transport cells without
changing mutation scope, affected count or transaction behavior.

## Input values

Scalar parameters are explicitly bound as VARCHAR so numeric-looking text and
exact decimals/integers do not go through driver floating-point inference.
Governed numeric comparisons, including numeric CTE outputs, cast parameters
to their own base-10 DECIMAL precision/scale before comparison. Otherwise a
text parameter such as 20.2501 could round to a DECIMAL column's scale and
incorrectly equal 20.25. Arithmetic mutation literals use exact numeric casts
as well. Values exceeding DuckDB's 38-digit DECIMAL precision reject explicitly.
Assignments are still converted by their native destination column types.

## Evidence and limits

- `t/epoch_timezone.t`: PostgreSQL/DuckDB raw epoch and UTC results, aliases,
  filters, required scope, DST folds, negative microseconds, NULL and formats.
- `t/temporal_format_bindings.t`: all 20 public formats, four temporal source
  types and five zones, with fixed DATE-midnight session-invariance checks.
- `t/duckdb_result_transport.t`: exact fractions/nanoseconds/large decimals,
  database-session zones, streaming, native ordering/paging/grouping/aggregates,
  windows, UNION/UNION ALL/EXCEPT, CTEs, numeric parameter scale, large identifiers,
  numeric-looking strings, mutation arithmetic and insert/update/delete RETURNING.
- `t/stream.t`: normalized decoder failure and exact-once handle release.

Ordinary list/struct/blob/JSON values retain their existing DBI representation.
This scalar transport does not recursively repair temporal or decimal members
inside arbitrary native nested types. These repository tests do not certify
arbitrary queries, all drivers, HTTP behavior, full backend parity or deployment.
Central adapter profiles remain separately bounded evidence.
