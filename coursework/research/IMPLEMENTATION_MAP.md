# ClickHouse implementation map

## Production API and state

Register only:

| Function | Parameters | Arguments/result |
|---|---|---|
| `timeSeriesAutocorrelation` | `lag[, max_samples]` | `(key, value) -> Float64` |
| `timeSeriesLjungBoxTest` | `max_lag[, model_df[, max_samples]]` | `(key, value) -> Tuple(statistic Float64, p_value Float64)` |
| `timeSeriesDurbinWatson` | `[max_samples]` | `(key, value) -> Float64` |

The shared state retains every finite sample, canonicalizes by key before
finalization/merge/serialization, rejects duplicate keys, enforces positive
`max_samples <= 10,000,000` and the lag/model-degree constraints in `DESIGN.md`,
and serializes a version, cap, count, and records. `add` appends and marks
out-of-order state; `merge` performs a linear two-way merge of canonical
states and rejects equal keys; `insertResultInto` finalizes the formulas in
`DESIGN.md`. No range-key or compact-state function is registered.

## Source and test locations

| Concern | Conventional location | Required work/evidence |
|---|---|---|
| Factory/registration | `src/AggregateFunctions/TimeSeries/` and `registerAggregateFunctions.cpp` | exactly three names, constant parameter/type checks, preview setting |
| State transition/merge | `TimeSeries/AggregateFunctionTimeSeriesDiagnostics.h/.cpp` | add, merge, serialize, deserialize, finalize; duplicate/cap errors |
| Key/value types | factory helper and state | supported scalar key types, native integer/floating-point-to-`Float64`, finite-value rejection; Decimal is unsupported |
| Documentation | source `FunctionDocumentation` and generated reference | signatures, formulas, ordering, errors, `NaN`, `max_samples` |
| Functional regression | `tests/queries/0_stateless/<new>.sql` and `.reference` | all permutations, interleaving merges, duplicates, caps, edge cases |
| Distributed regression | shard-tagged stateless/integration fixture | merge-tree/order invariance and failure propagation |
| Reference/benchmarks | independent reference and benchmark scripts | exact comparisons, `O(n)` memory, merge/finalize timings |

## Integration sequence and status

1. Land the shared state and parameter validation. **Complete: the production
   translation unit passes Clang 21 `-Werror`, and both aggregate and unified
   ClickHouse targets link.**
2. Add serialization/version and duplicate/cap rejection tests. **Complete:
   the isolated reference and focused native GoogleTest suites each pass
   15/15, including malformed and bounded-reserve payload cases.**
3. Register the three functions and result tuple. **Complete: the registration
   TU passes Clang 21 `-Werror`, and the built SQL surface executes.**
4. Add SQL and distributed permutation/merge tests against the independent
   reference. **Complete: the stateless fixture passes 1/1 and includes a real
   two-shard `Distributed` merge and duplicate propagation.**
5. Publish generated docs and benchmark evidence only after M6 in `PLAN.md`.
   **Complete: Python/statistical evidence and native Debug measurements with
   raw data, metadata, and explicit timing caveats are packaged.**

The compact range/interval design is a rejected negative result and must not be
introduced as an optimization without re-opening the arbitrary-order contract.
