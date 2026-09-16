# Research inventory and production decision

## Scope and status

This note keeps two inventories separate. The upstream/public inventory is the
ClickHouse documentation and source cross-check made at research time
(2026-09-10). The coursework checkout is a separate working-tree surface: it
registers seven private-preview aggregate APIs, consisting of the three
diagnostics and the four extensions listed below. The coursework names are not
claimed to be upstream/public APIs at that date.

Source presence and factory registration establish implementation scope only;
the dated evidence adds execution. Release and Debug focused runs pass 38/38,
SQL/Distributed/`AggregatingMergeTree` fixtures pass 4/4, native performance
grids are recorded, and generated examples pass 7/7. Required remote CI is
still **BLOCKED**, so this file makes no full-CI claim.

## Decision

Use one exact keyed store-sort state for the seven coursework APIs. It retains
the accepted `(timestamp, value)` rows up to `max_samples`, sorts by the unique
key before order-dependent work, and rejects duplicate keys and non-finite
values. Lags and trends are positional after key ordering; timestamp gaps are
ignored. The default state cap is 1,000,000 rows and the hard cap is 10,000,000.

The three baseline diagnostics are:

- `timeSeriesAutocorrelation(lag[, max_samples])`;
- `timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])`; and
- `timeSeriesDurbinWatson([max_samples])`.

The four coursework-only extensions are:

- `timeSeriesLaggedLinearRegression(order[, max_samples])`;
- `timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])`;
- `timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])`; and
- `timeSeriesMeanShiftChangePoint(min_segment[, max_samples])`.

Undefined numerical results are represented by NaN fields. ADF and KPSS return
statistics without p-values; the mean-shift result is descriptive and has no
calibrated p-value. The regression, ADF, and KPSS finalizers use checked work
limits and return an undefined result when the requested calculation is not
safe to complete.

## Complexity by API

Let `n` be the retained sample count, `n1` and `n2` the sizes of two states,
`m = min(max_lag, n - 1)`, `p` an order or augmentation lag, and `q` the KPSS
bandwidth. Every API pays `O(n log n)` only when its state needs canonical
sorting; an already canonical state is scanned in the finalizer. State merge
itself is a sorted-union operation costing `O(n1 + n2)` time and temporary
space. The API-specific finalizer costs are:

| API | Finalization work after sorting | Additional finalizer storage | Bound or convention |
|---|---:|---:|---|
| `timeSeriesAutocorrelation` | `O(n)` | `O(1)` | Fixed requested lag; lag must be below the cap |
| `timeSeriesLjungBoxTest` | `O(n * m)` | `O(1)` | `m` is the requested largest lag, bounded by the hard lag limit |
| `timeSeriesDurbinWatson` | `O(n)` | `O(1)` | Consecutive canonical positions, not elapsed-time gaps |
| `timeSeriesLaggedLinearRegression` | `O(n * (p + 1)^2)` | `O(p^2)` | `1 <= p <= 16`; QR work is capped at 100,000,000 row-columns-squared units |
| `timeSeriesADFStatistic` | `O(n * c^2)`, `c = 1 + p + I(deterministic=trend)` | `O(c^2)` | `0 <= p <= 16`; fixed lag and deterministic mode, no autolag or p-value |
| `timeSeriesKPSSTest` | `O(n * q)` | `O(1)` | Bartlett bandwidth `q <= 1024`; `n*q` work is capped at 100,000,000 |
| `timeSeriesMeanShiftChangePoint` | `O(n)` | `O(n)` transient suffix statistics | One-break two-mean SSE scan; `min_segment` excludes endpoint splits |

The retained state is exact rather than a compact lag/range summary. Its
storage and serialized payload grow with the number of accepted rows, while
the table above records each API's distinct finalizer cost instead of treating
all seven APIs as one generic `O(n)` operation.

## Scope evidence

| Question | Decision | Evidence to preserve |
|---|---|---|
| How is temporal order defined? | Explicit scalar key; canonical sort at state boundaries/finalize | type checks, permutation tests |
| Can arbitrary partial states merge? | Yes, linear merge of sorted vectors; equal keys fail | interleaving/tree tests |
| How are duplicates handled? | Reject in add, merge, and deserialize | error fixtures |
| How is memory bounded? | `max_samples` default 1M, hard cap 10M; overflow fails | cap-boundary tests |
| Why not compact ranges? | Boundary-only state loses arbitrary interleaved lag pairs | negative prototype comparison |
| What is the statistical output? | Seven APIs: three diagnostics, lagged regression, ADF statistic, KPSS statistic, and one-break mean shift | source contracts and independent references |

## Narrow research questions

1. Do row/block permutations and all tested merge trees agree within the chosen
   floating-point tolerance for each of the seven APIs?
2. Are duplicate, invalid-value, malformed-state, numerical-guard, and cap
   failures deterministic and safe before allocation?
3. Do measured finalizer costs follow the per-API bounds above as `n`, lag,
   order, bandwidth, series count, and merge fan-in vary?
4. Which claims are supported by the upstream/public inventory, and which are
   supported only by the coursework checkout's source and registration?

## Source and citation policy

For claims about upstream/public ClickHouse behavior, preserve an official
reference page or source registration, version/date checked, exact claim, and
URL. For formula claims, preserve a primary statistical reference. For the
coursework-only APIs, cite the checkout source and state explicitly that it is
working-tree implementation evidence. Keep upstream/public behavior,
coursework implementation, and measured experiment results explicitly
separated. Native claims here are tied to the dated raw ledgers; Python results
alone and local runs are never reported as remote CI.
