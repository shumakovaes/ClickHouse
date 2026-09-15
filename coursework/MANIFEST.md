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
| `evidence/experiments/run_extension_experiments.py` and `extension_results_20260915_final_v3_trusted/` | Seeded extension experiments and provenance-complete LF-normalized CSV/Markdown/JSON/hash outputs |
| `evidence/benchmarks/` | Reproducible benchmark script and generated CSV/Markdown/JSON outputs |
| `evidence/benchmarks/benchmark_extensions.py` and `extensions-20260915/{results.csv,results.json,summary.md}` | Bounded Python-oracle benchmark and recorded outputs for the four extensions; not ClickHouse throughput evidence |
| `evidence/native-benchmark/` | Native ClickHouse harness, raw TSV measurements, metadata, and measured summary |
| `evidence/native-validation/` | Compact native build/runtime environment, checksums, SQL test output, gtest output, and smoke row |
| `evidence/standalone-validation/README.md` | Exact optimized and ASan/UBSan validation record for the quarantined standalone comparison |
| `evidence/trusted-reference/README.md` | Isolated NumPy/SciPy/statsmodels reference-suite validation record |
| `research/` | Design/research/citation documents |
| `manuscript/report.md`, `report.tex`, `report.pdf` | Coursework report sources and generated submission PDF covering the seven APIs and pending extension acceptance ledger |
| `manuscript/.gitignore` | Excludes LaTeX intermediate files while retaining the PDF |
| `comparison/standalone_cpp/` | Clearly quarantined non-native comparison prototype (source only) |
| `build/setup_wsl.sh`, `build/run_native_validation.sh`, `build/run_extension_benchmark.sh`, `build/README.md` | Native build helper, isolated server/test runner, extension benchmark harness, and usage notes; extension harness requires an explicitly supplied Release binary |

Excluded: `__pycache__`, `standalone_tests`, `standalone_tests_san`, and other generated binaries or caches.
