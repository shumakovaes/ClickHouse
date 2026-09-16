# Exact, mergeable time-series statistics for ClickHouse

**Academic coursework submission · continuation status: 15 September 2026**

## Abstract

This coursework studies how order-dependent time-series statistics can be implemented as ordinary ClickHouse aggregate functions without depending on row arrival, block boundaries, shard placement, or merge-tree shape. The implementation retains every finite `(timestamp, value)` pair, sorts by a unique timestamp, and merges canonical states by exact sorted union. This gives a direct associative and commutative merge contract on valid disjoint-key inputs, at the explicit cost of `O(n)` persistent state.

The current source tree registers seven private-preview APIs: autocorrelation, the Ljung–Box test, Durbin–Watson, fixed-order lagged linear regression, a fixed-lag augmented Dickey–Fuller statistic, a KPSS statistic, and a one-mean-shift estimator. The four extensions deliberately return only quantities justified by their stated conventions: ADF and KPSS expose no p-values, while the change-point score is descriptive rather than calibrated. Regression uses a centered/scaled streaming Givens QR solver with explicit rank, conditioning, residual-resolution, and work guards. KPSS uses a function-local Bartlett bandwidth convention. Mean-shift finalization uses directly accumulated suffix moments to avoid cancellation.

Independent Python evidence, with seed `20260915`, `n=240`, and 120 repetitions, records coefficient recovery and directional diagnostic behavior. A separate Python-oracle benchmark measures only the batch reference algorithms and is not native ClickHouse performance evidence. Native Release build, seven-API GoogleTest, SQL/Distributed, and CI counts remain **PENDING** and are shown as explicit acceptance placeholders; no earlier three-function Debug count is reused as evidence for the extended tree.

## 1. Research question and scope

ClickHouse reads and combines data in parallel. Rows may arrive from several parts and shards, and partial aggregate states may be joined in different parenthesizations. Physical arrival order therefore cannot stand in for chronological order [@schulze2024clickhouse; @clickhouse_mergetree_docs; @clickhouse_parts_docs]. The research question is: *which ordered time-series statistics can be exposed as ordinary mergeable aggregates, under exactly what state and numerical contracts?*

For one SQL group, a valid logical series is

\[
X=((t_0,x_0),\ldots,(t_{n-1},x_{n-1})),\qquad
t_0<t_1<\cdots<t_{n-1},
\]

where every value is finite and every key is unique. `timestamp` is an ordering key, not a duration. Lags count positions after sorting; unequal gaps, time zones, and calendar effects are ignored. A caller who needs equally spaced AR, ADF, or KPSS inference must resample first. Rows with a NULL argument are skipped by ClickHouse's nullable combinator, which can itself change positional spacing.

The common `max_samples` parameter defaults to 1,000,000 and is limited to 10,000,000. Exceeding it is an error rather than truncation. The state is exact with respect to the retained canonical series but is not bounded-memory streaming and does not imply exact real arithmetic.

## 2. State, merge law, and compact-state NO-GO decision

The shared state stores all `(timestamp, Float64)` records. `add` appends in amortized `O(1)` time and marks out-of-order input dirty. Before merge, serialization, or finalization, a dirty vector is sorted and duplicate keys are rejected. Two canonical vectors are joined by a two-pointer sorted union in `O(n_1+n_2)` work. The serialized extension envelope identifies the finalizer and its constant parameters; the delegated sample payload remains versioned and carries the sample cap.

For finite maps with disjoint keys, let `C(S)` be their unique increasing-key representation and define

\[
S\oplus T=C(S\cup T).
\]

Because set union is associative and commutative and canonical sorting is unique,

\[
(S\oplus T)\oplus U=S\oplus(T\oplus U),\qquad
S\oplus T=T\oplus S,
\]

with the empty state as identity. Duplicate keys and cap overflow make the operation deliberately partial: any complete merge tree must eventually reject the same invalid logical union.

### 2.1 Why a compact boundary state is a NO-GO ordinary aggregate

The project ADR rejects a general `O(H)` prefix/suffix envelope for ordinary ClickHouse aggregation. Consider singleton states with keys `1`, `3`, and `2`. ClickHouse may merge `1` and `3` first. If that state forgets the interior and keeps only an envelope, it cannot later know that inserting key `2` must replace the apparent transition `1 -> 3` by `1 -> 2` and `2 -> 3`. For the lag-one product sum

