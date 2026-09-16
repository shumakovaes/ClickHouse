# Production plan: exact keyed time-series diagnostics and extensions

## Chosen scope

The implementation exposes seven private-preview aggregate names over one exact
keyed store-sort state. The state retains every finite `(timestamp, value)`
sample, canonicalizes by a unique timestamp before merge, serialization, or
finalization, and enforces `max_samples` (default `1,000,000`, hard maximum
`10,000,000`). Lags and trends are positional after key ordering; timestamp
gaps are ignored. Duplicate keys and non-finite values are errors, and
undefined numerical results are represented by `NaN` fields.

The baseline diagnostics are `timeSeriesAutocorrelation`,
`timeSeriesLjungBoxTest`, and `timeSeriesDurbinWatson`. The four implemented
extensions are:

| Function | Contract and bounded work |
|---|---|
| `timeSeriesLaggedLinearRegression(order[, max_samples])` | Positional AR model with intercept and lags 1 through `order`; `order` is 1--16. Centered/scaled non-pivoted Givens QR rejects ill-conditioned or undefined fits and caps `rows * order^2` work at `100000000`. |
| `timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])` | Fixed-lag ADF statistic and lag coefficient for `none`, `constant`, or `trend`; no autolag selection and no p-value. Uses the fixed-lag sample-admission, rank, residual-resolution, and QR guards documented in `EXTENSIONS_PLAN.md`. |
| `timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])` | Level or trend KPSS statistic with an explicit Bartlett bandwidth or the function-local default `min(n - 1, floor(12 * (n / 100)^0.25))`; bandwidth is capped at 1024 and `n * bandwidth` work at `100000000`; no p-value. |
| `timeSeriesMeanShiftChangePoint(min_segment[, max_samples])` | Descriptive one-break, two-mean SSE scan with an `O(n)` transient suffix-Welford pass, earliest numerical tie, and no calibrated p-value. Positive original-scale SSE overflow is reported as `+Inf`; no-improvement returns split index 0 and NaN fields. |

The four extensions share the exact keyed storage and merge law. Their state
envelope records the extension kind and constant parameters, while the payload
retains the independently versioned keyed samples. Local fitted models are not
merged; each finalizer fits or scans the canonical merged series.

## Compact-state decision

A compact prefix/suffix or bounded range state is a **NO-GO** ordinary aggregate
for arbitrary ClickHouse row, block, shard, spill, retry, persistence, and merge
order. The `1,3,2` schedule demonstrates that an engine-selected early merge can
discard the interior key needed for a later lag pair. Pairwise rejection of
non-adjacent ranges does not repair an ordinary aggregate because the reducer
does not control its merge tree.

The compact state remains a rejected comparison/prototype. It must not be
registered, exposed through `-State`/`-Merge`, used for `Distributed` aggregation,
or persisted in `AggregatingMergeTree` unless a future order-aware execution
operator proves complete adjacent ranges and canonical composition across every
local, remote, retry, spill, and persisted boundary. The production design is
therefore exact `O(n)` retained samples with canonical sorted union.

## Milestones and artifact status

