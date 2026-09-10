# Production plan: exact keyed time-series diagnostics

## Chosen scope

Deliver one exact `O(n)` store-sort keyed state and exactly three aggregate
functions: `timeSeriesAutocorrelation`, `timeSeriesLjungBoxTest`, and
`timeSeriesDurbinWatson`. The state stores every unique `(key, value)` sample up
to a positive `max_samples` cap (default `1,000,000`, hard maximum `10,000,000`).
Rows and partial states may arrive in any order; duplicate keys are rejected.
The compact range state is retained only as a rejected negative result, not as a
second production implementation.

## Milestones and status

| ID | Concrete output and acceptance evidence | Status |
|---|---|---|
| M1 | Freeze scope, signatures, key/value types, `max_samples`, duplicate/error policy, and non-goals in `DESIGN.md` | complete |
| M2 | State invariants, add/merge/finalize transitions, formulas, serialization/version contract | complete |
| M3 | Ordering and merge-equivalence matrix, including arbitrary interleaving and duplicate cases | complete |
| M4 | Independent reference plus SQL/C++ functional cases for all three functions and undefined results | complete: isolated reference 15/15, focused native gtest 15/15, stateless SQL 1/1 |
| M5 | ClickHouse registration, factory validation, result types, serialization, and docs implementation map | complete: Clang 21 `-Werror` TUs, aggregate target 5,672/5,672, unified target 1,167/1,167 |
| M6 | Reproducible experiment run: build identity, permutation/merge tests, cap/error tests, reference comparisons | complete: experiment suite 6/6; SQL/Distributed, state merge, and error paths pass |
| M7 | Complexity/memory/throughput comparison against the rejected compact-range prototype | complete within the resource-bound scope: Python comparison plus native Debug raw timings/state sizes |
| M8 | Coverage review closes every requirement with a source or runnable artifact; publish raw outputs | complete: targeted matrix and explicit gaps published; no instrumented percentage claimed |

## Formula and implementation checkpoints

1. For sorted `x_0..x_{n-1}`, compute mean and centered sum of squares `D`.
   For `h>0`, `rho_h = sum((x_i-mean)(x_{i-h}-mean))/D`.
2. Compute `Q = n(n+2) sum rho_h^2/(n-h)` for `h=1..max_lag`; return the
   chi-square survival probability with `max_lag-model_df` degrees of freedom.
3. Compute `DW = sum (x_i-x_{i-1})^2 / sum x_i^2` in key order.
4. Use compensated sums/centered updates, reject undefined cases with `NaN`,
   and reject all invalid data/cap/duplicate conditions.
5. Check add, merge, serialization, and finalize independently; then check
   arbitrary permutations and all small merge-tree shapes against the reference.

## Non-goals

No implicit range ordering, duplicate resolution, unbounded history, compact
range production state, STL/KPSS/AR/FFT/seasonal/anomaly functions, or claims
beyond the preserved native and statistical evidence.
