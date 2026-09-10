# Targeted coverage assessment

This is a review-based coverage assessment for the new implementation. It is
not an LLVM, gcov, or ClickHouse line/branch coverage report: a complete
instrumented ClickHouse build is impractical for this coursework checkout.
The assessment enumerates the state-machine and factory branches and maps each
one to an executable test or to an explicitly recorded gap.

## Evidence used

| Evidence | Scope |
|---|---|
| `src/AggregateFunctions/tests/gtest_time_series_diagnostics.cpp` | Direct native state tests: insertion, ordering, merge, duplicate detection, caps, serialization, finite-value checks, undefined results, and numerical stability. |
| `tests/queries/0_stateless/05161_time_series_diagnostics.sql` plus `.reference` | Registered-function integration: preview/arity gates, all three functions, state/merge/finalize paths, NULL combinator behavior, timestamp/value types, parameter errors, caps, duplicates, canonical serialized-byte equality, a distributed shard-state merge, and `AggregatingMergeTree`. |
| `coursework/reference/python/test_reference.py` | Independent formula, merge/order, serialization, limit, NaN, chi-square, and numerical-stability checks; property-style comparisons against SciPy/statsmodels where available. |
| `coursework/evidence/experiments/test_experiments.py` and recorded experiment outputs | Deterministic seeded generation, white-noise false-positive behavior, AR(1) detection, ACF error, and environment/provenance checks. |
| standalone C++ comparison and sanitizer run | Independent comparison harness and ASan/UBSan execution; this is supporting evidence, not production line coverage. |

The native gtest and functional SQL test are the primary evidence for the C++
implementation. The Python and experiment suites are deliberately treated as
independent behavioral evidence, not as proof that every ClickHouse dispatch
branch executed.

## State and serialization branch map

| ID | Implementation decision or branch | Evidence | Assessment |
|---|---|---|---|
| S1 | `add` accepts finite values and records an in-order first sample | Gtest `ArbitraryAddOrderIsCanonicalized`; SQL exact and typed cases | Covered |
| S2 | `add` marks state unsorted for a non-increasing timestamp | Gtest arbitrary-order and duplicate tests; SQL arbitrary-order case | Covered, including the duplicate-triggering non-increasing path |
| S3 | `add` rejects non-finite values | Gtest `NonFiniteValuesAreRejectedOnAdd`; SQL NaN/`inf`/`-inf` cases | Covered |
| S4 | `add` rejects a full state and invalid zero/over-hard limits | Gtest `SampleCapsApplyToAddsAndMerges`; SQL cap and parameter cases | Covered |
| S5 | `sortAndValidate` sorts an unsorted state, then validates uniqueness | Gtest arbitrary-order, merge, and serialization round trips; SQL order/merge cases | Covered |
| S6 | Already-sorted state avoids sorting and still validates uniqueness | Gtest direct sorted merge and round-trip; SQL serialized and merge cases | Covered |
| S7 | `merge` canonicalizes an unsorted right-hand state | Gtest `MergeTreeAndInterleavingAreCanonical`; SQL interleaved/reversed state merges | Covered |
| S8 | `merge` validates an already-sorted right-hand state | Gtest direct sorted/interleaving merge; SQL serialized state merges | Covered |
| S9 | Two-pointer merge takes left, right, and duplicate-key alternatives, then appends tails | Gtest interleaving merge; SQL interleaved/overlapping state cases | Covered; both left/right choices and duplicate rejection are exercised. Tail append is exercised by unequal state sizes. |
| S10 | `merge` rejects combined state size overflow | Gtest `SampleCapsApplyToAddsAndMerges`; SQL `Merge` cap case | Covered |
| S11 | Empty/constant/nonconstant centered moments, including zero scale | Gtest ACF tiny/constant and extreme-scale tests; SQL empty/constant cases | Covered |
| S12 | Midpoint/range normalization and compensated sums handle large offsets and extreme scales | Gtest large-offset and extreme-scale tests; SQL corresponding cases; Python stability cases | Covered for representative finite values; overflow/underflow at every possible IEEE boundary is not exhaustively sampled. |
| S13 | ACF invalid lag, lag zero, valid lag, and constant/short NaN paths | Gtest `AutocorrelationLagZeroTinyAndConstantSeries`, requested lags; SQL exact/insufficient/constant cases | Covered |
| S14 | Ljung--Box invalid max lag, short series, constant series, valid lag loop, and non-finite rho guard | Gtest `LjungBoxStatisticUsesRequestedLags`; SQL valid/short/constant/parameter cases; Python formula cases | Ordinary branches are covered. The defensive `!isfinite(rho)` return is not directly forced by an input because finite validated samples normally make it unreachable; recorded as a defensive gap. |
| S15 | Durbin--Watson short series, zero scale, normalized accumulation, and zero denominator | Gtest `DurbinWatsonUsesTimestampOrder`, extreme-scale; SQL singleton/zero/extreme cases | Covered |
| S16 | Serialization canonicalizes unsorted state and serializes sorted state | Gtest round trip and direct ordered-versus-permuted byte equality; SQL serialized-state/merge-state cases and equality of ordered versus permuted serialized bytes | Covered in both the state layer and the public aggregate-state path. |
| S17 | Serialization rejects bad version, cap mismatch/invalid cap, oversized count, unsorted/duplicate timestamps, non-finite value, and truncation | Gtests `CorruptVersionCountOrderAndNonFinitePayloadsAreRejected` and `CorruptCapsAndTruncatedPayloadsAreRejected`; Python JSON analogues | Covered by direct native malformed-payload tests. The SQL fixture adds public-path canonical-byte and state round-trip evidence, but does not replace direct malformed-byte coverage. |
| S18 | Deserialize reserve is bounded and accepts empty/valid canonical payload | Gtest round trip plus `DeserializationCrossesBoundedInitialReserve`; SQL empty aggregates | Covered, including a payload one sample beyond the 4096-element initial-reserve threshold |

