# Ordered keyed mergeable-statistics reference

`reference.py` is an intentionally simple, dependency-free correctness oracle
for exactly the production functions:

- `autocorrelation(lag) -> Float64` (a single lag, including lag 0)
- `ljung_box(max_lag, model_df=0) -> LjungBoxResult(statistic, p_value)`
- `durbin_watson() -> Float64`

`FullSampleKeyedStats` is the production-correct state: it retains all samples,
accepts rows/states in arbitrary order, sorts by UInt64 key on every entry path,
and rejects duplicates. `max_samples` defaults to 1,000,000 and is valid only
in `[1, 10,000,000]`, matching the production contract's configured and hard
ceilings.

`OrderedStats` is retained only as a **range-ordered research prototype** for
compact monoid experiments. It cannot merge interleaved key ranges; use the
full-sample state when correctness must be independent of partitioning/order.

## Contract

- `FullSampleKeyedStats` keys are unique UInt64 integers. Input row order is
  irrelevant; `merge` combines, sorts, and rejects any duplicate key. States
  must use the same `max_samples`, and exceeding that cap fails explicitly.
- Full-state JSON is canonical compact JSON with version, kind, cap, and sorted
  points: `{"version":2,"kind":"full-sample-keyed","maxSamples":...}`.
- `OrderedStats.split_at(i)` followed by its range-valid `merge` preserves every
  reported statistic, but that type intentionally rejects interleavings.
- ACF uses the production biased, sample-mean-centered denominator. Lag 0 is 1
  for nonconstant data; unavailable lags and constant/empty inputs are `NaN`.
- Ljung--Box requires all lags through `max_lag` (`n > max_lag`), never truncates
  them, and returns `(NaN, NaN)` for insufficient/constant data. Its p-value is
  a dependency-free chi-square survival probability with `max_lag - model_df`
  degrees of freedom; `0 <= model_df < max_lag` is required.
- Durbin--Watson requires at least two samples and returns `NaN` for a zero
  denominator. Ingest and deserialization reject NaN and ±infinity.
- Production finalization is numerically scale-safe: autocorrelation centers in
  a min/max-derived local coordinate system and normalizes before products;
  Durbin--Watson normalizes by max absolute value. This preserves representable
  variation near large offsets and avoids overflow/underflow for values such as
  ±`1e200` and ±`1e-200`.

Run deterministic tests from this directory:

```powershell
py -3 -m unittest -v test_reference
```

Fixed seeds cover random range merge trees, arbitrary-row-order/interleaved
full-state merge trees, large offsets, empty/constant/zero/nonfinite inputs,
caps, duplicate/canonical serialization rejection, and hand-checked ACF,
Ljung--Box p-values, and Durbin--Watson cases.

## Statistical-extension batch oracles

`extensions.py` is a second, deliberately independent batch implementation for
the continuation work. It covers fixed-order lagged linear regression, the ADF
statistic with a caller-selected lag and deterministic terms, the KPSS statistic
with a Bartlett long-run variance estimate, and an exact single mean-shift scan.
It does not reuse the mergeable production state or its numerical routines.

The core oracle uses only the Python standard library. When NumPy and
statsmodels are available, `test_extensions.py` additionally compares lagged
regression, ADF, and KPSS results with those third-party implementations. These
files are reference and test material; a function counts as a native ClickHouse
feature only after its C++ registration and focused native/SQL validation pass.

Run all reference tests from the repository root:

```powershell
py -3 -m unittest discover -s coursework/reference/python -p 'test_*.py'
```
