# Baseline ACF and Ljung--Box sensitivity experiments

- Seed: `20260916`; repetitions: `200`; ACF simulation length: `300`.
- Ljung--Box sample sizes: `100,300,1000`; lags: `20`; model_df: `0`; degrees of freedom: `20`; alpha: `0.05`.
- Runtime: `28.045` seconds.
- ACF uses the stable, biased sample-mean-centered baseline contract; every simulated result is cross-checked against `FullSampleKeyedStats`.
- Ljung--Box p-values use the dependency-free `reference.chi_square_sf` implementation.

## ACF snapshots

The complete 60-row positive-lag table (lags 1--20) is in `acf_lag_summary.csv`; the selected lags below make the theoretical comparison easy to inspect.

| process | lag | theoretical | empirical mean | bias | RMSE |
|---|---:|---:|---:|---:|---:|
| white_noise | 1 | 0.000000 | -0.004366 | -0.004366 | 0.059557 |
| white_noise | 5 | 0.000000 | -0.001511 | -0.001511 | 0.058652 |
| white_noise | 10 | 0.000000 | -0.001774 | -0.001774 | 0.055153 |
| white_noise | 20 | 0.000000 | -0.008052 | -0.008052 | 0.054519 |
| ar1_phi_0.5 | 1 | 0.500000 | 0.492454 | -0.007546 | 0.048691 |
| ar1_phi_0.5 | 5 | 0.031250 | 0.019061 | -0.012189 | 0.070867 |
| ar1_phi_0.5 | 10 | 0.000977 | -0.003185 | -0.004162 | 0.074470 |
| ar1_phi_0.5 | 20 | 0.000001 | -0.011226 | -0.011227 | 0.069139 |
| ar1_phi_0.9 | 1 | 0.900000 | 0.885410 | -0.014590 | 0.030398 |
| ar1_phi_0.9 | 5 | 0.590490 | 0.537303 | -0.053187 | 0.105715 |
| ar1_phi_0.9 | 10 | 0.348678 | 0.278849 | -0.069829 | 0.149650 |
| ar1_phi_0.9 | 20 | 0.121577 | 0.059818 | -0.061759 | 0.158499 |

## Ljung--Box rejection-rate sensitivity

These are finite-sample Monte Carlo estimates using the asymptotic chi-square calibration, not universal test properties. White noise is the null false-positive reference; AR(1) rows are serial-correlation alternatives.

| process | n | repetitions | rejections | rejection rate | Monte Carlo SE | 95% Wilson interval |
|---|---:|---:|---:|---:|---:|---:|
| white_noise | 100 | 200 | 14 | 0.0700 | 0.0180 | [0.0422, 0.1141] |
| white_noise | 300 | 200 | 11 | 0.0550 | 0.0161 | [0.0310, 0.0958] |
| white_noise | 1000 | 200 | 14 | 0.0700 | 0.0180 | [0.0422, 0.1141] |
| ar1_phi_0.5 | 100 | 200 | 178 | 0.8900 | 0.0221 | [0.8391, 0.9262] |
| ar1_phi_0.5 | 300 | 200 | 200 | 1.0000 | 0.0000 | [0.9812, 1.0000] |
| ar1_phi_0.5 | 1000 | 200 | 200 | 1.0000 | 0.0000 | [0.9812, 1.0000] |
| ar1_phi_0.9 | 100 | 200 | 200 | 1.0000 | 0.0000 | [0.9812, 1.0000] |
| ar1_phi_0.9 | 300 | 200 | 200 | 1.0000 | 0.0000 | [0.9812, 1.0000] |
| ar1_phi_0.9 | 1000 | 200 | 200 | 1.0000 | 0.0000 | [0.9812, 1.0000] |

Raw observations are in `acf_lag_raw.csv` and `ljung_box_raw.csv`; summary CSVs contain the reproducible aggregates.
