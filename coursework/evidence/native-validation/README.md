# Native ClickHouse validation

> Archived baseline record: this directory contains historical three-API
> evidence for the original coursework aggregates. It is not validation of
> any later extension or additional API surface.

This directory preserves the compact outputs from native validation on
2026-09-10. The patched checkout and build directory were on the WSL2 ext4
filesystem. The build was incremental from the recorded upstream revision,
but every changed production translation unit was compiled and both the
aggregate library and unified ClickHouse executable were linked.

## Results

| Layer | Observed result |
|---|---|
| clickhouse_aggregate_functions | 5,672/5,672 actions, exit 0 |
| unified clickhouse executable | 1,167/1,167 actions, exit 0 |
| ccache-backed repeat after CMake regeneration | 1,149/1,149 actions, exit 0 |
| clickhouse local smoke | all three aggregate APIs executed, exit 0 |
| 05161_time_series_diagnostics | 1 passed, 0 skipped, 0.48 s |
| TimeSeriesDiagnosticsState.* | 15 passed, 0 failed, 9 ms |

The SQL fixture exercised the preview gate, factory arity/type/parameter
validation, Nullable behavior, finite-value and duplicate rejection,
canonical serialized bytes, State/Merge/MergeState combinators, interleaved
states, an AggregatingMergeTree, and a real two-shard Distributed table using
test_cluster_two_shards_localhost. The focused GoogleTest runner exercised the
same checked-in state fixture directly, including corrupt and truncated
payloads and the bounded-deserialization-reserve case.

The raw compact outputs are [functional-test.txt](functional-test.txt) and
[gtest-run.txt](gtest-run.txt). [local-smoke.tsv](local-smoke.tsv) records the
visible three-function smoke result. Full multi-gigabyte binaries and build
logs are intentionally not packaged.

## Commands actually run

The initial lean configuration was:

~~~bash
cmake -S . -B tmp/coursework/build-lean -G Ninja \
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
CMAKE_BUILD_PARALLEL_LEVEL=4 cmake --build tmp/coursework/build-lean \
  --target clickhouse_aggregate_functions
CMAKE_BUILD_PARALLEL_LEVEL=4 cmake --build tmp/coursework/build-lean \
  --target clickhouse
~~~

The isolated server used the repository server/users configuration, the
repository test cluster configuration, and writable paths under
tmp/coursework/runtime. After readiness was confirmed with SELECT 1:

~~~bash
tests/clickhouse-test -q tests/queries \
  -b tmp/coursework/build-lean/programs/clickhouse \
  --no-long --no-random-settings -j 1 \
  05161_time_series_diagnostics
~~~

To avoid linking every unrelated ClickHouse unit test, validation added a
temporary checkout-only CMake runner containing Common/tests/gtest_main.cpp,
Common/tests/gtest_global_context.cpp, and the checked-in diagnostics fixture.
It linked the same production libraries as unit_tests_dbms. The delivered
reproduction guide uses the standard upstream-discovered unit_tests_dbms
target. The focused runner was invoked as:

~~~bash
tmp/coursework/build-lean/src/unit_tests_time_series_diagnostics \
  --gtest_filter='TimeSeriesDiagnosticsState.*'
~~~

The server was stopped with SYSTEM SHUTDOWN after the functional run.

## Failures found and resolved during native execution

The first server run exposed a fixture-only empty-input problem: this
ClickHouse revision does not publish the declared columns for a zero-row
`values()` call. The regression now uses one typed row filtered by `WHERE 0`.
The next comparison also replaced last-bit-sensitive Ljung--Box text with
six-decimal assertions and corrected the hand-computed merged ACF expectation
to 0.25. The first gtest run then caught two lower-level fixture defects: the
ACF of values 1 through 6 is 0.5, not 9/14, and a deserialization test built a
read buffer from a temporary payload string whose lifetime had ended. The
fixture now retains that payload. The final full reruns shown above pass; no
production-code workaround was made for a test failure.

## Checksums

| Artifact | SHA-256 |
|---|---|
| ClickHouse binary used for runtime and benchmark | ed87933045a2b92e0f88875308f2a3d161da6bab3ebb4b0bc45862b809674779 |
| aggregate-target build log | 5948ddc0721f82b0e91d51d5b6cb630357efa162689db449857ea8d88d4621c0 |
| unified-target build log | ae19f4be84949db759b043fc71dd394e63214a907ad1929ff39b515219ec097e |
| repeat unified-target build log | a9d491da248949588a235ff566af2a6567fbe24583a4258108060921d125148a |
| final focused-gtest build log | 618f2709da6a63d419d20f30ac7a29375d911c631338710280ce298e961e4a1d |
| packaged gtest output | 6d79f21f60c7ac1fc1933e64186efa5cd364f87d470e30ef6711d66227e52b07 |
| packaged functional-test output | fde9c73f17bba5e6c15f90fb049e91621807423dd2420dee9361f1283c6582c2 |
| production implementation .cpp | d81081b2585008df389f3e619b4a6a6a00777182dd9eb5f7c52b846c74dbaade |
| production implementation .h | b35c0672ae5fc6640d5de09e4b4ad23c41c5ba3c4eb670d90837adb4bea32970 |
| final GoogleTest fixture | 70119244f1bdff32213646145350ba3e87ee58b8a7f4b6c1fb56f6e7dd467369 |
| final SQL fixture | d3eff7ac64a19b90069bc4ad2010490ed39a0212a554522f81b3d46d4aa80882 |
| final SQL reference | e3294431e270a8ac21c57c08713d9400d1c79057a27ef4a0a65c8c6eb28bd7c8 |
