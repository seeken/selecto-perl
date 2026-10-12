# Fluent writes, domain actions, and editable rows

`Selecto::Write->new($engine)` binds a local builder to a genuine configured
engine. It uses native portable compilation and fresh engine governance for
scalar writes, and native action planning/authorization for named actions.
Existing immutable `Selecto::Write::Operation` builders keep their behavior.

## Configure the domain and host context

This domain grants insert/update/delete, ordinary returning, a tenant boundary,
and a named transition. The application supplies an already connected DBI
handle. Use `postgresql` for the editable-row examples below, or `sqlite` for
ordinary writes and actions.

```perl
use Selecto;
use JSON::PP ();

my $domain = Selecto::Domain->parse({
    name => 'Work Items',
    source => {
        source_table => 'work_items', primary_key => 'id', tenant_field => 'tenant_id',
        fields => [qw(id tenant_id name state archive_reason)],
        columns => {
            id => {type => 'integer'}, tenant_id => {type => 'integer'},
            name => {type => 'string'}, state => {type => 'string'},
            archive_reason => {type => 'string'},
        },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => {map { $_ => {enabled => JSON::PP::true, returning => 'all'} }
            qw(insert update delete)},
        fields => {
            name => {insertable => JSON::PP::true, updatable => JSON::PP::true},
            state => {insertable => JSON::PP::true, updatable => JSON::PP::true},
            archive_reason => {updatable => JSON::PP::true},
            tenant_id => {insertable => JSON::PP::true, immutable => JSON::PP::true,
                required_on => ['insert']},
        },
        scope => {tenant => {field => 'tenant_id', required => JSON::PP::true,
            satisfied_by => ['trusted_context']}},
        transitions => {state => {done => ['archived']}},
    },
    actions => {
        archive => {
            type => 'transition', scope => 'row', capability => 'work_items.archive',
            transition => {field => 'state', from => 'done', to => 'archived'},
            inputs => {reason => {type => 'string', required => JSON::PP::true}},
            execution => {kind => 'updato', operation => 'update',
                set => {state => 'archived', archive_reason => ['input', 'reason']}},
        },
    },
    capabilities => {
        'work_items.archive' => {operations => ['action', 'update'], action => 'archive'},
    },
});
my $engine = Selecto::Engine->new(
    domain => $domain,
    adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
    write_context => {tenant_id => 8}, # Host authenticates this value.
);
```

The host creates a root table with a generated `id`, `tenant_id`, `name`, `state`,
and nullable `archive_reason`. Selecto does not open a connection or migrate it.

## Scalar calls and actual SQL previews

```perl
my $result = eval {
    my $w = Selecto::Write->new($engine)->insert->with_tenant(8);
    $w->assignments(name => 'Test', state => 'done');
    $w->returning(qw(id name));
    my $preview = $w->preview;
    print $preview->{sql}, "\n";
    print JSON::PP->new->encode($preview->{params}), "\n";
    $w->execute;
};
my $error = $@;
die $error if $error;
my $id = $result->values->{id};
```

The PostgreSQL preview uses bound values, for example:

```sql
INSERT INTO "work_items" ("name", "state", "tenant_id") VALUES ($1, $2, $3) RETURNING "id", "name"
```

Parameters: `['Test', 'done', 8]`. Preview performs no target DML and conveys
no later execution authorization. Use the returned native preview for the actual
configured adapter, including additional required guards and preflight work.

`with_tenant(8)` supplies an absent tenant assignment before required-field
validation. Explicit `tenant_id => 9` or `tenant_id => undef` refuses. The field
comes from the domain, so a domain using `org_id` is supported. An already bound
engine cannot change tenants. An unbound engine produces a private configured
copy; the original engine stays unchanged. Read filters and request JSON do not
become trusted write context.

