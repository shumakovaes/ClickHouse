# Mergeability and state contracts

## Exact keyed state

`timeSeriesLaggedLinearRegression`, `timeSeriesADFStatistic`,
`timeSeriesKPSSTest`, and `timeSeriesMeanShiftChangePoint` all use the same
lossless keyed state as the baseline diagnostics. It retains every finite
`(timestamp, Float64 value)` row in `O(n)` space, plus a version and function
configuration. It is deliberately not a compact range monoid: boundaries
alone cannot recover positional lag pairs or interior change-point candidates
after arbitrary interleaving.

The configured `max_samples` is positive, defaults to 1,000,000, and cannot
exceed 10,000,000. A cap violation is an error. Nullable rows are skipped by
the standard ClickHouse combinator; non-finite values and duplicate keys are
rejected.

## Add, canonicalization, and merge

`add(S, timestamp, value)` appends in arrival order and records whether the
vector is out of order. Canonicalization sorts by timestamp and validates
strictly increasing keys. It occurs before finalization, merge, and
serialization, so all four extensions see one canonical positional series.

`merge(S1, S2)` requires matching extension kind, parameters, state version,
and `max_samples`. It canonicalizes each input, then uses a two-pointer
linear merge. Equal timestamps are a duplicate-key error, including when the
duplicate is split between states; no arrival-order tie break exists. The
empty state is the identity and the merged count must remain within the cap.

For disjoint key sets, this operation is semantically commutative and
associative: every valid merge tree yields the same strictly increasing keyed
record vector. That makes arbitrary block, shard, retry, and persisted-state
interleavings safe. Final floating-point reductions are deterministic in their
canonical input order but are not promised bitwise identical across different
execution paths; comparisons use the documented numerical tolerance. A
duplicate or malformed state must fail regardless of merge-tree shape.

Serialized state has a versioned extension envelope followed by the versioned
canonical keyed payload. Deserialization validates the expected kind and
parameters, cap, count, finite values, and strict key order before accepting
bytes. A version or parameter mismatch is incompatible, not a request to
reinterpret the payload.

## Positional semantics and finalizers

Timestamp order supplies only a canonical ordering key. Once sorted, all
lags, ADF differences and trend, KPSS trend and residual path, and
change-point splits use consecutive positions `0..n-1`; numeric timestamp
gaps are ignored. This is equal spacing in the positional model, not a claim
that elapsed time is equally spaced. Resample first when elapsed-time spacing
is required.

The four finalizers have these merge-safe boundaries:

| Extension | Finalization and undefined-result policy |
|---|---|
| `timeSeriesLaggedLinearRegression` | Fixed positional order `1..16`; centered/scaled Givens QR. Insufficient, rank-deficient, ill-conditioned, non-finite, or over-budget fits return NaN fields. |
| `timeSeriesADFStatistic` | Fixed augmentation lag `0..16` and `none`/`constant`/`trend`; returns coefficient, t-statistic, and usable observation count, but no p-value or autolag. |
| `timeSeriesKPSSTest` | `level`/`trend`; explicit or function-local Bartlett bandwidth, bounded at 1024; returns statistic, chosen bandwidth, and `n`, but no p-value. |
| `timeSeriesMeanShiftChangePoint` | One positional split, `O(n)` scan with transient suffix states; descriptive relative SSE score, earliest numerically tied split, and zero/NaNs when no improvement is identifiable. |

## Complexity

For `n` retained records, state memory and serialization are `O(n)`.
Appending is amortized `O(1)`. Sorting an out-of-order state costs
`O(n log n)`; merging canonical states costs `O(n1 + n2)` time and temporary
space. Lagged regression and ADF finalization additionally perform bounded
small-matrix QR work. KPSS finalization is `O(n * bandwidth)` with an
explicit checked work limit. Mean-shift finalization is `O(n)` time and
`O(n)` transient suffix memory.

## Compact ordered-range state: ADR-002 NO-GO

The compact state is not an alternative implementation of this merge
contract. It is a NO-GO for an ordinary `IAggregateFunction`, because a
generic reducer may merge disjoint ranges before a later range fills the
interior (`1, 3, 2`). Rejecting that particular pair is not sufficient: a
valid complete input could fail solely because the engine selected that merge
tree.

Compact state is acceptable only as a planner/operator-owned feature with a
provable contiguous canonical range contract: every child must own a dense
interval, the coordinator must merge only adjacent intervals in canonical
order, and the same guarantee must hold for remote, retry, spill, two-level,
and persisted paths. Until such an operator exists, do not expose compact
`-State`/`-Merge` behavior or `AggregatingMergeTree` semantics. The exact
keyed store-and-sort state is the only ordinary aggregate contract.
