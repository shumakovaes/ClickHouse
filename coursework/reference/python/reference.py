"""Independent oracle for the production keyed time-series diagnostics API.

This module deliberately stores observations in an immutable-like list.  It is
an oracle for implementations that use compact monoids: its `merge` operation
has the same ordered/no-overlap contract, while every statistic is calculated
directly from the merged observations.  That makes it suitable for property
tests even when the implementation under test has a radically different state
layout. `FullSampleKeyedStats` implements exactly the three baseline diagnostic
finalizers: single-lag autocorrelation, Ljung--Box (Q and p-value), and
Durbin--Watson. It accepts rows in any order and canonicalizes by UInt64 key.
`OrderedStats` remains below only as a deliberately constrained research
prototype for experiments outside that production contract.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import math
from typing import Iterable, Sequence


Number = float | int
UINT64_MAX = (1 << 64) - 1
DEFAULT_MAX_SAMPLES = 1_000_000


def _finite(x: Number) -> float:
    x = float(x)
    if not math.isfinite(x):
        raise ValueError("observations must be finite")
    return x


def _uint64(key: int) -> int:
    if not isinstance(key, int) or isinstance(key, bool) or not 0 <= key <= UINT64_MAX:
        raise ValueError("keys must be UInt64 integers")
    return key


def _close(a: float, b: float, atol: float = 1e-12) -> bool:
    return (math.isnan(a) and math.isnan(b)) or abs(a - b) <= atol


def chi_square_sf(statistic: float, degrees_of_freedom: int) -> float:
    """Chi-square survival function using the regularized incomplete gamma Q.

    This dependency-free implementation is adapted from the stable series /
    continued-fraction split used in numerical libraries. It avoids making the
    production oracle's p-value contingent on scipy or statsmodels.
    """
    if not isinstance(degrees_of_freedom, int) or isinstance(degrees_of_freedom, bool) or degrees_of_freedom <= 0:
        raise ValueError("degrees_of_freedom must be a positive integer")
    if math.isnan(statistic) or statistic < 0.0:
        return math.nan
    if math.isinf(statistic):
        return 0.0
    a, x = degrees_of_freedom / 2.0, statistic / 2.0
    if x == 0.0:
        return 1.0
    log_factor = -x + a * math.log(x) - math.lgamma(a)
    eps, tiny, max_iter = 3e-14, 1e-300, 10_000
    if x < a + 1.0:
        # P(a,x) series; Q is its complement.
        term = total = 1.0 / a
        for i in range(1, max_iter + 1):
            term *= x / (a + i)
            total += term
            if abs(term) <= abs(total) * eps:
                return max(0.0, min(1.0, 1.0 - total * math.exp(log_factor)))
    else:
        # Lentz continued fraction for Q(a,x).
        b = x + 1.0 - a
        c, d = 1.0 / tiny, 1.0 / max(b, tiny)
        h = d
        for i in range(1, max_iter + 1):
            an = -i * (i - a)
            b += 2.0
            d = an * d + b
            if abs(d) < tiny:
                d = tiny
            c = b + an / c
            if abs(c) < tiny:
                c = tiny
            d = 1.0 / d
            delta = d * c
            h *= delta
            if abs(delta - 1.0) <= eps:
                return max(0.0, min(1.0, math.exp(log_factor) * h))
    raise ArithmeticError("incomplete gamma did not converge")


@dataclass(frozen=True)
class LjungBoxResult:
    """The exact Tuple(statistic, p_value) production result shape."""

    statistic: float
    p_value: float


@dataclass(frozen=True)
class OrderedStats:
    """Range-ordered research prototype, not an arbitrary-key production state.

    This type is retained to model compact segment/range monoids. Its merge
    requires left keys to all precede right keys, so callers with interleaved
    states must use :class:`FullSampleKeyedStats` instead.
    """

    points: tuple[tuple[int, float], ...] = ()

    def __post_init__(self) -> None:
        keys = [k for k, _ in self.points]
        if any(not isinstance(k, int) or isinstance(k, bool) for k in keys):
            raise TypeError("keys must be integers")
        if keys != sorted(keys) or len(set(keys)) != len(keys):
            raise ValueError("keys must be strictly increasing and unique")
        object.__setattr__(self, "points", tuple((k, _finite(v)) for k, v in self.points))

    @classmethod
    def from_pairs(cls, pairs: Iterable[tuple[int, Number]]) -> "OrderedStats":
        return cls(tuple((int(k), _finite(v)) for k, v in pairs))

    @classmethod
    def from_values(cls, values: Iterable[Number], start_key: int = 0) -> "OrderedStats":
        return cls(tuple((start_key + i, _finite(v)) for i, v in enumerate(values)))

    @property
    def keys(self) -> tuple[int, ...]:
        return tuple(k for k, _ in self.points)

    @property
    def values(self) -> tuple[float, ...]:
        return tuple(v for _, v in self.points)

    @property
    def n(self) -> int:
        return len(self.points)

    def merge(self, right: "OrderedStats") -> "OrderedStats":
        """Concatenate two adjacent ordered segments; reject gaps/overlaps ambiguity.

        Keys establish global ordering.  A merge is legal only if every key in
        self precedes every key in right. Empty states are identities.
        """
        if not self.points:
            return right
        if not right.points:
            return self
        if self.points[-1][0] >= right.points[0][0]:
            raise ValueError("merge requires non-overlapping left-before-right key ranges")
        return OrderedStats(self.points + right.points)

    def split_at(self, index: int) -> tuple["OrderedStats", "OrderedStats"]:
        if not 0 <= index <= self.n:
            raise IndexError("split index outside [0, n]")
        return OrderedStats(self.points[:index]), OrderedStats(self.points[index:])

    def to_json(self) -> str:
        """Canonical, cross-language-friendly serialized state."""
        return json.dumps({"version": 1, "points": [[k, v] for k, v in self.points]},
                          allow_nan=False, separators=(",", ":"))

    @classmethod
    def from_json(cls, encoded: str) -> "OrderedStats":
        raw = json.loads(encoded)
        if raw.get("version") != 1 or not isinstance(raw.get("points"), list):
            raise ValueError("unsupported stats state")
        return cls.from_pairs((p[0], p[1]) for p in raw["points"])

    def _centered(self) -> tuple[float, ...]:
        if not self.n:
            return ()
        mean = math.fsum(self.values) / self.n
        return tuple(v - mean for v in self.values)

    def acf(self, max_lag: int) -> list[float]:
        """Sample-mean centered ACF, with unnormalised covariance sums.

        ACF[0] is 1 for a nonconstant nonempty series. Undefined lags and
        constant/empty series are NaN, rather than quietly returning zero.
        """
        if max_lag < 0:
            raise ValueError("max_lag must be non-negative")
        z = self._centered()
        denom = math.fsum(x * x for x in z)
        out: list[float] = []
        for lag in range(max_lag + 1):
            if lag >= self.n or denom == 0.0:
                out.append(math.nan)
            else:
                out.append(math.fsum(z[i] * z[i + lag] for i in range(self.n - lag)) / denom)
        return out

    def ljung_box(self, lags: int) -> float:
        """Ljung--Box Q using all lags min(lags, n-1); no p-value is implied."""
        if lags < 1:
            raise ValueError("lags must be positive")
        m = min(lags, self.n - 1)
        if m < 1:
            return math.nan
        rho = self.acf(m)
        if any(math.isnan(x) for x in rho[1:]):
            return math.nan
        return self.n * (self.n + 2.0) * math.fsum(rho[h] ** 2 / (self.n - h) for h in range(1, m + 1))

    def durbin_watson(self) -> float:
        y = self.values
        if not y:
            return math.nan
        denom = math.fsum(v * v for v in y)
        return math.nan if denom == 0.0 else math.fsum((y[i] - y[i - 1]) ** 2 for i in range(1, self.n)) / denom

    def ar1(self, steps: int = 1) -> dict[str, float]:
        """OLS y[t] = intercept + phi*y[t-1], and a `steps`-ahead forecast."""
        if steps < 1:
            raise ValueError("steps must be positive")
        if self.n < 2:
            return {"intercept": math.nan, "phi": math.nan, "forecast": math.nan}
        x, y = self.values[:-1], self.values[1:]
        xb, yb = math.fsum(x) / len(x), math.fsum(y) / len(y)
        sxx = math.fsum((v - xb) ** 2 for v in x)
        if sxx == 0.0:
            return {"intercept": math.nan, "phi": math.nan, "forecast": math.nan}
        phi = math.fsum((a - xb) * (b - yb) for a, b in zip(x, y)) / sxx
        intercept = yb - phi * xb
        if abs(phi - 1.0) <= 1e-14:
            forecast = self.values[-1] + steps * intercept
        else:
            forecast = phi ** steps * self.values[-1] + intercept * (1.0 - phi ** steps) / (1.0 - phi)
        return {"intercept": intercept, "phi": phi, "forecast": forecast}

    def kpss(self, bandwidth: int | None = None) -> float:
        """Level KPSS statistic with Bartlett/Newey--West long-run variance.

        Default bandwidth is floor(12*(n/100)^0.25), capped at n-1. This is a
        statistic only; callers should obtain critical values elsewhere.
        """
        n = self.n
        if n < 2:
            return math.nan
        if bandwidth is None:
            bandwidth = min(n - 1, int(math.floor(12.0 * (n / 100.0) ** 0.25)))
        if not 0 <= bandwidth < n:
            raise ValueError("bandwidth must be in [0, n-1]")
        z = self._centered()
        gamma0 = math.fsum(v * v for v in z) / n
        lrv = gamma0
        for h in range(1, bandwidth + 1):
            gamma = math.fsum(z[i] * z[i + h] for i in range(n - h)) / n
            lrv += 2.0 * (1.0 - h / (bandwidth + 1.0)) * gamma
        if lrv <= 0.0 or not math.isfinite(lrv):
            return math.nan
        partial = 0.0
        ss = 0.0
        for v in z:
            partial += v
            ss += partial * partial
        return ss / (n * n * lrv)

    def summary(self, max_lag: int = 10, kpss_bandwidth: int | None = None) -> dict[str, object]:
        return {"n": self.n, "acf": self.acf(max_lag), "ljung_box": self.ljung_box(max_lag),
                "durbin_watson": self.durbin_watson(), "ar1": self.ar1(),
                "kpss": self.kpss(kpss_bandwidth)}


@dataclass(frozen=True)
class FullSampleKeyedStats:
    """Production-correct full-sample keyed state.

    Every construction and merge sorts by key, rejects duplicate keys, and
    preserves all samples (up to ``max_samples``). Thus finalization is stable
    for arbitrary input row order and arbitrary, including interleaving, state
    merge trees. Key order determines temporal order; input order never does.
    """

    points: tuple[tuple[int, float], ...] = ()
    max_samples: int = DEFAULT_MAX_SAMPLES

    def __post_init__(self) -> None:
        if (not isinstance(self.max_samples, int) or isinstance(self.max_samples, bool)
                or not 1 <= self.max_samples <= 10_000_000):
            raise ValueError("max_samples must be in [1, 10000000]")
        if len(self.points) > self.max_samples:
            raise ValueError("max_samples cap exceeded")
        normalized = sorted((_uint64(k), _finite(v)) for k, v in self.points)
        if any(normalized[i - 1][0] == normalized[i][0] for i in range(1, len(normalized))):
            raise ValueError("duplicate key")
        object.__setattr__(self, "points", tuple(normalized))

    @classmethod
    def from_pairs(cls, pairs: Iterable[tuple[int, Number]], max_samples: int = DEFAULT_MAX_SAMPLES) -> "FullSampleKeyedStats":
        # Materialize once: validation must see duplicate keys anywhere in an
        # arbitrary iterator before exposing a state.
        return cls(tuple((_uint64(k), _finite(v)) for k, v in pairs), max_samples)

    @property
    def n(self) -> int:
        return len(self.points)

    @property
    def keys(self) -> tuple[int, ...]:
        return tuple(k for k, _ in self.points)

    @property
    def values(self) -> tuple[float, ...]:
        return tuple(v for _, v in self.points)

    def merge(self, other: "FullSampleKeyedStats") -> "FullSampleKeyedStats":
        """Merge states regardless of key-range overlap, then canonicalize.

        Any duplicate key, including one split across states, is rejected. A
        common cap is required so successful trees have a well-defined memory
        contract independent of parenthesization.
        """
        if self.max_samples != other.max_samples:
            raise ValueError("cannot merge states with different max_samples")
        if self.n + other.n > self.max_samples:
            raise ValueError("max_samples cap exceeded")
        return FullSampleKeyedStats(self.points + other.points, self.max_samples)

    def split_at(self, sorted_index: int) -> tuple["FullSampleKeyedStats", "FullSampleKeyedStats"]:
        if not 0 <= sorted_index <= self.n:
            raise IndexError("split index outside [0, n]")
        return (FullSampleKeyedStats(self.points[:sorted_index], self.max_samples),
                FullSampleKeyedStats(self.points[sorted_index:], self.max_samples))

    def to_json(self) -> str:
        return json.dumps({"version": 2, "kind": "full-sample-keyed", "maxSamples": self.max_samples,
                           "points": [[k, v] for k, v in self.points]}, allow_nan=False, separators=(",", ":"))

    @classmethod
    def from_json(cls, encoded: str, expected_max_samples: int | None = None) -> "FullSampleKeyedStats":
        """Read canonical state only; unlike row ingestion, never reorder JSON.

        The optional expected cap models aggregate deserialization: serialized
        and configured limits must be identical, rather than silently adopting
        a potentially hostile state payload's memory policy.
        """
        raw = json.loads(encoded)
        if raw.get("version") != 2 or raw.get("kind") != "full-sample-keyed" or not isinstance(raw.get("points"), list):
            raise ValueError("unsupported full-sample keyed state")
        serialized_cap = raw.get("maxSamples")
        if expected_max_samples is not None and serialized_cap != expected_max_samples:
            raise ValueError("serialized max_samples does not match expected max_samples")
        raw_points = raw["points"]
        if len(raw_points) > 10_000_000:
            raise ValueError("serialized sample count exceeds hard cap")
        points: list[tuple[int, float]] = []
        previous: int | None = None
        for item in raw_points:
            if not isinstance(item, list) or len(item) != 2:
                raise ValueError("invalid serialized point")
            key, value = _uint64(item[0]), _finite(item[1])
            if previous is not None and key <= previous:
                raise ValueError("serialized points must be strictly increasing")
            points.append((key, value))
            previous = key
        return cls(tuple(points), serialized_cap)

    def _ordered(self) -> OrderedStats:
        # `points` is canonicalized on every entry path. Reuse only the direct
        # formulas, not the range state's merge semantics.
        return OrderedStats(self.points)

    def _normalized_centered(self) -> tuple[float, ...] | None:
        """Return centered values in a safe O(1)-scale coordinate system.

        Centering directly around `sum(x)/n` loses useful low bits for a large
        common offset and squaring raw values can overflow (or underflow) even
        when the final statistic is perfectly representable. First translating
        by an overflow-safe min/max midpoint, then dividing by the largest
        translated magnitude, preserves all representable variation and makes
        every subsequent product bounded. The ACF is invariant to both affine
        transformations.
        """
        if not self.n:
            return None
        values = self.values
        low, high = min(values), max(values)
        # `low / 2 + high / 2` cannot overflow merely because low/high have
        # opposite signs, unlike `(low + high) / 2`.
        location = low / 2.0 + high / 2.0
        translated = tuple(value - location for value in values)
        scale = max(abs(value) for value in translated)
        if scale == 0.0:
            return None
        normalized = tuple(value / scale for value in translated)
        mean = math.fsum(normalized) / self.n
        return tuple(value - mean for value in normalized)

    def autocorrelation(self, lag: int) -> float:
        """Biased, sample-mean-centered ACF at one explicit lag, including 0.

        Lag zero is 1 for a nonconstant series. It is NaN for empty or
        constant data, consistent with the zero centered-sum denominator.
        A lag outside ``[0, n-1]`` is insufficient data and returns NaN.
        """
        if not isinstance(lag, int) or isinstance(lag, bool) or lag < 0:
            raise ValueError("lag must be a non-negative integer")
        if lag >= self.n:
            return math.nan
        centered = self._normalized_centered()
        if centered is None:
            return math.nan
        denominator = math.fsum(value * value for value in centered)
        if not denominator > 0.0:
            return math.nan
        numerator = math.fsum(centered[i] * centered[i - lag] for i in range(lag, self.n))
        return numerator / denominator

    def ljung_box(self, max_lag: int, model_df: int = 0) -> LjungBoxResult:
        """Return Q and chi-square survival p-value.

        ``max_lag`` must be positive and ``0 <= model_df < max_lag``. If the
        complete lag range is unavailable (n <= max_lag), or ACF is undefined,
        both fields are NaN; the method never silently shortens the test.
        """
        if not isinstance(max_lag, int) or isinstance(max_lag, bool) or max_lag < 1:
            raise ValueError("max_lag must be a positive integer")
        if (not isinstance(model_df, int) or isinstance(model_df, bool)
                or model_df < 0 or model_df >= max_lag):
            raise ValueError("model_df must satisfy 0 <= model_df < max_lag")
        if self.n <= max_lag:
            return LjungBoxResult(math.nan, math.nan)
        terms = []
        for lag in range(1, max_lag + 1):
            rho = self.autocorrelation(lag)
            if not math.isfinite(rho):
                return LjungBoxResult(math.nan, math.nan)
            terms.append(rho * rho / (self.n - lag))
        q = self.n * (self.n + 2.0) * math.fsum(terms)
        return LjungBoxResult(q, chi_square_sf(q, max_lag - model_df))

    def durbin_watson(self) -> float:
        if self.n < 2:
            return math.nan
        # DW is invariant to nonzero scaling, so normalizing raw values avoids
        # both x*x overflow near 1e200 and subnormal/zero products near 1e-200.
        scale = max(abs(value) for value in self.values)
        if scale == 0.0:
            return math.nan
        values = tuple(value / scale for value in self.values)
        denominator = math.fsum(value * value for value in values)
        if not denominator > 0.0:
            return math.nan
        numerator = math.fsum((values[i] - values[i - 1]) ** 2 for i in range(1, self.n))
        return numerator / denominator



def same_float(a: float, b: float, atol: float = 1e-10) -> bool:
    """Public helper for NaN-aware property assertions."""
    return _close(a, b, atol)
