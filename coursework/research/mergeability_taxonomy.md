# Mergeability taxonomy and negative results (coursework note)

This note uses **exact mergeability** in the algebraic sense.  A partial state is
computed for each input block and a merge operator combines partial states to
produce the same answer as one pass over the complete relation/sequence.  The
state may be larger than a machine word (for example, a map or a `p x p`
matrix), but a claimed fixed-size state must not grow with the number of rows
or distinct keys.  Approximate sketches and a second global sort are recorded
as useful engineering alternatives, but are not exact finite-state solutions.

For unordered data, the desired law is a commutative monoid homomorphism:

```
    s(empty) = e,       s(A union B) = s(A) op s(B),
    op(op(a,b),c) = op(a,op(b,c)),   op(a,b) = op(b,a).
```

For an ordered sequence, replace union by concatenation.  The operator then
needs only be associative, not commutative, and the physical merge must know
whether `A` precedes `B`.  This distinction is decisive for distributed SQL:
ordinary aggregation can merge unordered blocks in arbitrary order; it cannot
silently reconstruct a sequence.

## Classification at a glance

| Coursework family | Exact state that can be merged | Dependence on state size | ClickHouse suitability |
|---|---|---:|---|
| Commutative sufficient statistics | Fixed tuple of additive statistics | Fixed for fixed model dimension | Excellent (`sum`, `count`, states with `-Merge`) |
| Finite-boundary ordered states | At most `k` extrema/boundary records, with deterministic tie rule | `O(k)`; exact only for fixed `k` | Good as a bounded custom aggregate; order key must be explicit |
| Explicit-key disjoint ranges | Map from key to mergeable local state; disjoint maps union | `O(number of keys)` | Good for `GROUP BY`; not a fixed-size global aggregate |
| Prefix algebra | Associative boundary summary, often non-commutative | Fixed for a finite automaton/statistic; otherwise grows | Conditional; requires ordered blocks and stable keys |
| Matrix statistics | Additive matrices/vectors, then derive estimator | `O(p^2)` for fixed `p` | Good for fixed `p`; custom/state aggregate and numerical care |
| Recursive latent states | A transition/filter object, or the whole history | Usually grows with history; special linear cases are exceptions | Poor for exact arbitrary block merges |
| Ranks/global sort | Full order statistics or a sketch | Exact state generally `Omega(n)` | Exact global order is a final sort; sketches are mergeable/approximate |
| ARMA/iterative fitting | Objective/gradient only for a fixed parameter; fitted optimum is not a merge state | Optimization/history dependent | Poor as one aggregate; fit outside ClickHouse or export sufficient data |
| Exact change-point DP (`O(n)`) | DP frontier and cross-boundary candidates | `Omega(n)` in general | Not an algebraic aggregate; use batch/external algorithm |

The lower bounds below assume an unrestricted value domain and arbitrary block
boundaries.  A bounded domain, a fixed maximum input length, or a user-supplied
partition order can change a negative result; those assumptions must be stated
instead of being hidden in the implementation.

## 1. Commutative sufficient statistics: the positive baseline

If a likelihood or estimator has a finite-dimensional sufficient statistic,
and that statistic is additive over independent rows, it is exactly mergeable.
For example, for a scalar normal model one may store

`(n, S1 = sum(x), S2 = sum(x^2))`.

The merge is component-wise addition, and the mean/variance are computed only
after the final merge.  The same idea covers counts by category (with a map if
the category set is not fixed), contingency tables, and fixed-dimensional
linear-model statistics `(X'X, X'y, y'y)`.  Commutativity means a distributed
engine may repartition rows without changing the exact mathematical answer.

This is a sufficient condition, not a claim that every statistic named
“sufficient” is small.  A histogram with an unbounded set of values is a
mergeable map but not a fixed-size state.  Also, a numerically stable reducer
should specify the arithmetic model: floating-point addition is not literally
associative.  Pairwise/Kahan-style states improve reproducibility but do not
make ordinary IEEE addition associative.

