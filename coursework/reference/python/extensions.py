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
    if len(y) <= p + 4:
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


def kpss_test(values: Iterable[float], regression: str = "level", bandwidth: int | str = "legacy") -> KPSSResult:
    """KPSS statistic using Bartlett HAC; ``regression`` is level or trend."""
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
    if bandwidth == "legacy":
        bw = min(n - 1, int(math.floor(12.0 * (n / 100.0) ** 0.25)))
    elif isinstance(bandwidth, int) and not isinstance(bandwidth, bool):
        bw = bandwidth
    else:
        raise ValueError("bandwidth must be an integer or legacy")
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
    total_mean = math.fsum(y) / len(y)
    total_sse = math.fsum((x - total_mean) ** 2 for x in y)
    best = None
    for k in range(min_segment, len(y) - min_segment + 1):
        left, right = y[:k], y[k:]
        lm, rm = math.fsum(left) / k, math.fsum(right) / (len(y) - k)
        sse = math.fsum((x - lm) ** 2 for x in left) + math.fsum((x - rm) ** 2 for x in right)
        if best is None or sse < best[0]:
            best = (sse, k, lm, rm)
    assert best is not None
    sse, k, lm, rm = best
    reduction = 0.0 if total_sse == 0.0 else (total_sse - sse) / total_sse
    return MeanShiftResult(k, lm, rm, sse, reduction)
