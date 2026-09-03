# Action filter preconditions

Declare guards in `actions.<id>.preconditions`, not in caller intent:

```json
{"preconditions": [["eligible", true], ["<=", "priority", 3],
  {"field": "state", "op": "in", "value": ["done", "open"]}]}
```

Pairs mean equality; triples are comparator-first. Maps accept `comparator`,
`operator`, or `op` (default `eq` only when absent/null). Supported comparators
are `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, and non-empty-list `in`, with
symbolic aliases `=`, `!=`, `<>`, `>`, `>=`, `<`, and `<=`. Fields must be
direct declared source columns; they do not have to be writable. Malformed
declarations and unknown/joined fields fail closed. Missing/null guards add
no predicates. Non-empty guards require an update/delete action.

The planner ANDs these predicates with target and transition filters and exposes
normalized `type: "filter"`, `reason: "action_precondition"` metadata to capability
resolvers. Normalized plan triples are field-first. This does not grant write
or capability authority, and does not replace trusted tenant scope.

This action API plans; it does not execute the mutation. Hosts must include all
plan filters plus trusted scope in the final mutation and atomically enforce
expected affected-row cardinality. Preview does not reserve eligibility.
D076-D077 in specification 2.7 / `domain_actions` 1.1 check public planner behavior,
not arbitrary host callbacks or live mutation enforcement.

