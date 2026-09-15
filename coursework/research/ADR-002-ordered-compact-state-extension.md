# ADR-002: Ordered compact-state extension must not be an ordinary aggregate

- Status: Accepted for this continuation
- Scope: exact lag-sensitive time-series diagnostics over one explicitly keyed,
  dense series
- Decision: do not register a compact SQL aggregate. Retain the compact state
  as an ordered-range prototype; promote it only with a specialized
  planner/operator contract that proves every merge is between adjacent ranges.

## Context

The compact prototype stores a bounded lag summary and `O(L)` prefix/suffix
samples for a configured maximum lag `L`. It is exact for a dense, ordered
interval and for concatenating two adjacent intervals. It is not an exact
summary of an arbitrary set of disjoint intervals.

The existing production diagnostics aggregate deliberately has the other
contract: it retains every `(key, value)` sample, canonicalizes by key, and
can merge arbitrary interleaved partial states. That `O(n)` store-and-sort
design is suitable for ordinary ClickHouse aggregation. The compact state is
not a replacement for it.

## Decision and no-go result

An ordinary `IAggregateFunction` cannot enforce an end-to-end contiguous-range
guarantee. Its `merge(place, rhs, arena)` interface receives two states, but no
proof that they are consecutive pieces of the final series, no information
about unmerged future ranges, and no authority to constrain the reducer's
merge tree.

The implementation can validate a particular pair and reject a non-adjacent
merge. That does not make it a valid ordinary aggregate: normal aggregation,
distributed execution, spill/two-level aggregation, `-State`/`-Merge`, and
persisted aggregate states can combine partial states in an arbitrary binary
tree. A valid complete series could therefore fail merely because the engine
combined two non-adjacent leaves first.

The aggregate property `is_order_dependent` is insufficient. It communicates
that a result depends on row order to selected planner optimizations; it does
not provide an ordered-state merge API or prohibit generic aggregate-state
merges. Likewise, an `AggregatingMergeTree` merge groups equal sorting keys;
it does not prove that the time ranges inside the aggregate states are
adjacent.

**No compact SQL aggregate is registered in this continuation.** In
particular, there is no compact `AggregateFunction` implementation, no
`-State`/`-Merge` combinator surface, and no `AggregatingMergeTree` storage
contract for this design.

## Exact state contract

Let a nonempty state represent one series `s` on the closed discrete interval
`I = [lo, hi]`, with configured lag bound `L` and fixed successor/grid step
`d`. Its observations are finite real values `x_k` at every valid grid key.
The state carries its format version, series identity, configuration, interval,
overall centered moment, per-lag bivariate moments, and endpoint buffers.

The following are invariants, not best-effort checks:

1. Empty is canonical and is the only identity. A nonempty state has a single
   series identity and configuration `(format version, L, grid step, gap and
   numerical-origin policy)`.
2. The range is dense: `n = successorDistance(lo, hi) + 1`; successor and
   distance arithmetic are checked for overflow. Every pair of successive
   keys differs by exactly `d`.
3. There is exactly one finite value per grid key. Duplicate keys, missing
   keys, non-finite values, and a merge across a logical-series boundary are
   errors.
4. The overall centered state represents all `n` observations. For every
   `1 <= h <= L`, the lag state represents exactly `max(n - h, 0)` ordered
   pairs `(x_k, x_(k+h))`.
5. The prefix and suffix each hold exactly `min(L, n)` consecutive keyed
   samples. The prefix starts at `lo`, the suffix ends at `hi`, and overlapping
   buffer entries agree.
6. A merge requires identical identity and configuration. For nonempty
   operands exactly one orientation must be adjacent:
   `hi_left + d = lo_right`. The implementation may swap reversed operands to
   this canonical orientation, but rejects gaps, overlaps, and merely disjoint
   ranges.

An append is legal only at the immediate successor of `hi`. It updates every
lag summary with the new cross-boundary pairs available from the suffix, then
updates the bounded endpoint buffers.

## Why disjoint envelopes are not closed: `1, 3, 2`

Consider singleton partial states at keys `1`, `3`, and `2`. The reducer may
legally call the ordinary aggregate merge on `[1,1]` and `[3,3]` first. A
bounded state reduced to the outer envelope `[1,3]` has lost whether its
interior is dense, and it cannot correctly process `[2,2]` later.

For a first-lag transition sum, the complete series requires
`v_1*v_2 + v_2*v_3`. The two-row input with keys `1` and `3` has neither of
those valid adjacent pairs. Boundary-only data cannot decide, once key `2`
arrives, whether to insert two pairs, replace an assumed `1 -> 3` pair, or do
nothing. Any choice fails for some values. Retaining a list of all unresolved
holes/ranges avoids the loss, but grows to `Omega(n)` in the worst case and is
the store-and-sort design in another form.

## Correctness outline under an ordered operator

