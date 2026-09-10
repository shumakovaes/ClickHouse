# Research inventory and production decision

## Decision

The reviewed production implementation is an exact store-sort keyed state with `O(n)`
retained samples and explicit `max_samples`. Only three statistics are exposed:

- `timeSeriesAutocorrelation(lag[, max_samples])`;
- `timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])`; and
- `timeSeriesDurbinWatson([max_samples])`.

All three can be finalized from the fully key-sorted sample vector. Their
formulas, undefined cases, and numerical policy are specified in `DESIGN.md`.
The native source and factory wiring are included in the ClickHouse checkout;
build/test status is tracked in `PLAN.md` and is not implied by this inventory.

## Scope evidence

| Question | Decision | Evidence to preserve |
|---|---|---|
| How is temporal order defined? | Explicit scalar key; canonical sort at state boundaries/finalize | type checks, permutation tests |
| Can arbitrary partial states merge? | Yes, linear merge of sorted vectors; equal keys fail | interleaving/tree tests |
| How are duplicates handled? | Reject in add, merge, and deserialize | error fixtures |
| How is memory bounded? | `max_samples` default 1M, hard cap 10M; overflow fails | cap-boundary tests |
| Why not compact ranges? | Boundary-only state loses arbitrary interleaved lag pairs | negative prototype comparison |
| What is the statistical output? | ACF, Ljung--Box `(Q,p)`, Durbin--Watson | independent reference |

## Narrow research questions

1. Do row/block permutations and all tested merge trees agree within the chosen
   floating-point tolerance?
2. Are duplicate, invalid-value, malformed-state, and cap failures deterministic
   and safe before allocation?
3. What are the `O(n)` memory, merge, finalize, and throughput costs as `n`, lag,
   series count, and merge fan-in vary?

## Source and citation policy

For claims about current ClickHouse behavior, preserve an official reference
page or source registration, version/date checked, exact claim, and URL. For
formula claims, preserve a primary statistical reference. The included source
and registration establish implementation presence. The production and
registration translation units pass Clang 21 `-Werror`; the aggregate and
unified targets link; and the focused native gtest and SQL/Distributed fixture
pass. Keep current upstream behavior, project implementation, and measured
experiment results explicitly separated.