| ID | Concrete output and acceptance evidence | Status |
|---|---|---|
| M1 | Freeze seven-API scope, signatures, key/value types, caps, duplicate/error policy, positional semantics, and non-goals in `DESIGN.md` and `EXTENSIONS_PLAN.md` | Complete in source/research artifacts |
| M2 | Shared state add/merge/finalize transitions, canonical sorting, duplicate/cap rejection, versioned serialization, and malformed-state guards | Complete in the existing diagnostics state; reused by the extension envelope |
| M3 | Ordering and merge-equivalence matrix, including arbitrary interleaving and duplicate cases | Complete in the state contract and the extension test/fixture definitions |
| M4 | Independent Python/reference coverage for regression, ADF, KPSS, and mean shift, including numerical and edge cases | Present as independent oracle and experiment artifacts; not native execution evidence |
| M5 | Four extension implementations, source `FunctionDocumentation`, and global registration | Implemented in `AggregateFunctionTimeSeriesStatisticalExtensions.{h,cpp}` and `registerAggregateFunctions.cpp`; current Release-linked acceptance remains pending |
| M6 | Focused native extension GoogleTest source | Present: `gtest_time_series_statistical_extensions.cpp` defines 23 cases; Release-linked pass/fail count and runtime remain pending |
| M7 | Direct functional fixture and reference for all four extension names | Present: `05162_time_series_statistical_extensions.sql` plus `.reference`; execution result remains pending |
| M8 | Two-shard `Distributed` merge and duplicate propagation | Present: `05163_time_series_statistical_extensions_distributed.sql` plus `.reference`; actual distributed run remains pending |
| M9 | `AggregatingMergeTree` part merge, finalization, persistence, and duplicate failure | Present: `05164_time_series_statistical_extensions_aggregating_merge_tree.sql` plus `.reference`; actual run remains pending |
| M10 | Native acceptance ledger: Release configure/build, seven-API gtest, 05161--05164, Distributed, and `AggregatingMergeTree` raw logs | Pending; do not infer this from source presence or Python results |
| M11 | Native Release benchmark with recorded resource/timing metadata | Pending; the Python-oracle benchmark is not a native performance result |
| M12 | Required remote CI jobs and generated/reference documentation check | Pending actual remote outcomes and generated-doc artifacts |

## Formula and implementation checkpoints

1. Sort the complete keyed sample by unique timestamp before every order-
   dependent finalizer. Merge canonical states with a two-pointer sorted union;
   reject duplicate keys rather than resolving them.
2. For lagged regression, form positional lag rows only after sorting and solve
   the centered/scaled small QR system. Return a fixed-shape NaN result when
   observations, rank, conditioning, residual resolution, finiteness, or the
   checked work limit is not sufficient.
3. For ADF, fit the requested fixed augmentation lag and deterministic terms;
   return the t-ratio and coefficient for `y[t-1]`, retain usable observation
   count, and do not claim a p-value.
4. For KPSS, fit level or trend residuals, use the stated Bartlett bandwidth
   convention, enforce `q < n` and `n*q <= 100000000`, and return statistic,
   bandwidth, and observation count without a p-value.
5. For mean shift, scan legal splits with direct suffix Welford states, select
   the earliest reliably smaller SSE, return the descriptive score and segment
   means, and preserve valid split/score information when original-scale SSE is
   `+Inf`.
6. Check each extension's add, merge, serialization, finalization, parameter,
   type, NULL, cap, duplicate, non-finite, insufficient-data, and numerical
   contracts through both native and public-path evidence. Opaque malformed
   bytes remain a lower-level native harness responsibility because SQL cannot
   manufacture arbitrary aggregate-state payloads.

## Remaining validation and documentation gates

The following gates remain intentionally open until the dedicated acceptance
run records raw commands, revision/submodule state, toolchain, flags, exit
codes, durations, counts, resource use, and artifact hashes:

* Release configure/build and Release-linked seven-API GoogleTest results;
* stateless execution of 05161--05164, including the two-shard Distributed
  merge, duplicate propagation, and `AggregatingMergeTree` finalization;
* native Release performance/resource measurements;
* required remote CI jobs (local tests are not remote-CI evidence);
* generated/reference documentation extraction and publication checks for the
  four `FunctionDocumentation` entries;
* exhaustive threshold tests for QR conditioning/work, KPSS work, all scalar
  widths, every conversion alternative, and framework allocation failures.

Prior focused Debug results for the unchanged three-diagnostic baseline may be
retained as historical evidence. They do not validate compilation, linkage,
dispatch, serialization, numerical guards, distributed behavior, Release
performance, or CI status of the four extensions. No such extension pass or
status claim is made here before the pending gates produce their logs.
