# Canonical Explorer aggregate queries

`Selecto::API::Explorer` serves the HTTP-neutral `remote_query.explorer.v1`
profile. Send `POST <base>/explorer-query` with this envelope:

```json
{
  "format": "selecto.explorer-query",
  "format_version": 1,
  "query": {
    "select": ["area", {"aggregate": "count", "alias": "n"}],
    "group_by": ["area"],
    "rollup": true,
    "limit": 20,
    "offset": 0
  }
}
```

Domain and features pins are optional. Discovery is at `GET <base>/explorer-features`;
OpenAPI is at `GET <base>/openapi.json`. Authentication and the trusted engine's
field publication, field roles, required predicates and tenant boundary remain
host responsibilities. The engine enforces them on every constituent query.
The domain owns the root relation; there is no `from` override.

## Optional contract pins

Pinning protects against a field keeping its id while changing meaning. Use it
for integrations that must never run against a changed contract. It is off
unless the caller sends `domain: {"fingerprint":"<published fingerprint>"}`.
Without `domain`, the request runs against the current domain. A supplied
`domain` must be an object containing exactly one `fingerprint`, a non-empty
string. Empty objects, empty or non-string fingerprints, and extra keys return
`400 malformed_request`; a different fingerprint returns
`409 stale_domain_fingerprint`.

`features: {"revision":"<published features revision>"}` remains optional and
is checked independently, including without a domain pin. Results still return
the current `domain.fingerprint` and `features.revision`. Field publication and
role checks apply on every request.

Discovery advertises `optional_domain_pin: true` in the explorer-features
`supports` object, mirrored in OpenAPI at
`x-selecto-explorer-supports.optional_domain_pin`. Remote-query advertises it in
the canonical manifest's `query_capabilities.optional_domain_pin`; nested detail
uses the nested-detail-features `supports` object. All three envelopes accept
omission. Nested detail's context still binds its own fingerprint, publication
and revision and refuses a context from another fingerprint even when the
envelope omits `domain`.

## Optional aggregate coverage members

These additions retain envelope/profile version 1. Hosts advertise Boolean
`supports.as_of`, `supports.retarget`, `supports.pivot` and
`supports.subtotal_position`; each may be disabled with the host's `supports`
overrides. Absence or false in another runtime means clients must not send the
member. A disabled member returns `501 operation_unsupported`, before field and
shape checks. The features revision is the existing SHA-256 of canonical JSON
without `revision`, so these publications change it. OpenAPI publishes the four
properties, their response metadata and current capability restrictions.

Omitting all four retains existing query behavior and result shape. The required
new features revision is also echoed in query results, so that revision string
necessarily differs from releases preceding these capabilities.

### As of

```json
{"as_of": "2026-05-10"}
```

`query.as_of` accepts exactly the values admitted by `Selecto::Query->as_of`:
a valid ISO calendar date or timestamp with seconds, optional fractional seconds
and optional `Z` or numeric offset. Invalid dates, times, scalar types, null and
containers return `422 invalid_query`. A date retains its calendar day; a
timestamp determines the date in `query.timezone` (UTC by default).

It overrides the trusted host clock for date shortcuts, elapsed/relative bucket
bounds and the underlying query's computed clock expressions. It applies to
all grouping sets, pivot ranking, cells and totals. Successful JSON responses
echo the original input at top-level `meta.as_of`, alongside `meta.request_id`
when supplied, exactly as Detail's remote query does. Omission adds no metadata.
It is a read clock, not historical database snapshot selection. As with native
queries and Detail, explicit query timezones on SQLite, MySQL/MariaDB and
DuckDB must be UTC; PostgreSQL accepts IANA zones.

### Retarget

```json
{
  "retarget": "notes",
  "group_by": ["notes.kind"],
  "select": ["notes.kind", {"aggregate": "sum", "field": "notes.weight", "alias": "weight"}],
  "filters": [{"field": "area", "op": "eq", "value": "A"}]
}
```

`retarget` is a string association path, explicitly listed in the domain's
`retarget.targets`. Discovery adds `retargets`, an array of `{path, label, fields}`.
Each target's fields use the ordinary features field descriptors, with ids still
relative to the original root. A target's direct fields and to-one fields are
available as scalar groups/measures; paths that cross another to-many relation
remain unavailable as scalar aggregates. Hidden/redacted fields are omitted.
A target catalogue uses the original domain's visibility and role metadata.

Unpublished or disallowed targets return `403 operation_forbidden`; a non-string
returns `422 invalid_query`. Unknown and hidden fields retain the existing
`422 invalid_field` and `403 hidden_field` errors. Selections, grouping, measure
fields and ordering must stay under the target path. This extension admits
aggregate/summary queries; scalar Detail continues to use its existing route.

Filters and query-library segments are root context, just as in the native
Explorer. The query then retargets and reroots output intent, without changing
that context. Core `Selecto::Retarget` preserves every declared association hop,
required predicate, full target identity and tenant/scope boundary. Neither the
publication document nor a client-supplied target grants authority.

### Summary pivots

```json
{
  "group_by": ["area", "stage"],
  "select": ["area", "stage", {"aggregate": "count", "alias": "n"}],
  "rollup": true,
  "subtotal_position": "before",
  "pivot": {
    "column": "stage",
    "values": ["open", "done", null],
    "other": true,
    "totals": true
  }
}
```

