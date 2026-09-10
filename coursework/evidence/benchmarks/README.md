# Keyed lag-state benchmark

`benchmark_lag_state.py` is a standalone deterministic harness for three
keyed ACF/Ljung–Box/Durbin–Watson state designs:

* `compact_ordered`: a compact O(L)-per-key sufficient-statistics prototype
  for ordered, contiguous-range partial merges. It is not valid for arbitrary
  ClickHouse plans.
* `exact_store_sort`: an exact O(n) state that stores rows by key and sorts at
  finalize, including arbitrary partition/interleaving.
* `naive_full_recompute`: a full-row baseline that globally sorts and
  recomputes at finalize.

The CSV is long-form and times add, merge, and finalize separately. Finalizer
rows contain the computed ACF vector (`acf_json`), Ljung–Box Q, Durbin–Watson,
and a checksum over those statistics—not a toy row checksum. It also includes
lag/chunk/partition scaling, retained state size, row scaling, and operation
counts. `environment.json` captures Python/platform/CPU, git revision, command
line, seed, and all parameters. `summary.md` is generated from the same run
(median timings for each case) and calls out the compact design's ordering
precondition.

Run a modest case from the coursework package root:

```powershell
py -3 evidence/benchmarks/benchmark_lag_state.py `
  --output-dir evidence/benchmarks/run `
  --rows 1000,5000,10000 `
  --lags 1,8,64 `
  --chunks 1,4,16 `
  --repeats 2 `
  --seed 20260910
```

Use `py -3 evidence/benchmarks/benchmark_lag_state.py --help` to adjust sizes.
The merge metric models sequential partial-state merges. Contiguous and
interleaved partitions are both run; compact rows are intentionally omitted
for interleaved partitions because that design rejects them. Timings are local
microbenchmarks and should be compared on the same host using the captured
environment.
