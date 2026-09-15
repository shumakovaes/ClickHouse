# ClickHouse implementation map

## Production API and state

Register only:

| Function | Parameters | Arguments/result |
|---|---|---|
| `timeSeriesAutocorrelation` | `lag[, max_samples]` | `(key, value) -> Float64` |
| `timeSeriesLjungBoxTest` | `max_lag[, model_df[, max_samples]]` | `(key, value) -> Tuple(statistic Float64, p_value Float64)` |
| `timeSeriesDurbinWatson` | `[max_samples]` | `(key, value) -> Float64` |
| `timeSeriesLaggedLinearRegression` | `order[, max_samples]` | `(key, value) -> regression result` |
| `timeSeriesADFStatistic` | `augmentation_lags[, deterministic[, max_samples]]` | `(key, value) -> Tuple(statistic, coefficient, observations)` |
| `timeSeriesKPSSTest` | `regression[, bandwidth[, max_samples]]` | `(key, value) -> Tuple(statistic, bandwidth, observations)` |
| `timeSeriesMeanShiftChangePoint` | `min_segment[, max_samples]` | `(key, value) -> Tuple(split_index, score, mean_before, mean_after, sse)` |

The shared keyed state retains every finite sample in exact `O(n)` space,
canonicalizes by key before
finalization/merge/serialization, rejects duplicate keys, enforces positive
`max_samples <= 10,000,000` and the lag/model-degree constraints in `DESIGN.md`,
and serializes a version, cap, count, and records. `add` appends and marks
out-of-order state; `merge` performs a linear two-way merge of canonical
states and rejects equal keys; `insertResultInto` finalizes the formulas in
`DESIGN.md`. The four extensions use this same keyed state. No range-key or
compact-state function is registered.

ADF exposes the fixed-lag coefficient and statsmodels-compatible statistic,
but no p-value. It uses positional observations (callers requiring
equally-spaced inference must resample) and the documented QR/rcond,
resolution, rank, and work policy. KPSS uses its own finite-sample floor
convention and bounded `q`/work policy and produces no p-value. Mean shift is
an `O(n)` scan with transient suffix moments; its score is descriptive,
positive original-scale SSE overflow is represented by `+Inf`, and very small
SSE may underflow to zero. The native tie comparison uses
`gamma_n = n * epsilon / (1 - n * epsilon)` and accepts a later candidate only
when its SSE improves by more than
`8 * gamma_n * max(abs(candidate), abs(incumbent))`; otherwise it retains the
earliest split.

## Source and test locations

| Concern | Conventional location | Required work/evidence |
|---|---|---|
| Factory/registration | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.{h,cpp}` and `src/AggregateFunctions/registerAggregateFunctions.cpp` | exactly seven names (three diagnostics plus four extensions), constant parameter/type checks, preview setting |
| State transition/merge | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesDiagnostics.{h,cpp}` and `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.{h,cpp}` | add, merge, serialize, deserialize, finalize; duplicate/cap errors |
| Key/value types | factory helper and state | supported scalar key types, native integer/floating-point-to-`Float64`, finite-value rejection; Decimal is unsupported |
| Documentation | source `FunctionDocumentation` and generated reference | signatures, formulas, ordering, errors, `NaN`, `max_samples` |
| Functional regression | `tests/queries/0_stateless/05161_time_series_diagnostics.{sql,reference}` through `05164_time_series_statistical_extensions_aggregating_merge_tree.{sql,reference}` | permutations, interleaving merges, duplicates, caps, edge cases |
| Distributed regression | shard-tagged stateless/integration fixture | merge-tree/order invariance and failure propagation |
| Reference/benchmarks | independent reference and benchmark scripts | exact comparisons, `O(n)` memory, merge/finalize timings |

## Integration sequence and status

1. Land the shared state and parameter validation. **Complete: the production
   translation unit passes Clang 21 `-Werror`, and both aggregate and unified
   ClickHouse targets link.**
2. Add serialization/version and duplicate/cap rejection tests. **Complete for
   the baseline diagnostics: the isolated reference and focused native
   GoogleTest suites recorded 15/15, including malformed and bounded-reserve
   payload cases. The extension GoogleTest source currently defines 22 cases;
   its execution remains part of native acceptance.**
3. Register the four extension functions and result tuples. **Source
   registration is present; extension validation/acceptance remains pending.**
4. Add SQL and distributed permutation/merge tests against the independent
   reference. **The exact stateless fixtures are present at
   `tests/queries/0_stateless/05162_time_series_statistical_extensions.sql`,
   `05163_time_series_statistical_extensions_distributed.sql`, and
   `05164_time_series_statistical_extensions_aggregating_merge_tree.sql`;
   SQL/Distributed execution remains pending.**
5. Publish generated docs and benchmark evidence only after M6 in `PLAN.md`.
   **Python/statistical evidence and benchmark inputs are packaged; native
   Release, SQL, and CI acceptance remain pending.**

The compact range/interval design is a rejected negative result and must not be
introduced as an optimization without re-opening the arbitrary-order contract.
Validation, release-build acceptance, and CI status for the four extensions are
**pending evidence**.