`pivot.column` names one of the selected `group_by` ids (a plain field or the
alias of a formatted/bucket group). At least two groups and one aggregate are
required. The column axis is removed from the row groups; remaining groups form
the ordinary summary and its page. Rollup/cube sets are rebuilt over those row
axes; explicit grouping sets are projected onto them and deduplicated. Pivots
support array/object rows and whole-result row exports, but not `complete` or
`export.shape: grid`. Ordering may not name the removed column axis.

Optional pivot members:

- `values`: a nonempty array of distinct typed values (including JSON null),
  bounded by `max_buckets`, each at most 1000 characters. Formatted and bucket
  axes use their resulting string values. Chosen values keep caller order and
  appear even when empty. Without `other`, unchosen values are excluded from
  row membership and totals, matching the native chosen-value view.
- `top`: `{limit: <positive integer>, measure: <selected aggregate id>,
  order: "rank" | "natural"}`. Mutually exclusive with `values`; limit is
  bounded by `max_buckets`. Rank means descending measure, null measures last,
  with a deterministic typed axis-key tie break and null keys last. Natural
  reorders only the selected top-N values. Ranking covers the entire filtered,
  governed result, independent of the row page.
- `other`: JSON Boolean, default false. Requires `values` or `top`; adds a
  final Other column, including unchosen nulls. It counts toward `max_buckets`.
- `totals`: JSON Boolean, default true. Adds row-total measure columns. Rollup's
  total row also provides the column totals and the grand total. These remain
  aggregates of underlying matching rows, including for average, distinct
  count and percentages. Without rollup, a total row is not invented.
- `value_order`: a nonempty list of distinct typed values, at most 500 entries,
  used for discovered/natural column ordering. Otherwise an unformatted axis
  uses the domain field's published `value_order`. Unlisted values follow,
  null last. Text uses case-folded ordering with a code-point tie break and
  empty text last. Numeric and temporal axes use their natural types; bucket
  ranges use authored order. Explicit chosen values and top rank take priority.

Without values/top, columns are discovered across the entire result. Authored
bucket ranges also appear when empty. Column discovery is bounded by
`max_groups`; resulting columns (including Other) by `max_buckets`, and rendered
page cells by `max_result_cells`. Refusals use `422 invalid_query` for invalid
shapes/values and `422 result_limit_exceeded` for result budgets. Axis field
publication and selection/grouping roles are checked before execution.

Output `data.columns` contains row group columns followed by one column for
each pivot value/measure pair, then optional total columns. Every measure column
keeps its ordinary type, encoding, aggregate and source field. Generated ids
are `__pivot_<value-index>_<measure-index>` and `__pivot_total_<measure-id>`;
underscores are appended on collision with an earlier output id. Use the
published ids rather than constructing them. Value/measure columns additionally
carry:

```json
{"pivot": {"column": "stage", "value": "open", "other": false, "measure": "n"}}
```

Other uses `value: null, other: true`, distinct from a real null value's
`value: null, other: false`. Total columns carry
`{pivot: {column: "stage", total: true, measure: "n"}}`. Missing cells are null,
including empty chosen columns. Row arrays follow `data.columns`; object rows
use its ids. Columns are independent of offset/limit. `row_meta` describes the
remaining row axes, and page/count metadata describes that ordinary summary.

### Subtotal placement, ordering and paging

```json
{"rollup": true, "subtotal_position": "before", "limit": 2, "offset": 2}
```

`subtotal_position` accepts only `before` or `after` and requires one of rollup,
cube or grouping sets. Omission and explicit `after` preserve existing natural
ordering and NULL placement. `before` uses the native Explorer sequence:
subtotal/grand-total placeholders precede child values; an actual null group is
distinguished by its grouping-set membership. One-axis native subtotals put
actual nulls last; multiple axes put actual nulls first. Plain groups use domain
`value_order` when declared.

Explicit placement also permits `order_by` with grouping sets. Caller ordering
precedes natural group order, with deterministic remaining group keys as ties.
As in the native Explorer, a one-axis total is placed before/after all values
even with measure ordering; with multiple axes, primary measure ordering can
separate parents from children. Omitting placement retains the old refusal of
caller ordering with grouping sets.

Every grouping set is an ordinary bounded grouped query. The host compares
normalized typed keys and grouping membership in Perl, then applies limit and
offset to the merged sequence, independent of backend default NULL placement
or unspecified database result order. Rows from all sets count toward
`max_groups`. This is deterministic for an unchanged matching dataset; it does
not promise a snapshot across concurrent requests or constituent queries.
Native display-only continued parent headers are not data rows and do not
consume the page limit.

## Runtime and consumer adoption

Python, Go, Rails, F# and Django implementations must separately opt into each
member and publish its support. Existing envelopes retain version 1. Their
parity scope is the four support flags and revised features hash; target
catalogues; the four query members and their validation/refusal order; top-level
As of metadata; pivot column metadata, independent cell/total aggregation and
paging; and native subtotal ordering, including explicit caller order admission.
Other runtimes must not copy the Perl host's true flags until implemented.

The API console chooser should expose these members only when advertised, use
the target catalogue, preserve typed pivot values and render returned column
metadata. The components hand-off should transfer As of, the root-relative
retarget intent, pivot options/resolved axis and measure ids, and
`subtotal_position: before` plus its ordinary page offset/limit and measure
orders. It should stop rejecting those four representable views. Native display
labels and continued parent headers remain presentation concerns.
