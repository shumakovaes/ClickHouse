# Coursework manifest

Generated evidence is included as data and plots; no compiled artifacts are included. The four statistical extension sources and native test fixtures remain checkout paths referenced from this bundle, not duplicated source files.

| Path | Role |
|---|---|
| `README.md` | Package overview, reproduction entry points, and current validation status |
| `MANIFEST.md` | Package inventory and exclusions |
| `native/AggregateFunctionTimeSeriesDiagnostics.h` | Production state and API declarations |
| `native/AggregateFunctionTimeSeriesDiagnostics.cpp` | Production ClickHouse wrappers, validation, result types, and registration function |
| `../src/AggregateFunctions/registerAggregateFunctions.cpp` (checkout) | Existing production factory declaration/call; referenced but intentionally not duplicated in this bundle |
| `../src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.h` (checkout) | Shared keyed extension state, serialized parameter envelope, and `Kind` declarations for `timeSeriesLaggedLinearRegression`, `timeSeriesADFStatistic`, `timeSeriesKPSSTest`, and `timeSeriesMeanShiftChangePoint` |
| `../src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.cpp` (checkout) | Native factory parsing, result tuples, numerical finalizers, validation, and registration for the four extension APIs |
| `../src/AggregateFunctions/tests/gtest_time_series_statistical_extensions.cpp` (checkout) | Focused native state/serialization/merge and four-API aggregate tests |
| `../tests/queries/0_stateless/05162_time_series_statistical_extensions.sql` and `.reference` (checkout) | Direct SQL/type/edge/state coverage for all four extension APIs |
| `../tests/queries/0_stateless/05163_time_series_statistical_extensions_distributed.sql` and `.reference` (checkout) | Two-shard `Distributed` merge and duplicate-key propagation fixture |
| `../tests/queries/0_stateless/05164_time_series_statistical_extensions_aggregating_merge_tree.sql` and `.reference` (checkout) | `AggregatingMergeTree` persistence and merge fixture |
| `native_tests/gtest_time_series_diagnostics.cpp` | Native state-level test source |
| `tests/functional/05161_time_series_diagnostics.sql` and `.reference` | Numbered ClickHouse functional test and expected output |
| `tests/functional/README.md` | Functional-test scope and fixture limitations |
| `reference/python/README.md`, `reference.py`, `test_reference.py` | Independent baseline reference implementation and tests |
| `reference/python/extensions.py`, `test_extensions.py` | Independent batch oracle and tests for all four statistical extensions; not native evidence |
| `evidence/experiments/` | Reproducible experiment scripts, tests, and generated CSV/Markdown/PNG/JSON outputs |
| `evidence/experiments/run_extension_experiments.py` and `extension_results_20260915_final_v4_trusted/` | Seeded extension experiments and provenance-complete LF-normalized CSV/Markdown/JSON/hash outputs |
| `evidence/benchmarks/` | Reproducible benchmark script and generated CSV/Markdown/JSON outputs |
| `evidence/benchmarks/benchmark_extensions.py` and `extensions-20260916-final/{results.csv,results.json,summary.md,SHA256SUMS}` | Bounded 90-sample Python-oracle benchmark for the four extensions; not ClickHouse throughput evidence |
| `evidence/experiments/baseline_sensitivity_20260916_final/` | Fixed-seed positive-lag ACF and Ljung--Box sensitivity evidence, metadata, and SHA-256 manifest |
| `evidence/native-acceptance-20260916-58b61c3a/` | Release binary identity, 38/38 focused gtest log, 4/4 SQL logs, server configs, commands, ledger, and checked hashes |
| `evidence/native-benchmark-20260916-58b61c3a/` | 92 native Release benchmark rows, KPSS work-cap boundary, change-point scaling, metadata, queries, and hashes |
| `evidence/state-merge-benchmark-20260916-1ad279671/` | 123 direct, 192 serialized-state, and 96 state-merge/finalization measurements with exact runner and hashes |
| `evidence/debug-gtest-20260916-1ad279671/` | Current Debug 38/38 focused gtest log, metadata, and hashes |
| `evidence/docs-examples-20260916-1ad279671/` | Seven generated documentation examples, all passing, plus focused reports and server logs |
| `evidence/pdf-build-20260916-1ad279671-v2/` | Final 11-page technical PDF build logs, warning scan, TeX toolchain identity, and SHA-256 records |
| `evidence/native-benchmark/` | Native ClickHouse harness, raw TSV measurements, metadata, and measured summary |
| `evidence/native-validation/` | Compact native build/runtime environment, checksums, SQL test output, gtest output, and smoke row |
| `evidence/standalone-validation/README.md` | Exact optimized and ASan/UBSan validation record for the quarantined standalone comparison |
| `evidence/trusted-reference/README.md` | Isolated NumPy/SciPy/statsmodels reference-suite validation record |
| `research/` | Design/research/citation documents |
| `manuscript/report.md`, `report.tex`, `report.pdf` | Coursework report sources and visually inspected 11-page submission PDF covering all seven APIs and the completed local acceptance ledger |
| `manuscript/.gitignore` | Excludes LaTeX intermediate files while retaining the PDF |
| `comparison/standalone_cpp/` | Clearly quarantined non-native comparison prototype (source only) |
| `build/setup_wsl.sh`, `build/run_native_validation.sh`, `build/run_extension_native_acceptance.sh`, `build/run_extension_benchmark.sh`, `build/run_extension_state_merge_benchmark.sh`, `build/README.md` | Native build helpers, isolated acceptance runner, and two Release benchmark harnesses; all require explicit source/build provenance |

Excluded: `__pycache__`, `standalone_tests`, `standalone_tests_san`, and other generated binaries or caches.
