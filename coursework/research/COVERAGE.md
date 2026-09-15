# Targeted coverage assessment: exact keyed diagnostics and extensions

This is a review-based coverage assessment, not an LLVM, gcov, or ClickHouse
whole-program coverage report. It maps the shared state, the three original
diagnostics, and the four newly registered statistical extensions to executable
tests or to an explicitly recorded gap. The extension sources and test
fixtures are present in the working tree; the current Release-linked native,
SQL, distributed, and remote-CI acceptance run remains pending.

## Evidence inventory

| Evidence | Scope and current status |
|---|---|
| `src/AggregateFunctions/tests/gtest_time_series_diagnostics.cpp` | Fifteen focused native tests for the original keyed state and three diagnostics; the prior Debug evidence recorded 15/15. |
| `src/AggregateFunctions/tests/gtest_time_series_statistical_extensions.cpp` | Twenty-two focused test cases (seven state/envelope cases and fifteen aggregate/finalizer cases) for the four extension kinds; source is present, execution count is pending the dedicated acceptance run. |
| `tests/queries/0_stateless/05161_time_series_diagnostics.sql` plus `.reference` | Existing public-path coverage for the original three functions; prior Debug evidence recorded 1/1. |
| `tests/queries/0_stateless/05162_time_series_statistical_extensions.sql` plus `.reference` | Direct stateless coverage for all four extensions: preview gate, result shapes, undefined cases, parameter validation, representative `UInt64`/`Float64` dispatch, NULL handling, Decimal rejection, state combinators, duplicates, and non-finite values; fixture is present, execution is pending. |
| `tests/queries/0_stateless/05163_time_series_statistical_extensions_distributed.sql` plus `.reference` | Two-shard `Distributed` merge, serialized partial-state merge, and cross-shard duplicate propagation for all four extensions; fixture is present, execution is pending. |
| `tests/queries/0_stateless/05164_time_series_statistical_extensions_aggregating_merge_tree.sql` plus `.reference` | `AggregatingMergeTree` part/state persistence and duplicate-key failure for all four extensions; fixture is present, execution is pending. |
| `coursework/reference/python/test_reference.py`, `test_extensions.py`, and recorded experiment outputs | Independent formula, ordering, validation, statistical, and numerical evidence. These are oracle evidence, not proof of native dispatch or ClickHouse execution. |

The extension implementation is in
`src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.{h,cpp}`
and is registered by `src/AggregateFunctions/registerAggregateFunctions.cpp`.
The extension state delegates keyed sample storage, canonical sorting, duplicate
rejection, caps, and serialization to the exact store-and-sort state used by
the original diagnostics; its envelope records the extension kind and fixed
parameters.

## Shared state and serialization

| ID | State branch or invariant | Evidence | Assessment |
|---|---|---|---|
| S1 | Finite keyed samples are accepted, with arbitrary input order canonicalized before finalization | Existing diagnostics gtest and 05161; extension gtest shuffled-order case and 05162/05163 | Covered by test definitions; extension execution pending |
| S2 | Non-increasing keys mark a state dirty; canonical sorting then validates strict uniqueness | Existing diagnostics tests; extension state tests and 05162 duplicate cases | Covered in the shared state; extension public run pending |
| S3 | Non-finite values are rejected | Existing diagnostics gtest/SQL; extension gtest rejection case and 05162 NaN case | Covered by source-level tests; execution pending for the extension path |
| S4 | Positive `max_samples` and hard maximum are enforced on adds and merges | Existing diagnostics gtest/SQL; delegated extension state and 05162 parameter cases | Shared implementation covered; extension public execution pending |
| S5 | Unsorted states sort before merge/finalization; sorted states still validate uniqueness | Existing diagnostics tests; extension shuffled/interleaved merge tests | Covered by direct test definitions; current extension run pending |
| S6 | Canonical two-pointer merge handles left/right choices, duplicate keys, and unequal tails | Existing diagnostics gtest/SQL; extension interleaved merge and 05163 distributed cases | Covered by test definitions; distributed execution pending |
| S7 | Extension envelope rejects unsupported version/kind, parameter mismatch, and truncation; the delegated payload retains the shared count/order validation | Extension gtest parameter-mismatch/corrupt-envelope/truncated-payload case plus existing diagnostics malformed-payload tests | Envelope tests are present; extension execution pending |
| S8 | Empty, valid, and degenerate states retain the documented result shape and counts | Existing diagnostics tests; extension degenerate fixtures and 05162 | Covered by test definitions; public execution pending |

