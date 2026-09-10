# Measured results audit

These statements describe the generated CSVs, not theoretical guarantees. All rates use the fixed-seed run (`n=300`, `reps=200`, seed `20260910`). A 5% rejection rate is the decision rule (`p < 0.05`).

Scope: the three implemented core diagnostics are ACF, Ljung–Box, and Durbin–Watson. AR(1) fit/forecast and KPSS values are exploratory/future-extension outputs, reported separately and not counted as one of the three core diagnostics. The runtime and p-value provenance are recorded in `environment.json`.

## Formula audit

The ACF uses a demeaned series and the common (biased) denominator `sum(z²)`. Ljung–Box uses `n(n+2) * sum(rho_k²/(n-k))` over the requested lags, with a chi-square survival probability. Durbin–Watson is `sum(diff(x)²)/sum(x²)` for the supplied sequence; here it is descriptive because no residual model is supplied. AR(1) is OLS with an intercept, and the generator uses stationary initialization for |phi|<1. KPSS removes either a level or linear trend and estimates long-run variance with a Bartlett/Newey–West window; its p-values are critical-value interpolations because the KPSS null distribution is non-standard. SciPy was unavailable, so Ljung–Box p-values use the Wilson–Hilferty chi-square survival approximation; this is recorded in `environment.json`.

## False-positive and detection rates

For Ljung–Box, white noise is the serial-correlation null; its rejection rate is a false-positive estimate. AR(1), random walk, trend, and mean-shift rows are detection rates, but only the AR(1) cases are stationary alternatives. For KPSS, white noise is level-stationary, while trend-stationary is trend-stationary after a linear trend is removed; those are the false-positive reference cases for level (`c`) and trend (`ct`) KPSS respectively.

| process | Ljung–Box reject | KPSS level reject | KPSS trend reject |
|---|---:|---:|---:|
| white_noise | 0.065 | 0.025 | 0.065 |
| ar1_phi_0.5 | 1.000 | 0.050 | 0.060 |
| ar1_phi_0.9 | 1.000 | 0.170 | 0.290 |
| random_walk | 1.000 | 0.810 | 0.815 |
| trend_stationary | 1.000 | 1.000 | 0.045 |
| mean_shift | 1.000 | 1.000 | 0.790 |

The measured Ljung–Box false-positive rate is 0.065 (white noise), with detection 1.000 and 1.000 for the AR(1) settings. KPSS level false-positive rate is 0.025 for white noise; the trend-KPSS false-positive rate is 0.045 for the trend-stationary process. The random walk and mean shift are structural/nonstationary alternatives, not independent draws from a stationary null.

## ACF and AR(1) recovery

The theoretical lag-1 autocorrelation is defined here only for white noise (0) and AR(1) (`phi`). The random walk, mean shift, and deterministic trend do not have a single stationary ACF target, so their theory-error fields are intentionally `NA`.

| process | ACF(1) theory | ACF(1) mean | ACF bias | ACF RMSE | AR(1) phi theory | phi mean | phi bias | phi RMSE |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| white_noise | 0.0000 | 0.0052 | 0.0052 | 0.0570 | 0.0000 | 0.0052 | 0.0052 | 0.0572 |
| ar1_phi_0.5 | 0.5000 | 0.4889 | -0.0111 | 0.0502 | 0.5000 | 0.4905 | -0.0095 | 0.0498 |
| ar1_phi_0.9 | 0.9000 | 0.8827 | -0.0173 | 0.0340 | 0.9000 | 0.8862 | -0.0138 | 0.0322 |
| random_walk | NA | 0.9751 | NA | NA | NA | 0.9819 | NA | NA |
| trend_stationary | NA | 0.4222 | NA | NA | NA | 0.4250 | NA | NA |
| mean_shift | NA | 0.4942 | NA | NA | NA | 0.4959 | NA | NA |

For the supplied 200 repetitions, AR(1) phi RMSE is 0.0498 at phi=0.5 and 0.0322 at phi=0.9; the corresponding mean biases are -0.0095 and -0.0138. The ACF(1) RMSEs are 0.0570 (white noise), 0.0502 (phi=0.5), and 0.0340 (phi=0.9). These are Monte Carlo summaries, not confidence intervals.

## Change-point caveat

The midpoint mean shift is deliberately not a formal change-point test. ACF, Ljung–Box, Durbin–Watson, and KPSS can all react to a level break, but they do not identify its location or distinguish it reliably from other forms of nonstationarity. Use a dedicated change-point method and report its assumptions if locating or testing the break matters.

## Exact commands

```powershell
py -m unittest discover -s evidence/experiments -p "test_*.py"
py evidence/experiments/run_experiments.py --n 300 --reps 200 --seed 20260910 --output-dir evidence/experiments/results
py evidence/experiments/audit_results.py --input-dir evidence/experiments/results --output evidence/experiments/results/analysis.md
```

The single-run values used by the original diagnostic table are in `results.csv`; repeated summaries and theory-error calculations are in `repeat_summary.csv`.
