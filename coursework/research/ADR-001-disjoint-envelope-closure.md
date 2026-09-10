# ADR-001: Do not use a disjoint-range envelope as an ordinary aggregate state

- Status: Accepted for the coursework design
- Scope: exact ordered/lag-sensitive statistics over rows carrying an explicit
  key (for example `series_id, timestamp`)
- Decision: under normal ClickHouse aggregate semantics, use an exact
  store-and-sort state (`O(n)` retained rows) unless the input contract moves
  lag computation upstream or the planner supplies an order-preserving merge
  contract.

## Context

The proposed compact state is an **envelope**: a summary labelled by a key
range `[lo, hi]`, with enough payload at its boundaries to continue an ordered
or recursive computation.  The intended merge rule is valid when two states
are known to be adjacent and ordered (`hi_left <= lo_right`, with an explicit
tie rule).  The tempting extension is to allow any two disjoint ranges to be
merged first and to retain only their outer envelope `[min(lo), max(hi)]`.

That extension is not closed under arbitrary merge trees.  ClickHouse's normal
distributed aggregation may build partial states per block/shard, combine them
in different binary trees, and merge persisted states later.  A custom state
must therefore be associative for the merge plans the engine is allowed to
choose; it cannot rely on the physical order in which rows happened to arrive.

## Decision

Do not advertise the envelope as a fixed-size `-State`/`-Merge` aggregate for
exact ordered or lag-sensitive output.  Choose one of these explicit designs:

1. **Default exact design — store and sort.** Store the keyed records (or a
   lossless encoded equivalent) in the state.  Merge is multiset union, hence
   associative and commutative.  At finalization, sort by the canonical key and
   run the ordered/recursive computation.  The exact state is `O(n)` rows (and
   final work is at least the cost of sorting, normally `O(n log n)`).
2. **Precomputed-lag sufficient-statistics API.** Require the producer to
   compute lags against the canonical, already ordered full series and pass
   those lag columns as row data.  The aggregate then stores additive scalar,
   vector, or matrix statistics; merge is commutative and fixed-size for fixed
   lag order/model dimension.  This is a different API and must not be inferred
   from independently lagging arbitrary blocks.
3. **Planner-contract option.** Introduce a specialized ordered operator whose
   planner contract guarantees non-overlapping *adjacent* key intervals and an
   order-preserving merge tree.  The envelope can then be a non-commutative
   concatenation state.  This is valid only when every execution path, remote
   shard merge, and persisted-state merge honors the contract; it is not the
   semantics of an ordinary ClickHouse aggregate.

## Closure counterexample (`1, 3, 2`)

Consider three one-row partial states with keys `1`, `3`, and `2`, respectively.
Their individually valid envelopes are `[1,1]`, `[3,3]`, and `[2,2]`.  An
arbitrary merge tree may first combine the first two.  If the state is reduced
to one outer envelope, the result is `[1,3]`.  The state has now erased the
fact that key `2` is a hole and that no ordered interior payload was retained.
When `[2,2]` is merged next, there is no boundary-concatenation rule: key `2`
is interior to the stored envelope, not a right or left adjacent child.

This is not merely a cosmetic range problem.  Let each row also carry value
`v_k`, and let the requested statistic be the exact first-lag transition sum

`T = Σ_{consecutive keys (i,j)} v_i * v_j`.

For the rows with keys `1, 2, 3`, the answer is
`v_1 v_2 + v_2 v_3`; for the two-row set with keys `1, 3`, it is `v_1 v_3`.
An outer envelope `[1,3]` with only its two boundary payloads cannot represent
both the missing-interior and present-interior cases.  After the `2` state
arrives, it cannot know whether to insert a new interior transition, replace a
previously assumed `1 -> 3` adjacency, or do neither.  Any rule that guesses
must fail on one assignment of `(v_1,v_2,v_3)`.

Equivalently, the intended operation is partial concatenation.  Concatenation
is defined for `A` followed by `B` only when the merge knows that every key in
`A` precedes every key in `B`.  The pair `(1),(3)` is disjoint but not evidence
that no future block belongs between them.  A binary tree that combines them
first has created a state for which the later ordered concatenation operation is
undefined.  Therefore the family of single-envelope states is not closed under
the arbitrary merge trees permitted to an ordinary aggregate.

