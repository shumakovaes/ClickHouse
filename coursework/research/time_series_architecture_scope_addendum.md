# Time-series architecture and scope rationale

This addendum compares candidate implementations for a coursework-sized ClickHouse contribution. It is deliberately a scope analysis, not an upstream acceptance prediction. Any reference to “precedent” means an existing ClickHouse interface or documented design pattern; it does not imply that a new function would be accepted unchanged.

## Starting points already available

`arrayAutocorrelation(array[, max_lag])` is shipped in ClickHouse 26.4. It computes normalized autocorrelation per lag over an already-materialized numeric array, supports integer/float/decimal arrays, and can limit the output length. See the official [26.4 release call](https://presentations.clickhouse.com/2026-release-26.4/). Architecturally, it is a scalar array operation: callers must first collect a series into an array, and its result is an array rather than one row per key/lag.

ClickHouse also has a time-series aggregate family for grid/rate/delta/last-value calculations. The 25.6 release presentation lists `timeSeriesInstantDeltaToGrid`, `timeSeriesInstantRateToGrid`, `timeSeriesRateToGrid`, `timeSeriesResampleToGridWithStaleness`, `timeSeriesDeltaToGrid`, and `timeSeriesLastTwoSamples`, with a `(start, end, step, window)(timestamp, value)` style call. See the [25.6 release call](https://presentations.clickhouse.com/2025-release-25.6/). `timeSeriesGroupArray` is the relevant design precedent for an aggregate that groups samples into a time-series-shaped array; its existence should be verified against the target branch before relying on its exact signature or maturity. **Inference:** this family establishes that time-series-specific aggregate state and array output are acceptable ClickHouse patterns, but it does not establish an autocorrelation or statistical-diagnostic API.

## Candidate architectures

### A. Reuse `arrayAutocorrelation`

Pipeline: group rows by series key, build an ordered `groupArray`/time-series array, then call `arrayAutocorrelation`.

Advantages: no server C++ change; immediate baseline; simple correctness oracle; useful for demonstrating seasonality. Disadvantages: materializes the complete series, requires explicit ordering and missing-value policy, has array-size/memory pressure, and does not provide a mergeable keyed aggregate. It cannot by itself satisfy a missing stationarity/breakpoint task from the current intern list. See [Intern Tasks 2025/2026 #87836](https://github.com/ClickHouse/ClickHouse/issues/87836), which asks for stationarity, breakpoints, and predicted values.

### B. Exact O(n) keyed aggregate/window function

Maintain per-key state while scanning rows in timestamp order. For a requested lag set, update the necessary running sums/cross-products and finalize normalized statistics. A window implementation can emit a value per row; an aggregate can emit a compact result array/tuple at finalize.

Advantages: one pass over input, natural keyed operation, bounded state for a fixed lag set, and a clear performance story. Disadvantages: exact lag alignment depends on a defined regular-grid/irregular-time policy; arbitrary lag output can make state O(number of requested lags); unordered input requires sorting or rejection; distributed aggregation requires a merge state that preserves enough boundary samples. **Inference:** “O(n)” is only defensible after fixing the lag set and input semantics; it must not be advertised as O(n) for all lags and arbitrary unordered data.

### C. Compact O(L) contiguous-range prototype

For a contiguous numeric array of length L, calculate autocorrelation for a bounded lag range with a compact rolling/buffer representation. This is appropriate for an educational prototype with explicit regular spacing and missing-value policy.

Advantages: small implementation surface, easy reference comparison, bounded memory and straightforward deterministic tests. Disadvantages: it is array-oriented rather than keyed/streaming, and a naive all-lag calculation is O(L²); an O(L) claim only applies to a fixed number of lags or a specialized algorithm. It overlaps materially with the already-shipped `arrayAutocorrelation`, so novelty must be in a different contract (for example, a mergeable keyed aggregate), validation, or a missing statistical diagnostic—not the same function under another name.

### D. Precomputed-lag, order-independent aggregate state

For a configured lag set, retain sufficient statistics such as count, sum of x, sum of y, sum of x², sum of y², and sum of x·y for each lag. The state can merge across blocks if each pair is defined by an explicit timestamp/sequence relationship. It is order-independent with respect to block arrival, not magically independent of the series’ temporal ordering.

Advantages: mergeable aggregate state, distributed-query compatibility, and predictable O(number of configured lags) state. Disadvantages: pairing samples at lag k requires either a keyed lookup/ring buffer, regular sequence numbers, or boundary carry-over; the state design is more subtle than the final formula; arbitrary missing timestamps and duplicate timestamps need explicit semantics. **Inference:** this is the strongest architecture if the coursework goal is to teach ClickHouse aggregate-state merging, but it needs a narrow fixed-lag contract to remain reviewable.

## Recommended coursework shape

Recommend a small, explicitly scoped keyed aggregate (or aggregate-plus-window variant) for a fixed, user-specified lag bound on regularly sampled numeric data, with:

- explicit series key and timestamp/sequence assumptions;
- deterministic handling of nulls, duplicates, gaps, constant series, short series, and invalid lag;
- mergeable state with tests that split input into blocks and compare merged versus single-pass results;
- a reference query/Python calculation and property tests for normalization and symmetry;
- benchmarks separating fixed-lag O(n) behavior from all-lag O(L²) behavior;
- optional comparison with `arrayAutocorrelation` as an existing 26.4 baseline, not as new functionality.

If implementation time is tighter, choose the compact contiguous-range prototype, but position it as a validation/educational prototype and avoid claiming a new upstream feature where its semantics duplicate `arrayAutocorrelation`.

Avoid promising an unrestricted arbitrary-lag, irregular-time, distributed, fully window-frame-aware API in one coursework project. Such a design combines parser/API decisions, sorting semantics, null/gap policy, aggregate-state boundaries, and performance work. A focused implementation can still make a meaningful contribution toward the open statistical-function scope while staying consistent with ClickHouse’s stated intern-task constraints (isolated and approximately month-sized): [#87836](https://github.com/ClickHouse/ClickHouse/issues/87836).

## What “upstream acceptable” should mean here

The project should claim only that it produces an evidence-backed prototype or candidate implementation with a well-defined contract. Upstream suitability remains contingent on ClickHouse conventions, API naming, documentation, tests, distributed merge semantics, and maintainer review. This caution is especially important because the prior `aleks5d` time-series PRs were not merged into mainline and received feedback requesting stronger functional tests, documentation, and window semantics: [PR #1](https://github.com/aleks5d/ClickHouse/pull/1), [PR #2](https://github.com/aleks5d/ClickHouse/pull/2), [PR #3](https://github.com/aleks5d/ClickHouse/pull/3).
