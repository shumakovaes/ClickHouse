# ClickHouse master: statistical/time-series function inventory

**Scope.** This is an inventory of the current checkout at
`outputs/ClickHouse` (the checkout was inspected on 2026-09-10), with the
official ClickHouse documentation as the public cross-check. It is deliberately
limited to capabilities that matter for coursework on statistical/time-series
analysis. Function names below are exact names; a grouped row is a family, not a
new function.

The local documentation/source paths are relative to
`C:/Users/79261/Documents/Codex/2026-09-10/re/outputs/ClickHouse`.

## 1. Native aggregate/statistical building blocks

| Area | Native functions/family | What it provides | Version/maturity evidence | Current-checkout path | Official documentation |
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

## 2. Arrays and regular series functions

| Area | Native functions | Coursework use | Version/maturity evidence | Current-checkout path | Official documentation |
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

## 3. Window functions and lag construction

| Native function/family | Use | Current-checkout path | Official documentation |
|---|---|---|---|
| `lag`, `lead` | Previous/next row in a partition; generate lagged regressors and one-step targets | `docs/reference/functions/window-functions.mdx` | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |
| `lagInFrame`, `leadInFrame` | Frame-respecting lag/lead; important when using bounded `ROWS`/`RANGE` frames | Same | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |
| Aggregate-over-window (`sum`, `avg`, `min`, `max`, `count`, quantiles, etc.) | Rolling and expanding summaries over `ROWS`/`RANGE`/`GROUPS` frames | Same; aggregate implementations in `src/AggregateFunctions/` | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |
| `nonNegativeDerivative` | Non-negative derivative estimate over ordered timestamps | Same | [Window functions](https://clickhouse.com/docs/sql-reference/window-functions) |

Window support is the cleanest native way to build a row-oriented lag matrix;
arrays are the cleanest way to hand an ordered series to
`arrayAutocorrelation`/STL/FFT. ClickHouse documents that DateTime `RANGE`
offsets use numeric seconds rather than an `INTERVAL` expression.

## 4. Time-series aggregate inventory and maturity

The following are separate aggregate functions, not generic aliases. In the
current checkout every listed `timeSeries*.mdx` page says **private preview** and
requires `enable_time_series_aggregate_functions = true`. They were introduced
in v25.6 unless noted otherwise.

| Family | Exact functions | Semantics | Version | Maturity/setting | Current-checkout source/docs | Official pages |
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

## 5. Missing first-class scope (and search evidence)

An inventory search over the current checkout's
`docs/reference/functions`, `src/Functions`, and `src/AggregateFunctions` for
`stationarity`, `adfuller`, `kpss`, `autoregressive`, `arima`, `sarima`, and
`change.?point` returned no matching first-class function names. This is a
bounded source/docs search, not a claim that arbitrary SQL/UDF implementations
are impossible.

| Missing capability | Why it is genuinely distinct | Suggested coursework treatment |
|---|---|---|
| Stationarity tests: ADF, KPSS, Phillips–Perron and test diagnostics | STL/FFT/ACF describe structure but do not test a unit root or trend stationarity | Export a series/lag matrix or use a UDF/external reference implementation; report statistic, lag choice and p-value assumptions |
| Fitted AR(p), MA, ARMA, ARIMA/SARIMA and ETS/Holt–Winters models | `timeSeriesPredictLinearToGrid` is linear extrapolation; moving/exponential aggregates are smoothers, not fitted stochastic models | Use ClickHouse for ordered extraction, lag features, scoring and backtesting; fit in a controlled external/UDF component |
| Forecast intervals and model diagnostics | Native trend/preview functions do not expose ARIMA coefficient covariance, residual tests, AIC/BIC, prediction intervals or calibrated uncertainty | Keep diagnostics in the reference implementation and compare point forecasts plus error metrics |
| Statistical change-point detection | `timeSeriesChangesToGrid` counts value changes; it does not estimate a distributional regime boundary (CUSUM, PELT, binary segmentation, Bayesian CPD, etc.) | Implement/benchmark one explicit change-point algorithm, with synthetic known-break tests |

## 6. Duplicate-avoidance decisions

1. Do **not** implement a bespoke autocorrelation function: use
   `arrayAutocorrelation` (v26.4), and reserve custom code for confidence bands,
   missing-value policy, or numerical validation.
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

## 7. Coherent missing scope recommendation

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
4. Make the actual contribution one of: stationarity diagnostics, AR(p)/ARIMA
   fitting plus leakage-safe rolling backtests, or a genuine change-point method.
   Include comparison against the native baselines and state exactly which
   preview setting/build was used.

This boundary uses ClickHouse for what it already does well (aggregation,
ordering, windows, arrays, decomposition and grid operations) while leaving a
non-duplicative statistical-modeling question for the coursework.
