# Production plan: exact keyed time-series diagnostics and extensions

## Chosen scope

The implementation exposes seven private-preview aggregate names over one exact
keyed store-sort state. The state retains every finite `(timestamp, value)`
sample, canonicalizes by a unique timestamp before merge, serialization, or
finalization, and enforces `max_samples` (default `1,000,000`, hard maximum
`10,000,000`). Lags and trends are positional after key ordering; timestamp
gaps are ignored. Duplicate keys and non-finite values are errors, and
undefined numerical results are represented by `NaN` fields.

The baseline diagnostics are `timeSeriesAutocorrelation`,
`timeSeriesLjungBoxTest`, and `timeSeriesDurbinWatson`. The four implemented
extensions are:

| Function | Contract and bounded work |
|---|---|
| `timeSeriesLaggedLinearRegression(order[, max_samples])` | Positional AR model with intercept and lags 1 through `order`; `order` is 1--16. Centered/scaled non-pivoted Givens QR rejects ill-conditioned or undefined fits and caps `rows * order^2` work at `100000000`. |
| `timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])` | Fixed-lag ADF statistic and lag coefficient for `none`, `constant`, or `trend`; no autolag selection and no p-value. Uses the fixed-lag sample-admission, rank, residual-resolution, and QR guards documented in `EXTENSIONS_PLAN.md`. |
| `timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])` | Level or trend KPSS statistic with an explicit Bartlett bandwidth or the function-local default `min(n - 1, floor(12 * (n / 100)^0.25))`; bandwidth is capped at 1024 and `n * bandwidth` work at `100000000`; no p-value. |
| `timeSeriesMeanShiftChangePoint(min_segment[, max_samples])` | Descriptive one-break, two-mean SSE scan with an `O(n)` transient suffix-Welford pass, earliest numerical tie, and no calibrated p-value. Positive original-scale SSE overflow is reported as `+Inf`; no-improvement returns split index 0 and NaN fields. |

The four extensions share the exact keyed storage and merge law. Their state
envelope records the extension kind and constant parameters, while the payload
retains the independently versioned keyed samples. Local fitted models are not
merged; each finalizer fits or scans the canonical merged series.

## Compact-state decision

A compact prefix/suffix or bounded range state is a **NO-GO** ordinary aggregate
for arbitrary ClickHouse row, block, shard, spill, retry, persistence, and merge
order. The `1,3,2` schedule demonstrates that an engine-selected early merge can
discard the interior key needed for a later lag pair. Pairwise rejection of
non-adjacent ranges does not repair an ordinary aggregate because the reducer
does not control its merge tree.

The compact state remains a rejected comparison/prototype. It must not be
registered, exposed through `-State`/`-Merge`, used for `Distributed` aggregation,
or persisted in `AggregatingMergeTree` unless a future order-aware execution
operator proves complete adjacent ranges and canonical composition across every
local, remote, retry, spill, and persisted boundary. The production design is
therefore exact `O(n)` retained samples with canonical sorted union.

## Milestones and artifact status

| ID | Concrete output and acceptance evidence | Status |
|---|---|---|
| M1 | Freeze seven-API scope, signatures, key/value types, caps, duplicate/error policy, positional semantics, and non-goals in `DESIGN.md` and `EXTENSIONS_PLAN.md` | Complete in source/research artifacts |
| M2 | Shared state add/merge/finalize transitions, canonical sorting, duplicate/cap rejection, versioned serialization, and malformed-state guards | Complete in the existing diagnostics state; reused by the extension envelope |
| M3 | Ordering and merge-equivalence matrix, including arbitrary interleaving and duplicate cases | Complete in the state contract and the extension test/fixture definitions |
| M4 | Independent Python/reference coverage for regression, ADF, KPSS, and mean shift, including numerical and edge cases | Present as independent oracle and experiment artifacts; not native execution evidence |
| M5 | Four extension implementations, source `FunctionDocumentation`, and global registration | Complete; linked into the recorded 26.9.1.1 Release binary |
| M6 | Focused native extension GoogleTest source | Complete: 23 extension + 15 baseline cases pass **38/38** in both Release and Debug |
| M7 | Direct functional fixture and reference for all four extension names | Complete: `05162` passes **1/1** |
| M8 | Two-shard `Distributed` merge and duplicate propagation | Complete: `05163` passes **1/1**, including all-four cross-shard duplicate errors |
| M9 | `AggregatingMergeTree` part merge, finalization, persistence, and duplicate failure | Complete: `05164` passes **1/1**, with two persisted parts and four expected errors |
| M10 | Native acceptance ledger: Release configure/build, seven-API gtest, 05161--05164, Distributed, and `AggregatingMergeTree` raw logs | Complete under `evidence/native-acceptance-20260916-58b61c3a/`; all hashes verify |
| M11 | Native Release benchmark with recorded resource/timing metadata | Complete: 92 main rows plus 123 direct, 192 state-size, and 96 merge rows |
| M12 | Required remote CI jobs and generated/reference documentation check | Documentation complete (seven generator checks and 7/7 examples); remote CI **BLOCKED** because the PR workflow admits only `master` as its base, the PR correctly targets the coursework base branch, and the fork has zero registered self-hosted runners |

## Formula and implementation checkpoints

1. Sort the complete keyed sample by unique timestamp before every order-
   dependent finalizer. Merge canonical states with a two-pointer sorted union;
   reject duplicate keys rather than resolving them.
2. For lagged regression, form positional lag rows only after sorting and solve
   the centered/scaled small QR system. Return a fixed-shape NaN result when
   observations, rank, conditioning, residual resolution, finiteness, or the
   checked work limit is not sufficient.
3. For ADF, fit the requested fixed augmentation lag and deterministic terms;
   return the t-ratio and coefficient for `y[t-1]`, retain usable observation
   count, and do not claim a p-value.
4. For KPSS, fit level or trend residuals, use the stated Bartlett bandwidth
   convention, enforce `q < n` and `n*q <= 100000000`, and return statistic,
   bandwidth, and observation count without a p-value.
5. For mean shift, scan legal splits with direct suffix Welford states, select
   the earliest reliably smaller SSE, return the descriptive score and segment
   means, and preserve valid split/score information when original-scale SSE is
   `+Inf`.
6. Check each extension's add, merge, serialization, finalization, parameter,
   type, NULL, cap, duplicate, non-finite, insufficient-data, and numerical
   contracts through both native and public-path evidence. Opaque malformed
   bytes remain a lower-level native harness responsibility because SQL cannot
   manufacture arbitrary aggregate-state payloads.

## Remaining validation gates

Local Release/Debug, SQL, Distributed, `AggregatingMergeTree`, benchmarks, and
generated-documentation gates are closed by the 2026-09-16 evidence packages.
Two limits remain explicit:

* required remote GitHub CI is **BLOCKED** until the base branch's PR workflow
  admits `coursework/mergeable-time-series-statistics` and compatible
  self-hosted runners are registered, or an explicitly authorized minimal
  GitHub-hosted workflow is added; local execution is not remote-CI evidence;
* exhaustive platform/allocation coverage (every toolchain, CPU, scalar
  conversion alternative, threshold neighborhood, and allocation failure) is
  outside the bounded coursework run.
