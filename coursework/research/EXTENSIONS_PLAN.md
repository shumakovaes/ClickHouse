# Time-series statistical extensions plan

## Status and baseline

This continuation starts from commit
`1a5ee147a53b284f1efc28e97803c3c837a706f3` on the verified baseline branch;
the active checkout is `coursework/time-series-extensions`.

The baseline comprises exactly three private-preview diagnostic aggregates over
the exact keyed `O(n)` state: autocorrelation, Ljung--Box, and Durbin--Watson.
The state retains all finite `(timestamp, Float64(value))` pairs, sorts them by
a unique timestamp, and therefore merges arbitrary interleaved partial states
correctly. The four extension implementations and registration are at
`src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.{h,cpp}`
and `src/AggregateFunctions/registerAggregateFunctions.cpp`; their focused
native tests are at
`src/AggregateFunctions/tests/gtest_time_series_statistical_extensions.cpp`.
That source defines 23 extension cases. Together with 15 baseline cases it
passes **38/38** in the recorded Release and Debug focused runs; the four SQL
fixtures pass **4/4** with no skips.

This file is the decision gate for the next four research directions. A method
is not a native API merely because a Python or standalone C++ prototype exists.

## Shared temporal contract

Unless a function states a stronger precondition:

- `timestamp` is a unique ordering key, not an elapsed-time measure;
- lags count positions after canonical sorting;
- gaps between timestamps are ignored;
- a caller who needs equally spaced statistical inference must resample first;
- rows with a NULL argument are skipped by the standard ClickHouse combinator;
- duplicate timestamps and non-finite values are errors;
- undefined statistical results are represented by NaN fields;
- the persistent state is capped by `max_samples` and consumes `O(n)` memory;
- arbitrary input, block, shard, and merge-tree order must not change the
  canonical logical series.

## Decision table

| Direction | Native target | State and cost | Decision gate |
|---|---|---|---|
| Compact lag state | No ordinary aggregate | `O(L)` only for complete adjacent ordered ranges | Research prototype until an execution operator proves adjacency on every merge path |
| Lagged linear regression | `timeSeriesLaggedLinearRegression` | Exact keyed rows; `O(n)` state, bounded small-matrix QR at finalize | Validation/acceptance after rank, numerical, merge, SQL, and distributed tests pass |
| ADF | `timeSeriesADFStatistic` | Exact keyed rows; fixed augmentation lag and deterministic mode | Statistic only; no p-value without audited MacKinnon response surfaces |
| KPSS | `timeSeriesKPSSTest` | Exact keyed rows; Bartlett/Newey--West finalization | No compact claim; explicit asymptotic convention and work cap |
| Mean-shift change point | `timeSeriesMeanShiftChangePoint` | Exact keyed rows; one-break `O(n)` final scan | Descriptive score only; no uncalibrated p-value or generic multiple-break claim |

## Compact ordered-range state

The `1, 3, 2` counterexample remains decisive. If singleton states 1 and 3 are
collapsed first, a bounded envelope cannot later determine how key 2 changes
the omitted interior lag pairs. Rejecting the first merge does not repair an
ordinary aggregate: ClickHouse is allowed to choose that merge tree for a
complete input.

A correct compact state requires an execution-level invariant stronger than
the aggregate interface provides:

1. every state is a complete dense interval with explicit lower and upper
   positions;
2. only adjacent intervals are combined;
3. operands are reduced in canonical left-to-right order;
4. remote aggregation, retries, spills, two-level aggregation, persisted
   states, and final coordinator merges preserve the same rule.

Until a specialized order-aware plan step enforces those facts, the compact
implementation stays quarantined in comparison/reference material. It must not
expose `-State`, `-Merge`, Distributed aggregation, or `AggregatingMergeTree`
semantics.

## Lagged linear regression

For order `p`, the intended positional model is

```text
y[t] = intercept + coefficient[0] * y[t-1] + ...
       + coefficient[p-1] * y[t-p] + error[t].
```

The order is fixed at aggregate creation and tightly capped. Lagged rows are
formed only after the full keyed state is sorted, because arbitrary shards can
interleave. Coefficients are fitted once at finalization; locally fitted
coefficients are never merged.

