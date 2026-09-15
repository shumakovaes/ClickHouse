# Limitations and explicit non-goals

- The implementation is an exact `O(n)` store-sort state, not a bounded-memory
  streaming approximation. `max_samples` bounds accepted records; exceeding it
  fails explicitly.
- The production surface includes the three diagnostics and four registered
  extensions: lagged linear regression, ADF, KPSS, and mean shift. Validation,
  release-build acceptance, and CI status for the extensions remain pending.
- ADF exposes the fixed-lag coefficient, its statistic, and usable observation
  count, but no p-value. It assumes positional,
  equally spaced observations; timestamps are not used to infer spacing. The
  QR/rcond rank and resolution/work policy can return an undefined result for
  ill-conditioned or insufficient designs.
- KPSS uses its own documented finite-sample floor convention and bounded `q`
  and work limits. It exposes no p-value.
- Mean shift is an `O(n)` native scan with `O(n)` transient suffix moments. Its
  score is descriptive, not a calibrated change-point test. A positive
  original-unit SSE may overflow to `+Inf`, a tiny one may underflow to zero,
  and candidates equal within the documented numerical tolerance retain the
  earliest split.
- The aggregate does not infer order from insertion position or physical table
  layout. The SQL grouping key identifies a series and each sample needs a
  unique temporal/order key.
- Duplicate keys are rejected rather than deduplicated, averaged, or resolved
  by an unstable tie rule. Non-finite values are rejected.
- ACF and Ljung--Box are undefined for short or constant series under the
  current contract; Durbin--Watson is undefined for fewer than two samples or
  a zero denominator and returns `NaN` in those cases.
- The exact keyed state serializes samples in canonical key order, so shuffled
  input and different merge trees produce identical state bytes and the same
  finalizer operation order. Last-bit differences may still occur across
  toolchains or CPU targets; cross-platform acceptance therefore uses stated
  numerical tolerances rather than demanding universal bitwise identity.
- The serialized format is versioned and carries `max_samples`; incompatible
  versions/caps, malformed counts, non-finite values, or non-increasing keys
  must fail before unsafe allocation.
- A compact ordinary aggregate state is a **NO-GO** design for arbitrary row,
  block, and merge order. The compact range/prefix/suffix state is retained only
  as a rejected negative result and is not a production function or fallback.
- Native validation used a lean Debug build with optional libraries disabled,
  7.6 GiB of WSL2 RAM, and four build jobs. The aggregate and unified targets,
  focused gtest, and targeted SQL/Distributed fixture passed, but the complete
  ClickHouse test corpus and a release-mode build were outside this coursework
  machine's practical scope.
- Native benchmark cases stop at 50,000 rows and include process startup. Their
  0.01-second timing resolution is sufficient to record state footprint and a
  resource-bounded smoke comparison, not to claim production throughput.
