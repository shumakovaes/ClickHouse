# Formal design: exact keyed time-series diagnostics

## Production scope

The production implementation is one exact `O(n)` store-sort state. It stores every
accepted `(key, value)` sample (up to `max_samples`) and canonicalizes samples
by key. Keys are the temporal order; arrival order, block order, and merge-tree
shape are not temporal inputs. The state is intended to be used per SQL group
(the group identifies the series); there is no inferred series or range from
physical storage.

Only these aggregate functions are in scope:

```sql
timeSeriesAutocorrelation(lag[, max_samples])(key, value) -> Float64
timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])(key, value)
  -> Tuple(statistic Float64, p_value Float64)
timeSeriesDurbinWatson([max_samples])(key, value) -> Float64
```

`key` accepts the supported scalar timestamp/order types (`UInt32`, `UInt64`,
`DateTime`, or `DateTime64`); native integer/floating-point `value` arguments
are converted to `Float64` (Decimal values are not accepted by the current
factory). Values must be finite; rows with a NULL argument are skipped by
ClickHouse's nullable aggregate handling. Duplicate keys are rejected, both
within one state and when two states are merged. `max_samples` is a positive
constant, defaults to `1,000,000`, and cannot exceed the hard cap `10,000,000`.
Exceeding the cap is an error; samples are never silently dropped.
Autocorrelation `lag` is non-negative and may be zero; `max_lag` is positive
and both are bounded by the hard lag limit. Positive lags must be less than
`max_samples`; `model_df` is non-negative and strictly less than `max_lag`.

## State and transitions

For one SQL group, the state retains `(key, Float64 value)` records plus a
serialization version and the configured `max_samples`. The implementation
appends arrival-order records, marks the state unsorted when needed, and
canonicalizes by key before finalization, merge, or serialization. Canonical
states have strictly increasing keys and no duplicate keys; an equal key is
rejected rather than resolved by arrival order.

`merge(left, right)` requires the same function parameters/version and a common
`max_samples`. It performs a two-pointer merge of the two canonical vectors;
an equal key is a duplicate-key error. The combined count must remain within
`max_samples`. Empty state is the identity.

`finalize` reads the canonical key order and computes the requested statistic.
No result may depend on insertion, block, or merge order. Empty or too-short
inputs return `NaN` where the statistic is undefined. ACF and Ljung--Box also
return `NaN` for zero variance; Durbin--Watson returns `NaN` only for a zero
denominator, while a nonzero constant series correctly returns zero.

## Exact formulas

For sorted values `x_0, ..., x_{n-1}`, let

```text
mean = (1/n) * sum(x_i)
D     = sum((x_i - mean)^2)
```

The biased, mean-centered autocorrelation at positive lag `h` is

```text
rho_h = sum(i=h..n-1) (x_i - mean)(x_{i-h} - mean) / D
```

For `h = 0`, the implementation returns `1` when `D > 0` and `NaN` when the
series is empty or constant. For positive `h`, it is `NaN` when `h >= n` or
`D = 0`. The Ljung--Box statistic for
`m = max_lag` is

```text
Q = n * (n + 2) * sum(h=1..m) rho_h^2 / (n - h)
```

It is `NaN` when `n <= m` or any required autocorrelation is undefined. The
p-value is the chi-squared survival probability `P(ChiSquare(m-model_df) >= Q)`;
`model_df < max_lag` is required. Durbin--Watson is

```text
DW = sum(i=1..n-1) (x_i - x_{i-1})^2 / sum(i=0..n-1) x_i^2
```

It is `NaN` when `n < 2` or its denominator is zero. The implementation uses
midpoint/range-scaled centered accumulation for ACF/Ljung--Box and max-absolute
scaling for Durbin--Watson, with Neumaier-compensated sums, to reduce avoidable
rounding error. Results are numerically equivalent within a documented
tolerance, not promised bitwise identical across all floating-point paths.

## Rejected alternative

A compact range/interval state retaining only prefixes, suffixes, or `keys ×
lag` samples is a rejected negative result for production. It requires ordered,
contiguous partial ranges and cannot support arbitrary interleaving merges
without retaining the full history. It may remain as a benchmark/prototype
baseline, but no compact-range function is registered or promised.
