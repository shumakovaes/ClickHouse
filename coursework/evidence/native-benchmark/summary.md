# Native benchmark summary

The native harness completed all 81 main measurements (three functions,
three row counts, three lag labels, and three repetitions), plus three
serialized-state, three merge-fan-in, and nine grouped-series measurements.
Every command exited successfully. The visible 1,000-row smoke result was:

| ACF(8) | Ljung--Box Q(8) | Durbin--Watson |
|---:|---:|---:|
| 0.97338079 | 7856.153678662713 | 0.00059016 |

For the largest 50,000-row cases, median complete-process wall times were:

| Function | lag 1 | lag 8 | lag 64 |
|---|---:|---:|---:|
| autocorrelation | 0.05 s | 0.06 s | 0.06 s |
| Ljung--Box | 0.05 s | 0.05 s | 0.06 s |
| Durbin--Watson | 0.05 s | 0.05 s | 0.06 s |

Durbin--Watson has no lag parameter; its repeated lag-labelled rows are a
control for the common benchmark matrix. Median maximum resident set size in
these 50,000-row cases was approximately 153 MiB. The 0.01-second timer
resolution and process startup dominate these small Debug-build runs, so the
derived rows/second figures must not be interpreted as production throughput.

The serialized autocorrelation state sizes for 50,000 total samples were:

| Partial states | RowBinary bytes | Construction wall time |
|---:|---:|---:|
| 1 | 800,018 | 0.06 s |
| 4 | 800,072 | 0.05 s |
| 16 | 800,288 | 0.06 s |

This is exactly 16 bytes per stored sample plus an 18-byte
version/cap/count header per state. Merging 1, 4, or 16 partial states each
took 0.05 s in the complete-process measurement. Holding total input at
50,000 rows while grouping into 1, 4, or 16 series also produced 0.05-second
medians. These measurements confirm the intended linear serialized footprint;
they are not precise enough to distinguish sub-process-startup CPU costs.

Raw data are in [raw_results.tsv](raw_results.tsv),
[state_sizes.tsv](state_sizes.tsv), [merge_results.tsv](merge_results.tsv),
and [grouped_results.tsv](grouped_results.tsv). Exact build and hardware
metadata are in [metadata.txt](metadata.txt), and the runnable harness is
[run_native_benchmark.sh](run_native_benchmark.sh).