## Original diagnostic branches

The original matrix remains applicable to the unchanged diagnostics state:

| ID | Branch | Evidence | Assessment |
|---|---|---|---|
| D1 | Centered moments, midpoint/range normalization, compensated sums, and constant/short cases | Existing diagnostics gtest/05161 plus independent Python cases | Covered for representative finite values; every IEEE boundary is not exhaustively sampled |
| D2 | ACF lag zero, valid lag, invalid lag, and undefined short/constant paths | Existing diagnostics gtest and 05161 | Covered in the prior focused evidence |
| D3 | Ljung--Box lag loop, degrees of freedom, short/constant paths, and named tuple result | Existing diagnostics gtest/05161 and Python formula cases | Ordinary paths covered; defensive non-finite-rho guard remains a gap |
| D4 | Durbin--Watson key order, zero denominator, and extreme-scale normalization | Existing diagnostics gtest/05161 | Covered for representative finite values |
| D5 | Serialization canonicalization, version/cap/count/order/non-finite/truncation rejection, and bounded reserve | Existing diagnostics gtest and 05161 state paths | Covered in the prior focused evidence |
| D6 | Factory preview gate, arity, timestamp/value dispatch, Decimal rejection, and NULL combinator | 05161 SQL fixture | Covered in the prior functional evidence; all scalar widths are not enumerated |

## Four extension APIs

### `timeSeriesLaggedLinearRegression`

| Branch or contract | Evidence in the working tree | Assessment |
|---|---|---|
| Positional AR model, exact order-1 hand fixture, shuffled rows, intercept and coefficient-array result | Extension gtest `LaggedRegressionExactAndShuffled`; 05162 exact and shuffled queries; 05163 distributed reference | Covered by test definitions; native/public execution pending |
| Centered/scaled non-pivoted Givens QR, fixed order range 1--16, reciprocal-condition and finite-fit guards | Implementation source and extension gtest degenerate/merge/work-cap cases | Ordinary successful and undefined paths plus both lagged-regression and ADF QR work boundaries are represented; every rank/conditioning alternative is not exhaustively forced |
| Insufficient, constant, rank-deficient, or non-finite fit returns fixed-shape NaNs | Extension gtest `DegenerateFinalizersReturnNaN`; 05162 undefined and non-finite cases | Covered by test definitions; execution pending |
| `rows * order^2` work guard | Source guard; no dedicated public boundary assertion in the current fixtures | Explicit gap: add a native boundary test before claiming exhaustive regression-finalizer coverage |

### `timeSeriesADFStatistic`

| Branch or contract | Evidence in the working tree | Assessment |
|---|---|---|
| Fixed augmentation lag 0--16; deterministic `none`, `constant`, and `trend`; named `(statistic, coefficient, observations)` result; no p-value | Extension gtest golden cases for all deterministics; 05162 exact tuple/type queries | Covered by test definitions; execution pending |
| Statsmodels-compatible fixed-lag admission, observation count, positive residual degrees of freedom, and exact-fit undefined result | Extension gtest minimum-boundary, exact-fit, small-noise/lag/trend cases; 05162 boundary queries | Covered by test definitions; execution pending |
| Positional trend semantics after canonical key sorting and arbitrary/interleaved state merge | Extension gtest interleaved merge; 05162 shuffled/state queries; 05163 distributed fixture | Covered by test definitions; distributed execution pending |
| QR rank/conditioning, residual-resolution, work, and extreme-scale guards | Source and selected degenerate cases | Partial: selected guards are exercised, but every threshold and numeric boundary is not exhaustively sampled |

### `timeSeriesKPSSTest`

| Branch or contract | Evidence in the working tree | Assessment |
|---|---|---|
| Level/trend regression, explicit bandwidth, default `min(n - 1, floor(12*(n/100)^0.25))`, and named `(statistic, bandwidth, observations)` result | Extension gtest hand/trend/default-boundary cases; 05162 exact and 101-row queries | Covered by test definitions; execution pending |
| Bartlett long-run variance with `q=0`, `q=n-1`, and rejection at `q>=n` | Extension gtest `KPSSTrendBandwidthAndDefaultBandwidthBoundaries`; 05162 boundary queries | Covered by test definitions; execution pending |
| Constant/short/invalid cases, `q <= 1024`, and checked `n*q <= 100000000` work policy | Extension gtest constant/work-cap cases; 05162 q=1024 case; 05163 distributed state | Covered by test definitions; execution and exact boundary result pending |
| Statistic-only contract and no p-value | Source documentation, gtest tuple checks, 05162/05163 | Covered by source/test definitions; generated documentation check pending |

