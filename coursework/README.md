# ClickHouse time-series diagnostics coursework package

This package contains the coursework evidence and the current native C++ implementation of three baseline mergeable aggregate functions plus four statistical extension APIs.

The baseline diagnostics are:

* `timeSeriesAutocorrelation(lag[, max_samples])`
* `timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])`
* `timeSeriesDurbinWatson([max_samples])`

The four extensions are:

| API | Signature and result |
|---|---|
| `timeSeriesLaggedLinearRegression` | `timeSeriesLaggedLinearRegression(order[, max_samples])(timestamp, value)` -> `Tuple(intercept Float64, coefficients Array(Float64))`; fixed-order positional lagged regression. |
| `timeSeriesADFStatistic` | `timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])(timestamp, value)` -> `Tuple(statistic Float64, coefficient Float64, observations UInt64)`; fixed-lag ADF statistic for `none`, `constant`, or `trend`, with no p-value. |
| `timeSeriesKPSSTest` | `timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])(timestamp, value)` -> `Tuple(statistic Float64, bandwidth UInt64, observations UInt64)`; level/trend KPSS statistic with the implementation's Bartlett bandwidth convention, with no p-value. |
| `timeSeriesMeanShiftChangePoint` | `timeSeriesMeanShiftChangePoint(min_segment[, max_samples])(timestamp, value)` -> `Tuple(split_index UInt64, score Float64, mean_before Float64, mean_after Float64, sse Float64)`; descriptive one-mean-shift estimator with earliest tied split. |

All seven APIs store `(timestamp, Float64 value)` samples and canonicalize by timestamp before finalization, merge, and serialization; duplicate timestamps and cap overflow are rejected. The baseline native source is copied into `native/`. The extension source remains in the active ClickHouse checkout at the paths listed below and is registered there by the corresponding checkout change; this package is an evidence bundle, not a second source tree.

## Package map

| Area | Contents |
|---|---|
| [native](native/) | Current production aggregate implementation (`.h`/`.cpp`). |
| [native_tests](native_tests/) | Lower-level GoogleTest coverage for state, merge, serialization, and validation behavior. |
| [tests/functional](tests/functional/) | Numbered ClickHouse SQL functional test and reference output. |
| [reference/python](reference/python/) | Python oracle and its tests. |
| [evidence/experiments](evidence/experiments/) | Seeded statistical experiments and generated CSV/Markdown/PNG/JSON results. |
| [evidence/benchmarks](evidence/benchmarks/) | Python state-design benchmark and captured outputs. |
| [evidence/native-benchmark](evidence/native-benchmark/) | Executed native ClickHouse benchmark, raw TSV data, metadata, and summary. |
| [evidence/native-validation](evidence/native-validation/) | Native build, SQL/Distributed, smoke, and focused GoogleTest evidence. |
| `evidence/release-build-20260916-1ad279671/` | Release build provenance: retained full build `6838/6838`, later default-target incremental verification `545/545`, binary identities, logs, and SHA-256 manifest. |
| `evidence/native-acceptance-20260916-58b61c3a/` | Final Release-linked 38-test and four-fixture acceptance ledger with commands, configs, logs, hashes, and binary identity. |
| `evidence/native-benchmark-20260916-58b61c3a/` | Final 92-row native Release timing grid, including KPSS work-cap and change-point scaling boundaries. |
| `evidence/state-merge-benchmark-20260916-1ad279671/` | Direct, serialized-state, and merge/finalization measurements: 123, 192, and 96 rows respectively. |
| `evidence/debug-gtest-20260916-1ad279671/` | Exact Debug focused run: 38/38 tests passed. |
| `evidence/docs-examples-20260916-1ad279671/` | Generated-documentation example runner: all seven selected examples passed. |
| `evidence/pdf-build-20260916-30ed69c7b-v7/` | Archived 11-page technical-report build: LaTeX/BibTeX logs, warning scan, toolchain record, and SHA-256. |
| [evidence/standalone-validation](evidence/standalone-validation/) | Exact optimized and ASan/UBSan run record for the quarantined standalone comparison. |
| [evidence/trusted-reference](evidence/trusted-reference/) | Isolated NumPy/SciPy/statsmodels reference-suite validation record. |
| [research](research/) | Design, ordering, mergeability, implementation, inventory, and citation notes. |
| [research/COMPACT_STATE_CLOSURE_PROPOSITION.md](research/COMPACT_STATE_CLOSURE_PROPOSITION.md) | Formal compact-state closure result, counterexample, and adjacent-range contract. |
| [manuscript](manuscript/) | Current HSE coursework report in Markdown, editable DOCX, final PDF, and SHA-256 manifest; the older TeX source is retained only as legacy provenance. |
| [comparison/standalone_cpp](comparison/standalone_cpp/) | Dependency-free comparison prototype, explicitly outside the native API. |
| [build](build/) | WSL setup helper, isolated native-validation runner, and build notes. |

## Extension source, tests, and evidence

The extension implementation is intentionally referenced at its checkout paths
rather than copied into this bundle:

