# Statistical-extension Python-oracle benchmark

This is a local Python reference benchmark, **not ClickHouse native throughput, allocation, or query-plan evidence**.
It times only independent batch-oracle finalizer calls; deterministic input construction and warmups are outside each timed sample.

- Seed: `20260915`
- Warmups per case: `1`; timed repetitions per case: `3`
- AR/ADF/KPSS n: `256,1024,4096`
- AR p: `1,4,8`; ADF p: `0,2,4`
- KPSS trend q: `0,8,32`
- Change-point n: `256,1024,4096`, min segment `8`

`tracemalloc_peak_bytes` is Python-traced allocation during one call, not process RSS or a native allocator measurement.
The change-point oracle is an intentionally direct O(n²) reference scan, so its size cap is stricter than the other cases.

| finalizer | n | p | q | regression | min segment | median ms | min–max ms | median traced peak bytes | checksum |
|---|---:|---:|---:|---|---:|---:|---:|---:|---|
| adf_statistic | 1024 | 0 |  | constant |  | 17.773 | 17.625–17.888 | 210016 | `31802c25448b1e03` |
| adf_statistic | 1024 | 2 |  | constant |  | 31.905 | 28.295–32.264 | 210892 | `c6228aa4a875de5c` |
| adf_statistic | 1024 | 4 |  | constant |  | 31.337 | 30.651–34.221 | 245132 | `ce8e105f42cbea3b` |
| adf_statistic | 256 | 0 |  | constant |  | 3.894 | 3.822–3.903 | 48672 | `f6933bc81724c223` |
| adf_statistic | 256 | 2 |  | constant |  | 4.993 | 4.954–5.118 | 49548 | `8bf35a8daad93a03` |
| adf_statistic | 256 | 4 |  | constant |  | 6.760 | 6.678–6.786 | 59212 | `918b9847db50ba69` |
| adf_statistic | 4096 | 0 |  | constant |  | 78.213 | 73.034–78.254 | 847840 | `306626b8d4171337` |
| adf_statistic | 4096 | 2 |  | constant |  | 100.665 | 99.239–103.857 | 848716 | `02d7da3d6623461c` |
| adf_statistic | 4096 | 4 |  | constant |  | 130.798 | 129.793–131.613 | 981260 | `95ff2b12340ae84b` |
| kpss_test | 1024 |  | 0 | trend |  | 5.382 | 5.351–5.431 | 153132 | `ae1029e5d05455c3` |
| kpss_test | 1024 |  | 32 | trend |  | 30.178 | 30.159–30.618 | 153132 | `10f211845ca9cb20` |
| kpss_test | 1024 |  | 8 | trend |  | 11.638 | 11.348–11.672 | 153132 | `7a24055df912c23f` |
| kpss_test | 256 |  | 0 | trend |  | 1.272 | 1.270–1.294 | 34096 | `8b5c00a6a5ea48d2` |
| kpss_test | 256 |  | 32 | trend |  | 3.027 | 3.023–3.066 | 34096 | `aceabdefb84d8059` |
| kpss_test | 256 |  | 8 | trend |  | 1.741 | 1.715–1.742 | 34096 | `2f16196f94d58316` |
| kpss_test | 4096 |  | 0 | trend |  | 22.253 | 21.651–24.257 | 625260 | `06c398f86155453f` |
| kpss_test | 4096 |  | 32 | trend |  | 402.003 | 312.299–453.527 | 625260 | `5d3072b7e205d1f7` |
| kpss_test | 4096 |  | 8 | trend |  | 69.958 | 53.634–143.186 | 625260 | `0c85ea700cdf00e7` |
| lagged_linear_regression | 1024 | 1 |  |  |  | 13.877 | 12.345–17.332 | 176256 | `248c6d123f558573` |
| lagged_linear_regression | 1024 | 4 |  |  |  | 18.492 | 17.408–18.640 | 177128 | `6de5469ab8cf2538` |
| lagged_linear_regression | 1024 | 8 |  |  |  | 27.460 | 27.315–28.480 | 212040 | `aee68d24ffb7005b` |
| lagged_linear_regression | 256 | 1 |  |  |  | 2.913 | 2.855–2.938 | 40032 | `f9853efe5a03400a` |
| lagged_linear_regression | 256 | 4 |  |  |  | 3.849 | 3.783–3.859 | 40904 | `1f08c2286f0c93f6` |
| lagged_linear_regression | 256 | 8 |  |  |  | 6.149 | 6.104–6.185 | 51240 | `cec75af7c5bb357b` |
| lagged_linear_regression | 4096 | 1 |  |  |  | 62.911 | 50.925–71.710 | 716160 | `eafdebff989d1362` |
| lagged_linear_regression | 4096 | 4 |  |  |  | 80.732 | 70.063–89.692 | 717032 | `5c5b8f2b893b15f0` |
| lagged_linear_regression | 4096 | 8 |  |  |  | 123.553 | 109.642–166.972 | 850304 | `a9244ecf186619f6` |
| single_mean_shift_change_point | 1024 |  |  |  | 8 | 917.798 | 911.786–963.949 | 88752 | `8b6a08d8a7460132` |
| single_mean_shift_change_point | 256 |  |  |  | 8 | 59.250 | 52.109–66.637 | 21104 | `4f10a3205ff70af8` |
| single_mean_shift_change_point | 4096 |  |  |  | 8 | 5824.721 | 5223.022–16362.563 | 359088 | `5637bf30e5e3b74d` |

Raw repetitions are in `results.csv`; machine/runtime/configuration metadata and the same rows are in `results.json`.
