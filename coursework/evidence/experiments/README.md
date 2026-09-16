# Synthetic statistical experiments

This directory preserves archived baseline exploratory evidence predating the
four registered extensions (`timeSeriesLaggedLinearRegression`,
`timeSeriesADFStatistic`, `timeSeriesKPSSTest`, and
`timeSeriesMeanShiftChangePoint`). The historical CSV-derived results and
simulation code remain unchanged; this runner is not evidence for the newer
extension APIs.

`run_experiments.py` generates six deliberately simple processes:

- iid white noise;
- stationary AR(1), with `phi=0.5` and `phi=0.9`;
- a random walk;
- a deterministic linear trend plus iid noise (trend-stationary);
- an iid series with a midpoint mean shift.

For each process it computes sample ACF, Ljung–Box (20 lags), Durbin–Watson,
an OLS AR(1) fit and one-step forecast, and KPSS statistics for both level (`c`)
and trend (`ct`) stationarity. It then repeats each simulation to estimate
empirical 5% rejection rates. The fixed default seed makes the run exactly
reproducible; pass a new seed to obtain a separate Monte Carlo experiment.

## Run

From the coursework package root:

```powershell
py evidence/experiments/run_experiments.py --n 300 --reps 200
py evidence/experiments/audit_results.py --input-dir evidence/experiments/results
```

Use `--output-dir PATH` to write elsewhere. The default output directory is
`evidence/experiments/results/` and contains CSV files, a runtime
`environment.json`, a Markdown summary, and an
ACF figure if Matplotlib is installed. `audit_results.py` converts the CSVs into
`results/analysis.md`, including measured rates, ACF theory error, AR(1)
recovery, and the change-point caveat. The three core diagnostics are ACF,
Ljung–Box, and Durbin–Watson; the AR(1) fit/forecast and KPSS sections are
archived baseline exploratory outputs and are reported separately. They
predate, and do not characterize, the four registered extensions.
`results/environment.json` records the runtime and p-value provenance. NumPy is required; SciPy improves
Ljung–Box p-values but is optional. Without SciPy, a Wilson–Hilferty chi-square
survival approximation is used. KPSS p-values are conservative interpolation
over standard published critical values, because the KPSS null distribution is
non-standard.

## Final baseline sensitivity run

`run_baseline_sensitivity_experiments.py` is the narrower, dependency-free
follow-up used by the final report. The recorded directory
`baseline_sensitivity_20260916_final/` contains 12,000 raw positive-lag ACF
rows, 1,800 raw Ljung--Box rows, 60 and 9 summary rows respectively, metadata,
and a checked SHA-256 manifest. It uses seed `20260916`, 200 repetitions,
sample sizes 100/300/1000 for Ljung--Box, and lags 1--20 for ACF. Every ACF
result is cross-checked against `FullSampleKeyedStats`; rejection rates include
Monte Carlo standard errors and Wilson intervals and remain finite-sample
simulation estimates rather than universal guarantees.

```powershell
py evidence/experiments/run_baseline_sensitivity_experiments.py `
  --output-dir <fresh-run-dir>/baseline-sensitivity
```

## Interpretation cautions

Rejection rates are estimates with Monte Carlo error, not universal properties
of a test. The Ljung–Box test detects serial correlation, not every form of
nonstationarity. Durbin–Watson is computed on the supplied series itself (for
residual diagnostics, pass model residuals to `durbin_watson`). A trend-stationary
series is expected to look non-level-stationary under KPSS `c` but more
stationary after detrending with KPSS `ct`.

Run the unit tests with:

```powershell
py -m unittest discover -s evidence/experiments -p "test_*.py"
```
