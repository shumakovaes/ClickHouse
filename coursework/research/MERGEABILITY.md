# Mergeability and state contracts

## Production state

All three supported functions use the same exact store-sort keyed state. A
state retains every accepted `(key, Float64 value)` sample, plus serialization
version and `max_samples`; it canonicalizes by key before finalization, merge,
or serialization. The state size is `O(n)` records for `n` samples. This is
deliberately not a compact range monoid: retaining only boundaries cannot
reproduce lagged pairs for arbitrary interleavings.

## Add, merge, finalize

`add(S, key, value)` rejects non-finite values, duplicate keys, invalid
parameters, and a count that would exceed `max_samples`. The current
implementation appends records in `O(1)` amortized time and pays `O(n log n)`
to canonicalize an out-of-order state; the observable result is independent of
arrival order.

`merge(S1, S2)` requires matching function parameters, format/version, and
`max_samples`. The two sorted vectors are merged in `O(n1+n2)` time and space;
an equal key is rejected, including a duplicate split across states. Thus
`merge` is commutative and associative as a semantic operation, with the usual
floating-point tolerance caveat. `merge(S, empty) = S`.

`finalize(S)` scans the canonical key order. The formulas are:

```text
rho_h = sum(i=h..n-1) (x_i-mean)(x_{i-h}-mean) / sum(i=0..n-1)(x_i-mean)^2
Q     = n(n+2) * sum(h=1..max_lag) rho_h^2/(n-h)
DW    = sum(i=1..n-1)(x_i-x_{i-1})^2 / sum(i=0..n-1)x_i^2
```

`timeSeriesAutocorrelation(0)` returns `1` for a non-constant series and `NaN`
for an empty or constant series. `timeSeriesLjungBoxTest` returns `(Q,
chi-square survival probability)` with
`max_lag-model_df` degrees of freedom. Undefined cases return `NaN` as stated
in `DESIGN.md`.

## Complexity

For `n` retained samples and `H = max_lag`, state memory and serialization are
`O(n)`. The implementation appends in `O(1)` amortized time and sorts an
out-of-order state in `O(n log n)` when canonicalization is required; two-state
merge is `O(n1+n2)` time and temporary space. Durbin--Watson and one
autocorrelation finalize in `O(n)`. Ljung--Box finalize is `O(nH)` in the
implementation because each requested lag is evaluated from the stored samples.

## State compatibility and wire safety

Serialized state starts with an explicit format version and carries
`max_samples`, count, then records. Deserialization must check version, cap,
count, finite values, and strictly increasing keys before allocation. A state
whose serialized `max_samples` differs from the receiving function's parameter
is incompatible and must fail; bytes must never be silently reinterpreted.

## Rejected compact range result

The compact range state is retained only as a rejected negative result. It can
be correct for pre-ordered adjacent ranges with a carefully specified boundary
policy, but it is not correct for arbitrary input or merge order. It is not part
of the production API, registration, or coverage pass.
