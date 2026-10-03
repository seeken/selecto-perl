# Typed governed insert admission

Governed insert candidates are checked using actual database storage semantics
before INSERT. This closes differences between the standalone portable scalar
comparator and a typed database column, including numeric-looking text and
decimal scale rounding. The pure `QueryEnforcement::evaluate` contract and its
239/489 scalar fixtures remain unchanged.

The engine replaces internal field-type metadata from its trusted domain (or
declared graph relationship). The SQL adapter validates every referenced policy
field and literal, verifies actual storage metadata inside the write transaction,
and evaluates a bound prospective row with that storage type and collation.
Only SQL TRUE permits the candidate. The values used for binding are the same
explicit scalar or literal-expression values checked by admission. A policy
field cannot rely on an unevaluated DEFAULT, generated value, or missing input.

The initial supported domain types are integer, decimal, string/text, and boolean.
Integers use canonical signed decimal syntax within signed 64-bit range; decimals
use canonical finite decimal/exponent syntax without whitespace, leading `+`,
hexadecimal notation, or leading zeroes. Boolean values are 0/1. SQL NULL retains
three-valued predicate semantics. Existing non-finite scalar refusal is retained.

SQLite requires a real DBD::SQLite handle with column metadata support, an ordinary
main-schema table, no same-name temporary object, no transforming triggers, and
non-generated policy fields. Storage must have the supported integer, numeric,
or text affinity. String comparison uses the actual BINARY, NOCASE, or RTRIM
collation. Unsupported custom collations/types are refused. PostgreSQL requires
a real DBD::Pg handle and ordinary nonpartitioned/noninherited table without
user triggers or rewrite rules. Supported storage types are built-in integer,
numeric (including declared precision/scale), text/varchar, and boolean; actual
column collation is preserved. Custom/domain types, generated policy columns,
and unsupported storage mismatches are refused.

PostgreSQL holds a table lock across metadata inspection and DML; SQLite's
transaction keeps the inspected schema stable. A five-second database query
budget bounds the admission probe, including PostgreSQL lock waits. A savepoint
allows PostgreSQL timeout settings to be restored after a failed probe.

Other adapters fail with `query_rule_not_evaluable` for governed prospective-row
checks until they implement and verify equivalent storage support. Queries and
unguarded inserts are unaffected. Required-predicate and query-enforced upserts
remain refused by their existing rules; permitted tenant-scoped upsert candidates
also receive typed admission, in addition to conflict-identity enforcement.

The check rejects the failing command before its DML. This is not a guarantee
that earlier commands in an explicit batch or graph had no effects: the existing
transaction/rollback contract still applies to earlier commands. Graph bindings
are checked once the trusted parent values are available. Arbitrary external
effects, host callbacks, concurrent administrative changes, and arbitrary schema
or collation behavior are outside the bounded profile.

`t/security_insert_admission.t` exercises SQLite and, when
`SELECTO_TEST_PG_DSN` is configured, disposable PostgreSQL. Shared profile
`typed_insert_admission` adds TA001–TA005 native observations with both unscoped
and governed readback. One language running against two databases does not meet
the profile's two-independent-implementation differential requirement.
