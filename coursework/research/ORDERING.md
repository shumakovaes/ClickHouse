# Ordering semantics

## One semantic order and three execution orders

The aggregate receives `(key, value)` pairs. Key order is the only temporal
order: finalization sorts/canonicalizes by key. Arrival order (rows within a
block), block/part order, and merge order (including distributed merge-tree
shape) are execution details and must not change a result except for documented
floating-point tolerance.

The SQL grouping key identifies the series. It is not inferred from physical
part order, and no implicit `range_key` or contiguous-range assumption exists
in the production contract.

## Required guarantees

- Arbitrary row and block permutations produce the same canonical state and
  statistic.
- Arbitrary state interleaving and merge-tree parenthesization produce the same
  result within tolerance.
- Keys are strictly unique. An equal key in one input or across two states is a
  hard duplicate-key error; the implementation never chooses a value by
  arrival order.
- Rows with `NULL` in either argument are skipped by ClickHouse's nullable
  aggregate handling. NaN and infinity are rejected, as are invalid parameters
  and `max_samples` overflow.
- Equal timestamps are therefore not tie-broken: if two observations have the
  same key, the query must deduplicate before aggregation or fail.

## Adversarial ordering matrix

Coverage must compare a sorted baseline with reversed and randomized rows,
different block sizes, every small merge-tree parenthesization, interleaved
partial states, and distributed/shard permutations. Each case compares both
the final value and the expected validation error. The reference result is
computed from the sorted unique key/value set.

## Complexity and non-guarantees

For `n` retained records, state memory is `O(n)`. Sorted-vector add is `O(n)`
worst case after `O(log n)` lookup; two-state merge is `O(n1+n2)`; finalization
is `O(n)` after canonicalization (or `O(n log n)` if a buffered state sorts at
finalize). A compact `O(keys × lag)` range state is explicitly rejected because
it cannot honor these arbitrary-order guarantees. Ordinary floating-point
execution is not promised bitwise identical.
