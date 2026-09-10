# Limitations and explicit non-goals

- The implementation is an exact `O(n)` store-sort state, not a bounded-memory
  streaming approximation. `max_samples` bounds accepted records; exceeding it
  fails explicitly.
- Only `timeSeriesAutocorrelation`, `timeSeriesLjungBoxTest`, and
  `timeSeriesDurbinWatson` are production scope. STL, KPSS, AR, FFT, seasonal,
  anomaly, and other candidate functions are out of scope.
- The aggregate does not infer order from insertion position or physical table
  layout. The SQL grouping key identifies a series and each sample needs a
  unique temporal/order key.
- Duplicate keys are rejected rather than deduplicated, averaged, or resolved
  by an unstable tie rule. Non-finite values are rejected.
- ACF and Ljung--Box are undefined for short or constant series under the
  current contract; Durbin--Watson is undefined for fewer than two samples or
  a zero denominator and returns `NaN` in those cases.
- Floating-point results can differ in the last bits across merge trees. The
  acceptance criterion is a stated numerical tolerance, not bitwise identity.
- The serialized format is versioned and carries `max_samples`; incompatible
  versions/caps, malformed counts, non-finite values, or non-increasing keys
  must fail before unsafe allocation.
- The compact range/prefix/suffix state is a rejected negative result. It is
  valid only under stronger ordered-adjacent-range assumptions and is not a
  production function or fallback.
- Native validation used a lean Debug build with optional libraries disabled,
  7.6 GiB of WSL2 RAM, and four build jobs. The aggregate and unified targets,
  focused gtest, and targeted SQL/Distributed fixture passed, but the complete
  ClickHouse test corpus and a release-mode build were outside this coursework
  machine's practical scope.
- Native benchmark cases stop at 50,000 rows and include process startup. Their
  0.01-second timing resolution is sufficient to record state footprint and a
  resource-bounded smoke comparison, not to claim production throughput.
