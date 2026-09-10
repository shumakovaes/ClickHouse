# `timeSeriesGroupArray`: state and merge precedent

This note records the implementation pattern in the inspected ClickHouse
checkout (`outputs/ClickHouse`, HEAD
`4d7f75efa83c3d81dff96373ce9874e2864c4e23`, 2026-09-09). It is useful as a
precedent for a keyed aggregate that retains ordered `(timestamp, value)`
samples. The aggregate state itself is **per grouping key**: the outer
aggregation engine owns the hash table from SQL `GROUP BY` keys to aggregate
states; `AggregateFunctionTimeSeriesGroupArray::Data` does not contain an
internal key map.

## Source and documentation anchors

All paths are relative to
`C:/Users/79261/Documents/Codex/2026-09-10/re/outputs/ClickHouse`.

| Evidence | Exact path and lines |
|---|---|
| State representation, fast append, sort/merge/dedup | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.h:51-175` |
| Input dispatch, scalar/array forms, array-length checking | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.h:233-385` |
| Aggregate lifecycle, merge hook, serialization, deserialization, result | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.h:213-231, 422-529` |
| Accepted types, preview setting, creator validation, docs, registration | `src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.cpp:17-96, 99-170` |
| Global registration declaration/call | `src/AggregateFunctions/registerAggregateFunctions.cpp:104-107, 222-227` |
| Duplicate-value rule, including NaN | `src/AggregateFunctions/TimeSeries/timeseriesMaxValueForDuplicateTimestamp.h:11-22` |
| Generated/reference docs | `docs/reference/functions/aggregate-functions/timeSeriesGroupArray.mdx:11-42` |

Public reference: [ClickHouse `timeSeriesGroupArray` documentation](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesGroupArray).

Official source mirrors: [`AggregateFunctionTimeSeriesGroupArray.h`](https://github.com/ClickHouse/ClickHouse/blob/master/src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.h), [`AggregateFunctionTimeSeriesGroupArray.cpp`](https://github.com/ClickHouse/ClickHouse/blob/master/src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.cpp), [`timeseriesMaxValueForDuplicateTimestamp.h`](https://github.com/ClickHouse/ClickHouse/blob/master/src/AggregateFunctions/TimeSeries/timeseriesMaxValueForDuplicateTimestamp.h), and [`registerAggregateFunctions.cpp`](https://github.com/ClickHouse/ClickHouse/blob/master/src/AggregateFunctions/registerAggregateFunctions.cpp).

## Type and input contract

The factory supports three equivalent input shapes:

| SQL shape | Source evidence | Contract |
|---|---|---|
| `timeSeriesGroupArray(timestamp, value)` | `.cpp:81-95`; `.h:245-257` | One scalar sample per input row. |
| `timeSeriesGroupArray(timestamps, values)` | `.cpp:81-95`; `.h:348-384` | Both arguments are arrays; each row contributes a whole series. Selected rows must have equal timestamp/value array lengths (`.h:374-377`). |
| `timeSeriesGroupArray(samples)` | `.cpp:68-79`; `.h:337-347` | One `Array(Tuple(timestamp, value))` per row; the input type is also the result type, enabling `SimpleAggregateFunction` as documented in `.cpp:102-110`. |

Timestamp types are `UInt32`, `DateTime`, or `DateTime64`; array forms use the
corresponding nested type (`.cpp:30-41, 90-95`; docs `.mdx:34-38`). Internally
`DateTime`/`UInt32` use `TimestampType=UInt32`, while `DateTime64` uses
`TimestampType=DateTime64` (`.cpp:26-37`). Values are only `Float32` or `Float64`
(`.cpp:46-56`). The creator rejects mixed scalar/array arguments and any
parameter (`.cpp:66, 81-95`).

## State shape and complexity

The per-group state is:

```text
Data {
    PODArray<Element> elements;  // Element { timestamp, value }
    bool sorted = true;
}
```

This is `AggregateFunctionTimeSeriesGroupArray.h:51-68`. The element array uses
`PODArray<Element, 32, MixedAlignedArenaAllocator<alignof(Element), 4096>>`
(`.h:57-60`). The source comments state that small states stay in the
aggregation arena, while larger buffers use the general allocator so growth can
reclaim the previous buffer (`.h:57-60`).

| Operation | Behavior and asymptotic implication | Source |
|---|---|---|
| Add an in-order sample | If `timestamp > back.timestamp`, append; amortized O(1). `sorted` remains true. | `.h:70-84` |
| Add duplicate at current tail | If `timestamp == back.timestamp`, replace the value with the duplicate-timestamp max; O(1), no new element. | `.h:73-80` |
| Add an out-of-order sample | Append and set `sorted=false`; no insertion into the middle. Add remains amortized O(1), with deferred sorting. | `.h:73-84` |
| Sort/finalize | If dirty, sort by timestamp and compact duplicate runs. Sorting is O(n log n), compaction O(n); if already sorted it is a no-op. | `.h:137-174` |
| Merge sorted disjoint ranges | Sorts the left state if needed, then appends or prepends the right range; O(n+m) data movement/copying. | `.h:86-127` |
| Merge overlapping sorted ranges | Allocates `n+m`, `std::merge`s both ranges in O(n+m), then deduplicates in O(n+m), and swaps the result into the state. | `.h:129-135` |
| Merge with dirty right state | Copies the right state into an arena-backed temporary and sorts/deduplicates that copy first; O(m log m) for that sort plus merge cost. The source state stays intact. | `.h:101-110` |
| Emit result | Calls `Data::sort`, then writes one tuple per retained timestamp; O(n) after any deferred sort. | `.h:502-529` |

Therefore this is an O(n)-memory **append-and-deferred-sort** state, not an
online balanced tree or hash index by timestamp. The common ordered-ingest path
avoids per-row sorting; arbitrary arrival order pays at finalization or merge.
The aggregate keeps all retained samples until duplicate compaction; there is no
timestamp index and no per-state uniqueness map.

## Duplicate semantics

Equal timestamps collapse to one sample, retaining the numerically greatest
value. `timeseriesMaxValueForDuplicateTimestamp` treats a NaN as losing to a
non-NaN value; if both are NaN, the result remains NaN
(`timeseriesMaxValueForDuplicateTimestamp.h:11-22`). The rule is explicitly
described as associative and commutative, so arrival/merge order does not change
the selected value. In the state:

- tail duplicates are resolved immediately (`.h:73-80`);
- duplicates introduced by out-of-order ingestion are resolved by
  `sortElements` (`.h:151-174`);
- duplicates across partial aggregate states are resolved after `std::merge`
  (`.h:129-135`).

The comparator uses timestamp only (`.h:146-149`), so values do not affect sort
order; the max rule is applied by the subsequent linear compaction pass.

## Memory and cap semantics

There is **no user-visible max-size parameter**. The creator calls
`assertNoParameters` (`AggregateFunctionTimeSeriesGroupArray.cpp:66`), and
`Data` stores every sample until sorting removes duplicate timestamps. The
`reserveAdd`/`addMany` path only reserves capacity (`.h:239-243, 259-279`);
it is not a cap.

The only hard-looking number, `MAX_ELEMENTS_TO_RESERVE = 4096`, is a
deserialization safety bound, not a state-size bound (`.h:538-542`). A serialized
state claiming more than 4096 elements reserves only 4096 initially and then
grows as values are read (`.h:475-494`). Thus a valid large state can still
consume memory proportional to its element count. A coursework aggregate that
needs bounded memory must add and document its own cap/eviction policy rather
than infer one from this precedent.

## Merge, serialization, and compatibility

`mergeImpl` delegates to `Data::merge` (`.h:422-425`). The merge implementation
preserves the right-hand state, handles empty states, exploits disjoint ranges,
and uses a temporary for overlapping ranges (`.h:86-135`). This is the pattern
to copy for a mergeable state: maintain a cheap sortedness invariant, normalize
dirty partial states, and make duplicate resolution associative/commutative.

Serialization is canonical and versioned:

1. `serialize` writes `UInt16 FORMAT_VERSION` (currently `1`), then `size_t`
   element count, then all timestamps, then all values in little-endian order
   (`.h:445-456`).
2. If the state is dirty, serialization sorts/deduplicates a temporary copy so a
   `const` state is not mutated; `serialize` receives no arena
   (`.h:427-443`).
3. `deserialize` rejects a different format version, clears prior contents,
   reads the count, reserves only `min(size, 4096)`, reads timestamps and values,
   checks whether input order is strictly increasing, and calls `sort` to restore
   the invariant (`.h:458-500`). The order check is retained for peers that may
   write samples in arrival order (`.h:488-491`).

The format is therefore explicit but not self-describing beyond the aggregate's
templated type; timestamp/value types are selected by the function instance.
Corrupt counts are less likely to trigger a huge upfront allocation because the
initial reservation is bounded (`.h:478-481`), although there is intentionally no
semantic maximum for a valid state.

## Registration and maturity

The factory registers `timeSeriesGroupArray` at
`AggregateFunctionTimeSeriesGroupArray.cpp:99-170`.

- The creator rejects use by default unless
  `enable_time_series_aggregate_functions` **or** `enable_time_series_table` is
  enabled (`.cpp:17-21, 58-64`).
- Documentation in source labels it private preview and specifies
  `enable_time_series_aggregate_functions=true` (`.cpp:102-114`).
- The source registration records **IntroducedIn v25.8** (`.cpp:166-170`),
  matching the generated docs (`timeSeriesGroupArray.mdx:11-23`).
- The global aggregate registry declares and invokes the registration function
  (`src/AggregateFunctions/registerAggregateFunctions.cpp:104-107, 222-225`).

Official reference: [timeSeriesGroupArray](https://clickhouse.com/docs/sql-reference/aggregate-functions/reference/timeSeriesGroupArray).

## Design implications for a coursework aggregate

Use this implementation as a precedent for:

- one aggregate state per SQL grouping key, with the engine—not the aggregate—
  owning the key-to-state map;
- an append-only `PODArray`/vector plus a dirty/sorted bit;
- O(1)-amortized ordered ingestion and deferred O(n log n) normalization;
- associative/commutative duplicate reduction so parallel partial merges are
  deterministic;
- merge paths optimized for disjoint time ranges and linear merge for overlap;
- versioned, canonical serialization and defensive bounded initial reservation.

Do not claim this precedent provides bounded state, online timestamp lookup,
stationarity testing, AR/ARIMA fitting, or statistical change-point detection.
Those require additional state/algorithms and should be scoped explicitly.