**ClickHouse implication.** Built-in aggregate states and `-State`/`-Merge`
combinators are a natural fit.  Keep raw additive state in materialized views
and derive ratios, variances, or model coefficients at query time.  Do not
claim exact reproducibility across arbitrary merge trees unless the numeric
representation and merge order are controlled.

## 2. Finite-boundary ordered states

An ordered statistic can still be mergeable when the requested answer depends
on only a fixed number of boundaries.  For a fixed `k`, store the `k` smallest
records (or the `k` largest) under a total order `(value, unique_id)`.  The
merge is “take the `k` best from the union of both stored lists”; items outside
either local boundary cannot enter the global top-`k`.  This operation is
associative and idempotent with respect to the retained candidates, so it is an
exact `O(k)` state for fixed `k`.  The same argument applies to first/last `k`
records when a total ordering key is available.

The boundary must be finite and specified in advance.  Exact median, exact
95th percentile, or “return all rows below the globally computed threshold”
does **not** have this property: the number of values that may straddle the
unknown boundary grows with input size.  A quantile sketch can summarize the
boundary approximately, and a bounded-domain histogram can be exact, but both
are different assumptions/results.

**Counterargument to a common mistake.** Keeping the local median of each
block is insufficient: two blocks of unequal sizes can have the same local
median but different numbers of values on either side, changing the global
median.  Retaining `k` values around each local median does not fix this for an
arbitrary number of blocks unless `k` grows with the number of blocks.

**ClickHouse implication.** A bounded top-`k` UDAF is suitable if ties use a
stable key and the state has a documented size bound.  `quantileExact`-style
solutions that retain all samples are mergeable operationally but have
state/memory `O(n)`, so they belong in the “holistic/exact sort” class, not the
fixed-state class.  Approximate quantile functions are valid only when their
error guarantee is acceptable.

## 3. Explicit-key disjoint ranges

Suppose each row has an explicit key and each block owns a disjoint key range.
For each key `u`, compute a local state `q_u` (for example a count or a normal
sufficient statistic).  The global state is a finite-support map

`Q : u -> q_u`,

and disjoint maps merge by key-wise union.  If ranges overlap, the same key’s
states merge with the local operator rather than being concatenated.  If the
task requires one output per key, this is exact and easy to parallelize;
“disjoint” only removes duplicate-key conflict handling.

This is not a constant-size summary when the number of distinct keys is
unbounded.  A lower bound is immediate: after seeing `m` keys, changing the
value associated with any one key can change the required answer for that key;
there are therefore at least as many distinguishable states as possible key
maps (and at least `m` pieces of information in the simplest count example).
No fixed tuple independent of `m` can answer all key queries exactly.

**ClickHouse implication.** `GROUP BY key` plus mergeable per-key aggregates is
the intended execution model, and partition pruning helps when key ranges are
explicit.  Treat the map cardinality as a resource bound, not as a fixed-size
algebraic statistic.  A query needing a single global answer over all keys
cannot assume disjoint ranges unless the partition metadata enforces it.

## 4. Prefix algebra

Some sequence-dependent quantities have a small composable boundary summary.
For a sequence `A`, let `tot(A)` be its total and `pref(A)` its maximum prefix
sum (including the empty prefix).  For concatenation `AB`,

`tot(AB) = tot(A) + tot(B)`

and

`pref(AB) = max(pref(A), tot(A) + pref(B))`.

Thus `(tot, pref)` is an associative, generally non-commutative summary.  A
finite automaton gives the same pattern: summarize a block by the state
transition it induces; compose transitions when blocks are in order.  Run
length summaries with first/last symbols and boundary run lengths are another
finite-boundary example.