Updates/deletes use `filter(['id', $id])`, or a native root expression such as
`filter(Selecto::Expression->eq('id', $id))`. Repeated filters combine with AND.
Tenant scope is retained. Writes default to exactly one affected row;
`expected_cardinality(['exactly', 2])` needs the domain's bulk permission.
Upserts use `conflict_target(qw(...))` and optional
`upsert_update_fields(qw(...))`; the latter only narrows assigned writable fields.
All native scoped-upsert restrictions remain in force.

Setters return the same builder. `assignments` and `inputs` replace their entire
sets and accept a hashref or even named pairs. Duplicate pairs and odd lists
refuse without changing the previous draft. Inputs are copied. A builder cannot
switch operation or mix scalar and action methods. Execution consumes the draft
even on failure; construct a fresh builder for a deliberate new attempt. There
are no automatic mutation retries. Preview leaves the draft available.

## Invoke a named domain action

```perl
# Host-owned resolver, called separately for preview and execution.
my $policy = sub {
    my ($request, $context) = @_;
    return $host_authorizer->($request, $context);
};
my $done = eval {
    my $a = Selecto::Write->new($engine)->action('archive')->with_tenant(8);
    $a->target($id);
    $a->inputs(reason => 'completed');
    my $preview = $a->preview(resolver => $policy,
        context => {actor => {id => $authenticated_user_id}});
    print $preview->{statement}{sql}, "\n";
    print JSON::PP->new->encode($preview->{statement}{params}), "\n";
    $a->execute(resolver => $policy,
        context => {actor => {id => $authenticated_user_id}});
};
my $error = $@;
die $error if $error;
```

The domain selects operation, assignments, typed inputs, transition source
state, preconditions, target bounds, executor, and result. Missing/hidden/disabled
capabilities refuse, and preview permission does not enable execution. Native
action envelopes preserve `action`, `phase`, `decision`, and `statement` or
`result`. There is no action `assignments` override or scalar returning override.
The helper accepts explicit host resolver/context options, not caller grants or
raw plans. Existing direct native grant APIs remain available separately.

A declared bulk action accepts `target({ids => [3, 4, 5]})`; exact IDs must be
unique and obey host/domain bounds. Unknown actions, undeclared/invalid inputs,
stale transitions, and wrong-tenant targets refuse through native governance.

## Immediate updates in PostgreSQL

```perl
my $created = $engine->transaction(sub {
    my ($tx) = @_;
    my $res = Selecto::Write->new($tx)->insert->with_tenant(8)
        ->assignments(name => 'Editable', state => 'done')
        ->return_for_update(qw(id name))->execute;
    $res->row->write->update->assignments(name => 'Changed')->execute;
    return $res;
});
# Values remain readable; $created->row now refuses as expired.
```

`return_for_update` is mutually exclusive with `returning`. It requires exactly
one inserted/updated/upserted row and every explicitly granted primary-key field
in the requested projection. Delete and bulk handles refuse. Hidden identity
retrieval is not implemented. Unsupported adapters refuse explicitly.

The callback pins one connection and transaction. Native writes use savepoints
and never commit it independently. Nested callbacks use their own savepoint and
handle lifetime. A callback inside an external host transaction does not commit
the host transaction. Handles expire at callback exit, including nested callback
exit, rollback, or a changed/released connection or server transaction identity.
Do not manually commit, reconnect, or release the handle inside the callback.

Opaque row references cannot be reconstructed from displayed values. Follow-up
updates combine their exact stored key with fresh domain and tenant governance;
they cannot change that key. A failed handle-produced write poisons its callback,
so catching a child error cannot accidentally commit a partially built parent.

Read-side locking uses the same handle contract:

```perl
$engine->transaction(sub {
    my ($tx) = @_;
    my $read = $tx->query->filter(Selecto::Expression->eq('id', $id))
        ->select_for_update(qw(id name));
    my $preview = $read->preview; # SQL ends in FOR UPDATE OF the root alias.
    my $editable = $read->execute;
    $editable->row->write->update->assignments(name => 'Updated')->execute;
});
```

