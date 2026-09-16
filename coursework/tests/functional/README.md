# Time-series diagnostics and extensions functional tests

`05161_time_series_diagnostics.sql` exercises the baseline three diagnostics.
The exact checkout fixtures
`tests/queries/0_stateless/05162_time_series_statistical_extensions.sql`,
`05163_time_series_statistical_extensions_distributed.sql`, and
`05164_time_series_statistical_extensions_aggregating_merge_tree.sql` cover the
four registered extensions in direct, Distributed, and `AggregatingMergeTree`
execution:

```text
timeSeriesAutocorrelation(lag[, max_samples])(timestamp, value)
timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])(timestamp, value)
timeSeriesDurbinWatson([max_samples])(timestamp, value)
timeSeriesLaggedLinearRegression(order[, max_samples])(timestamp, value)
timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])(timestamp, value)
timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])(timestamp, value)
timeSeriesMeanShiftChangePoint(min_segment[, max_samples])(timestamp, value)
```

The test covers the disabled preview gate, malformed call shapes, exact
hand-checked values (including ACF lag zero), named
Ljung--Box tuple fields, undefined finite cases, arbitrary row order, all four
supported scalar timestamp types (`UInt32`, `UInt64`, `DateTime`, and
`DateTime64`), native numeric value dispatch, non-finite rejection, Decimal
rejection, ClickHouse's internal `Null` combinator behavior, parameter and
`max_samples` caps, interleaved and reversed `Merge`/`MergeState` combinators,
duplicate timestamps, canonical serialized bytes across input permutations,
`AggregatingMergeTree` part merges,
and large-offset/extreme-scale numeric stability.

The fixture is tagged `stateful, distributed` and also exercises the ordinary
test-cluster `Distributed` engine. It partitions a shared local table by the
virtual `_shard_num` column so the two logical localhost shards contribute
disjoint keys, then checks the merged diagnostic result. A second query reads
both shard copies without that partition and must propagate the production
duplicate-key `BAD_ARGUMENTS` failure. The cluster definition is the existing
`test_cluster_two_shards_localhost` from `tests/config/config.d/clusters.xml`;
no additional service or fixture is required.

Nullable arguments are intentionally accepted through ClickHouse's internal
`Null` combinator: every row containing a NULL is skipped, and the result type
is nullable. Decimal values are intentionally rejected because the factory
requires `isNativeNumber(value_type)`; the expected diagnostic is
`ILLEGAL_TYPE_OF_ARGUMENT`. The autocorrelation `lag` parameter is
non-negative (lag zero is defined as 1 for a non-constant series), while
Ljung--Box `max_lag` is positive.

The focused native source at
`src/AggregateFunctions/tests/gtest_time_series_statistical_extensions.cpp`
defines 23 extension cases. Together with the 15 baseline cases, the recorded
Release and Debug focused runs both pass **38/38**. ADF checks cover
fixed-lag statistic/coefficient output (no p-value),
positional semantics and the caller's equal-spacing responsibility, and the
QR/rcond/resolution/work rejection policy. KPSS checks the
implementation-specific finite-sample bandwidth floor, `q` and work limits,
and statistic-only output. Mean-shift checks its linear scan, descriptive
score, `+Inf` on positive original-scale SSE overflow, tiny-SSE underflow
behavior, and earliest-index tie rule. Native mean-shift selection uses
`gamma_n = n * epsilon / (1 - n * epsilon)` and accepts a later split only
when its SSE improves by more than
`8 * gamma_n * max(abs(candidate), abs(incumbent))`; the Python oracle uses a
strict `<` comparison and retains the earliest exact tie, so intentionally
near-tied objectives may differ. A compact ordinary aggregate state is
explicitly NO-GO for arbitrary merge order.

The `.reference` values are computed from the production implementation’s
documented formulas and contracts. Generic SQL cannot manufacture malformed
opaque aggregate states, so version/count/order/truncation corruption remains
a lower-level harness responsibility. The Release-linked acceptance run passes
`05161`--`05164` **4/4** with no skips, including two-shard and persisted-state
duplicate failures. Raw logs are under
`evidence/native-acceptance-20260916-58b61c3a/`. Required remote CI remains
**BLOCKED** and is not inferred from these local results.