The solver scales and centers columns and uses a small Givens QR reduction
rather than raw normal equations. The finalizer has a checked
`rows * columns^2 <= 100000000` work budget. The non-pivoted scaled solve
rejects a reciprocal condition estimate below `1e-12`. Insufficient,
rank-deficient, ill-conditioned, or non-finite fits return a fixed-shape NaN
result.

## ADF statistic

For fixed augmentation lag `p`, form

```text
delta(y[t]) = deterministic_terms + gamma * y[t-1]
              + sum(phi[j] * delta(y[t-j])) + error[t].
```

Supported deterministic specifications are none, constant, and constant plus
linear trend. The trend uses canonical row position, not the numeric timestamp.
The returned ADF statistic is the t-ratio for `gamma` from the fixed requested
regression. It is not a Student-t test. Fixed-lag sample admission matches the
statsmodels rule `p <= floor(n / 2) - deterministic_terms - 1`, followed by a
positive residual-degrees-of-freedom check. Residual variance below the
scaled Float64 backward-error floor is reported as unresolved (`NaN`) instead
of turning QR roundoff into an enormous t-ratio.

The first native scope intentionally omits p-values and automatic lag search.
Both require additional statistical conventions and would make the result
conditional on model selection choices not represented by the current API.

## KPSS statistic

The intended modes are level and linear-trend stationarity. Residuals are
formed after canonical sorting, and the long-run variance uses a Bartlett
kernel with an explicit bandwidth or the documented function-local floor rule
`min(n - 1, floor(12 * (n / 100)^0.25))`. This is not called another
library's legacy mode. The statistic is
based on the squared cumulative residual path, so a fixed-size commutative
state is not claimed.

The direct finalizer costs `O(n * bandwidth)`. It must enforce a checked work
limit rather than accepting a combination that would perform uncontrolled
quadratic-scale work. P-values are omitted from the first native scope; the
bandwidth and observation count are returned with the statistic.

## Single mean-shift change point

This is a deliberately restricted one-break estimator, not general change
point dynamic programming. For each legal split, it minimizes the sum of
within-segment squared errors and retains the earliest reliably distinguishable
minimum. The native comparison uses
`gamma_n = n * epsilon / (1 - n * epsilon)` and accepts a later candidate only
when its SSE improves by more than
`8 * gamma_n * max(abs(candidate), abs(incumbent))`; this count-aware relative
envelope treats smaller differences as ties and therefore preserves the
earliest split. The independent Python batch oracle uses a strict `<` SSE
comparison, so it also preserves the earliest exact tie but can choose a
different split for deliberately near-tied objectives. The score is the
fraction of the one-mean total variation removed by the best two-mean fit. It
is descriptive and is not a p-value.

The result reports the number of samples in the left segment, the score, both
segment means, and the best two-segment SSE. A zero split denotes no
identifiable improvement. `min_segment` excludes unstable endpoint splits.
The finalizer builds direct suffix Welford states in `O(n)` transient memory;
this avoids the catastrophic cancellation caused by reconstructing right-hand
SSE as a difference of total and prefix moments. Numerically tied objectives
retain the earliest canonical split.

## Validation gate for every native API

Before a new name is counted as implemented, require all of the following:

1. dependency-free batch oracle and hand-computed examples;
2. optional cross-check against a pinned trusted library where one exists;
3. shuffled-row and arbitrary interleaved merge-tree equivalence;
4. duplicate, non-finite, cap, parameter, and insufficient-data cases;
5. extreme-scale and large-offset numerical cases;
6. canonical serialization plus malformed payload rejection;
7. factory arity/type/private-preview tests;
8. `-State`, `-Merge`, and `-MergeState` tests;
9. `AggregatingMergeTree` persistence;
10. an actual two-shard Distributed merge and cross-shard duplicate failure;
11. focused native and SQL execution with raw logs;
12. updated limitations and reproduction instructions.

## Release and CI claims

The final local run uses a separate Release directory and records revision,
submodule state, Clang 21/Ninja/CMake identity, exact commands, exit codes,
durations, test counts, configs, resource measurements, and SHA-256 manifests.
This supports a local Release-validation claim only. Required remote GitHub CI
remains **BLOCKED**: draft PR `#1` is mergeable/clean, but the inherited
workflow admits only `master` as its base while the PR correctly targets
`coursework/mergeable-time-series-statistics`, and the fork has zero registered
self-hosted runners. No full-CI claim is made.