### `timeSeriesMeanShiftChangePoint`

| Branch or contract | Evidence in the working tree | Assessment |
|---|---|---|
| One-break scan, `min_segment`, exact split/means/score/SSE, and descriptive (not p-value) result | Extension gtest hand fixture; 05162 exact tuple query; 05163 distributed and 05164 persistence | Covered by test definitions; execution pending |
| Earliest split for numerical ties and no-improvement `(split_index=0, NaN fields)` | Extension gtest tie/no-improvement/repeated-tie cases; 05162 repeated-pattern query | Covered by test definitions; execution pending |
| Direct suffix Welford accumulation preserves tiny SSE under cancellation and large-offset behavior | Extension gtest large-offset and cancellation cases | Covered by direct test definition; execution pending |
| Positive original-scale SSE overflow reports `+Inf`; tiny SSE may underflow to zero | Extension gtest overflow case; implementation documentation | Covered by test definition; execution pending |
| Constant/empty/short series returns undefined result | Extension gtest degenerate case; 05162 undefined query | Covered by test definitions; execution pending |

## Public-path and persistence coverage

`05162` defines the direct contract surface for all four names: private-preview
enablement, malformed arity and parameters, representative `UInt64`/`Float64`
dispatch, Decimal rejection, NULL skipping, finite-value rejection, duplicates,
exact tuples, undefined values, `-State`/`-Merge`/`-MergeState`, and interleaved
partial states. It does not enumerate every supported timestamp/value width.
Generic SQL cannot manufacture arbitrary opaque bytes, so malformed extension
payload tests remain a lower-level gtest responsibility.

`05163` partitions a shared table across the existing two-shard localhost test
cluster and checks direct distributed finalization, serialized partial-state
merge, and duplicate-key error propagation. `05164` creates separate
`AggregatingMergeTree` parts, merges all four extension states, finalizes them,
and checks duplicate-state failure. These fixtures are present with references;
their current execution result must be recorded by the dedicated acceptance run.

## Explicit gaps and remaining gates

The following are intentionally not reported as covered:

* instrumented line/branch percentages for ClickHouse or the new translation
  unit;
* the Release configure/build, Release-linked gtest run, and actual SQL result
  counts for 05161--05164;
* actual two-shard Distributed and `AggregatingMergeTree` execution logs;
* required remote CI jobs; local execution is not remote-CI evidence;
* native Release performance/resource measurements (the Python oracle is not a
  native benchmark);
* generated/reference documentation extraction and publication checks for the
  four new source `FunctionDocumentation` entries;
* direct invocation of every internal unknown-name and `Field::tryGet`
  conversion alternative, every scalar width, every allocator/accounting
  failure, and every exception path in ClickHouse framework code;
* every QR rank/conditioning threshold, KPSS work boundary, and floating-point
  IEEE overflow/underflow boundary;
* statistical power/size claims beyond the fixed-seed independent experiment
  grid.

The compact prefix/suffix or bounded range state is a **NO-GO** ordinary
aggregate for arbitrary row, block, shard, spill, retry, persistence, and merge
order. The `1,3,2` counterexample shows that boundary-only state loses interior
lag pairs after an engine-selected merge. It remains a rejected prototype and
must not be registered, exposed through `-State`/`-Merge`, used by
`Distributed` aggregation, or used in `AggregatingMergeTree` without a new
order-aware execution contract that proves adjacent canonical ranges at every
merge boundary.

## Conclusion

The shared state and the four extension source/test surfaces are implemented in
the working tree, and the test matrix above records the intended contract. The
prior three-diagnostic Debug evidence remains valid for the unchanged baseline.
No extension Release/gtest/SQL/Distributed/`AggregatingMergeTree`/remote-CI
pass count is claimed until the dedicated acceptance run produces its raw logs;
the remaining validation and generated-documentation gates are deliberately
left pending.
