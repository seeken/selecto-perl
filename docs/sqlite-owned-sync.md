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
