# Reproducing the seven time-series aggregate APIs

This is the run protocol for the current ClickHouse checkout. It covers all
seven private-preview aggregate APIs without treating an older three-function
run as extension evidence. Use a new operator-selected run directory; this
document does not assert any result, pass count, checksum, or final evidence
path.

## APIs, fixtures, and settings

| API | Parameters | Row arguments |
|---|---|---|
| `timeSeriesAutocorrelation` | `lag[, max_samples]` | `(timestamp, value)` |
| `timeSeriesLjungBoxTest` | `max_lag[, model_df[, max_samples]]` | `(timestamp, value)` |
| `timeSeriesDurbinWatson` | `[max_samples]` | `(timestamp, value)` |
| `timeSeriesLaggedLinearRegression` | `order[, max_samples]` | `(timestamp, value)` |
| `timeSeriesADFStatistic` | `augmentation_lags[, deterministic[, max_samples]]` | `(timestamp, value)` |
| `timeSeriesKPSSTest` | `regression[, bandwidth[, max_samples]]` | `(timestamp, value)` |
| `timeSeriesMeanShiftChangePoint` | `min_segment[, max_samples]` | `(timestamp, value)` |

The actual private-preview setting is
`enable_time_series_aggregate_functions = 1`. The fixtures use
`max_threads = 1` and `max_block_size = 2`; fixtures 05161 and 05163
additionally use `prefer_localhost_replica = 0`. Do not substitute
`allow_experimental_time_series_aggregate_functions`.

Run the four actual checkout fixtures, not only their review copies:

* `tests/queries/0_stateless/05161_time_series_diagnostics.sql`
* `tests/queries/0_stateless/05162_time_series_statistical_extensions.sql`
* `tests/queries/0_stateless/05163_time_series_statistical_extensions_distributed.sql`
* `tests/queries/0_stateless/05164_time_series_statistical_extensions_aggregating_merge_tree.sql`

05161 covers the three diagnostics; 05162 covers the four extensions directly;
05163 covers two-shard `Distributed` merges; 05164 covers persisted
`AggregatingMergeTree` states.

## Windows source and WSL mirror

Use a revision containing the implementation, registration, both gtest sources,
and SQL fixtures 05161--05164. Keep source and build directories on WSL ext4
(for example `/work/clickhouse`), not `/mnt/c`. A Windows checkout may be
the source of truth, but copy it once rather than overlaying trees.

From PowerShell, replace the placeholders and use the checked-in helper:

```powershell
wsl.exe -l -v
wsl.exe -d Ubuntu -- bash -lc "CH_COPY_FROM=/mnt/c/<path-to-windows-ClickHouse> CH_SOURCE_DIR=/work/clickhouse bash /mnt/c/<path-to-windows-ClickHouse>/coursework/build/setup_wsl.sh copy"
wsl.exe -d Ubuntu -- bash -lc "CH_SOURCE_DIR=/work/clickhouse bash /work/clickhouse/coursework/build/setup_wsl.sh submodules"
```

If the checkout is already in WSL, skip `copy`. Before building, record:

```bash
cd /work/clickhouse
git rev-parse HEAD
git status --short --branch
git submodule status --recursive
test -f src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesStatisticalExtensions.cpp
test -f tests/queries/0_stateless/05164_time_series_statistical_extensions_aggregating_merge_tree.sql
```

The helper's `install` action is opt-in. It expects CMake 3.25+, Clang/LLVM
21+, Ninja, and initialized pinned submodules. Run `capture` after configure.

## Debug/lean build

This low-memory recipe disables optional libraries, tests, examples, benchmarks,
ThinLTO, Rust, XRay, and split debug symbols. Run from the checkout root with
`CH_JOBS=1`:

```bash
cd /work/clickhouse
export CH_SOURCE_DIR=/work/clickhouse
export CH_BUILD_DIR=/work/clickhouse/build-coursework-debug
export CH_BUILD_TYPE=Debug
export CH_ENABLE_LIBRARIES=OFF
export CH_ENABLE_TESTS=OFF
export CH_JOBS=1
CH_BUILD_TARGET=clickhouse_aggregate_functions bash coursework/build/setup_wsl.sh configure
CH_BUILD_TARGET=clickhouse_aggregate_functions bash coursework/build/setup_wsl.sh build
CH_BUILD_TARGET=clickhouse bash coursework/build/setup_wsl.sh build
CH_BUILD_TARGET=clickhouse bash coursework/build/setup_wsl.sh capture
```

