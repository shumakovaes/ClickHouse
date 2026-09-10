"""Reproducible simulations for common time-series diagnostics.

The implementation intentionally depends only on the Python standard library and
NumPy.  SciPy is used when installed for a more accurate chi-square p-value;
otherwise a documented Wilson--Hilferty approximation is used.  Run this file
from the coursework package root, or pass an explicit output directory::

    py evidence/experiments/run_experiments.py --reps 200 --n 300

Generated files are ``results.csv``, ``repeat_summary.csv``, ``summary.md`` and,
when Matplotlib is installed, ``acf_diagnostics.png``.
"""

from __future__ import annotations

import argparse
import csv
import importlib.metadata
import importlib.util
import json
import math
import os
import platform
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

import numpy as np


PROCESS_NAMES = ("white_noise", "ar1_phi_0.5", "ar1_phi_0.9", "random_walk", "trend_stationary", "mean_shift")


@dataclass(frozen=True)
class ExperimentConfig:
    n: int = 300
    reps: int = 200
    seed: int = 20260910
    max_lag: int = 20
    mean_shift: float = 2.0
    trend_slope: float = 0.01


def generate_series(kind: str, n: int, rng: np.random.Generator, *, phi: float | None = None,
                    trend_slope: float = 0.01, mean_shift: float = 2.0) -> np.ndarray:
    """Generate one series, using N(0,1) innovations and explicit conventions."""
    e = rng.normal(size=n)
    if kind == "white_noise":
        return e
    if kind == "ar1":
        if phi is None or abs(phi) >= 1:
            raise ValueError("AR(1) requires phi with |phi| < 1")
        y = np.empty(n)
        y[0] = e[0] / math.sqrt(1 - phi * phi)  # stationary initialization
        for t in range(1, n):
            y[t] = phi * y[t - 1] + e[t]
        return y
    if kind == "random_walk":
        return np.cumsum(e)
    if kind == "trend_stationary":
        t = np.arange(n, dtype=float)
        return trend_slope * t + e
    if kind == "mean_shift":
        y = e.copy()
        y[n // 2:] += mean_shift
        return y
    raise ValueError(f"unknown process: {kind}")


def acf(x: Iterable[float], nlags: int = 20) -> np.ndarray:
    """Biased sample ACF from lag zero through ``nlags``."""
    z = np.asarray(list(x), dtype=float)
    if z.ndim != 1 or z.size < 2:
        raise ValueError("x must contain at least two observations")
    z = z - z.mean()
    denom = float(np.dot(z, z))
    if denom == 0:
        return np.full(min(nlags, z.size - 1) + 1, np.nan)
    return np.array([float(np.dot(z[: z.size - k], z[k:]) / denom) for k in range(min(nlags, z.size - 1) + 1)])


def _normal_sf(x: float) -> float:
    return 0.5 * math.erfc(x / math.sqrt(2.0))


def chi2_sf(stat: float, df: int) -> float:
    """Chi-square survival probability; SciPy when available, approximation otherwise."""
    if not np.isfinite(stat) or df <= 0:
        return float("nan")
    try:
        from scipy.stats import chi2  # type: ignore
        return float(chi2.sf(stat, df))
    except ImportError:
        # Wilson--Hilferty transformation is adequate for diagnostic summaries.
        z = ((stat / df) ** (1 / 3) - (1 - 2 / (9 * df))) / math.sqrt(2 / (9 * df))
        return _normal_sf(z)


def ljung_box(x: Iterable[float], lags: int = 20) -> tuple[float, float]:
    """Return Q statistic and p-value for the joint zero-autocorrelation test."""
    z = np.asarray(list(x), dtype=float)
    n = z.size
    lags = min(int(lags), n - 1)
    r = acf(z, lags)[1:]
    q = n * (n + 2) * float(np.sum((r * r) / (n - np.arange(1, lags + 1))))
    return q, chi2_sf(q, lags)


def durbin_watson(x: Iterable[float]) -> float:
    """Durbin--Watson ratio for the supplied sequence (typically model residuals)."""
    z = np.asarray(list(x), dtype=float)
    denom = float(np.dot(z, z))
    return float(np.dot(np.diff(z), np.diff(z)) / denom) if denom else float("nan")


def fit_ar1_forecast(x: Iterable[float]) -> tuple[float, float, float]:
    """OLS fit x[t] = intercept + phi*x[t-1] and one-step forecast."""
    y = np.asarray(list(x), dtype=float)
    if y.size < 3:
        raise ValueError("at least three observations are required")
    X = np.column_stack((np.ones(y.size - 1), y[:-1]))
    intercept, phi = np.linalg.lstsq(X, y[1:], rcond=None)[0]
    return float(intercept), float(phi), float(intercept + phi * y[-1])


def _ols_residuals(x: np.ndarray, regression: str) -> np.ndarray:
    t = np.arange(x.size, dtype=float)
    X = np.column_stack((np.ones(x.size), t)) if regression == "ct" else np.ones((x.size, 1))
    return x - X @ np.linalg.lstsq(X, x, rcond=None)[0]


def kpss_statistic(x: Iterable[float], regression: str = "c") -> float:
    """KPSS statistic with Newey--West long-run variance estimate.

    ``regression='c'`` tests level stationarity; ``'ct'`` removes a linear trend
    before testing trend stationarity.  This is the statistic, not a claim that
    a p-value is exact: the finite-sample KPSS distribution is non-standard.
    """
    if regression not in {"c", "ct"}:
        raise ValueError("regression must be 'c' or 'ct'")
    y = np.asarray(list(x), dtype=float)
    u = _ols_residuals(y, regression)
    n = y.size
    s = np.cumsum(u)
    bandwidth = max(1, min(n - 1, int(12 * (n / 100) ** 0.25)))
    gamma0 = float(np.dot(u, u) / n)
    long_run = gamma0
    for lag in range(1, bandwidth + 1):
        gamma = float(np.dot(u[lag:], u[:-lag]) / n)
        long_run += 2 * (1 - lag / (bandwidth + 1)) * gamma
    if long_run <= 0:
        return float("inf")
    return float(np.sum(s * s) / (n * n * long_run))


def kpss_pvalue(stat: float, regression: str = "c") -> float:
    """Conservative interpolation against standard KPSS critical values.

    Values are the commonly reported asymptotic critical values (10%, 5%, 2.5%,
    1%).  Exact p-values are not available from a simple closed form.
    """
    levels = (0.10, 0.05, 0.025, 0.01)
    critical = (0.347, 0.463, 0.574, 0.739) if regression == "c" else (0.119, 0.146, 0.176, 0.216)
    if not np.isfinite(stat):
        return 0.0
    if stat < critical[0]:
        return 0.10
    if stat >= critical[-1]:
        return 0.005
    for i in range(len(critical) - 1):
        if critical[i] <= stat < critical[i + 1]:
            # log-linear interpolation in the published tail probabilities.
            a, b = critical[i], critical[i + 1]
            w = (stat - a) / (b - a)
            return float(levels[i] + w * (levels[i + 1] - levels[i]))
    return 0.05


def one_run(kind: str, x: np.ndarray, max_lag: int) -> dict[str, float | str]:
    q, lb_p = ljung_box(x, max_lag)
    intercept, phi, forecast = fit_ar1_forecast(x)
    kpss_level = kpss_statistic(x, "c")
    kpss_trend = kpss_statistic(x, "ct")
    return {
        "process": kind,
        "n": int(x.size),
        "acf1": float(acf(x, 1)[1]),
        "ljung_box_q": q,
        "ljung_box_p": lb_p,
        "durbin_watson": durbin_watson(x),
        "ar1_intercept": intercept,
        "ar1_phi_hat": phi,
        "ar1_forecast": forecast,
        "kpss_level_stat": kpss_level,
        "kpss_level_p": kpss_pvalue(kpss_level, "c"),
        "kpss_trend_stat": kpss_trend,
        "kpss_trend_p": kpss_pvalue(kpss_trend, "ct"),
    }


def _specs(config: ExperimentConfig) -> list[tuple[str, Callable[[np.random.Generator], np.ndarray]]]:
    return [
        ("white_noise", lambda r: generate_series("white_noise", config.n, r)),
        ("ar1_phi_0.5", lambda r: generate_series("ar1", config.n, r, phi=0.5)),
        ("ar1_phi_0.9", lambda r: generate_series("ar1", config.n, r, phi=0.9)),
        ("random_walk", lambda r: generate_series("random_walk", config.n, r)),
        ("trend_stationary", lambda r: generate_series("trend_stationary", config.n, r, trend_slope=config.trend_slope)),
        ("mean_shift", lambda r: generate_series("mean_shift", config.n, r, mean_shift=config.mean_shift)),
    ]


def run(config: ExperimentConfig) -> tuple[list[dict], list[dict]]:
    if config.n < 30 or config.reps < 1:
        raise ValueError("n must be >= 30 and reps must be >= 1")
    rng = np.random.default_rng(config.seed)
    rows: list[dict] = []
    repeat: list[dict] = []
    for kind, generator in _specs(config):
        x = generator(rng)
        rows.append(one_run(kind, x, config.max_lag))
        lb_reject = 0
        kpss_level_reject = 0
        kpss_trend_reject = 0
        acf1_values: list[float] = []
        phi_values: list[float] = []
        for _ in range(config.reps):
            r = one_run(kind, generator(rng), config.max_lag)
            acf1_values.append(float(r["acf1"]))
            phi_values.append(float(r["ar1_phi_hat"]))
            lb_reject += int(float(r["ljung_box_p"]) < 0.05)
            kpss_level_reject += int(float(r["kpss_level_p"]) < 0.05)
            kpss_trend_reject += int(float(r["kpss_trend_p"]) < 0.05)
        acf_theory = {"white_noise": 0.0, "ar1_phi_0.5": 0.5, "ar1_phi_0.9": 0.9}.get(kind, float("nan"))
        phi_theory = {"white_noise": 0.0, "ar1_phi_0.5": 0.5, "ar1_phi_0.9": 0.9}.get(kind, float("nan"))
        acf_arr = np.asarray(acf1_values)
        phi_arr = np.asarray(phi_values)
        repeat.append({
            "process": kind,
            "reps": config.reps,
            "ljung_box_rejection_rate_5pct": lb_reject / config.reps,
            "kpss_level_rejection_rate_5pct": kpss_level_reject / config.reps,
            "kpss_trend_rejection_rate_5pct": kpss_trend_reject / config.reps,
            "acf1_theory": acf_theory,
            "acf1_mean": float(acf_arr.mean()),
            "acf1_bias": float(acf_arr.mean() - acf_theory) if np.isfinite(acf_theory) else float("nan"),
            "acf1_rmse": float(np.sqrt(np.mean((acf_arr - acf_theory) ** 2))) if np.isfinite(acf_theory) else float("nan"),
            "ar1_phi_theory": phi_theory,
            "ar1_phi_mean": float(phi_arr.mean()),
            "ar1_phi_bias": float(phi_arr.mean() - phi_theory) if np.isfinite(phi_theory) else float("nan"),
            "ar1_phi_rmse": float(np.sqrt(np.mean((phi_arr - phi_theory) ** 2))) if np.isfinite(phi_theory) else float("nan"),
        })
    return rows, repeat


def _write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def _write_markdown(path: Path, config: ExperimentConfig, rows: list[dict], repeat: list[dict]) -> None:
    scipy_available = importlib.util.find_spec("scipy") is not None
    lb_provenance = (
        "SciPy was available in this run, so Ljung–Box p-values use SciPy's chi-square survival function."
        if scipy_available
        else "SciPy was unavailable in this run, so Ljung–Box p-values use the Wilson–Hilferty chi-square survival approximation."
    )
    with path.open("w", encoding="utf-8") as f:
        f.write("# Synthetic time-series diagnostics\n\n")
        f.write(f"Seed `{config.seed}`, n=`{config.n}`, repeated simulations=`{config.reps}`.\n\n")
        f.write("Scope: the three implemented core diagnostics are ACF, Ljung–Box, and Durbin–Watson. The AR(1) fit/forecast and KPSS sections are exploratory/future-extension outputs and should not be treated as part of the three-diagnostic result. The single-run table is one draw per process. Rejection rates are empirical proportions from independent draws; they are not theoretical probabilities.\n\n")
        f.write(f"P-value provenance: {lb_provenance} KPSS p-values use interpolation over standard published asymptotic critical values because its null distribution is non-standard. See `environment.json` for the full runtime record.\n\n")
        f.write("## Single-run diagnostics\n\n")
        columns = ["process", "acf1", "ljung_box_p", "durbin_watson", "ar1_phi_hat", "ar1_forecast", "kpss_level_p", "kpss_trend_p"]
        f.write("| " + " | ".join(columns) + " |\n|" + "|".join(["---"] * len(columns)) + "|\n")
        for row in rows:
            f.write("| " + " | ".join(str(row[c]) if isinstance(row[c], str) else f"{row[c]:.4f}" for c in columns) + " |\n")
        f.write("\n## Repeated simulations\n\n")
        cols2 = list(repeat[0])
        f.write("| " + " | ".join(cols2) + " |\n|" + "|".join(["---"] * len(cols2)) + "|\n")
        for row in repeat:
            f.write("| " + " | ".join(str(row[c]) if isinstance(row[c], str) else f"{row[c]:.4f}" for c in cols2) + " |\n")


def _plot(path: Path, config: ExperimentConfig) -> bool:
    try:
        import matplotlib.pyplot as plt  # type: ignore
    except ImportError:
        return False
    rng = np.random.default_rng(config.seed)
    fig, axes = plt.subplots(2, 3, figsize=(13, 7), constrained_layout=True)
    for ax, (kind, generator) in zip(axes.flat, _specs(config)):
        x = generator(rng)
        r = acf(x, config.max_lag)
        ax.stem(range(len(r)), r, linefmt="C0-", markerfmt="C0.", basefmt=" ")
        ax.axhline(1.96 / math.sqrt(config.n), color="C1", ls="--", lw=0.8)
        ax.axhline(-1.96 / math.sqrt(config.n), color="C1", ls="--", lw=0.8)
        ax.set_title(kind.replace("_", " "))
        ax.set_xlabel("lag")
        ax.set_ylabel("ACF")
        ax.set_ylim(-1, 1)
    fig.savefig(path, dpi=140)
    plt.close(fig)
    return True


def _package_version(name: str) -> str | None:
    """Return an installed distribution version without making it a dependency."""
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def capture_environment(config: ExperimentConfig, command: str | None = None) -> dict[str, object]:
    """Capture the runtime and exact simulation configuration used for an output set."""
    scipy_available = importlib.util.find_spec("scipy") is not None
    return {
        "command": command or " ".join(sys.argv),
        "seed": config.seed,
        "n": config.n,
        "reps": config.reps,
        "config": {
            "max_lag": config.max_lag,
            "mean_shift": config.mean_shift,
            "trend_slope": config.trend_slope,
        },
        "python": platform.python_version(),
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "cpu": platform.processor(),
        "cpu_count": os.cpu_count(),
        "packages": {
            "numpy": _package_version("numpy"),
            "scipy": _package_version("scipy"),
            "matplotlib": _package_version("matplotlib"),
        },
        "scipy_available": scipy_available,
        "p_value_provenance": {
            "ljung_box": (
                "SciPy chi-square survival function"
                if scipy_available
                else "Wilson-Hilferty chi-square survival approximation; SciPy was unavailable"
            ),
            "kpss": "Interpolation over standard published asymptotic critical values; KPSS null distribution is non-standard",
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n", type=int, default=300)
    parser.add_argument("--reps", type=int, default=200)
    parser.add_argument("--seed", type=int, default=20260910)
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "results")
    args = parser.parse_args(argv)
    config = ExperimentConfig(n=args.n, reps=args.reps, seed=args.seed)
    rows, repeat = run(config)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    _write_csv(args.output_dir / "results.csv", rows)
    _write_csv(args.output_dir / "repeat_summary.csv", repeat)
    _write_markdown(args.output_dir / "summary.md", config, rows, repeat)
    (args.output_dir / "environment.json").write_text(
        json.dumps(capture_environment(config), indent=2) + "\n", encoding="utf-8"
    )
    plotted = _plot(args.output_dir / "acf_diagnostics.png", config)
    print(f"Wrote results to {args.output_dir} (plot={'yes' if plotted else 'no'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
