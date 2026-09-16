# Native ClickHouse aggregate benchmark

> Archived baseline record: this harness and its packaged results cover only
> the historical three-API coursework baseline. They are not extension
> validation and make no claim about later APIs or implementations.

This harness measures the three coursework aggregates in the locally built
ClickHouse binary:

* `timeSeriesAutocorrelation`
* `timeSeriesLjungBoxTest`
* `timeSeriesDurbinWatson`

It uses deterministic data,
`sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11)`,
with `n` in `{1000, 10000, 50000}` and lag in `{1, 8, 64}`. Each case is
repeated three times by default with `max_threads=1`. The output format is
`Null` after aggregate evaluation; the separate `smoke.tsv` file records one
visible result row to prove that every function ran. Timings are wall-clock
seconds for a complete `clickhouse local` process, so process startup is
included.

The harness also records maximum resident set size (`max_rss_kb`) and input
rows per second.  `state_sizes.tsv` emits
`timeSeriesAutocorrelationState(8)` in RowBinary for 1, 4, and 16 grouped
partial states, so `serialized_bytes` is the measured encoded-state footprint.
`merge_results.tsv` runs the matching `timeSeriesAutocorrelationMerge(8)`
query over those partial states.  `grouped_results.tsv` keeps 50,000 input
rows fixed while grouping one, four, or 16 series.  These supplemental cases
are intentionally modest and include query-process startup in every timing.

These are engineering measurements of the Debug build used for validation,
not production-performance claims.  The raw data and build metadata are
written to the script-local `results/` directory by
`run_native_benchmark.sh` unless an explicit output path is provided.

## Run in WSL

From the ClickHouse repository root, invoke the packaged harness and write a
fresh result set to a separate directory:

```bash
bash coursework/evidence/native-benchmark/run_native_benchmark.sh \
  tmp/coursework/build-lean/programs/clickhouse \
  coursework/evidence/native-benchmark/reproduced
```

Or provide an explicit WSL binary and output directory:

```bash
bash coursework/evidence/native-benchmark/run_native_benchmark.sh \
  /home/user/clickhouse-coursework/tmp/coursework/build-lean/programs/clickhouse \
  /mnt/c/path/to/ClickHouse/coursework/evidence/native-benchmark/reproduced
```

The script requires the lean native binary to exist and exits without making
measurements otherwise.

## Output files

* `raw_results.tsv`: all three finalized aggregate functions for the size/lag matrix.
* `state_sizes.tsv`: serialized RowBinary state size and state-construction timing.
* `merge_results.tsv`: partial-state fan-in timing for 1/4/16 states.
* `grouped_results.tsv`: fixed-input grouped-series timing.
* `metadata.txt`: binary, revision, compiler, kernel, CPU, and timing details.
* `smoke.tsv`: visible correctness smoke result for all three functions.
