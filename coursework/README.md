# ClickHouse time-series diagnostics coursework package

This package contains the coursework evidence and the current native C++ implementation of three mergeable aggregate functions:

* `timeSeriesAutocorrelation(lag[, max_samples])`
* `timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])`
* `timeSeriesDurbinWatson([max_samples])`

The implementation stores `(timestamp, Float64 value)` samples, canonicalizes by timestamp before finalization/merge/serialization, rejects duplicate timestamps, and enforces the serialized sample cap. The native source is copied from the active ClickHouse checkout and is registered there by the corresponding checkout change; this package is an evidence bundle, not a second source tree.

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
| [evidence/standalone-validation](evidence/standalone-validation/) | Exact optimized and ASan/UBSan run record for the quarantined standalone comparison. |
| [evidence/trusted-reference](evidence/trusted-reference/) | Isolated NumPy/SciPy/statsmodels reference-suite validation record. |
| [research](research/) | Design, ordering, mergeability, implementation, inventory, and citation notes. |
| [manuscript](manuscript/) | Coursework report source and generated PDF. |
| [comparison/standalone_cpp](comparison/standalone_cpp/) | Dependency-free comparison prototype, explicitly outside the native API. |
| [build](build/) | WSL setup helper, isolated native-validation runner, and build notes. |

## Reproduction and validation status

Run Python commands from this package directory. The experiment suite and generated evidence are available in [evidence/experiments](evidence/experiments/); benchmark outputs are in [evidence/benchmarks](evidence/benchmarks/). The optional-dependency reference validation is recorded in [evidence/trusted-reference](evidence/trusted-reference/). The numbered SQL test is in [tests/functional](tests/functional/), and [build/setup_wsl.sh](build/setup_wsl.sh) prepares a WSL toolchain.

Current validation status (2026-09-10): the production and factory-registration
translation units compile with Clang 21 and `-Werror`; the lean aggregate
target completed **5,672/5,672** actions and the unified ClickHouse target
completed **1,167/1,167**. The built 26.9.1.1 binary executed all three SQL
functions. The focused GoogleTest run passes **15/15**, and the numbered
stateless test passes **1/1**, including a real two-shard `Distributed` merge,
canonical state bytes, and `AggregatingMergeTree` persistence. The isolated
NumPy/SciPy/statsmodels reference suite passes **15/15**; the experiment suite
reports **6 passed**. The standalone comparison reports **1,764 checks** in
both normal and ASan/UBSan runs. The native Debug benchmark completed 81 main
measurements plus state-size, fan-in, and grouped-series cases; its process-
startup-dominated results are reported without a production-throughput claim.

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