\[
T(X)=\sum_{i=1}^{n-1}x_{i-1}x_i,
\]

the missing cross-boundary terms depend on information already discarded. Disjoint ranges are not necessarily adjacent, and keeping every disjoint subrange degenerates to `O(n)` in the worst case.

A compact design would be valid only if a specialized execution operator guaranteed complete adjacent ranges, canonical left-to-right composition, and preservation of those conditions across spills, retries, remote aggregation, persisted states, and final coordinator merges. The ordinary aggregate interface provides none of these guarantees. Therefore no compact alternative is registered, exposed through `-State`/`-Merge`, or used to justify the seven APIs. This is a design decision, not an unfinished optimization.

## 3. Public API

All seven functions are private-preview parameterized aggregates over `(timestamp, value)`:

```text
timeSeriesAutocorrelation(lag[, max_samples])(timestamp, value)
  -> Float64
timeSeriesLjungBoxTest(max_lag[, model_df[, max_samples]])(timestamp, value)
  -> Tuple(statistic Float64, p_value Float64)
timeSeriesDurbinWatson([max_samples])(timestamp, value)
  -> Float64
timeSeriesLaggedLinearRegression(order[, max_samples])(timestamp, value)
  -> Tuple(intercept Float64, coefficients Array(Float64))
timeSeriesADFStatistic(augmentation_lags[, deterministic[, max_samples]])(timestamp, value)
  -> Tuple(statistic Float64, coefficient Float64, observations UInt64)
timeSeriesKPSSTest(regression[, bandwidth[, max_samples]])(timestamp, value)
  -> Tuple(statistic Float64, bandwidth UInt64, observations UInt64)
timeSeriesMeanShiftChangePoint(min_segment[, max_samples])(timestamp, value)
  -> Tuple(split_index UInt64, score Float64, mean_before Float64,
           mean_after Float64, sse Float64)
```

Keys accept `UInt32`, `UInt64`, `DateTime`, or `DateTime64`. Values accept native integer and floating-point types and are converted to `Float64`; Decimal is not accepted. Duplicate timestamps and non-finite values are errors. The primary private-preview gate is `enable_time_series_aggregate_functions`; the factory also accepts the legacy compatibility gate `enable_time_series_table`.

## 4. Established diagnostics

Let `x_0,...,x_{n-1}` be canonical values, with

\[
\bar x=\frac1n\sum_{i=0}^{n-1}x_i,
\qquad M_2=\sum_{i=0}^{n-1}(x_i-\bar x)^2.
\]

The biased, overall-mean autocorrelation at position lag `h` is

\[
\rho_h=
\frac{\sum_{i=h}^{n-1}(x_i-\bar x)(x_{i-h}-\bar x)}{M_2}.
\]

Lag zero is 1 for a non-constant series. Empty, constant, or insufficient inputs produce `NaN`.

For `H=max_lag`, Ljung–Box is

\[
Q(H)=n(n+2)\sum_{h=1}^{H}\frac{\rho_h^2}{n-h},
\qquad
p=\Pr\{\chi^2_{H-d}\ge Q(H)\},
\]

where `d=model_df` and `0<=d<H` [@boxpierce1970; @ljungbox1978]. This is the one API in the family that returns a calibrated tail probability, subject to its asymptotic assumptions.

Durbin–Watson is

\[
DW=\frac{\sum_{i=1}^{n-1}(x_i-x_{i-1})^2}
         {\sum_{i=0}^{n-1}x_i^2}.
\]

It is classically a residual diagnostic [@durbinwatson1950; @durbinwatson1971], but the aggregate fits no regression. Fewer than two samples or a zero denominator yields `NaN`.

## 5. Lagged linear regression

For fixed order `p`, the fitted positional autoregression follows the classical autoregressive lag construction [@yule1927]:

\[
y_t=\alpha+\sum_{j=1}^{p}\phi_j y_{t-j}+\varepsilon_t,
\qquad t=p,\ldots,n-1.
\]