* `../src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.h` — shared extension state, parameter envelope, and four-kind declarations.
* `../src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.cpp` — factory parsing, result tuples, finalizers, validation, and extension registration.
* `../src/AggregateFunctions/registerAggregateFunctions.cpp` — checkout registry call for the extension registration function.
* `../src/AggregateFunctions/tests/gtest_time_series_statistical_extensions.cpp` — focused state, serialization, merge, numerical-boundary, and aggregate tests covering all four APIs.
* `../tests/queries/0_stateless/05162_time_series_statistical_extensions.sql` and `.reference` — direct SQL, type, parameter, edge, and state/merge coverage.
* `../tests/queries/0_stateless/05163_time_series_statistical_extensions_distributed.sql` and `.reference` — two-shard `Distributed` merge and duplicate propagation coverage.
* `../tests/queries/0_stateless/05164_time_series_statistical_extensions_aggregating_merge_tree.sql` and `.reference` — `AggregatingMergeTree` persistence and merge coverage.

Independent evidence and reproduction artifacts are:

* `reference/python/extensions.py` and `reference/python/test_extensions.py` — independent batch oracles and tests for the four statistical contracts.
* `evidence/experiments/run_extension_experiments.py` — seeded AR, ADF, KPSS, and mean-shift experiment runner; the final provenance-complete LF-normalized output is under `evidence/experiments/extension_results_20260915_final_v4_trusted/`.
* `evidence/benchmarks/benchmark_extensions.py` — bounded Python-oracle benchmark; `evidence/benchmarks/extensions-20260916-final/{results.csv,results.json,summary.md}` contains 90 fresh timed samples.
* `evidence/experiments/run_baseline_sensitivity_experiments.py` — fixed-seed ACF/Ljung--Box sensitivity runner; `evidence/experiments/baseline_sensitivity_20260916_final/` contains 12,000 ACF and 1,800 Ljung--Box raw rows plus summaries and hashes.
* `build/run_extension_native_acceptance.sh`, `build/run_extension_benchmark.sh`, and `build/run_extension_state_merge_benchmark.sh` — the executed Release acceptance and benchmark harnesses; each evidence directory retains the exact runner copy and checksum.
* `manuscript/report.md`, `manuscript/report.docx`, `manuscript/report.pdf`, and `manuscript/SHA256SUMS` — source, editable document, visually inspected 34-page HSE submission, and integrity hashes covering all seven APIs and the completed local acceptance ledger.
* `manuscript/report.tex` — legacy source of the archived 11-page technical report; it is not the source of the current HSE submission.

## Reproduction and validation status

Run Python commands from this package directory. The experiment suite and generated evidence are available in [evidence/experiments](evidence/experiments/); benchmark outputs are in [evidence/benchmarks](evidence/benchmarks/). The optional-dependency reference validation is recorded in [evidence/trusted-reference](evidence/trusted-reference/). The numbered SQL test is in [tests/functional](tests/functional/), and [build/setup_wsl.sh](build/setup_wsl.sh) prepares a WSL toolchain.

Archived baseline validation status (2026-09-10): for the original three
diagnostics, the production and factory-registration translation units compile
with Clang 21 and `-Werror`; the lean aggregate target completed
**5,672/5,672** actions and the unified ClickHouse target completed
**1,167/1,167**. The built 26.9.1.1 binary executed all three baseline SQL
functions. The focused GoogleTest run passes **15/15**, and the numbered
stateless test passes **1/1**, including a real two-shard `Distributed` merge,
canonical state bytes, and `AggregatingMergeTree` persistence. The isolated
NumPy/SciPy/statsmodels reference suite passes **15/15**; the baseline
experiment suite reports **6 passed**. The standalone comparison reports
**1,764 checks** in both normal and ASan/UBSan runs. The native Debug benchmark
completed 81 main measurements plus state-size, fan-in, and grouped-series
cases; its process-startup-dominated results are reported without a
production-throughput claim. These archived counts predate the four extension
APIs and are not extension acceptance evidence.

Extension local acceptance completed on 2026-09-16. The exact Release binary
for revision `58b61c3a0f3ab17dddc0507657aca3934b179538` passed **38/38**
focused GoogleTests and **4/4** SQL fixtures (`05161`--`05164`) with no skips;
the latter includes real two-shard `Distributed` execution, cross-shard
duplicate rejection, and `AggregatingMergeTree` persistence. A current Debug
binary at revision `1ad279671de9cdda088fb64046d6ae1d4e7f854f` independently
passed the same **38/38** tests. The Release benchmark recorded **92** timing
rows; the supplemental run recorded **123** direct, **192** state-size, and
**96** merge rows. All seven generated pages passed generator drift checks and
their embedded examples passed **7/7**. These acceptance claims are tied to the
retained local evidence, exact commands, revisions, and binary identities.

The native source is intended for integration under `src/AggregateFunctions/TimeSeries`; the checkout used to prepare this package already contains that implementation and its factory-registration change. The standalone comparison code is not a substitute for native validation and is quarantined under `comparison/` for that reason.

## Exclusions

Compiled binaries and `__pycache__` directories are intentionally excluded. The
authoritative production changes live in the checkout's `src` and `tests`
trees; the copies under this package exist only to keep the submission bundle
self-contained.

## Provenance

Source artifacts were assembled from the reviewed workspace materials and the active ClickHouse `src/AggregateFunctions/TimeSeries` implementation. See [research/citations-map.md](research/citations-map.md) and [manuscript/report.md](manuscript/report.md) for the academic provenance and narrative.

The raw `environment.json` files retain the original `work/...` command paths
as historical run provenance. For a relocated copy of this package, the
package-relative commands in the adjacent README files are the authoritative
reproduction commands.