The helper defaults to `clang-21`, `clang++-21`, `ld.lld-21`, and
`llvm-ar-21`. If another approved toolchain is used, set `CH_CC`,
`CH_CXX`, `CH_LD`, and `CH_AR` together.

## Release build

Use a separate build directory. This recipe does not claim Release success:

```bash
cd /work/clickhouse
export CH_SOURCE_DIR=/work/clickhouse
export CH_BUILD_DIR=/work/clickhouse/build-coursework-release
export CH_BUILD_TYPE=Release
export CH_ENABLE_LIBRARIES=OFF
export CH_ENABLE_TESTS=OFF
export CH_JOBS=1
CH_BUILD_TARGET=clickhouse bash coursework/build/setup_wsl.sh configure
CH_BUILD_TARGET=clickhouse bash coursework/build/setup_wsl.sh build
CH_BUILD_TARGET=clickhouse bash coursework/build/setup_wsl.sh capture
```

Record the Release binary's absolute path and SHA-256 for the native extension
benchmark.

## Focused GoogleTest

Configure a separate test-enabled Debug directory and build
`unit_tests_dbms`. The filter covers the diagnostics and all extension state
and finalizer tests:

```bash
cd /work/clickhouse
export CH_SOURCE_DIR=/work/clickhouse
export CH_BUILD_DIR=/work/clickhouse/build-coursework-gtest
export CH_BUILD_TYPE=Debug
export CH_ENABLE_LIBRARIES=OFF
export CH_ENABLE_TESTS=ON
export CH_JOBS=1
bash coursework/build/setup_wsl.sh configure
CH_BUILD_TARGET=unit_tests_dbms bash coursework/build/setup_wsl.sh build
build-coursework-gtest/src/unit_tests_dbms --gtest_color=no --gtest_filter='TimeSeriesDiagnosticsState.*:TimeSeriesStatisticalExtensionsState.*:TimeSeriesStatisticalExtensionsAggregate.*'
```

Save complete stdout/stderr and the exact filter. Enter no pass count until the
command completes and its log is reviewed.

## SQL 05161--05164

From the checkout root, run each exact test name with one worker and without long
tests or settings randomization. The loop deliberately creates a separate raw
log per fixture; replace `<fresh-run-dir>` with a new directory:

```bash
cd /work/clickhouse
CH_BINARY=/work/clickhouse/build-coursework-debug/programs/clickhouse
for test_name in 05161_time_series_diagnostics 05162_time_series_statistical_extensions 05163_time_series_statistical_extensions_distributed 05164_time_series_statistical_extensions_aggregating_merge_tree; do tests/clickhouse-test -q tests/queries -b "$CH_BINARY" --no-long --no-random-settings -j 1 "$test_name" 2>&1 | tee "<fresh-run-dir>/$test_name.log"; done
```

The repository helper can run an isolated smoke plus only 05161, but it does not
replace the four-fixture run:

```bash
CH_SOURCE_DIR=/work/clickhouse CH_BUILD_DIR=/work/clickhouse/build-coursework-debug CH_TEST_PATTERN=05161_time_series_diagnostics CH_VALIDATION_OUTPUT=<fresh-run-dir>/native-validation bash coursework/build/run_native_validation.sh
```

## Python oracle and experiments

From the coursework directory, run the dependency-free oracle tests, the core
experiment and audit, and the independent extension experiment. Use fresh
output directories:

```powershell
cd <path-to-ClickHouse>/coursework
py -3 -m unittest discover -s reference/python -p "test_*.py"
py -3 -m unittest discover -s evidence/experiments -p "test_*.py"
py -3 evidence/experiments/run_experiments.py --n 300 --reps 200 --seed 20260910 --output-dir <fresh-run-dir>/experiments/core
py -3 evidence/experiments/audit_results.py --input-dir <fresh-run-dir>/experiments/core --output <fresh-run-dir>/experiments/core/analysis.md
py -3 evidence/experiments/run_extension_experiments.py --n 240 --reps 120 --seed 20260915 --adf-lags 1 --change-min-segment 20 --output-dir <fresh-run-dir>/experiments/extensions
```

The extension experiment uses the independent standard-library oracle. An
optional `statsmodels` cross-check must be labelled as optional and does not
create an ADF/KPSS p-value claim.

The standalone Python benchmarks are oracle/algorithm measurements, not native
ClickHouse throughput:

