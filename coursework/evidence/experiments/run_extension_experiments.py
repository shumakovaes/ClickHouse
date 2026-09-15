"""Seeded, dependency-free experiments for registered time-series extensions.

The core calculations deliberately call the independent standard-library oracle
in ``coursework/reference/python/extensions.py``.  ``statsmodels`` is optional
and, when present, is written only as a labelled cross-check: it is never a
requirement for the experiment or its reported conclusions.

Run from the ClickHouse checkout or any directory::

    py coursework/evidence/experiments/run_extension_experiments.py

Use ``--output-dir`` for an explicit immutable result location.  The default
creates a new UTC-timestamped directory next to this script.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import importlib.metadata
import json
import math
import platform
import random
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import fmean
from typing import Any, Callable, Iterable


SCRIPT = Path(__file__).resolve()
COURSEWORK = SCRIPT.parents[2]
REFERENCE = COURSEWORK / "reference" / "python"
sys.path.insert(0, str(REFERENCE))

from extensions import (  # noqa: E402
    adf_statistic,
    kpss_test,
    lagged_linear_regression,
    single_mean_shift_change_point,
)


@dataclass(frozen=True)
class Config:
    seed: int = 20260915
    reps: int = 120
    n: int = 240
    adf_lags: int = 1
    change_min_segment: int = 20


def stable_seed(base: int, *labels: object) -> int:
    text = ":".join(str(x) for x in (base, *labels)).encode("utf-8")
    return int.from_bytes(hashlib.sha256(text).digest()[:8], "big")


def rng_for(config: Config, *labels: object) -> random.Random:
    return random.Random(stable_seed(config.seed, *labels))


def mean(values: Iterable[float]) -> float:
    values = list(values)
    return fmean(values) if values else math.nan


def sample_sd(values: Iterable[float]) -> float:
    values = list(values)
    if len(values) < 2:
        return math.nan
    center = fmean(values)
    return math.sqrt(math.fsum((x - center) ** 2 for x in values) / (len(values) - 1))


def finite(values: Iterable[float]) -> list[float]:
    return [value for value in values if math.isfinite(value)]


def simulate_ar(coefficients: tuple[float, ...], noise_sd: float, n: int, rng: random.Random, intercept: float = 0.4) -> list[float]:
    """Generate a fixed-order AR process after a short deterministic burn-in."""
    order = len(coefficients)
    y = [0.0] * (n + 200)
    for t in range(order, len(y)):
        y[t] = intercept + math.fsum(coefficients[j] * y[t - j - 1] for j in range(order)) + rng.gauss(0.0, noise_sd)
    return y[-n:]


def simulate_random_walk(n: int, rng: random.Random) -> list[float]:
    value = 0.0
    values: list[float] = []
    for _ in range(n):
        value += rng.gauss(0.0, 1.0)
        values.append(value)
    return values


def simulate_trend(n: int, rng: random.Random, slope: float = 0.06) -> list[float]:
    return [1.0 + slope * t + rng.gauss(0.0, 0.7) for t in range(n)]


def simulate_level(n: int, rng: random.Random) -> list[float]:
    return [1.0 + rng.gauss(0.0, 1.0) for _ in range(n)]


def simulate_shift(n: int, split: int, rng: random.Random, shift: float = 2.5) -> list[float]:
    return [rng.gauss(0.0, 0.7) + (shift if t >= split else 0.0) for t in range(n)]


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    keys = sorted({key for row in rows for key in row})
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys, extrasaction="raise", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_text_lf(path: Path, contents: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(contents)


def write_sha256_manifest(output_dir: Path) -> None:
    entries = [path for path in sorted(output_dir.iterdir()) if path.is_file() and path.name != "SHA256SUMS"]
    manifest = "".join(f"{sha256(path)}  {path.name}\n" for path in entries)
    write_text_lf(output_dir / "SHA256SUMS", manifest)


def optional_package_versions() -> dict[str, str | None]:
    result: dict[str, str | None] = {}
    for package in ("numpy", "scipy", "statsmodels", "pandas"):
        try:
            result[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            result[package] = None
    return result


def git_metadata() -> tuple[str | None, list[str] | None]:
    repository = COURSEWORK.parent
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
        status = subprocess.check_output(
            ["git", "-C", str(repository), "status", "--short"], text=True, stderr=subprocess.DEVNULL
        ).splitlines()
        return revision, status
    except (OSError, subprocess.CalledProcessError):
        return None, None


def ar_recovery(config: Config) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    scenarios = (
        ("ar1_phi_0.25_noise_0.2", (0.25,), 0.2),
        ("ar1_phi_0.70_noise_1.0", (0.70,), 1.0),
        ("ar2_phi_0.50_-0.25_noise_0.5", (0.50, -0.25), 0.5),
    )
    rows: list[dict[str, Any]] = []
    summary: list[dict[str, Any]] = []
    for scenario, truth, noise_sd in scenarios:
        errors: list[list[float]] = [[] for _ in range(len(truth) + 1)]
        successes = 0
        for rep in range(config.reps):
            values = simulate_ar(truth, noise_sd, config.n, rng_for(config, "ar", scenario, rep))
            try:
                fitted = lagged_linear_regression(values, len(truth))
                estimate = (fitted.intercept, *fitted.lags)
                successes += 1
                for index, target in enumerate((0.4, *truth)):
                    errors[index].append(estimate[index] - target)
                outcome = "fit"
            except ValueError:
                estimate = (math.nan,) * (len(truth) + 1)
                outcome = "undefined"
            rows.append({
                "experiment": "ar_recovery",
                "scenario": scenario,
                "rep": rep,
                "order": len(truth),
                "noise_sd": noise_sd,
                "intercept_true": 0.4,
                "intercept_hat": estimate[0],
                **{f"phi_{j + 1}_true": value for j, value in enumerate(truth)},
                **{f"phi_{j + 1}_hat": estimate[j + 1] for j in range(len(truth))},
                "outcome": outcome,
            })
        item: dict[str, Any] = {
            "experiment": "ar_recovery",
            "scenario": scenario,
            "reps": config.reps,
            "fit_count": successes,
            "undefined_count": config.reps - successes,
        }
        for index, error in enumerate(errors):
            label = "intercept" if index == 0 else f"phi_{index}"
            item[f"{label}_bias"] = mean(error)
            item[f"{label}_rmse"] = math.sqrt(mean(x * x for x in error)) if error else math.nan
        summary.append(item)
    return rows, summary


def adf_direction(config: Config) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    stationary_stats: list[float] = []
    walk_stats: list[float] = []
    direction_hits = 0
    for rep in range(config.reps):
        stationary = simulate_ar((0.5,), 1.0, config.n, rng_for(config, "adf", "stationary", rep), intercept=0.0)
        walk = simulate_random_walk(config.n, rng_for(config, "adf", "walk", rep))
        stationary_stat = adf_statistic(stationary, config.adf_lags, "constant")
        walk_stat = adf_statistic(walk, config.adf_lags, "constant")
        stationary_stats.append(stationary_stat)
        walk_stats.append(walk_stat)
        direction_hits += int(stationary_stat < walk_stat)
        rows.extend((
            {"experiment": "adf_direction", "process": "stationary_ar1", "rep": rep, "statistic": stationary_stat},
            {"experiment": "adf_direction", "process": "random_walk", "rep": rep, "statistic": walk_stat},
        ))
    return rows, {
        "experiment": "adf_direction",
        "reps": config.reps,
        "stationary_mean_statistic": mean(stationary_stats),
        "random_walk_mean_statistic": mean(walk_stats),
        "stationary_more_negative_hit_rate": direction_hits / config.reps,
        "p_value_claim": "none",
    }


def kpss_behavior(config: Config) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    level_values: list[float] = []
    walk_values: list[float] = []
    trend_level_values: list[float] = []
    trend_trend_values: list[float] = []
    level_vs_walk_hits = 0
    trend_detrend_hits = 0
    for rep in range(config.reps):
        level = simulate_level(config.n, rng_for(config, "kpss", "level", rep))
        walk = simulate_random_walk(config.n, rng_for(config, "kpss", "walk", rep))
        trend = simulate_trend(config.n, rng_for(config, "kpss", "trend", rep))
        level_stat = kpss_test(level, "level").statistic
        walk_stat = kpss_test(walk, "level").statistic
        trend_level = kpss_test(trend, "level").statistic
        trend_stat = kpss_test(trend, "trend").statistic
        level_values.append(level_stat)
        walk_values.append(walk_stat)
        trend_level_values.append(trend_level)
        trend_trend_values.append(trend_stat)
        level_vs_walk_hits += int(level_stat < walk_stat)
        trend_detrend_hits += int(trend_stat < trend_level)
        rows.extend((
            {"experiment": "kpss_behavior", "process": "level_stationary", "mode": "level", "rep": rep, "statistic": level_stat},
            {"experiment": "kpss_behavior", "process": "random_walk", "mode": "level", "rep": rep, "statistic": walk_stat},
            {"experiment": "kpss_behavior", "process": "trend_stationary", "mode": "level", "rep": rep, "statistic": trend_level},
            {"experiment": "kpss_behavior", "process": "trend_stationary", "mode": "trend", "rep": rep, "statistic": trend_stat},
        ))
    return rows, {
        "experiment": "kpss_behavior",
        "reps": config.reps,
        "level_stationary_mean": mean(level_values),
        "random_walk_mean": mean(walk_values),
        "trend_level_mean": mean(trend_level_values),
        "trend_detrended_mean": mean(trend_trend_values),
        "level_less_than_walk_hit_rate": level_vs_walk_hits / config.reps,
        "detrended_less_than_level_hit_rate": trend_detrend_hits / config.reps,
        "p_value_claim": "none",
    }


def change_point_behavior(config: Config) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    errors: list[float] = []
    exact_hits = 0
    tolerance_hits = 0
    tolerance = max(2, config.n // 20)
    for rep in range(config.reps):
        rng = rng_for(config, "change_point", rep)
        split = rng.randrange(config.change_min_segment, config.n - config.change_min_segment + 1)
        values = simulate_shift(config.n, split, rng)
        result = single_mean_shift_change_point(values, config.change_min_segment)
        error = abs(result.index - split)
        errors.append(error)
        exact_hits += int(error == 0)
        tolerance_hits += int(error <= tolerance)
        rows.append({
            "experiment": "mean_shift",
            "rep": rep,
            "true_split": split,
            "estimated_split": result.index,
            "absolute_error": error,
            "score": result.sse_reduction,
            "sse": result.sse,
        })
    return rows, {
        "experiment": "mean_shift",
        "reps": config.reps,
        "mean_absolute_localization_error": mean(errors),
        "exact_hit_rate": exact_hits / config.reps,
        "within_tolerance": tolerance,
        "within_tolerance_hit_rate": tolerance_hits / config.reps,
    }


def edge_outcomes(config: Config) -> list[dict[str, Any]]:
    """Record NULL/short/constant cases separately from Monte Carlo quality."""
    cases: list[tuple[str, list[float | None]]] = [
        ("null_rows_skipped", [1.0, None, 2.0, None, 3.0, 4.0, 5.0]),
        ("short", [1.0, 2.0]),
        ("constant", [7.0] * 12),
    ]
    rows: list[dict[str, Any]] = []
    for label, raw in cases:
        values = [value for value in raw if value is not None]
        def outcome(call: Callable[[], object]) -> str:
            try:
                value = call()
                if isinstance(value, float) and math.isnan(value):
                    return "nan"
                if hasattr(value, "statistic") and math.isnan(getattr(value, "statistic")):
                    return "nan"
                return "value"
            except ValueError:
                return "undefined"
        rows.extend((
            {"case": label, "input_rows": len(raw), "usable_rows": len(values), "extension": "lagged_regression", "outcome": outcome(lambda: lagged_linear_regression(values, 1))},
            {"case": label, "input_rows": len(raw), "usable_rows": len(values), "extension": "adf", "outcome": outcome(lambda: adf_statistic(values, 0, "constant"))},
            {"case": label, "input_rows": len(raw), "usable_rows": len(values), "extension": "kpss_level", "outcome": outcome(lambda: kpss_test(values, "level", 0))},
            # The native contract deliberately uses split 0 for a constant/no-identifiable-break result.
            {"case": label, "input_rows": len(raw), "usable_rows": len(values), "extension": "mean_shift_native_contract", "outcome": "split_0" if len(set(values)) <= 1 else outcome(lambda: single_mean_shift_change_point(values, 1))},
        ))
    return rows


def optional_statsmodels_crosscheck(config: Config) -> list[dict[str, Any]]:
    if importlib.util.find_spec("statsmodels") is None:
        return [{"available": False, "label": "optional_statsmodels_crosscheck", "detail": "statsmodels_not_installed"}]
    try:
        import numpy as np  # type: ignore
        from statsmodels.tsa.ar_model import AutoReg  # type: ignore
        from statsmodels.tsa.stattools import adfuller, kpss  # type: ignore
    except Exception as error:  # optional packages sometimes have binary import failures
        return [{"available": False, "label": "optional_statsmodels_crosscheck", "detail": f"import_failed:{type(error).__name__}"}]

    values = simulate_ar((0.5, -0.25), 0.5, config.n, rng_for(config, "statsmodels", "ar2"))
    ours = lagged_linear_regression(values, 2)
    theirs = AutoReg(np.asarray(values), lags=2, trend="c").fit().params
    adf_ours = adf_statistic(values, 1, "constant")
    adf_theirs = adfuller(values, maxlag=1, regression="c", autolag=None, result_object=False)[0]
    kpss_ours = kpss_test(values, "level", 4).statistic
    kpss_theirs = kpss(np.asarray(values), regression="c", nlags=4, result_object=False)[0]
    return [{
        "available": True,
        "label": "optional_statsmodels_crosscheck",
        "ar_intercept_difference": ours.intercept - float(theirs[0]),
        "ar_phi1_difference": ours.lags[0] - float(theirs[1]),
        "ar_phi2_difference": ours.lags[1] - float(theirs[2]),
        "adf_statistic_difference": adf_ours - float(adf_theirs),
        "kpss_statistic_difference": kpss_ours - float(kpss_theirs),
    }]


def write_summary(path: Path, config: Config, summaries: list[dict[str, Any]], edges: list[dict[str, Any]], runtime_seconds: float) -> None:
    counts: dict[str, int] = {}
    for row in edges:
        key = f"{row['case']}:{row['outcome']}"
        counts[key] = counts.get(key, 0) + 1
    lines = [
        "# Extension experiment summary",
        "",
        f"- Seed: `{config.seed}`; repetitions: `{config.reps}`; observations per simulation: `{config.n}`.",
        f"- Runtime: `{runtime_seconds:.3f}` seconds.",
        "- Core calculations use only Python standard library plus the independent coursework oracle.",
        "- ADF and KPSS entries report statistic direction/behavior only; they make no p-value or calibrated rejection claim.",
        "",
        "## Aggregate results",
        "",
        "| Experiment | Key result |",
        "|---|---|",
    ]
    for item in summaries:
        experiment = item["experiment"]
        if experiment == "ar_recovery":
            result = f"{item['scenario']}: fits={item['fit_count']}/{item['reps']}, phi_1 RMSE={item.get('phi_1_rmse', math.nan):.4f}"
        elif experiment == "adf_direction":
            result = f"stationary-more-negative hit rate={item['stationary_more_negative_hit_rate']:.3f}"
        elif experiment == "kpss_behavior":
            result = f"level<walk={item['level_less_than_walk_hit_rate']:.3f}; detrended<level={item['detrended_less_than_level_hit_rate']:.3f}"
        else:
            result = f"MAE={item['mean_absolute_localization_error']:.3f}; exact hit={item['exact_hit_rate']:.3f}; ±{item['within_tolerance']} hit={item['within_tolerance_hit_rate']:.3f}"
        lines.append(f"| {experiment} | {result} |")
    lines += ["", "## Edge outcomes", "", "| Outcome | Count |", "|---|---:|"]
    lines.extend(f"| {key} | {value} |" for key, value in sorted(counts.items()))
    write_text_lf(path, "\n".join(lines) + "\n")


def run(config: Config, output_dir: Path) -> dict[str, Any]:
    if config.reps < 1 or config.n < 60 or config.change_min_segment < 1 or config.n < 2 * config.change_min_segment:
        raise ValueError("require reps >= 1, n >= 60, and n >= 2 * change_min_segment")
    output_dir.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    ar_rows, ar_summary = ar_recovery(config)
    adf_rows, adf_summary = adf_direction(config)
    kpss_rows, kpss_summary = kpss_behavior(config)
    change_rows, change_summary = change_point_behavior(config)
    edges = edge_outcomes(config)
    crosscheck = optional_statsmodels_crosscheck(config)
    runtime_seconds = time.perf_counter() - started

    write_csv(output_dir / "ar_recovery.csv", ar_rows)
    write_csv(output_dir / "adf_direction.csv", adf_rows)
    write_csv(output_dir / "kpss_behavior.csv", kpss_rows)
    write_csv(output_dir / "mean_shift.csv", change_rows)
    write_csv(output_dir / "edge_outcomes.csv", edges)
    write_csv(output_dir / "optional_statsmodels_crosscheck.csv", crosscheck)
    summaries = [*ar_summary, adf_summary, kpss_summary, change_summary]
    write_csv(output_dir / "summary.csv", summaries)
    write_summary(output_dir / "summary.md", config, summaries, edges, runtime_seconds)

    revision, status = git_metadata()
    metadata = {
        "schema_version": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "config": asdict(config),
        "runtime_seconds": runtime_seconds,
        "python": sys.version,
        "command": [sys.executable, *sys.argv],
        "optional_package_versions": optional_package_versions(),
        "platform": platform.platform(),
        "git_revision": revision,
        "git_status": status,
        "script_sha256": sha256(SCRIPT),
        "oracle_sha256": sha256(REFERENCE / "extensions.py"),
        "optional_statsmodels_available": bool(crosscheck[0].get("available")),
        "row_counts": {
            "ar_recovery": len(ar_rows), "adf_direction": len(adf_rows), "kpss_behavior": len(kpss_rows),
            "mean_shift": len(change_rows), "edge_outcomes": len(edges), "crosscheck": len(crosscheck),
        },
        "notes": [
            "Fixed seeds are derived from the top-level seed and stable scenario labels.",
            "ADF and KPSS are compared by statistic direction only; no p-value conclusions are emitted.",
            "NULL edge rows are intentionally filtered before the oracle call to model ClickHouse Null-combinator row skipping.",
            "The native change-point contract maps no identifiable constant change to split_index 0.",
        ],
    }
    write_text_lf(output_dir / "metadata.json", json.dumps(metadata, indent=2, sort_keys=True, allow_nan=False) + "\n")
    write_sha256_manifest(output_dir)
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=Config.seed)
    parser.add_argument("--reps", type=int, default=Config.reps)
    parser.add_argument("--n", type=int, default=Config.n)
    parser.add_argument("--adf-lags", type=int, default=Config.adf_lags)
    parser.add_argument("--change-min-segment", type=int, default=Config.change_min_segment)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    config = Config(args.seed, args.reps, args.n, args.adf_lags, args.change_min_segment)
    output_dir = args.output_dir or SCRIPT.parent / f"extension_results_{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"
    metadata = run(config, output_dir)
    print(json.dumps({"output_dir": str(output_dir), "runtime_seconds": metadata["runtime_seconds"], "row_counts": metadata["row_counts"]}, sort_keys=True))


if __name__ == "__main__":
    main()
