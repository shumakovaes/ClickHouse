"""Independent batch oracles for exploratory time-series statistics.

The functions here intentionally do not import the production reference state.
They retain a small amount of data only for a single batch calculation and use
standard-library arithmetic so that tests can compare a separately structured
implementation with native code or third-party libraries.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Iterable


def _values(values: Iterable[float]) -> tuple[float, ...]:
    out = tuple(float(x) for x in values)
    if any(not math.isfinite(x) for x in out):
        raise ValueError("values must be finite")
    return out


def _solve(a: list[list[float]], b: list[float]) -> list[float]:
    """Small pivoted Gaussian elimination; raises on a singular design."""
    n = len(b)
    m = [row[:] + [rhs] for row, rhs in zip(a, b)]
    scale = max((abs(x) for row in a for x in row), default=0.0)
    tol = max(1e-14 * scale, 1e-300)
    for col in range(n):
        pivot = max(range(col, n), key=lambda i: abs(m[i][col]))
        if abs(m[pivot][col]) <= tol:
            raise ValueError("singular regression design")
        m[col], m[pivot] = m[pivot], m[col]
        p = m[col][col]
        for j in range(col, n + 1):
            m[col][j] /= p
        for i in range(n):
            if i == col:
                continue
            factor = m[i][col]
            if factor:
                for j in range(col, n + 1):
                    m[i][j] -= factor * m[col][j]
    return [m[i][n] for i in range(n)]


@dataclass(frozen=True)
class LaggedRegressionResult:
    coefficients: tuple[float, ...]
    nobs: int
    sse: float

    @property
    def intercept(self) -> float:
        return self.coefficients[0]

    @property
    def lags(self) -> tuple[float, ...]:
        return self.coefficients[1:]


def lagged_linear_regression(values: Iterable[float], order: int) -> LaggedRegressionResult:
    """OLS ``y[t] = c + sum(phi[j] * y[t-j])`` for a fixed lag order."""
    y = _values(values)
    if not isinstance(order, int) or isinstance(order, bool) or order < 1:
        raise ValueError("order must be a positive integer")
    nobs = len(y) - order
    if nobs <= order + 1:
        raise ValueError("too few observations for lagged regression")
    rows = [[1.0, *[y[t - j] for j in range(1, order + 1)]] for t in range(order, len(y))]
    target = list(y[order:])
    xtx = [[math.fsum(row[i] * row[j] for row in rows) for j in range(order + 1)] for i in range(order + 1)]
    xty = [math.fsum(row[i] * value for row, value in zip(rows, target)) for i in range(order + 1)]
    beta = _solve(xtx, xty)
    residuals = [value - math.fsum(c * x for c, x in zip(beta, row)) for row, value in zip(rows, target)]
    return LaggedRegressionResult(tuple(beta), nobs, math.fsum(e * e for e in residuals))


def _ols_statistic(y: tuple[float, ...], rows: list[list[float]], target: list[float], coefficient: int) -> float:
    k = len(rows[0])
    xtx = [[math.fsum(row[i] * row[j] for row in rows) for j in range(k)] for i in range(k)]
    xty = [math.fsum(row[i] * value for row, value in zip(rows, target)) for i in range(k)]
    beta = _solve(xtx, xty)
    residuals = [value - math.fsum(c * x for c, x in zip(beta, row)) for row, value in zip(rows, target)]
    df = len(target) - k
    if df <= 0:
        raise ValueError("too few observations for ADF regression")
    sigma2 = math.fsum(e * e for e in residuals) / df
    inv_col = _solve(xtx, [1.0 if i == coefficient else 0.0 for i in range(k)])
    variance = sigma2 * inv_col[coefficient]
    if variance <= 0 or not math.isfinite(variance):
        raise ValueError("singular ADF variance")
    return beta[coefficient] / math.sqrt(variance)


def adf_statistic(values: Iterable[float], p: int, deterministic: str = "constant") -> float:
    """ADF t-statistic with fixed lag ``p`` and no p-value interpolation."""
    y = _values(values)
    if not isinstance(p, int) or isinstance(p, bool) or p < 0:
        raise ValueError("p must be a non-negative integer")
    if deterministic not in {"none", "constant", "trend"}:
        raise ValueError("deterministic must be none, constant, or trend")
    # Match statsmodels' fixed-lag feasibility guard: n >= 2*p + 2 for no
    # deterministic terms, then two additional observations per deterministic
    # column (constant or constant+trend).
    deterministic_columns = {"none": 0, "constant": 1, "trend": 2}[deterministic]
    if len(y) < 2 * p + 2 + 2 * deterministic_columns:
        raise ValueError("too few observations for ADF")
    dy = tuple(y[i] - y[i - 1] for i in range(1, len(y)))
    rows, target = [], []
    for t in range(p + 1, len(y)):
        row = ([1.0] if deterministic in {"constant", "trend"} else [])
        if deterministic == "trend":
            row.append(float(t))
        row.append(y[t - 1])
        row.extend(dy[t - 1 - j] for j in range(1, p + 1))
        rows.append(row)
        target.append(dy[t - 1])
    coefficient = (0 if deterministic == "none" else 1 + (deterministic == "trend"))
    return _ols_statistic(y, rows, target, coefficient)


@dataclass(frozen=True)
class KPSSResult:
    statistic: float
    bandwidth: int


def kpss_test(values: Iterable[float], regression: str = "level", bandwidth: int | str = "default", *, q: int | None = None) -> KPSSResult:
    """KPSS statistic using Bartlett HAC; default q is a documented floor rule.

    ``q`` is accepted as a keyword alias for ``bandwidth``. The default is
    ``floor(12*(n/100)**0.25)``, capped at ``n-1``; no external package's
    legacy mode is implied.
    """
    y = _values(values)
    n = len(y)
    if n < 2:
        raise ValueError("at least two observations are required")
    if regression not in {"level", "trend"}:
        raise ValueError("regression must be level or trend")
    t = tuple(float(i) for i in range(n))
    if regression == "trend":
        rows = [[1.0, x] for x in t]
        beta = _solve([[math.fsum(r[i] * r[j] for r in rows) for j in range(2)] for i in range(2)],
                      [math.fsum(r[i] * z for r, z in zip(rows, y)) for i in range(2)])
        residuals = tuple(z - beta[0] - beta[1] * x for z, x in zip(y, t))
    else:
        mean = math.fsum(y) / n
        residuals = tuple(z - mean for z in y)
    if q is not None:
        if bandwidth != "default":
            raise ValueError("specify either q or bandwidth, not both")
        bandwidth = q
    if bandwidth == "default":
        bw = min(n - 1, int(math.floor(12.0 * (n / 100.0) ** 0.25)))
    elif isinstance(bandwidth, int) and not isinstance(bandwidth, bool):
        bw = bandwidth
    else:
        raise ValueError("bandwidth must be an integer or 'default'")
    if not 0 <= bw < n:
        raise ValueError("bandwidth must be in [0, n-1]")
    lrv = math.fsum(x * x for x in residuals) / n
    for lag in range(1, bw + 1):
        gamma = math.fsum(residuals[i] * residuals[i - lag] for i in range(lag, n)) / n
        lrv += 2.0 * (1.0 - lag / (bw + 1.0)) * gamma
    if lrv <= 0 or not math.isfinite(lrv):
        return KPSSResult(math.nan, bw)
    partial = 0.0
    ss = 0.0
    for x in residuals:
        partial += x
        ss += partial * partial
    return KPSSResult(ss / (n * n * lrv), bw)


def kpss_keyed(points: Iterable[tuple[float, float]], regression: str = "level", q: int | None = None) -> KPSSResult:
    """Sort unique ``(key, value)`` observations, then apply :func:`kpss_test`."""
    rows = sorted((float(key), float(value)) for key, value in points)
    if any(not math.isfinite(k) or not math.isfinite(v) for k, v in rows):
        raise ValueError("keys and values must be finite")
    if any(rows[i - 1][0] == rows[i][0] for i in range(1, len(rows))):
        raise ValueError("duplicate key")
    return kpss_test((v for _, v in rows), regression, q=q)


@dataclass(frozen=True)
class MeanShiftResult:
    index: int
    before_mean: float
    after_mean: float
    sse: float
    sse_reduction: float


def single_mean_shift_change_point(values: Iterable[float], min_segment: int = 1) -> MeanShiftResult:
    """Exact one-break mean fit, with earliest split on ties."""
    y = _values(values)
    if not isinstance(min_segment, int) or isinstance(min_segment, bool) or min_segment < 1:
        raise ValueError("min_segment must be a positive integer")
    if len(y) < 2 * min_segment:
        raise ValueError("too few observations for requested minimum segment")
    # Work in a bounded coordinate system: the selected split and relative
    # improvement are invariant to nonzero affine scaling, while raw squares
    # can overflow at 1e200 or underflow at 1e-200.
    low, high = min(y), max(y)
    location = low / 2.0 + high / 2.0
    translated = tuple(x - location for x in y)
    scale = max((abs(x) for x in translated), default=0.0)
    if scale == 0.0:
        return MeanShiftResult(0, math.nan, math.nan, math.nan, math.nan)
    z = tuple(x / scale for x in translated)
    total_mean = math.fsum(z) / len(z)
    total_sse = math.fsum((x - total_mean) ** 2 for x in z)
    best = None
    for k in range(min_segment, len(y) - min_segment + 1):
        left, right = z[:k], z[k:]
        lm, rm = math.fsum(left) / k, math.fsum(right) / (len(y) - k)
        sse = math.fsum((x - lm) ** 2 for x in left) + math.fsum((x - rm) ** 2 for x in right)
        if best is None or sse < best[0]:
            best = (sse, k, lm, rm)
    assert best is not None
    sse, k, lm, rm = best
    reduction = (total_sse - sse) / total_sse if total_sse else math.nan
    if not reduction > 0.0:
        return MeanShiftResult(0, math.nan, math.nan, math.nan, math.nan)
    # Report the original-scale SSE/means.  Positive overflow is represented
    # honestly as +inf; the selected split and dimensionless score remain
    # useful.  Very small representable inputs may analogously underflow SSE
    # to zero after rescaling.
    before = location + lm * scale
    after = location + rm * scale
    original_sse = sse * scale * scale
    return MeanShiftResult(k, before, after, original_sse, reduction)
