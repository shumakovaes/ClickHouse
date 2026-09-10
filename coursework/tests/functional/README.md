# Time-series diagnostics functional test

`05161_time_series_diagnostics.sql` exercises only the three final aggregate
time-series diagnostics APIs:

```text
timeSeriesAutocorrelation(lag[, max_samples])(timestamp, value)
timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])(timestamp, value)
timeSeriesDurbinWatson([max_samples])(timestamp, value)
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

The `.reference` values are computed from the production implementation’s
documented formulas and contracts. Generic SQL cannot manufacture malformed
opaque aggregate states, so version/count/order/truncation corruption remains
a lower-level harness responsibility.