The returned coefficient array is ordered `(phi_1,...,phi_p)`. `p` is fixed at aggregate creation, must lie in `[1,16]`, and must be below `max_samples`. Lagged design rows are constructed only after the full keyed state has been sorted. Locally fitted coefficients are never merged; merging local models would not equal fitting the global design.

The finalizer centers and scales response and predictor columns, then performs a streaming Givens QR factorization without column pivoting. It requires positive residual degrees of freedom, rejects rank-deficient or non-finite designs, and rejects a scaled reciprocal condition estimate below `1e-12`. The checked work budget is

\[
r p^2\le 100{,}000{,}000,
\]

where `r=n-p` is the number of design rows. Exceeding the budget or failing the numerical guards returns a fixed-shape result containing `NaN` values. The persistent state remains `O(n)`; QR finalization is `O(rp^2)` with a small bounded matrix.

## 6. Fixed-lag ADF statistic

For augmentation lag `p`, the implemented regression is

\[
\Delta y_t=d_t+\gamma y_{t-1}
 +\sum_{j=1}^{p}\psi_j\Delta y_{t-j}+\varepsilon_t,
\qquad t=p+1,\ldots,n-1.
\]

This is the fixed-lag augmented Dickey--Fuller regression [@dickeyfuller1979; @saiddickey1984].

The deterministic mode is exactly one of:

- `none`: no deterministic term;
- `constant` (default): an intercept;
- `trend`: an intercept and linear trend in canonical row position.

The augmentation lag is fixed at aggregate creation and lies in `[0,16]`. For a series long enough to form regression rows, the function returns the coefficient `gamma`, its regression t-ratio, and `observations=n-p-1`. It performs no automatic lag selection and returns no p-value. The statistic is not a Student-t hypothesis test; obtaining ADF critical probabilities would require an audited response-surface convention not present in this API.

Sample admission follows the fixed-lag guard used by the official statsmodels `adfuller` implementation [@statsmodels_adfuller_source]:

\[
p\le\left\lfloor\frac n2\right\rfloor-d-1,
\]

where `d` is the number of deterministic terms (`0`, `1`, or `2`), followed by a positive residual-degrees-of-freedom check. The returned observation count remains informative even when the fit is undefined.

The same centered/scaled, non-pivoted Givens QR solver is used. Let `r=n-p-1` be the number of post-lag regression rows (and the returned `observations` count), and let `c` be the actual QR column count: `1+p` for `none` or `constant`, and `2+p` for `trend`; centering removes the explicit constant column but not its residual-degree-of-freedom cost. A fit is undefined if it is insufficient, singular, ill-conditioned (`rcond<1e-12`), non-finite, or if

\[
r c^2>100{,}000{,}000.
\]

An additional backward-error floor treats residual variance below Float64 resolution as unresolved instead of turning QR roundoff into an enormous t-ratio. Timestamp spacing is ignored: ADF interpretation requires the caller to supply defensibly equally spaced observations.

## 7. KPSS statistic

`timeSeriesKPSSTest` accepts `regression='level'` or `regression='trend'`. Let `e_t` be residuals after subtracting the sample mean in level mode or an intercept and canonical-position linear trend in trend mode. Define the cumulative residual path

\[
S_t=\sum_{i=0}^{t}e_i,
\]

the sample autocovariances

\[
\widehat\gamma_h=\frac1n\sum_{t=h}^{n-1}e_t e_{t-h},
\]

and the Bartlett/Newey–West long-run variance

\[
\widehat\omega_q^2=\widehat\gamma_0+
2\sum_{h=1}^{q}\left(1-\frac{h}{q+1}\right)\widehat\gamma_h.
\]

The returned statistic is

\[
KPSS=\frac{n^{-2}\sum_{t=0}^{n-1}S_t^2}{\widehat\omega_q^2}
\]

[@kpss1992; @neweywest1987]. The function returns the statistic, the resolved requested/default bandwidth parameter, and `n`; that bandwidth field remains populated even when a guard makes the statistic undefined. It returns no p-value.

For `n>=2`, if bandwidth is omitted, this implementation uses its own explicit floor rule

\[
q=\min\left(n-1,\left\lfloor12(n/100)^{1/4}\right\rfloor\right).
\]

