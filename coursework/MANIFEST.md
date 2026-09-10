# Coursework manifest

Generated evidence is included as data and plots; no compiled artifacts are included.

| Path | Role |
|---|---|
| `README.md` | Package overview, reproduction entry points, and current validation status |
| `MANIFEST.md` | Package inventory and exclusions |
| `native/AggregateFunctionTimeSeriesDiagnostics.h` | Production state and API declarations |
| `native/AggregateFunctionTimeSeriesDiagnostics.cpp` | Production ClickHouse wrappers, validation, result types, and registration function |
| `../src/AggregateFunctions/registerAggregateFunctions.cpp` (checkout) | Existing production factory declaration/call; referenced but intentionally not duplicated in this bundle |
| `native_tests/gtest_time_series_diagnostics.cpp` | Native state-level test source |
| `tests/functional/05161_time_series_diagnostics.sql` and `.reference` | Numbered ClickHouse functional test and expected output |
| `tests/functional/README.md` | Functional-test scope and fixture limitations |
| `reference/python/README.md`, `reference.py`, `test_reference.py` | Independent reference implementation and tests |
| `evidence/experiments/` | Reproducible experiment scripts, tests, and generated CSV/Markdown/PNG/JSON outputs |
| `evidence/benchmarks/` | Reproducible benchmark script and generated CSV/Markdown/JSON outputs |
| `evidence/native-benchmark/` | Native ClickHouse harness, raw TSV measurements, metadata, and measured summary |
| `evidence/native-validation/` | Compact native build/runtime environment, checksums, SQL test output, gtest output, and smoke row |
| `evidence/standalone-validation/README.md` | Exact optimized and ASan/UBSan validation record for the quarantined standalone comparison |
| `evidence/trusted-reference/README.md` | Isolated NumPy/SciPy/statsmodels reference-suite validation record |
| `research/` | Design/research/citation documents |
| `manuscript/report.md`, `report.tex`, `report.pdf` | Coursework report sources and generated submission PDF |
| `manuscript/.gitignore` | Excludes LaTeX intermediate files while retaining the PDF |
| `comparison/standalone_cpp/` | Clearly quarantined non-native comparison prototype (source only) |
| `build/setup_wsl.sh`, `build/run_native_validation.sh`, `build/README.md` | Native build helper, isolated server/test runner, and usage notes |

Excluded: `__pycache__`, `standalone_tests`, `standalone_tests_san`, and other generated binaries or caches.