The negative result is equally important: asking for **every** prefix value,
the exact prefix at an arbitrary rank, or a sequence of all prefix locations
requires retaining a vector whose length is the block length.  A first/last
value and a total cannot reconstruct the interior.  Moreover, because the
operator is non-commutative, an arbitrary distributed merge tree is invalid
unless each child carries an order interval and the parent composes intervals
in that order.

**ClickHouse implication.** Prefix summaries are viable only with an explicit
monotone sequence key and a merge plan that preserves interval order.  Ordinary
`groupArray`/partial aggregation should not be treated as an ordered monoid;
materialize sorted blocks or use window functions for the final ordered pass.
For a finite automaton, a custom state can work; for all prefix outputs, use a
sorted/window or external sequence algorithm.

## 5. Matrix statistics

For fixed predictor dimension `p`, matrix-valued sufficient statistics are still
finite-dimensional and additive.  In least squares, each row contributes

`G_i = x_i x_i^T`, `h_i = x_i y_i`, and `r_i = y_i^2`.

Merge by matrix/vector addition and compute `beta = G^{-1} h` only once at the
end.  Covariance and Gaussian graphical-model statistics have the same shape.
The inverse, determinant, rank, or Cholesky factor is a **derived** quantity;
merging locally inverted matrices is generally wrong because
`(G1+G2)^(-1) != G1^(-1)+G2^(-1)`.

The state is `O(p^2)`, so the result is fixed-size only when `p` is fixed.  If
columns are data-dependent or `p` grows with rows, the matrix itself is an
unbounded state.  Floating-point conditioning matters: summing normal
equations can be unstable for ill-conditioned designs; a mergeable QR-like
state or higher precision may be required for a numerical, rather than purely
algebraic, guarantee.

**ClickHouse implication.** This is suitable for fixed-schema analytics with
arrays/tuples or a custom aggregate state.  Store additive matrices, not a
locally solved coefficient vector.  Expect more implementation and testing
than scalar aggregates, particularly around serialization, dimension checks,
and deterministic numeric reduction.

## 6. Recursive latent states

Filtering a latent process usually has an update of the form

`z_t = F(z_{t-1}, x_t)`;

the result for a suffix depends on the posterior/latent state at the exact
boundary.  A block can be summarized by the function it induces on *every*
possible incoming state.  For a finite-state deterministic automaton that
function is a finite transition table, so it falls under prefix algebra.  For a
linear Gaussian state-space model, a block can sometimes be represented by
finite-dimensional information-form matrices, but these matrices may also
need boundary observations, process noise, and a carefully defined likelihood
semantics.

For general HMM filtering, nonlinear state-space models, particle filters, or
posterior paths, the induced function/distribution is not representable by a
fixed finite tuple.  Two prefixes can have equal mean/variance (or equal
chosen moments) while producing different posterior predictions for a suffix;
the suffix distinguishes them.  Therefore “merge local filtered states” is not
an exact operation unless the model explicitly proves closure of the chosen
state family.

**ClickHouse implication.** Recursive inference belongs in an ordered pipeline
or an external model job.  A custom aggregate is defensible only after proving
that the block state is a closed transition object and that blocks are composed
in sequence order.  A local final latent estimate is not a mergeable partial
state.

## 7. Ranks and global sort: an information lower bound

For a sequence/multiset of `n` distinct values, exact sorted order has `n!`
possibilities.  Any summary that can answer arbitrary rank queries must
distinguish those possibilities (at least `log2(n!) = Omega(n log n)` bits in
the worst case); even a single exact median over an unrestricted domain needs
state that grows with `n`.

A simple indistinguishability proof for median is useful.  Assume a bounded
summary has two different prefixes `A` and `B` with the same state.  Choose a
suffix containing values between their differing order statistics and enough
extreme sentinels to make the global median depend on that difference.  The
merge routine sees the same state for `A` and `B` and the same suffix state, so
it must return the same result, contradicting exactness.  As `n` grows, such a
pair is unavoidable by the pigeonhole principle.

