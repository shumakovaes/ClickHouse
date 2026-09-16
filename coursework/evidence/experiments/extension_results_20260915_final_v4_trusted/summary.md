# Extension experiment summary

- Seed: `20260915`; repetitions: `120`; observations per simulation: `240`.
- Runtime: `4.171` seconds.
- Core calculations use only Python standard library plus the independent coursework oracle.
- ADF and KPSS entries report statistic direction/behavior only; they make no p-value or calibrated rejection claim.

## Aggregate results

| Experiment | Key result |
|---|---|
| ar_recovery | ar1_phi_0.25_noise_0.2: fits=120/120, phi_1 RMSE=0.0639 |
| ar_recovery | ar1_phi_0.70_noise_1.0: fits=120/120, phi_1 RMSE=0.0510 |
| ar_recovery | ar2_phi_0.50_-0.25_noise_0.5: fits=120/120, phi_1 RMSE=0.0625 |
| adf_direction | stationary-more-negative hit rate=1.000 |
| kpss_behavior | level<walk=0.942; detrended<level=1.000 |
| mean_shift | MAE=0.108; exact hit=0.908; ±12 hit=1.000 |

## Edge outcomes

| Outcome | Count |
|---|---:|
| constant:nan | 1 |
| constant:split_0 | 1 |
| constant:undefined | 2 |
| null_rows_skipped:undefined | 1 |
| null_rows_skipped:value | 3 |
| short:undefined | 2 |
| short:value | 2 |
