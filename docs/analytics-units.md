# Analytics units

Selecto canonical domain columns may optionally describe the semantic unit of a numeric value. The column is the source of truth; aggregate measures inherit the unit instead of copying it into measure presets.

```perl
amount => {
    type => 'decimal',
    unit => {kind => 'currency', code => 'USD'},
    behavior => 'flow',
}
```

Supported unit kinds are `count`, `currency`, `distance`, `duration`, `mass`, `percentage`, `ratio`, and `scalar`. Currency requires a three-letter code. Distance, duration, and mass require a portable identifier code. Percentage values declare whether stored values are fractions or whole percentages; the default is `fraction`.

The optional behaviors are `flow`, `stock`, `ratio`, and `rate`. They distinguish calculations that cannot be inferred from a database numeric type. For example, cumulative totals are available for flows but not for point-in-time stock values.

Unannotated numeric columns infer the generic `scalar` unit. Counts always produce `count`. `SUM`, `AVG`, `MIN`, and `MAX` preserve the source unit. Analytical transformations use `Selecto::Analytics::TransformRegistry` to derive their output unit and applicability centrally.

`true_percentage` counts true values among non-null booleans and produces a whole-percentage unit; an empty or all-null group yields SQL `NULL`.

Domains must not use unit metadata for chart type, axis placement, color, or other presentation settings. Those choices belong to graph series and frames.

## Server-side transformations

`Selecto::Analytics::Pipeline` applies registered transformations to a bounded,
ordered aggregate series after database execution. This keeps PostgreSQL and
DuckDB behavior identical and keeps analytical calculations out of the browser.
Every output point retains both `raw_value` and displayed `value`, plus its
derivation metadata.

The pipeline supports percent of total, percent and percentage-point change,
index to first non-zero value, cumulative totals, trailing and exponential
moving averages, min/max normalization, and z-scores. Moving-average windows
are restricted to 2–365 points. Missing values remain missing; a cumulative
series continues its running value after a gap, and trailing averages use the
available values in each partial window. Percentage change returns no value
when its prior denominator is zero.