```powershell
py -3 evidence/benchmarks/benchmark_extensions.py --output-dir <fresh-run-dir>/benchmarks/python-extensions --seed 20260915 --n 256,1024,4096 --ar-orders 1,4,8 --adf-orders 0,2,4 --kpss-bandwidths 0,8,32 --change-point-n 256,1024,4096 --min-segment 8 --warmup 1 --repetitions 3
py -3 evidence/benchmarks/benchmark_lag_state.py --output-dir <fresh-run-dir>/benchmarks/core-state --rows 1000,5000,10000 --lags 1,8,64 --chunks 1,4,16 --repeats 2 --seed 20260910
```

## Native extension benchmark

`coursework/build/run_extension_benchmark.sh` starts an isolated server and
measures `timeSeriesLaggedLinearRegression`, `timeSeriesADFStatistic`,
`timeSeriesKPSSTest`, and `timeSeriesMeanShiftChangePoint`. Use the Release
binary and a new empty output directory:

```bash
cd /work/clickhouse
CH_BINARY=/work/clickhouse/build-coursework-release/programs/clickhouse CH_SOURCE_DIR=/work/clickhouse OUTPUT_DIR=<fresh-run-dir>/native-extension-benchmark bash coursework/build/run_extension_benchmark.sh
```

The checked-in runner uses the actual
`enable_time_series_aggregate_functions` setting, validates all numeric grids,
and records both the expected and observed result class at the KPSS work-cap
boundary. Run that exact checked-in file so its SHA-256 can be tied to the
evidence package.

Defaults in that runner are `N_VALUES=1000,10000`, `ORDER_VALUES=1,4,8`,
`ADF_ORDER_VALUES=0,2,4`, `KPSS_Q_VALUES=1,4`,
`MIN_SEGMENT_VALUES=1,60`, one warm-up, and three repetitions. It also
includes KPSS `n=97656/97657` and mean-shift `n=10000/100000` boundaries.
Record any overrides to `N_VALUES`, `ORDER_VALUES`, `ADF_ORDER_VALUES`,
`KPSS_Q_VALUES`, `MIN_SEGMENT_VALUES`, `WARMUP`, or `REPETITIONS`.

## PDF regeneration

`coursework/manuscript/report.tex` is checked in beside the generated PDF, but
no repository script or canonical Markdown-to-LaTeX generator was found. If
`pdflatex` and BibTeX are available and the `.tex` source is the intended
input, write to a fresh directory and run LaTeX, BibTeX, then two final LaTeX
passes:

```bash
cd /work/clickhouse/coursework/manuscript
PDF_OUT=<fresh-run-dir>/pdf
mkdir -p "$PDF_OUT"
pdflatex -interaction=nonstopmode -halt-on-error -output-directory "$PDF_OUT" report.tex
(cd "$PDF_OUT" && BIBINPUTS=/work/clickhouse/coursework/research: bibtex report)
pdflatex -interaction=nonstopmode -halt-on-error -output-directory "$PDF_OUT" report.tex
pdflatex -interaction=nonstopmode -halt-on-error -output-directory "$PDF_OUT" report.tex
```

The output is `<fresh-run-dir>/pdf/report.pdf`. Record the LaTeX version,
command output, and SHA-256; do not claim PDF regeneration if not run.

## Run ledger (fill only after execution)

Keep raw logs, commands, environment metadata, binary hashes, and generated
tables in a new run directory. Replace each `[TO FILL]` only with values from
the corresponding completed command.

| Check | Command/input | Result, log, or output path |
|---|---|---|
| Checkout revision/status | `git rev-parse HEAD`; `git status --short --branch` | `[TO FILL]` |
| Debug/lean build | Debug `setup_wsl.sh` configure/build | `[TO FILL]` |
| Release build | Release `setup_wsl.sh` configure/build | `[TO FILL]` |
| Focused gtest | `unit_tests_dbms` filter above | `[TO FILL]` |
| SQL 05161 | exact test name above | `[TO FILL]` |
| SQL 05162 | exact test name above | `[TO FILL]` |
| SQL 05163 | exact test name above | `[TO FILL]` |
| SQL 05164 | exact test name above | `[TO FILL]` |
| Python oracle/tests | both `unittest discover` commands | `[TO FILL]` |
| Core/extension experiments | seeded commands above | `[TO FILL]` |
| Python benchmarks | extension and core scripts | `[TO FILL]` |
| Native extension benchmark | corrected runner and Release binary | `[TO FILL]` |
| PDF regeneration | LaTeX, BibTeX, then two final LaTeX passes, if run | `[TO FILL]` |

An unrun, failed, skipped, or unsupported check remains visible as such; do
not convert it into a passing result or substitute an older evidence path.
