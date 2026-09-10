# ClickHouse time-series work: prior art, current landscape, and justified scope

Research snapshot: 2026-09-10. Links are primary ClickHouse/GitHub sources unless explicitly marked otherwise. Statements labelled **Inference** are conclusions from the cited evidence, not claims made verbatim by ClickHouse.

## Executive conclusion

ClickHouse now has a meaningful time-series substrate: ordinary time bucketing and `WITH FILL`/`INTERPOLATE`, dedicated PromQL-oriented grid aggregates, `timeSeriesRange`, and (in 26.4) array autocorrelation. It is not a complete statistics/forecasting toolkit. The current intern list still explicitly requests statistical aggregate/window functions for stationarity, breakpoints, and predicted values. A defensible project therefore needs to target a narrow, testable gap (for example, a documented stationarity/breakpoint aggregate or a validated array/window diagnostic), not re-present Holt–Winters or autocorrelation as novel.

## Current ClickHouse capabilities

### Time-grid and interpolation primitives

ClickHouse’s time-series guidance uses `toStartOfInterval` for custom buckets and `ORDER BY ... WITH FILL STEP ... INTERPOLATE` to materialize missing buckets and carry gauge values forward. The official tutorial demonstrates counters/gauges, histograms, and sparse-series filling: [Working with Time Series Data in ClickHouse](https://clickhouse.com/blog/working-with-time-series-data-and-functions-ClickHouse).

The 25.6 release introduced specialized aggregate functions for PromQL-style grid calculations: `timeSeriesInstantDeltaToGrid`, `timeSeriesInstantRateToGrid`, `timeSeriesRateToGrid`, `timeSeriesResampleToGridWithStaleness`, `timeSeriesDeltaToGrid`, and `timeSeriesLastTwoSamples`; the release presentation gives the call shape and says PromQL support was still in progress: [25.6 release call](https://presentations.clickhouse.com/2025-release-25.6/). `timeSeriesRange` was introduced in 25.8 as a DateTime-array generator: [new functions in 2025](https://clickhouse.com/blog/new-functions-2025).

**Maturity flag:** these grid functions are infrastructure for resampling/rate/delta/last-value semantics, not generic forecasting or anomaly detection. The 25.6 source presentation explicitly described the PromQL implementation as in progress. **Inference:** they reduce the need to build a new grid/resampling primitive, but do not close the statistics gap.

### `arrayAutocorrelation` (26.4)

Version 26.4 added `arrayAutocorrelation(array[, max_lag])`, computing normalized autocorrelation by lag for integer, floating-point, and decimal arrays. The official example shows seasonality-oriented use and optional lag truncation: [26.4 release call](https://presentations.clickhouse.com/2026-release-26.4/). The upstream release list includes stable 26.4 builds: [ClickHouse releases](https://github.com/ClickHouse/ClickHouse/releases).

**Maturity flag:** this is a shipped scalar array function, not evidence that stationarity testing, break-point detection, forecasting, confidence intervals, or model selection are shipped. **Inference:** a new project should treat autocorrelation as an available baseline/feature to integrate with, and focus novelty on missing diagnostics, semantics, tests, or performance evidence.

### Core statistical building blocks

Existing SQL/window machinery includes ordinary aggregates, aggregate states, `lagInFrame`/`leadInFrame`, array operations, `histogram`, and ordered windows. The time-series tutorial shows that production workflows can be composed from these primitives, but composition is not the same as a first-class statistical API: [time-series tutorial](https://clickhouse.com/blog/working-with-time-series-data-and-functions-ClickHouse). **Inference:** a project can be isolated at the aggregate/window-function layer without modifying storage or the query planner.

## Current intern landscape

The active [Intern Tasks 2025/2026 issue #87836](https://github.com/ClickHouse/ClickHouse/issues/87836) lists “Statistical aggregate functions”: aggregate or window functions for checking process stationarity, breaking points, and generating predicted values (lines 304–306). This is the clearest current statement of the open gap. The same issue asks that intern tasks be isolated and suitable for roughly a month (lines 175–183), which supports a focused function plus tests/benchmark rather than a complete forecasting framework.

The prior [Intern Tasks 2023/2024 issue #58394](https://github.com/ClickHouse/ClickHouse/issues/58394) names time-series analysis with aggregate functions and explicitly links `aleks5d` PRs 1–3. It says the functions had not been added to mainline, planned options were incomplete, and quality/performance had not been tested on real data (lines 426–442). That wording remains a constraint on what can be claimed.

The older [Intern Tasks 2022/2023 issue #42194](https://github.com/ClickHouse/ClickHouse/issues/42194) assigned `aleks5d` the broader list of stationary tests, shock-event detection, and Holt–Winters forecast (lines 506–513). The historical list is a proposal, not proof that any item shipped.

## `aleks5d` PRs 1–3: what already exists

### PR #1 — exponential smoothing alpha

[Add Window Function ExponentialSmoothingAlpha](https://github.com/aleks5d/ClickHouse/pull/1) starts as an aggregate-function implementation and is later changed to a window function. It adds alpha-parameter exponential smoothing, a time-aware/fill-gaps path, shared counter/helper code, and SQL tests. Review comments request functional SQL tests, clearer helper design/naming, less over-templating, deterministic/simple fixtures, `PARTITION BY` and bounded-frame tests, and clearer explanation of time weights. The page still shows the PR as open; there is no evidence here of upstream merge.

### PR #2 — Holt

[Add Window Function Holt](https://github.com/aleks5d/ClickHouse/pull/2) adds level/trend smoothing with alpha and beta, initially as an aggregate then reworked as a window function. It includes serialization/deserialization and visitor fixes, tuple output changes, tests, and comments. Review feedback asks for substantial documentation, clarification of parameter/value semantics, and an explanation of exact remapping. The page is shown as closed, with no evidence of upstream mainline merge.

### PR #3 — Holt–Winters

[Add Window Function HoltWinters](https://github.com/aleks5d/ClickHouse/pull/3) adds seasonal smoothing with alpha, beta, gamma, and season count, including additive/multiplicative prototypes, a type abstraction, window-function rework, tests, and comments. The page shows no reviews and is closed; no upstream merge is established by the record.

## Gaps and scope justification

The evidence supports these gaps:

1. No claim that Holt/Holt–Winters are upstream features: #58394 says the opposite.
2. No claim that the original scope is complete: stationary tests and shock-event detection from #42194 are not implemented by PRs 1–3.
3. No claim of production validation: #58394 explicitly says real-data quality and performance were not tested.
4. No claim of complete API/docs/window semantics: PR #1 requests partition/bounded-frame tests; PR #2 requests substantial docs and parameter clarification; PR #3 has no review record, which is not approval.
5. No claim that `arrayAutocorrelation` is new: it shipped in 26.4 and should be used as existing baseline functionality.

**Recommended bounded scope (Inference):** select one missing statistical capability from #87836—stationarity, breakpoint detection, or a carefully defined prediction primitive—and deliver a first-class aggregate/window function with explicit null/constant/short-series behavior, deterministic functional SQL tests (including partitions and bounded frames where applicable), documentation, comparison against a reference implementation, and benchmarks on realistic synthetic/real data. Optional integration with `arrayAutocorrelation` can demonstrate seasonality diagnostics, but should be described as composition with an existing 26.4 function.
