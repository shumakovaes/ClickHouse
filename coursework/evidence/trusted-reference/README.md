# Trusted reference validation

> Archived baseline record: this Python reference run supports the historical
> three-API coursework evidence only. It is not validation of later extensions
> or additional APIs.

This record captures the isolated optional-dependency run of the Python
reference suite. The virtual environment was created under
`work/trusted_reference_venv`, outside this package, and no environment files
or Python caches are included here.

## Environment

| Component | Version |
|---|---|
| Python | 3.12.6 (Windows AMD64) |
| NumPy | 2.5.3 |
| SciPy | 1.18.1 |
| statsmodels | 0.15.0 |
| pandas | 3.0.5 |

## Command and result

From `coursework/reference/python/`, the exact command was:

```text
C:\Users\79261\Documents\Codex\2026-09-10\re\work\trusted_reference_venv\Scripts\python.exe -m unittest -v test_reference
```

Result: **15/15 tests passed** in both the workspace reference copy and the
packaged copy. The optional NumPy/statsmodels test ran (rather than being
skipped), covering ACF, Ljung--Box, and KPSS comparisons. Statsmodels emitted
only its expected interpolation/future warnings.

## Compatibility correction

Statsmodels 0.15 changed `nlags="legacy"` to use a ceiling bandwidth, while
this oracle deliberately defines its default KPSS bandwidth with a floor. The
optional cross-check therefore now passes the oracle's explicit bandwidth to
statsmodels. This changes only the validation comparison; production code and
the oracle's stated convention are unchanged.
