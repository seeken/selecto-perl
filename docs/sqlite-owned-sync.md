# SQLite owned-set synchronization

`Selecto::Write::Graph` accepts `owned_sets` alongside its ordered row nodes:

```perl
my $graph = Selecto::Write::Graph->new(
    nodes => [
        {id => 'root', command => $parent_update},
        {id => 'kept', command => $child_update,
         bindings => [{from => 'root', key => 'id', field => 'parent_id'}]},
    ],
    owned_sets => [{parent => 'root', relationship => 'children',
                   nodes => ['kept'], delete_missing => 1}],
);
my $result = $engine->execute_graph($graph);
```

The domain's exact writable relationship must declare `ownership` as `owned`
or `composition`, `strategy => 'sync'`, `delete_missing => 1`, ordered
`identity_fields`, a child domain, parent/child keys and a delete operation
grant. The child domain must independently grant deletes. Every graph row on
that relationship must appear in its set. An empty `nodes` array represents
an empty complete owned set.

The engine adds internal `RETURNING` fields without changing the caller graph.
Cleanup derives the parent key and retained complete identities from actual
returned rows. Caller predicates and metadata cannot supply a cleanup scope.
The DELETE combines parent ownership, the trusted child tenant, the child's
required predicate and the exclusion of whole composite identities. Duplicate,
missing or null returned identities refuse and roll the graph back.

All graph rows and cleanup run atomically. Cleanup follows descendant sets
before ancestor sets independently of the submitted set order. An existing
host transaction keeps its pending work; an owned graph in external mode uses
its own savepoint. A late database failure rolls back every graph mutation.
The usual engine bounded-write limit also applies to cleanup.

Canonical `required_filters` accept bounded portable root-field guards and
apply to both reads and writes, including nested child policy and cleanup.
Invalid fields or unsupported guards refuse domain construction. The existing
`with_required_predicate` API remains available for trusted derived domains.

`owned_set_sync` is advertised for native SQLite only when actual SQLite
supports `RETURNING` (3.35 or newer). `result->metadata` reports the number of
sets and each actual cleanup affected count. Native tests use in-memory SQLite,
including generated identities beyond 2^53, composite identities, policy
boundaries, empty sets and rollback after a real DELETE trigger failure.

Declared `rules` now govern native writes, batches, graphs, and action patches.
Input rules see typed assigned values. Candidate rules see the actual stored
row overlaid with the proposed changes; updates and deletes require exactly
one governed row. Transaction rules run in that same transaction. Required
values supplied by database expressions or external evidence remain pending
when the provider cannot establish their prospective value. Missing fields,
overflow, and a provider snapshot explicitly marked incomplete fail with
`required_data_rule_pending`; a violated rule returns `data_rule_failed`.
Normalizers produce stored assignments, which are checked again against field
grants and trusted tenants before any mutation.

Required SQLite rules on mutations also verify ordinary, unshadowed,
trigger-free storage and compatible primitive column affinities inside the
transaction. Virtual/generated storage and custom text collations refuse when
the provider cannot establish that contract. Numeric candidates use SQLite's
actual NUMERIC conversion, so underflow and non-finite values cannot pass using
only the authored decimal spelling. This does not promise fixed-scale decimal
storage. Stored Booleans and exact integers are canonicalized before rules.

For graph collection rules, the runtime reads the complete eligible prior set
inside the write transaction and derives the final set from declared child
inserts, updates, deletes, and owned synchronization. Reads include ownership,
child write tenant scope, and child required predicates. `max_rows` may tighten
the default 1,000 row bound. Two deltas resolving to the same stored whole
identity are refused, including predicates that alias through SQLite affinity
or collation. Omitted sync rows also pass child delete rules before dispatch.

`plan_action` applies declared action input rules. `preview_action` and
`execute_action` reselect the declared action from its intent before using a
plan. One-root collection actions support declared owned/composition
relationship targets with `add`, `update`, `remove`, and `reorder` entries.
An ordered delta remains usable on a sync-capable edge; a full `sync` patch
requires all of the explicit cleanup grants described above. Field targets,
multiple root rows, and delete-root collection patches require a host executor.

An update action with only collection patches uses `reference_only` on its
root graph node. This anchor selects one policy-scoped parent and returns the
binding keys without issuing a synthetic root update. Added entries may carry
`client_id`; the result's `metadata->{identity_mapping}` contains the actual
ordered identity returned by SQLite. Mapping validation stays inside the
transaction, preserving exact 64-bit generated values and rollback semantics.
