# Reproducing the exact keyed diagnostics

This protocol reproduces the evidence for the three implemented aggregates.
The recorded run linked both the aggregate and unified ClickHouse targets,
passed the focused native GoogleTest suite 15/15, and passed the stateless
SQL/Distributed fixture 1/1. Exact outputs, hashes, and environment values are
preserved under `evidence/native-validation/`.

## Provenance

Record the ClickHouse commit, compiler/standard library, OS/kernel, CPU, thread
count, build type, generator/reference versions, random seed, and all relevant
settings. Record ISO dates, `SELECT version()`, `system.build_options`, and a
checksum for every input, query, serialized state, and raw output.

## Exact package commands

Run these commands from the `coursework/` directory in PowerShell. Reproduced
outputs go to new directories so the captured evidence is not overwritten.

```powershell
py -3 -m unittest discover -s reference/python -p "test_*.py"
py -3 -m unittest discover -s evidence/experiments -p "test_*.py"
py -3 evidence/experiments/run_experiments.py --n 300 --reps 200 --seed 20260910 --output-dir reproduced/experiments
py -3 evidence/experiments/audit_results.py --input-dir reproduced/experiments --output reproduced/experiments/analysis.md
py -3 evidence/benchmarks/benchmark_lag_state.py --output-dir reproduced/benchmarks --rows 1000,5000,10000 --lags 1,8,64 --chunks 1,4,16 --repeats 2 --seed 20260910
```

For the native checkout, either use `build/setup_wsl.sh` as documented in
`build/README.md`, or run the equivalent commands below from the ClickHouse
repository root in WSL. Keep source and build files on WSL's ext4 filesystem.

```bash
cmake -S . -B build-coursework -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=clang-21 \
  -DCMAKE_CXX_COMPILER=clang++-21 \
  -DCMAKE_LINKER=ld.lld-21 \
  -DCMAKE_AR=llvm-ar-21 \
  -DENABLE_LIBRARIES=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_BENCHMARKS=OFF \
  -DENABLE_THINLTO=OFF \
  -DENABLE_RUST=OFF \
  -DENABLE_XRAY=OFF \
  -DSPLIT_DEBUG_SYMBOLS=OFF
CMAKE_BUILD_PARALLEL_LEVEL=4 cmake --build build-coursework --target clickhouse_aggregate_functions
CMAKE_BUILD_PARALLEL_LEVEL=4 cmake --build build-coursework --target clickhouse
CH_BUILD_DIR="$PWD/build-coursework" \
  bash coursework/build/run_native_validation.sh
```

The checked-in gtest is discovered automatically by the standard test-enabled
`unit_tests_dbms` target:

```bash
cmake -S . -B build-coursework-tests -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=clang-21 \
  -DCMAKE_CXX_COMPILER=clang++-21 \
  -DCMAKE_LINKER=ld.lld-21 \
  -DCMAKE_AR=llvm-ar-21 \
  -DENABLE_LIBRARIES=OFF \
  -DENABLE_TESTS=ON \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_BENCHMARKS=OFF \
  -DENABLE_THINLTO=OFF \
  -DENABLE_RUST=OFF \
  -DENABLE_XRAY=OFF \
  -DSPLIT_DEBUG_SYMBOLS=OFF
CMAKE_BUILD_PARALLEL_LEVEL=4 cmake --build build-coursework-tests --target unit_tests_dbms
build-coursework-tests/src/unit_tests_dbms --gtest_filter='TimeSeriesDiagnosticsState.*'
```

The native benchmark uses the same built binary and writes a fresh result set
without overwriting the packaged evidence:

```bash
REPEAT_COUNT=3 bash coursework/evidence/native-benchmark/run_native_benchmark.sh \
  build-coursework/programs/clickhouse \
  coursework/evidence/native-benchmark/reproduced
```

## Protocol

1. Build the selected revision with the documented ClickHouse workflow and
   preserve stdout/stderr and checksums for the linked targets.
2. Generate deterministic `(series_group, key, value)` data with unique keys,
   deliberate duplicate-key fixtures, finite/invalid-value fixtures, and a fixed
   seed. Keep logical data identical across layouts.
3. Run sorted, reversed, randomized, different-block-size, and shard-permuted
   inputs for `timeSeriesAutocorrelation`, `timeSeriesLjungBoxTest`, and
   `timeSeriesDurbinWatson`.
4. Build partial states with interleaved key ranges and exercise every small
   merge-tree parenthesization. Compare against one-shot aggregation and the
   independent exact reference.
5. Exercise `max_samples` at `0`, `1`, the exact boundary, one over the boundary,
   and the hard maximum; include duplicate keys in one state, across states, and
   in serialized payloads.
6. Save query text, settings, stderr/stdout, timings, peak memory, state sizes,
   validation errors, and result checksums. Keep raw outputs separate from
   derived tables/plots.

## Required comparisons

Report absolute/relative error versus the reference, merge-vs-one-shot
difference, duplicate/cap error counts, throughput, peak memory, serialized
state size, and sensitivity to sample count, series count, lag, and fan-in.
Use repeated timing runs with an explicit warm-up policy. A failed, unsupported,
or unrun case must remain visible rather than being recorded as passing.

## Evidence layout

Suggested directories are `results/raw/`, `results/processed/`,
`manuscript/tables/`, and `manuscript/figures/`. Preserve machine-readable
outputs and the exact command that produced each one; screenshots alone are not
reproducibility evidence.