For `n<2`, the resolved bandwidth is zero and the statistic is undefined. This convention must not be described as another library's `legacy` mode. An explicit `q` is non-negative and capped at 1024; creation requires `q<max_samples`, while a defined statistic additionally requires `q<n`. Direct finalization is `O(nq)` and returns an undefined statistic when `nq>100,000,000`, the long-run variance is non-positive/non-finite, or the detrended series has no resolvable variation. The timestamp/equal-spacing caveat applies here as strongly as for ADF.

## 8. One-mean-shift estimator

For every legal split `k` satisfying `min_segment<=k<=n-min_segment`, define

\[
SSE(k)=\sum_{i<k}(x_i-\bar x_{0:k})^2+
       \sum_{i\ge k}(x_i-\bar x_{k:n})^2.
\]

The chosen split minimizes this objective. If

\[
SSE_0=\sum_{i=0}^{n-1}(x_i-\bar x)^2,
\]

the descriptive score is

\[
score=\max\left(0,1-\frac{SSE(k^*)}{SSE_0}\right).
\]

It is the fraction of one-mean variation removed by a two-mean fit, not a p-value and not a general multiple-change procedure. `min_segment` must be positive and cannot exceed `max_samples/2`. `split_index` is the number of samples in the left segment. No identifiable improvement returns `split_index=0` with `NaN` fields.

The native finalizer range-scales values, maintains a running prefix Welford moment [@welford1962; @chan1983], and stores directly accumulated suffix Welford moments. Reconstructing suffix SSE by subtracting the prefix and between-mean terms from the total was rejected because a strong break can make that subtraction catastrophically cancel. The native scan is `O(n)` time with `O(n)` transient suffix memory in addition to the `O(n)` persistent keyed state. The independent Python oracle intentionally uses a direct `O(n^2)` slice scan.

Let `gamma_n=n*epsilon/(1-n*epsilon)`, where `epsilon` is binary64 machine epsilon. The finalizer accepts a later candidate only when `incumbent-candidate > 8*gamma_n*max(|candidate|,|incumbent|)`; this count-aware envelope prevents accumulated Welford rounding on a long no-improvement series from manufacturing a change, and otherwise retains the earliest canonical split. After rescaling, a positive SSE too large for `Float64` is returned as `+Inf` without discarding an otherwise valid split; an extremely small SSE may underflow to zero. The dimensionless score can remain valid in both cases.

## 9. Numerical policy shared by the family

ACF and Ljung–Box use a midpoint/range coordinate transform; Durbin–Watson divides by the maximum absolute value. Compensated sums reduce avoidable cancellation. Regression columns are centered and scaled before QR. KPSS and mean-shift calculations similarly operate in scaled coordinates. These transformations preserve the stated dimensionless quantities in exact arithmetic, but cannot recover information already lost when an input is converted to `Float64`.

Undefined outcomes are part of the contract, not silent success. Depending on the API, they appear as `NaN` scalar or tuple fields while counts/bandwidth may remain populated. The independent Python oracle checks ordinary numerical formulas; it is not a bitwise or edge-case API oracle: it may raise `ValueError`, uses a strict change-point comparison, and omits native work guards. Cross-platform validation must use absolute and relative tolerances and separately check finiteness, `NaN`, bounds, and deterministic tie behavior.

## 10. Implementation and validation status

The checkout on branch `coursework/time-series-extensions` contains the original diagnostics state and wrapper plus `AggregateFunctionTimeSeriesStatisticalExtensions.h/.cpp`. The extension state delegates all keyed storage and canonical merging to the same exact sample state, while its envelope records the finalizer kind and constant parameters. The global registry source calls both registration functions. Three additional SQL/reference fixtures (`05162`--`05164`, four fixtures total with `05161`) and a focused extension GoogleTest source are present in the working tree.

Source presence and registration are not equivalent to validated native execution. The current seven-API acceptance ledger is therefore:

| Native acceptance layer | Current status |
|---|---|
| Release configure/build | **PENDING — record target/action counts, duration, flags, exit code, revision, and binary hash** |
| Seven-API focused GoogleTest | **PENDING — record passed/failed test counts and runtime from the Release-linked runner** |
| SQL stateless fixtures `05161`–`05164` | **PENDING — record passed/skipped/failed counts and runtime** |
| Two-shard Distributed and `AggregatingMergeTree` execution | **PENDING — record the executed fixture result and duplicate-error propagation** |
| Required remote CI | **PENDING — record actual required-job names and outcomes; local execution is not CI** |
| Native Release benchmark | **PENDING — do not substitute the Python-oracle benchmark** |

