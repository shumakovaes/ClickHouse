# Ordering semantics

## Canonical key order versus execution order

The aggregate receives `(timestamp, value)` pairs. Timestamp order is the
only semantic order. Arrival order, row/block order, part order, shard
interleaving, and merge-tree shape are execution details and must not change
the canonical keyed series or its result. The SQL grouping key identifies the
series; no physical range or implicit contiguous interval is inferred.

Each state retains all accepted rows up to `max_samples`. It appends in
arrival order, sorts by ascending timestamp whenever canonicalization is
required, and validates strict uniqueness. A timestamp occurring twice is a
hard duplicate-key error, whether both rows arrived in one state or the rows
meet during a merge. No value is chosen by arrival order. Non-finite values,
invalid parameters, and cap overflow are also errors; NULL arguments are
skipped by ClickHouse's nullable aggregate handling.

## Positional equal-spacing model

After sorting, the observations are indexed `0..n-1`. Adjacent indices are one
positional step apart even when their numeric timestamps have a large or
irregular gap. Therefore:

- lagged regression lags use prior positions;
- ADF differences, augmentation lags, and its optional trend use positions;
- KPSS level/trend residuals and cumulative path use positions; and
- mean-shift `split_index` counts rows in the left positional segment.

The functions do not interpret timestamp differences as elapsed time, do not
insert missing timestamps, and do not reject a gap merely because it is not a
fixed numeric step. This is equal-spacing semantics in the canonical
positional model. Callers needing elapsed-time equal spacing must resample
before aggregation; duplicate timestamps must be removed before aggregation
or the query fails.

## Deterministic merge contract

Before merging, both states are canonicalized and checked for the same
extension kind, parameters, serialization version, and `max_samples`. A
two-pointer merge of strictly increasing vectors forms the union in linear
time. Equal keys fail; the combined row count must fit the cap. Empty state is
the identity. Thus any valid disjoint-state merge order produces the same
canonical record vector, including arbitrary interleaving and
parenthesization. Final floating-point calculations are deterministic for
that canonical order, with documented tolerance rather than a bitwise
identity promise across all reduction paths.

Serialization first produces the canonical order and records a versioned
extension envelope plus the keyed payload. Deserialization rejects unsupported
versions, parameter mismatches, malformed counts, non-finite values, and
non-increasing keys. State bytes are never silently interpreted under a
different function configuration.

## Ordering behavior of the four extensions

| Function | Canonical positional operation |
|---|---|
| `timeSeriesLaggedLinearRegression(order[, max_samples])` | Fits fixed order `p` using rows `t = p..n-1`; coefficients are returned in lag order 1 through `p`. |
| `timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])` | Uses `delta(y[t])`, `y[t-1]`, fixed positional difference lags, and an optional position trend; returns the fixed-lag coefficient/t-statistic and usable row count. |
| `timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])` | Regresses level or position trend, then evaluates the Bartlett long-run variance and cumulative residual path in canonical order. |
| `timeSeriesMeanShiftChangePoint(min_segment[, max_samples])` | Evaluates legal positional splits, minimizes two-segment SSE, and keeps the earliest candidate when improvement is within the documented count-aware `8*gamma_n` relative roundoff envelope. |

Undefined fits/statistics return NaN fields (and the documented zero split for
an unidentifiable change point); this is a finalization result, not a change
to ordering or merge behavior. The extension-specific limits remain part of
the contract: regression order and ADF augmentation are capped at 16, KPSS
bandwidth at 1024 with a checked work budget, and all state sizes use the
shared `max_samples` cap.

## Compact-state restriction (ADR-002)

The exact keyed store-and-sort state is the ordinary aggregate design. A
compact `O(L)` range state is a NO-GO for ordinary aggregate registration and
generic `-State`/`-Merge`: disjoint ranges can be merged before an omitted
interior key arrives, so boundaries cannot reconstruct positional lags or
ordered candidates. Compact state may be used only by a future
planner/operator that proves canonical contiguous range ownership and merges
only adjacent ranges on every local, remote, retry, spill, and persisted path.
Without that end-to-end proof, no contiguous-range assumption is part of the
production ordering contract.
