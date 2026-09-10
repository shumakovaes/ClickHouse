# Synthetic time-series diagnostics

Seed `20260910`, n=`300`, repeated simulations=`200`.

Scope: the three implemented core diagnostics are ACF, Ljung–Box, and Durbin–Watson. The AR(1) fit/forecast and KPSS sections are exploratory/future-extension outputs and should not be treated as part of the three-diagnostic result. The single-run table is one draw per process. Rejection rates are empirical proportions from independent draws; they are not theoretical probabilities.

P-value provenance: SciPy was unavailable in this run, so Ljung–Box p-values use the Wilson–Hilferty chi-square survival approximation. KPSS p-values use interpolation over standard published asymptotic critical values because its null distribution is non-standard. See `environment.json` for the full runtime record.

## Single-run diagnostics

| process | acf1 | ljung_box_p | durbin_watson | ar1_phi_hat | ar1_forecast | kpss_level_p | kpss_trend_p |
|---|---|---|---|---|---|---|---|
| white_noise | -0.1184 | 0.2592 | 2.2325 | -0.1185 | 0.1131 | 0.1000 | 0.1000 |
| ar1_phi_0.5 | 0.4942 | 0.0000 | 1.0082 | 0.4957 | -0.4846 | 0.1000 | 0.1000 |
| ar1_phi_0.9 | 0.8707 | 0.0000 | 0.2499 | 0.8709 | -0.2355 | 0.0577 | 0.1000 |
| random_walk | 0.9796 | 0.0000 | 0.0086 | 0.9800 | 7.1092 | 0.0050 | 0.0050 |
| trend_stationary | 0.3750 | 0.0000 | 0.5287 | 0.3761 | 2.0395 | 0.0050 | 0.1000 |
| mean_shift | 0.4854 | 0.0000 | 0.7218 | 0.4861 | 1.3312 | 0.0050 | 0.0273 |

## Repeated simulations

| process | reps | ljung_box_rejection_rate_5pct | kpss_level_rejection_rate_5pct | kpss_trend_rejection_rate_5pct | acf1_theory | acf1_mean | acf1_bias | acf1_rmse | ar1_phi_theory | ar1_phi_mean | ar1_phi_bias | ar1_phi_rmse |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| white_noise | 200.0000 | 0.0650 | 0.0250 | 0.0650 | 0.0000 | 0.0052 | 0.0052 | 0.0570 | 0.0000 | 0.0052 | 0.0052 | 0.0572 |
| ar1_phi_0.5 | 200.0000 | 1.0000 | 0.0500 | 0.0600 | 0.5000 | 0.4889 | -0.0111 | 0.0502 | 0.5000 | 0.4905 | -0.0095 | 0.0498 |
| ar1_phi_0.9 | 200.0000 | 1.0000 | 0.1700 | 0.2900 | 0.9000 | 0.8827 | -0.0173 | 0.0340 | 0.9000 | 0.8862 | -0.0138 | 0.0322 |
| random_walk | 200.0000 | 1.0000 | 0.8100 | 0.8150 | nan | 0.9751 | nan | nan | nan | 0.9819 | nan | nan |
| trend_stationary | 200.0000 | 1.0000 | 1.0000 | 0.0450 | nan | 0.4222 | nan | nan | nan | 0.4250 | nan | nan |
| mean_shift | 200.0000 | 1.0000 | 1.0000 | 0.7900 | nan | 0.4942 | nan | nan | nan | 0.4959 | nan | nan |