The earlier three-diagnostic revision has archived focused Debug evidence. Those historical results remain useful for the unchanged baseline but do not validate compilation, linkage, SQL dispatch, serialization, numerical guards, or distributed behavior of the four new APIs. No native Release/gtest/SQL/CI count is claimed here until a new seven-API run produces its logs.

## 11. Extension experiment: independent Python evidence

The extension experiment uses seed `20260915`, `n=240`, 120 repetitions, fixed ADF lag 1, and `min_segment=20`. Its final provenance-complete LF-normalized run took 4.170579 seconds under Python 3.12.6 on Windows. The recorded tables contain 360 AR-fit rows, 240 ADF rows, 480 KPSS rows, 120 mean-shift rows, 12 edge outcomes, and one optional-library cross-check row. Calculations use the independent coursework batch oracle; optional statsmodels was available only as a cross-check. These results are statistical/reference evidence, not execution of the C++ aggregates.

| Experiment | Verified result |
|---|---:|
| AR(1), phi=0.25, noise SD 0.2 | 120/120 fits; intercept bias 0.002854 and RMSE 0.034467; phi1 bias -0.007942 and RMSE 0.063852 |
| AR(1), phi=0.70, noise SD 1.0 | 120/120 fits; intercept bias 0.009558 and RMSE 0.089170; phi1 bias -0.007259 and RMSE 0.051025 |
| AR(2), phi=(0.50,-0.25), noise SD 0.5 | 120/120 fits; intercept bias 0.004495 and RMSE 0.049320; phi1 bias -0.005070 and RMSE 0.062453; phi2 bias -0.007596 and RMSE 0.061536 |
| ADF direction | stationary mean -7.76810; random-walk mean -1.56964; stationary was more negative in 120/120 pairs |
| KPSS level behavior | level-stationary mean 0.16800; random-walk mean 0.86441; level was smaller in 113/120 pairs (0.9417) |
| KPSS trend behavior | detrended trend mean 0.07503; level-only trend mean 1.70315; detrended was smaller in 120/120 pairs |
| Mean-shift localization | mean absolute error 0.1083 samples; exact in 109/120 (0.9083); within 12 samples in 120/120 |

ADF and KPSS rows are directional comparisons only. Because the APIs deliberately return no p-values, these rows make no calibrated rejection-rate claim. The optional statsmodels cross-check differences were approximately `5.33e-15` for ADF, zero for the AR intercept, `1.67e-16` and `3.05e-16` for the two AR coefficients, and `1.39e-17` for KPSS. They support agreement of this fixture, not universal equivalence across all inputs and conventions.

The recorded edge grid contains constant, short, and NULL-filtered cases. It checks that undefined results stay explicit, that usable values remain available where defined, and that a constant series maps to `split_index=0`. It is not a replacement for the pending C++ and SQL runs.

## 12. Python-oracle benchmark, explicitly non-native

The extension benchmark times independent batch-oracle finalizers on Windows/Python 3.12.6. Input generation and one warm-up are outside each timed sample; each case has three timed repetitions. `tracemalloc` measures Python-traced allocation, not process RSS and not a ClickHouse allocator. The change-point oracle is intentionally `O(n^2)`, unlike the native `O(n)` finalizer.

Selected largest-case medians are:

| Python oracle finalizer | Configuration at n=4096 | Median time | Median traced peak |
|---|---|---:|---:|
| lagged regression | p=1 | 167.348 ms | 716,160 bytes |
| lagged regression | p=8 | 305.731 ms | 850,248 bytes |
| ADF | p=0, constant | 214.918 ms | 847,840 bytes |
| ADF | p=4, constant | 380.251 ms | 981,260 bytes |
| KPSS | trend, q=0 | 62.994 ms | 625,260 bytes |
| KPSS | trend, q=32 | 419.694 ms | 625,260 bytes |
| mean shift | min_segment=8 | 18,541.648 ms | 359,088 bytes |