Fixed top-`k` is the finite-boundary exception above.  Approximate rank/quantile
sketches (t-digest, KLL, histogram) are mergeable because they relax exactness.

**ClickHouse implication.** Use `ORDER BY`/distributed sort when exact global
ordering is required; expect `O(n log n)` work and shuffle/storage costs.  Use a
mergeable sketch only with an explicit error contract.  A `GROUP BY` aggregate
cannot produce an exact globally ranked list with bounded state.

## 8. ARMA and iterative fitting

An optimizer’s final parameter vector is not a sufficient statistic for another
optimizer.  Two blocks can have the same local ARMA estimate but different
likelihood surfaces, sample sizes, and boundary innovations; there is no
operation that combines the two estimates to obtain the optimum of the union.
For ARMA, innovations are recursive and depend on the preceding latent errors,
so splitting at an arbitrary boundary changes the conditional likelihood.

For a *fixed* parameter value, a conditional Gaussian log-likelihood is a sum
of per-time contributions and can be evaluated blockwise if the required
initial/boundary state is supplied.  That does not make the maximization
mergeable: exact fitting requires the whole objective as a function of the
parameters, or an equivalent sufficient representation.  For generic ARMA
models this function is not a fixed finite-dimensional additive statistic.
Gradient/Hessian batches can support an approximate distributed optimizer, but
the answer depends on iteration order, line searches, initialization, and
stopping tolerance.

**ClickHouse implication.** Store/stream observations and fit in a time-series
or statistical engine.  ClickHouse can precompute fixed lag cross-products or
serve batches, but should not be presented as an exact ARMA fitting aggregate.
If an iterative UDAF is used, label it an algorithmic approximation and record
parameter initialization and convergence settings.

## 9. Exact change-point dynamic programming (`O(n)` frontier)

For a segmentation objective, a typical recurrence is

`D[t,k] = min_{s < t} {D[s,k-1] + C(s,t)}`,

where `t` is a time index, `k` the number of segments, and `C(s,t)` the segment
cost.  After a block ends at `b`, a segment may start before `b` and end after
`b`; its cost and the best predecessor depend on every relevant candidate `s`.
Consequently an exact block summary must retain a frontier indexed by
candidate start/time (and often by `k`), which is `Omega(n)` in general.

The same conclusion follows by adversarial costs: for each candidate `s`, a
future suffix can be chosen so that only `s` yields the optimal cross-boundary
segment.  A summary that discards `s` cannot answer all possible suffixes.
Additive prefix sums make one particular `C(s,t)` cheap to evaluate, but they
do not remove the need to compare all candidate starts.  Special assumptions
(bounded number of change points, a proven Monge/convex cost, or a restricted
window) can yield subquadratic or bounded-interface algorithms; those are
additional theorems, not generic mergeability.

**ClickHouse implication.** Exact change-point DP is a batch/window/external
algorithm, not a commutative aggregate.  ClickHouse may provide ordered input,
prefix features, and candidate data, but a final DP should run in a procedure
that owns the full sequence (or an algorithm with a proved restricted
frontier).  Storing one DP state per row in an `AggregatingMergeTree` does not
make the recurrence mergeable.

## Practical decision rule

Before implementing a `-State`/`-Merge` aggregate, write the required law
`state(A concat B) = merge(state(A), state(B))` (or the commutative analogue)
and specify the order/tie/precision semantics.  Then ask:

1. Is the state a fixed-dimensional additive statistic or a closed finite
   transition object?  If yes, implement and prove associativity.
2. Is it a fixed number of order boundaries or an explicitly bounded key map?
   If yes, document the bound and key/order assumptions.
3. Does the answer need all ranks, all prefixes, latent history, iterative
   optima, or every DP candidate?  If yes, expect an unbounded state and use a
   sort, window, sketch, or external batch algorithm.

This separates an algebraic merge guarantee from an implementation that merely
happens to combine partial results on one particular query plan.
