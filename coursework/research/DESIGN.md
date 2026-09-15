# Formal design: exact keyed time-series diagnostics and extensions

## Production state and scope

The four statistical extensions use one exact keyed store-and-sort state. It
retains every accepted `(timestamp, Float64 value)` row, up to `max_samples`,
and does not retain a fitted model or a compact range envelope. The SQL
grouping key identifies the logical series; physical block, part, shard, and
merge order are not temporal inputs.

The current extension surface is:

```sql
timeSeriesLaggedLinearRegression(order[, max_samples])(timestamp, value)
  -> Tuple(intercept Float64, coefficients Array(Float64))
timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])(timestamp, value)
  -> Tuple(statistic Float64, coefficient Float64, observations UInt64)
timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])(timestamp, value)
  -> Tuple(statistic Float64, bandwidth UInt64, observations UInt64)
timeSeriesMeanShiftChangePoint(min_segment[, max_samples])(timestamp, value)
  -> Tuple(split_index UInt64, score Float64, mean_before Float64,
           mean_after Float64, sse Float64)
```

The three baseline diagnostics use the same state and contract.
`timestamp` accepts `UInt32`, `UInt64`, `DateTime`, or `DateTime64`; native
integer and floating-point values are converted to `Float64`. Decimal values
are not accepted by the current factory. Values must be finite. Rows with a
NULL argument are skipped by ClickHouse's nullable aggregate handling. The
default state cap is 1,000,000 rows and the hard cap is 10,000,000; exceeding
the configured cap is an error, never silent truncation.

## Keyed state and deterministic merge

`add` appends a keyed record and marks the state unsorted when the new key is
not greater than the previous arrival key. Before finalization, merge, or
serialization, the state is canonicalized by ascending timestamp. A canonical
state has strictly increasing keys. Equal timestamps are rejected as a hard
duplicate error both within one state and when two states are merged; arrival
order never selects a winner.

`merge(left, right)` first canonicalizes and validates both operands, checks
that their function parameters, state version, and `max_samples` agree, then
performs a two-pointer merge of the sorted records. Equal keys are rejected,
including a duplicate split across the operands. The combined count must fit
the cap. Empty state is the identity. Consequently the canonical keyed
record set is independent of row order, block order, shard interleaving, and
binary merge-tree shape; the statistical finalizers have the same result up to
the documented floating-point tolerance. Serialization writes a versioned
extension envelope (function kind and parameters) followed by the versioned
canonical keyed payload; incompatible parameters, non-increasing keys,
non-finite values, malformed counts, and unsupported versions fail rather than
being reinterpreted.

The state is exact in the sense that it loses no accepted keyed rows, and its
retained memory and serialized size are `O(n)` for `n` rows. Appending is
amortized `O(1)`; sorting an out-of-order state costs `O(n log n)`, while
merging already canonical states costs `O(n1 + n2)` time and temporary space.

## Positional equal-spacing semantics

After canonical timestamp sorting, rows are treated as observations at
positions `0, 1, ..., n - 1`. A lag of one means the next canonical row, and
the numeric timestamp difference is ignored. Thus the statistical model has
equal spacing in **position**, not elapsed-time semantics: timestamp gaps are
allowed and are not filled or weighted. A caller requiring equally spaced
elapsed-time inference must resample before aggregation. Duplicate keys still
fail; a missing numeric timestamp between two keys is not itself an error.

## Extension definitions

### Lagged linear regression

For fixed order `p` (`1 <= p <= 16`), finalization fits the positional model

```text
y[t] = intercept + coefficient[0] * y[t-1] + ...
       + coefficient[p-1] * y[t-p] + error[t].
```

Rows and lag columns are formed only after the full keyed state is sorted. The
centered/scaled, non-pivoted streaming Givens QR fit returns coefficients in
lag order 1 through `p`. Insufficient observations, rank deficiency,
ill-conditioning (scaled reciprocal condition estimate below `1e-12`),
non-finite intermediate results, or a checked `rows * columns^2` work budget
above 100,000,000 return the fixed-shape result with NaN fields.

### ADF statistic

For fixed augmentation lag `p` (`0 <= p <= 16`), the positional regression is

```text
delta(y[t]) = deterministic terms + gamma * y[t-1]
              + sum(phi[j] * delta(y[t-j])) + error[t].
```

`deterministic` is `none`, `constant` (the default), or `trend`; the trend is
the canonical row position, not the numeric timestamp. The returned
coefficient and statistic are the fixed-regression estimate and t-ratio for
`gamma`. Fixed-lag sample admission follows
`p <= floor(n / 2) - deterministic_terms - 1`, with a positive residual
degrees-of-freedom check. The usable post-lag row count is returned even when
the fit is undefined. No autolag selection or p-value is performed. The QR
resolution policy reports an unresolved fit as NaN instead of turning
roundoff into an unbounded t-ratio.

### KPSS statistic

`regression` is `level` or `trend`. Residuals are computed in canonical
position order, with the trend regressed on positions `0..n-1`. The long-run
variance uses a Bartlett/Newey--West kernel. An omitted bandwidth is

```text
min(n - 1, floor(12 * (n / 100)^0.25)).
```

An explicit bandwidth is non-negative, capped at 1024, and must be below
`max_samples`; a statistic requires it to be below the observed `n`. The
finalizer returns NaN for invalid/undefined variance or when its checked
`n * bandwidth` work limit exceeds 100,000,000. No p-value is estimated.

### Mean-shift change point

This is a one-break estimator, not generic multiple-change-point dynamic
programming. For each split with at least `min_segment` canonical samples on
both sides, it minimizes within-segment SSE. `split_index` is the number of
left-position samples, `score` is the dimensionless relative SSE reduction,
and the means and SSE are in the original value scale. Direct suffix Welford
states make finalization `O(n)` transient memory and avoid subtractive
cancellation. With `gamma_n=n*epsilon/(1-n*epsilon)`, improvements no larger
than `8*gamma_n*max(abs(candidate),abs(incumbent))` retain the earliest split;
the count-aware tolerance covers accumulated Welford roundoff. No identifiable improvement
returns split zero and NaN fields; a positive original-unit SSE that exceeds
Float64 is represented as `+Inf`.

## Compact-state decision (ADR-002)

The compact ordered-range prototype is a **NO-GO as an ordinary SQL
aggregate**. A bounded prefix/suffix state is exact only when every state is a
dense, canonical contiguous range and every merge is a proven adjacent
left-to-right merge. Ordinary `IAggregateFunction` execution cannot prove that
premise across arbitrary aggregation trees, distributed gathers, retries,
spills, persisted states, `-State`/`-Merge`, or `AggregatingMergeTree`. The
`1, 3, 2` schedule demonstrates why disjoint envelopes lose an interior row.

Compact state may be reconsidered only inside a planner/operator feature that
proves contiguous canonical range ownership and enforces adjacency on every
merge path. Until then, the exact keyed `O(n)` state above is the production
contract; no compact aggregate or generic compact state combinator is
promised.