The benchmark spans `n={256,1024,4096}`, AR orders `{1,4,8}`, ADF lags `{0,2,4}`, and KPSS bandwidths `{0,8,32}`. Its only defensible interpretation is algorithmic behavior of the independent Python oracle on one host. It provides no ClickHouse throughput, query-plan, vectorization, RSS, serialization-size, or Release-build claim.

## 13. Limitations and threats to validity

- Every function retains all accepted samples. `max_samples` makes exhaustion explicit but does not make the state suitable for unlimited histories.
- Dirty state sorting costs `O(n log n)`; Ljung–Box costs `O(nH)`; lagged regression and ADF cost `O(rc^2)`; KPSS costs `O(nq)`; native mean shift uses `O(n)` transient memory.
- Lags and trends are positional. Unequal timestamps are not repaired, and skipped NULL rows alter the position sequence.
- ADF has fixed caller-selected lag and no p-value or MacKinnon calibration. KPSS has a local bandwidth rule and no p-value. Their statistics alone do not prove stationarity or nonstationarity.
- Lagged regression fits a conditional linear model but supplies no forecast intervals or automatic order selection.
- Mean shift assumes at most one change in the mean, returns a descriptive score, and does not provide a false-positive calibration or distinguish mean change from other misspecification.
- Non-pivoted QR and a fixed `rcond` threshold intentionally reject some difficult but mathematically identifiable designs. The residual-resolution policy may classify genuine noise below the Float64 floor as unresolved.
- The Python experiment uses one sample length, one top-level seed, and 120 repetitions. Its frequencies are Monte Carlo observations, not theoretical probabilities.
- The Python benchmark is not native. Native Release build, extension gtest, SQL/Distributed execution, CI, and native Release performance are still pending.
- The branch is coursework work in a fork; registration metadata is not evidence that the functions have entered an official ClickHouse release.

## 14. Reproduction protocol

From the manuscript directory, the independent extension evidence can be reproduced with:

```powershell
py -3 -m unittest discover -s ../reference/python -p "test_*.py"
py -3 ../evidence/experiments/run_extension_experiments.py `
  --seed 20260915 --n 240 --reps 120 --adf-lags 1 `
  --change-min-segment 20 --output-dir <new-output-directory>
py -3 ../evidence/benchmarks/benchmark_extensions.py `
  --output-dir <new-benchmark-directory> --seed 20260915 `
  --n 256,1024,4096 --ar-orders 1,4,8 --adf-orders 0,2,4 `
  --kpss-bandwidths 0,8,32 --change-point-n 256,1024,4096 `
  --min-segment 8 --warmup 1 --repetitions 3
```

The checked-in experiment evidence is under `evidence/experiments/extension_results_20260915_final_v4_trusted/`; the Python and native benchmark evidence paths are recorded separately. Native acceptance must record the exact revision, submodule state, Release configuration, toolchain, commands, exit codes, durations, test counts, resource use, and artifact hashes. Until those files exist, every native acceptance entry in Section 10 remains `PENDING`.

## 15. Conclusion

The central result is architectural. Exact order-dependent statistics can behave as ordinary distributed aggregates when the state retains the complete keyed sample and merge is canonical sorted union. The `1,3,2` counterexample shows why a compact prefix/suffix envelope is not closed under arbitrary ClickHouse merge trees.

Seven private-preview APIs now exist in source with explicit formulas and resource guards. The extensions narrow their claims deliberately: fixed-order AR coefficients, a fixed-lag ADF t-statistic without a p-value, KPSS under a stated Bartlett bandwidth convention without a p-value, and a descriptive one-break mean-shift objective. Independent Python experiments and benchmarks make the mathematics inspectable, but the native Release/gtest/SQL/CI ledger remains pending. Treating those layers separately is necessary for an auditable engineering claim.

## References

Complete bibliographic records are in [`../research/bibliography.bib`](../research/bibliography.bib). They cover ClickHouse execution and time-series precedents, mergeable aggregate algebra, stable moments, autoregression, Dickey--Fuller/ADF, the Ljung–Box family, Durbin–Watson, KPSS, and Bartlett/Newey–West long-run variance estimation.
