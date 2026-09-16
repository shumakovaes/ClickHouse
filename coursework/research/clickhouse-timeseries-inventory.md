# ClickHouse public inventory and coursework checkout

**Scope.** This inventory has two explicitly separate views, both checked on
2026-09-10. Sections 1--4 and 5--7 describe the upstream/public ClickHouse
documentation and source available at research time. Section 4A describes the
coursework checkout's additional working-tree registration. The seven
coursework APIs are not claimed to be upstream/public APIs at that date.
Function names below are exact names; a grouped row is a family, not a new
function.

The local documentation/source paths are relative to
`C:/Users/79261/Documents/Codex/2026-09-10/re/outputs/ClickHouse`.

## 1. Upstream/public aggregate/statistical building blocks

| Area | Native functions/family | What it provides | Version/maturity evidence | Research snapshot path | Official documentation |
|---|---|---|---|---|---|
| Descriptive aggregates | `count`, `sum`, `avg`, `min`, `max`, `median`, `quantile*`, `stddev*`, `var*` | Grouped summaries, robust/quantile summaries, dispersion | Mature, ordinary aggregate-function reference | `docs/reference/functions/aggregate-functions/reference-index.mdx` | [Aggregate-function reference](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference) |
| Correlation/covariance | `corr`, `corrStable`, `covarPop`, `covarSamp`, `corrMatrix` | Pairwise association and covariance; `corrMatrix` for a correlation matrix | Mature aggregate functions | Same aggregate reference index; implementations under `src/AggregateFunctions/` | [Correlation and covariance entries](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference) |
| Regression/trend | `simpleLinearRegression`, `stochasticLinearRegression`, `simpleLinearRegression`-style aggregate states | Trend slope/intercept and aggregate-state workflows; not autoregression | Mature where documented; check function-specific entry for build support | `docs/reference/functions/aggregate-functions/reference-index.mdx`; `src/AggregateFunctions/` | [Aggregate-function reference](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference) |
| Ordered samples | `groupArray`, `groupArrayMovingAvg`, `groupArrayMovingSum`, `groupArrayInsertAt`, `groupArrayLast` | Collect a bounded/unbounded array and simple moving summaries; useful as a pre-processing bridge to array functions | Mature aggregate family | `docs/reference/functions/aggregate-functions/reference-index.mdx` | [Aggregate-function reference](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference) |
| Exponential/time-decayed summaries | `exponentialMovingAverage`, `exponentialTimeDecayedAvg`, `exponentialTimeDecayedCount`, `exponentialTimeDecayedMax`, `exponentialTimeDecayedSum` | Online smoothing/decay baselines | Mature functions; these are smoothers, not fitted ARIMA/ETS models | Aggregate reference index; `src/AggregateFunctions/` | [Aggregate-function reference](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference) |
| Aggregate combinators | `-If`, `-Array`, `-Map`, `-State`, `-Merge`, `-ForEach`, `-Resample` (suffixes applied to compatible aggregates) | Conditional, array-wise, map-wise, state/merge, element-wise and resampled aggregation | Mature combinator mechanism; `-Resample` is especially useful for bucket baselines | `docs/reference/functions/aggregate-functions/combinators.mdx` | [Aggregate combinators](https://clickhouse.com/docs/sql-reference/aggregate-functions/combinators) |

These aggregates are useful baselines and feature-generation primitives. They do
not, by themselves, constitute stationarity tests, an autoregressive fit, or a
change-point detector.

## 2. Upstream/public arrays and regular series functions

| Area | Native functions | Coursework use | Version/maturity evidence | Research snapshot path | Official documentation |
|---|---|---|---|---|---|
| Array transforms | `arrayMap`, `arrayFilter`, `arrayZip`, `arrayEnumerate`, `arraySlice`, `arrayFlatten` | Build aligned lag/value tuples, remove invalid samples, and construct feature arrays | Mature regular functions | `docs/reference/functions/regular-functions/array-functions.mdx`; `src/Functions/array/` | [Array functions](https://clickhouse.com/docs/sql-reference/functions/array-functions) |
| Differences/cumulative features | `arrayDifference`, `arrayCumSum`, `arrayCumSumNonNegative`, `arrayReverse`, `arraySort` | First differences, cumulative counters, ordering and transformation before modeling | Mature regular functions | Same array-functions doc and `src/Functions/array/` | [Array functions](https://clickhouse.com/docs/sql-reference/functions/array-functions) |
| Array-level reduction/folding | `arrayReduce`, `arrayReduceInRanges`, `arrayFold` | Apply an aggregate or lambda across an array; can express custom feature calculations, but not a packaged statistical test | Mature regular functions | Same array-functions doc and `src/Functions/array/` | [Array functions](https://clickhouse.com/docs/sql-reference/functions/array-functions) |
| Autocorrelation | `arrayAutocorrelation(arr[, max_lag])` | Normalized autocorrelation by lag; direct ACF/seasonality exploration | **Introduced v26.4**; current source registers `Array(Float64)` output and returns NaN for zero variance | `src/Functions/array/arrayAutocorrelation.cpp` | [26.4 release presentation](https://presentations.clickhouse.com/2026-release-26.4/), [26.4 release notes](https://github.com/ClickHouse/clickhouse-docs/blob/main/docs/cloud/reference/01_changelog/02_release_notes/26_4.md) |
| STL decomposition | `seriesDecomposeSTL(series, period)` | Seasonal, trend, residual and baseline arrays | **Introduced v24.1** | `src/Functions/seriesDecomposeSTL.cpp`; `docs/reference/functions/regular-functions/time-series-functions.mdx` | [Time-series functions](https://clickhouse.com/docs/sql-reference/functions/time-series-functions) |
| Tukey outlier score | `seriesOutliersDetectTukey(series[, min_percentile, max_percentile, K])` | IQR/Tukey-fence anomaly score for each series element | **Introduced v24.2** | `src/Functions/seriesOutliersDetectTukey.cpp`; same time-series doc | [Time-series functions](https://clickhouse.com/docs/sql-reference/functions/time-series-functions) |
| FFT period detection | `seriesPeriodDetectFFT(series)` | Candidate period detection for a regular numeric series | **Introduced v23.12**; returns NaN for too-short/unsupported input | `src/Functions/seriesPeriodDetectFFT.cpp`; same time-series doc | [Time-series functions](https://clickhouse.com/docs/sql-reference/functions/time-series-functions) |
| Timestamp grids | `timeSeriesRange(start_timestamp, end_timestamp, step)` | Generate regular timestamp arrays for joining/aligning observations | **Introduced v25.8** | `docs/reference/functions/regular-functions/time-series-functions.mdx`; `src/Functions/` | [Time-series functions](https://clickhouse.com/docs/sql-reference/functions/time-series-functions) |

`arrayAutocorrelation` is the native ACF capability to use for the coursework;
do not implement a second SQL autocorrelation UDF unless the experiment is
explicitly about reproducing/validating its numerical behavior.

## 3. Upstream/public window functions and lag construction

| Native function/family | Use | Research snapshot path | Official documentation |
|---|---|---|---|
| `lag`, `lead` | Previous/next row in a partition; generate lagged regressors and one-step targets | `docs/reference/functions/window-functions.mdx` | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |
| `lagInFrame`, `leadInFrame` | Frame-respecting lag/lead; important when using bounded `ROWS`/`RANGE` frames | Same | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |
| Aggregate-over-window (`sum`, `avg`, `min`, `max`, `count`, quantiles, etc.) | Rolling and expanding summaries over `ROWS`/`RANGE`/`GROUPS` frames | Same; aggregate implementations in `src/AggregateFunctions/` | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |
| `nonNegativeDerivative` | Non-negative derivative estimate over ordered timestamps | Same | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |

Window support is the cleanest native way to build a row-oriented lag matrix;
arrays are the cleanest way to hand an ordered series to
`arrayAutocorrelation`/STL/FFT. ClickHouse documents that DateTime `RANGE`
offsets use numeric seconds rather than an `INTERVAL` expression.

## 4. Upstream/public time-series aggregate inventory and maturity

The following are separate upstream/public aggregate functions, not generic
aliases. In the research snapshot, every listed public `timeSeries*.mdx` page
says **private preview** and requires
`enable_time_series_aggregate_functions = true`. They were introduced in v25.6
unless noted otherwise. This table does not include the coursework-only APIs in
Section 4A.

| Family | Exact functions | Semantics | Version | Maturity/setting | Research snapshot source/docs | Official pages |
|---|---|---|---|---|---|---|
| Grid resampling | `timeSeriesResampleToGridWithStaleness` (alias `timeSeriesLastToGrid`) | Most recent sample on each regular grid point, subject to staleness | v25.6 | Private preview; `enable_time_series_aggregate_functions=true` | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeseriesHelpers.cpp`; `docs/reference/functions/aggregate-functions/timeSeriesResampleToGridWithStaleness.mdx` | [Resample with staleness](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesResampleToGridWithStaleness) |
| Counter rates | `timeSeriesRateToGrid`, `timeSeriesInstantRateToGrid` | PromQL-like `rate` and `irate` on a regular grid | v25.6 | Private preview; same setting | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeseriesHelpers.cpp` plus `AggregateFunctionTimeseriesExtrapolatedValue.h`/`AggregateFunctionTimeseriesInstantValue.h`; matching `timeSeries*.mdx` | [rate](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesRateToGrid), [instant rate](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesInstantRateToGrid) |
| Counter deltas | `timeSeriesDeltaToGrid`, `timeSeriesInstantDeltaToGrid` | PromQL-like `delta` and `idelta` | v25.6 | Private preview; same setting | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeseriesHelpers.cpp`; matching docs | [delta](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesDeltaToGrid), [instant delta](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesInstantDeltaToGrid) |
| Derivative/prediction | `timeSeriesDerivToGrid`, `timeSeriesPredictLinearToGrid` | Derivative and linear extrapolation over grid samples | v25.6 | Private preview; same setting | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeseriesHelpers.cpp`; matching docs | [deriv](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesDerivToGrid), [linear prediction](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesPredictLinearToGrid) |
| Counter event counts | `timeSeriesChangesToGrid`, `timeSeriesResetsToGrid` | Count value changes and counter resets | v25.6 | Private preview; same setting | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeseriesHelpers.cpp`; matching docs | [changes](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesChangesToGrid), [resets](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesResetsToGrid) |
| Ordered sample retention | `timeSeriesGroupArray` | Sort timestamp/value samples; duplicate timestamps retain the greatest value | v25.8 | Private preview; same setting | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.cpp` and `.h`; `docs/reference/functions/aggregate-functions/timeSeriesGroupArray.mdx` | [timeSeriesGroupArray](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesGroupArray) |
| Two-sample state | `timeSeriesLastTwoSamples` | Retain two latest samples for `irate`/`idelta`, useful in materialized/Aggregating tables | v25.6 | Private preview; same setting | `src/AggregateFunctions/TimeSeries/AggregateFunctionLast2Samples.cpp` and `.h`; matching docs | [timeSeriesLastTwoSamples](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesLastTwoSamples) |

These functions solve time alignment, PromQL-compatible counter operations and
simple linear extrapolation. They are not general-purpose stochastic-model
fitting APIs. For reproducible coursework, record the setting and the exact
server build; preview functions may differ between a source checkout and a
deployed release.

## 4A. Coursework checkout: seven registered APIs

The checkout at the path above additionally registers seven private-preview
aggregate names over an exact keyed sample state. The three baseline names are
implemented in `AggregateFunctionTimeSeriesDiagnostics.cpp`; the four
coursework extensions are implemented in
`AggregateFunctionTimeSeriesStatisticalExtensions.cpp`. This is working-tree
evidence, not evidence that these names were upstream/public on 2026-09-10.
The dated extension ledger now establishes local Release/Debug, SQL,
Distributed, `AggregatingMergeTree`, performance-grid, and documentation
execution. Registration, Python results, and source inspection were not used as
substitutes. Required remote CI remains BLOCKED and is reported separately.

Let `n` be retained samples, `m = min(max_lag, n - 1)`, `p` be an order or
augmentation lag, `c` be the regression column count, and `q` be the KPSS
bandwidth. If a state is out of key order, canonical sorting adds `O(n log n)`;
merging two canonical states costs `O(n1 + n2)` for state sizes `n1` and `n2`.
The finalizer bounds below are per API and exclude that conditional sort.

| API | Checkout contract | Finalizer complexity after sorting | Extra finalizer storage |
|---|---|---:|---:|
| `timeSeriesAutocorrelation(lag[, max_samples])` | Centered positional ACF; undefined cases are NaN | `O(n)` | `O(1)` |
| `timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])` | Ljung--Box statistic and chi-squared survival p-value | `O(n * m)` | `O(1)` |
| `timeSeriesDurbinWatson([max_samples])` | Durbin--Watson over consecutive canonical residuals | `O(n)` | `O(1)` |
| `timeSeriesLaggedLinearRegression(order[, max_samples])` | Intercept plus lags 1--`p`; centered/scaled Givens QR; undefined fit returns NaNs | `O(n * c^2)`, `c = p + 1` | `O(c^2)` |
| `timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])` | Fixed-lag ADF statistic and coefficient for `none`, `constant`, or `trend`; no p-value | `O(n * c^2)`, `c = 1 + p + I(trend)` | `O(c^2)` |
| `timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])` | Level/trend KPSS with explicit Bartlett bandwidth; no p-value | `O(n * q)` | `O(1)` |
| `timeSeriesMeanShiftChangePoint(min_segment[, max_samples])` | Descriptive one-break two-mean SSE scan; no calibrated p-value | `O(n)` | `O(n)` suffix statistics |

The extension-specific guards are `p <= 16` for regression/ADF,
`q <= 1024` and `n*q <= 100000000` for KPSS, and a checked
`n*c^2 <= 100000000` QR budget. All seven retain keyed samples up to the
configured state cap; that storage fact does not replace the per-API
finalization bounds in the table.

## 5. Upstream/public missing first-class scope (and search evidence)

An inventory search over the upstream/public snapshot's
`docs/reference/functions`, `src/Functions`, and `src/AggregateFunctions` for
`stationarity`, `adfuller`, `kpss`, `autoregressive`, `arima`, `sarima`, and
`change.?point` returned no matching first-class function names. This is a
bounded source/docs search, not a claim that arbitrary SQL/UDF implementations
are impossible. The four coursework extension names are intentionally excluded
from this upstream/public negative result and are listed in Section 4A.

| Upstream/public gap at research time | Why it is genuinely distinct | Coursework boundary |
|---|---|---|
| Stationarity tests: ADF, KPSS, Phillips–Perron and test diagnostics | STL/FFT/ACF describe structure but do not test a unit root or trend stationarity | The checkout adds fixed-lag ADF and level/trend KPSS statistics, deliberately without p-values or autolag; Phillips–Perron remains external scope |
| Fitted AR(p), MA, ARMA, ARIMA/SARIMA and ETS/Holt–Winters models | `timeSeriesPredictLinearToGrid` is linear extrapolation; moving/exponential aggregates are smoothers, not fitted stochastic models | The checkout adds fixed-order lagged linear regression only; use ClickHouse for extraction/scoring and a controlled external component for broader model families |
| Forecast intervals and model diagnostics | Native trend/preview functions do not expose ARIMA coefficient covariance, residual tests, AIC/BIC, prediction intervals or calibrated uncertainty | Keep uncertainty and model-selection diagnostics in the reference implementation; compare point forecasts plus error metrics |
| Generic statistical change-point detection | `timeSeriesChangesToGrid` counts value changes; the checkout's mean-shift API estimates one descriptive two-mean break, not CUSUM, PELT, binary segmentation, or Bayesian CPD | Benchmark the one-break estimator separately and use an explicit multi-break algorithm only as additional scope |

## 6. Duplicate-avoidance decisions

1. For upstream/public array work, do **not** implement a second SQL
   autocorrelation UDF: use `arrayAutocorrelation` (v26.4), and reserve custom
   code for confidence bands, missing-value policy, or numerical validation.
   The checkout's keyed `timeSeriesAutocorrelation` is a separate coursework
   aggregate contract, not an upstream/public replacement claim.
2. Do **not** reimplement STL, FFT period detection, or Tukey/IQR outlier scoring:
   `seriesDecomposeSTL`, `seriesPeriodDetectFFT`, and
   `seriesOutliersDetectTukey` already cover those baselines.
3. Do **not** reimplement regular-grid PromQL primitives (`rate`, `irate`,
   `delta`, `idelta`, `deriv`, `changes`, `resets`, or staleness resampling)
   unless the research question is preview-function validation or portability.
4. Do **not** label `timeSeriesChangesToGrid` a change-point detector; it counts
   changes. A genuine change-point contribution needs a statistical regime-change
   method and a test protocol.
5. Do **not** label `timeSeriesPredictLinearToGrid` AR/ARIMA; it is a linear,
   PromQL-like extrapolation baseline. Likewise, smoothing aggregates are not a
   fitted forecasting model.

## 7. Coherent boundary recommendation

Use a layered project boundary:

1. Build an ordered, regularized series with
   `timeSeriesGroupArray`/`timeSeriesResampleToGridWithStaleness` when the preview
   setting is available; otherwise use a documented `groupArray` + ordering
   fallback.
2. Generate lag/difference features with windows (`lag`, `lagInFrame`) and arrays
   (`arrayDifference`, `arrayMap`, `arrayZip`), then obtain native ACF and basic
   seasonality candidates with `arrayAutocorrelation` and
   `seriesPeriodDetectFFT`.
3. Treat STL, Tukey, moving averages and linear grid prediction as native
   baselines.
4. Evaluate the checkout's four extensions against these public baselines with
   leakage-safe tests and explicit complexity/undefined-result reporting. Any
   further contribution should be clearly distinct: e.g. Phillips--Perron,
   ARIMA/ETS with intervals, or a calibrated multi-break detector. State
   exactly which preview setting/build and which checkout revision were used.

This boundary uses upstream/public ClickHouse for aggregation, ordering,
windows, arrays, decomposition and grid operations, while treating the seven
checkout APIs as coursework implementation evidence and leaving any additional
statistical-modeling question non-duplicative.