For adjacent intervals `A` then `B`, every lag pair in their concatenation is
in exactly one of: the pairs internal to `A`, the cross-boundary pairs, or the
pairs internal to `B`. The cross-boundary values are available in the suffix
of `A` and prefix of `B` because their distance is at most `L`. Combining the
three disjoint pair summaries gives the defining lag summary of `A || B`; the
same decomposition holds for the overall moment and endpoint buffers.

Thus, in exact arithmetic, `mergeAdjacent(S(A), S(B)) = S(A || B)`. Induction
over any binary tree whose children are adjacent intervals proves equivalence
to a direct ordered scan. Reversed arguments are harmless only because the
operator first establishes and uses the canonical left/right orientation.
Floating-point results remain tolerance-equivalent rather than bitwise equal
across different legal tree shapes unless the operator fixes its reduction
tree.

The missing proof for an ordinary aggregate is precisely the routing premise:
that every internal node joins adjacent intervals. State validation cannot
supply that premise after a generic reducer has selected its children.

## Strongest safe deliverable now

Keep the compact design as a standalone, explicitly ordered range prototype.
Its API may expose only operations equivalent to:

```text
appendSuccessor(key, value)
mergeAdjacent(left, right)
finalize()
```

It must validate the state contract above and must not expose generic state
serialization/merge as a ClickHouse aggregate. A non-aggregate operation over
one supplied, already ordered dense array or one verified ordered stream is
also acceptable, because it does not claim parallel aggregate-state closure.

The current standalone C++ comparison and benchmark artifacts are the
appropriate home for this deliverable. They document an educational/reference
implementation and its bounded-state costs; they are not evidence that a
normal ClickHouse query plan supplies the required order.

## Requirements for a future engine feature

A production compact feature requires a new order-aware query-plan operator,
not an implementation of `IAggregateFunction`. Its contract must establish:

1. A total order `(series_id, key)` and a fixed discrete grid/step per series,
   with duplicate-key and missing-key rejection.
2. A full sort or an equivalent proven ordered source before compact-state
   construction.
3. A single ordered consumer per series, or range partitioning that records
   exact interval ownership and a coordinator that merges only adjacent
   intervals.
4. The same restriction at remote gathers, retries, spills, two-level paths,
   parallel replicas, and finalization. Retry semantics require a documented
   exact-once identity or an explicit duplicate-rejection policy.
5. No generic `-State`/`-Merge` escape hatch and no use in
   `AggregatingMergeTree` until those subsystems carry and enforce the same
   range-routing contract.
6. A versioned internal representation only if it crosses an operator-owned
   exchange; deserialization must validate all range, count, buffer, finite
   value, and configuration invariants before allocation or merge.

Candidate implementation targets for that separate feature are a new
`OrderedContiguousRangeStep` under `src/Processors/QueryPlan/`, a matching
transform under `src/Processors/Transforms/`, and explicit integration with
the existing sorting/gather pipeline. No changes to aggregate registration are
authorized by this ADR.

## Required tests

- Compare singleton append, every two-way split, and all small
  adjacency-respecting merge trees against a direct ordered oracle.
- Verify reversed adjacent inputs canonicalize to the same result.
- Reject gaps, overlaps, duplicates, wrong series/configuration/version,
  non-finite values, malformed endpoint buffers or lag counts, and key
  successor overflow.
- Exercise lengths below, equal to, and above `L`; empty states, constant
  values, large common offsets, and extreme finite scales.
- Use the `1,3,2` schedule and randomized arbitrary merge schedules as
  negative tests: generic compact merging must reject rather than manufacture
  an answer.
- For an eventual operator, assert its planned pipeline contains the required
  global ordered merge and no generic aggregate-state reducer. Test local,
  remote, retry, and range-partitioned execution, including invalid shard
  boundaries.
- Compare operator outputs to the exact store-and-sort state using documented
  scale-aware numerical tolerances.

## Benchmark rules

Benchmark compact state only on inputs partitioned into ordered contiguous
ranges and report that precondition beside every timing and state-size result.
Benchmark the exact store-and-sort state separately on arbitrary row order and
interleaved partitions. Do not compare compact timings with arbitrary-plan
results as though they had the same semantic contract. The compact state is
`O(L)` per represented series/range; unresolved-range retention needed for an
arbitrary merge plan is not bounded this way.

## Promotion and stopping criteria

Promote from prototype only when all of these are true:

1. The planner/operator routing invariant is specified and proved for every
   supported execution path.
2. The required plan, adversarial scheduling, distributed, persistence, and
   numerical tests pass.
3. The SQL surface makes its dense-grid and ordered-execution semantics
   explicit and offers no generic aggregate-state escape path.
4. Benchmark results demonstrate a material benefit under the same validated
   contract, not merely on a favorable local merge order.

Stop at the prototype (and retain the existing store-and-sort aggregate) if
any path can still invoke generic `IAggregateFunction::merge` on arbitrary
partial ranges, if range ownership cannot be proved through a remote/persisted
boundary, or if product scope requires ordinary `-State`/`-Merge` or
`AggregatingMergeTree` compatibility. In those cases exact compactness and
ordinary ClickHouse aggregate semantics are incompatible.