One can avoid the information loss by retaining a set/list of every disjoint
subrange and its payload, or by retaining enough interior records to re-sort.
In the worst case this has one component per row and is `Omega(n)` state.  That
is precisely the store-and-sort design; calling it a “compact envelope” does
not change its asymptotic size.

## Why disjoint ranges alone do not repair the state

Disjointness is a set property, not an order-preservation guarantee.  A map
from key ranges to lossless payloads can be unioned commutatively, but if the
payload is later needed in key order, the map must retain all ranges and their
interior records (or an equivalent ordered index).  Collapsing disjoint ranges
to one min/max interval introduces false adjacency.  Collapsing them to a
finite number of boundaries fails when an arbitrary number of later keys can
fall into the omitted gaps.

The only fixed-size exceptions are tasks whose semantics do not inspect the
interior (for example `min`, `max`, or fixed top-`k`), or a model with a proven
finite transition object.  Exact lags, recursive innovations, all-prefix
outputs, ranks, and unconstrained change-point frontiers inspect interior order
and do not meet that exception.

## Alternative A: precomputed-lag sufficient-statistics API

For a fixed AR order `p`, define an upstream schema such as

`(series_id, t, y_t, lag_1, ..., lag_p, valid_lag_mask)`.

`lag_j` must be computed from the canonical complete series, not by sorting or
padding each physical block independently.  A row can then contribute, for
example, `X_t X_t^T`, `X_t y_t`, and `y_t^2`, where
`X_t=(lag_1,...,lag_p)`.  The aggregate sums these objects, and the final fit
operates on the merged matrix statistics.  State size is `O(p^2)` per group,
not `O(n)`, and arbitrary ClickHouse merge trees are safe under exact real
arithmetic (subject to the documented floating-point reduction policy).

The API must document boundary rows and missing-lag handling.  If the desired
likelihood includes a recursive innovation or a stationarity boundary term,
those terms must also be supplied in a proven additive form; merely exposing
lag columns does not make a generic ARMA optimizer mergeable.

## Alternative B: planner contract for ordered envelope merges

A specialized operator may retain a small envelope if it establishes all of the
following invariants:

1. Every input state covers a closed key interval and carries exact `lo`/`hi`.
2. Child intervals are non-overlapping and adjacent (or the gap semantics are
   explicitly represented) before they are combined.
3. The parent receives children in canonical key order and combines only
   `left || right`; it never first combines `[1,1]` with `[3,3]` when `[2,2]`
   may exist.
4. The same restrictions apply to distributed, retry, two-level, and
   persisted-state merges, with deterministic duplicate/tie handling.

This turns the state into an ordered, non-commutative algebra.  It may be a
reasonable engine extension, but it is an execution/planner guarantee rather
than a property of the aggregate state itself.  If any caller can invoke
`merge` outside the contract, the `1,3,2` failure returns.

## Consequences for ClickHouse

- Normal `GROUP BY` and `AggregatingMergeTree` workflows should use the
  lossless store-and-sort state for exact order-sensitive answers, accepting
  `O(n)` memory/storage and a final sort, or use the precomputed-lag API.
- A custom envelope UDAF is safe only when its documentation and deployment
  enforce Alternative B.  A local test that happens to merge `[1]`, `[2]`,
  `[3]` in order is not evidence of correctness.
- Fixed top-`k`, scalar/matrix sums, and per-key additive maps remain ordinary
  mergeable aggregates; this ADR concerns the stronger claim that a bounded
  envelope can recover arbitrary interior order or lags.
- Approximate sketches are another possible product decision, but they relax
  exactness and should be labelled with their error contract rather than used
  as a proof of envelope closure.

## Rejected alternatives

- **Assume arrival order is key order:** distributed blocks, retries, and
  background state merges invalidate this assumption.
- **Keep only min/max and first/last payloads:** the `1,3,2` example shows that
  future rows can land in the omitted interior.
- **Merge local fitted models or local lagged blocks:** local estimates and
  block-boundary lags are not sufficient statistics for the global ordered
  problem.