An exact root-key equality and a public root-field projection including that key
are required. Grouped/aggregate, joined-field, set, retargeted, query-library,
and advanced-source projections refuse. Lock only the root; children retain
their own governance. Lock timeouts/deadlocks remain adapter errors. A preview
does not acquire a row lock. Never keep a database transaction open while a user
edits a browser form. PostgreSQL advertises `transaction_edit_handles`; SQLite
write reservations are not claimed as equivalent row locks.

## Add an owned child

Before configuring the engine, declare an edge under
`writes.relationships.items` in the parent's domain:

```perl
items => {
    writable => JSON::PP::true, ownership => 'owned', cardinality => 'many',
    allowed_ops => ['insert'], child_key => 'parent_id', identity_fields => ['id'],
    write => {modes => ['append_only'], create => JSON::PP::true},
    domain => $child_domain_contract,
}
```

`$child_domain_contract` is the full native domain with its own relation, fields,
tenant metadata, enabled insert, field grants, and constraints. It declares
`parent_id` as a stored field. The parent must grant the native graph's read
anchor through its update/returning policy. An ordinary join grants no write.

```perl
$engine->transaction(sub {
    my ($tx) = @_;
    my $created = Selecto::Write->new($tx)->insert
        ->assignments(name => 'Parent', state => 'done')->return_for_update('id')->execute;
    my $child = $created->row->related_write('items')->insert;
    $child->assignments(name => 'First item'); # No parent_id or tenant assignment.
    my $preview = $child->preview; # Native ordered graph statements and bindings.
    $child->execute;
});
```

The helper uses the existing governed graph path to recheck the parent's exact
identity and relationship, bind the foreign key, and materialize the child's
trusted tenant. Supplying a parent foreign-key assignment refuses. The pilot
supports owned one-to-many insert edges bound to the parent's primary key;
shared references, synchronization, arbitrary joined updates, and child edit
handles remain explicit unsupported capabilities.

## Compound identities

Compound root identities use a nonempty, distinct field list in the domain:
`source => {primary_key => ['tenant_id', 'id'], ...}`. Both
`return_for_update(qw(tenant_id id name))` and locked reads must explicitly
select every key field. Locked reads also require an equality for each part:

```perl
my $editable = $tx->query->where(Selecto::Expression->all(
    Selecto::Expression->eq('tenant_id', 8),
    Selecto::Expression->eq('id', $id),
))->select_for_update(qw(tenant_id id name))->execute;
$editable->row->write->update->assignments(name => 'Changed')->execute;
```

The handle retains all actual returned components; a follow-up cannot assign
any identity field. Missing/null components refuse. Native compound row actions
accept `target({tenant_id => 8, id => $id})`; missing or extra fields refuse.
Compound bulk-action targets and relationship bindings across multiple columns
are not implemented. Existing scalar relationship bindings still require the
declared globally unique parent field; a compound component alone does not
acquire that guarantee.

## Verification

`t/fluent_write_builder.t` exercises real SQLite writes, action authorization,
tenant omission/conflicts, count rollback, upsert masks, Unicode/null/large-key
returning, and builder input isolation. `t/fluent_transaction.t` checks callback
replay and ambiguous/known commit reporting. Collection-action success and late
child rollback also run through the helper in
`t/sqlite_rule_writes.integration.t`.

With `SELECTO_PERL_TEST_POSTGRES_URL` pointing to a disposable database,
`t/fluent_edit_handles.integration.t` verifies generated/exact identities,
both upsert branches, scalar/compound identities, actual two-connection lock contention, preview behavior,
owned-child atomicity, nested/host transaction ownership, and handle expiry.
It creates uniquely named synthetic tables and removes only its own tables.

Run `script/with-local-deps prove -lr t` and
`script/with-local-deps sh -c 'perl Makefile.PL && make test'` with the repository's
installed Perl dependencies. Existing central write/action certificates retain
their enumerated native API boundaries; these helpers do not invent a new
certification profile or imply parity with another runtime.