## Factory, type, and result branches

| ID | Branch | Evidence | Assessment |
|---|---|---|---|
| F1 | Private-preview setting rejects disabled calls and permits enabled calls | Functional SQL first asserts `UNKNOWN_AGGREGATE_FUNCTION`, then enables `enable_time_series_aggregate_functions` and runs successful calls | Covered by the passing native functional run. |
| F2 | Binary-arity validation | Functional SQL invokes autocorrelation with one row argument and Durbin--Watson with two parameters, both expecting `NUMBER_OF_ARGUMENTS_DOESNT_MATCH` | Covered by the passing native functional run. |
| F3 | ACF parameter parsing: one/two parameters, unsigned and invalid values | SQL valid cap/lag and invalid zero/negative/too-large cases; Python parameter checks | Covered behaviorally; direct unsigned `Field` conversion alternatives are not separately enumerated. |
| F4 | Ljung--Box parsing: one, two, three parameters; `model_df < max_lag` | SQL valid tuple calls, fitted `model_df`, invalid zero/equal/negative cases | Covered |
| F5 | Durbin--Watson zero/one parameter and too many parameters | SQL default and capped valid calls plus invalid cap and two-parameter rejection | Covered |
| F6 | `max_samples` validation and lag hard-limit/order checks | SQL zero, over-hard, equal-to-cap, and lag-over-hard cases | Covered for public SQL parameters |
| F7 | Native numeric value acceptance and Decimal rejection | SQL Int32/Float32/Float64/UInt64 acceptance and Decimal rejection | Covered for representative numeric types; every native integer/float width is not enumerated. |
| F8 | Timestamp dispatch: DateTime64, DateTime/UInt32, UInt64; unsupported Date rejection | SQL has all supported families and Date rejection | Covered |
| F9 | Result dispatch: Float64 ACF/DW and named tuple Ljung--Box with/without finite p-value | SQL checks values, tuple type/names, and NaN p-value; native state tests check formulas | Covered |
| F10 | Nullable combinator skips NULL timestamp/value rows and returns Nullable result | SQL nullable value, nullable timestamp, all-null cases | Covered |

## Explicitly untested or only partially tested behavior

The following are intentionally not reported as covered:

* instrumented line/branch percentages for ClickHouse as a whole or for the
  new translation unit;
* direct invocation of the internal unknown-name branch and all individual
  `Field::tryGet` conversion alternatives;
* the defensive Ljung--Box non-finite-autocorrelation guard, which is not
  reachable through ordinary finite validated samples under the current
  algorithm;
* every timestamp/value width and every allocator/accounting failure path;
* exceptions thrown by `assert_cast` or allocation failures; these belong to
  ClickHouse framework/system testing rather than this feature's contract;
* statistical power/size behavior beyond the fixed-seed experiment grid.

These gaps do not invalidate the contract-level evidence, but they should be
closed before treating the feature as production-ready. In particular, the
next focused native test addition should exercise the internal unknown-name
factory branch and the remaining `Field::tryGet` conversion alternatives.

## Conclusion

All normal state transitions and public success/error contracts have executed
native or functional evidence: the focused state suite passes 15/15 and the
SQL/Distributed fixture passes 1/1. The assessment supports the stated behavior
and mergeability claims, but it is a test-matrix review, not a measured code
coverage result; the explicit gaps above remain unresolved by design.
