# Standalone C++ comparison prototype

`standalone.cpp` contains two dependency-free reference implementations:

- `CompactState`, an ordered, dense, explicit-key range summary with `O(L)`
storage, stable centered univariate and lagged bivariate moments, and
  prefix/suffix boundary buffers. Its KPSS prefix statistics use a per-range
  translation origin, transformed during merge, to avoid large-offset
  cancellation;
- `FullSampleState`, a sorted keyed full-sample oracle that can merge arbitrary
  disjoint fragments and validates density when diagnostics are finalized.

Both paths compute ACF, Ljung--Box, Durbin--Watson, AR(1) fits with and without
an intercept, and the level-stationarity KPSS statistic with a Bartlett HAC
bandwidth. The executable includes deterministic randomized merge-tree tests,
duplicate/gap/overlap checks, an exact three-point example, and text
serialization round-trips.

This program is quarantined comparison evidence, not the production ClickHouse
implementation. In particular, its compact path requires dense ordered ranges;
the production keyed state accepts timestamp gaps, arbitrary row/state order,
and retains all samples. The AR(1) and KPSS portions are archived baseline
exploratory evidence predating the four registered extensions
(`timeSeriesLaggedLinearRegression`, `timeSeriesADFStatistic`,
`timeSeriesKPSSTest`, and `timeSeriesMeanShiftChangePoint`); they are not SQL
API claims for those extensions.

Compile and run in the configured Ubuntu WSL distribution:

```sh
clang++-21 -std=c++23 -O2 -Wall -Wextra -Werror standalone.cpp -o standalone_tests
./standalone_tests
```

The recorded 2026-09-10 run passed 1,764 checks both normally and under
AddressSanitizer plus UndefinedBehaviorSanitizer. A sanitizer reproduction is:

```sh
clang++-21 -std=c++23 -O1 -g -fsanitize=address,undefined \
  -fno-omit-frame-pointer -Wall -Wextra -Werror \
  standalone.cpp -o standalone_tests_san
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
  ./standalone_tests_san
```
