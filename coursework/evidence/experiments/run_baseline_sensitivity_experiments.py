"""Reproducible all-lag ACF and Ljung--Box sensitivity experiments.

This runner is deliberately separate from the archived baseline experiment. It
adds the two small pieces of evidence needed to close the statistical-
experiment gap: empirical ACFs at every positive lag through 20 are compared with the
white-noise/AR(1) targets, and Ljung--Box rejection rates are measured across
three sample sizes. The simulation code is local to this file; only the
trusted baseline oracle is imported for executable cross-checks and its
dependency-free chi-square survival function.

The output directory must be new. A complete run writes raw and summary CSVs,
Markdown, metadata, and a SHA256 manifest. The default run uses 200 repetitions
and fixed seed 20260916; use ``--reps`` and ``--seed`` for a registered
alternative experiment.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import platform
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from statistics import fmean
from typing import Iterable


SCRIPT = Path(__file__).resolve()
COURSEWORK = SCRIPT.parents[2]
REFERENCE = COURSEWORK / "reference" / "python"
sys.path.insert(0, str(REFERENCE))

from reference import FullSampleKeyedStats, chi_square_sf  # noqa: E402


DEFAULT_SEED = 20260916
DEFAULT_REPS = 200
MAX_LAG = 20
SAMPLE_SIZES = (100, 300, 1000)
ALPHA = 0.05
MODEL_DF = 0
DEGREES_OF_FREEDOM = MAX_LAG - MODEL_DF
PROCESSES = (
    ("white_noise", None),
    ("ar1_phi_0.5", 0.5),
    ("ar1_phi_0.9", 0.9),
)


def stable_seed(base: int, *labels: object) -> int:
    """Derive independent, reproducible streams without order dependence."""
    payload = ":".join(str(value) for value in (base, *labels)).encode("utf-8")
    return int.from_bytes(hashlib.sha256(payload).digest()[:8], "big")


def simulate_white_noise(n: int, rng: random.Random) -> list[float]:
    return [rng.gauss(0.0, 1.0) for _ in range(n)]


def simulate_ar1(n: int, phi: float, rng: random.Random) -> list[float]:
    """Generate an approximately stationary AR(1) after a fixed burn-in."""
    burn_in = 200
    values = [0.0] * (n + burn_in)
    for index in range(1, len(values)):
        values[index] = phi * values[index - 1] + rng.gauss(0.0, 1.0)
    return values[-n:]


def acf(values: Iterable[float], max_lag: int) -> list[float]:
    """Return the stable baseline ACF contract from lag zero onward."""
    if not isinstance(max_lag, int) or isinstance(max_lag, bool) or max_lag < 0:
        raise ValueError("max_lag must be a non-negative integer")
    series = [float(value) for value in values]
    if any(not math.isfinite(value) for value in series):
        raise ValueError("observations must be finite")
    if not series:
        return [math.nan] * (max_lag + 1)
    low, high = min(series), max(series)
    location = low / 2.0 + high / 2.0
    translated = [value - location for value in series]
    scale = max(abs(value) for value in translated)
    if scale == 0.0:
        return [math.nan] * (max_lag + 1)
    normalized = [value / scale for value in translated]
    mean = math.fsum(normalized) / len(normalized)
    centered = [value - mean for value in normalized]
    denominator = math.fsum(value * value for value in centered)
    result: list[float] = []
    for lag in range(max_lag + 1):
        if lag >= len(series) or not denominator > 0.0:
            result.append(math.nan)
        else:
            result.append(
                math.fsum(centered[index] * centered[index + lag] for index in range(len(series) - lag))
                / denominator
            )
    return result


def ljung_box(values: Iterable[float], lags: int, model_df: int = 0) -> tuple[float, float]:
    """Return the Q statistic and dependency-free chi-square tail probability."""
    series = [float(value) for value in values]
    if not isinstance(lags, int) or isinstance(lags, bool) or lags < 1:
        raise ValueError("lags must be a positive integer")
    if not isinstance(model_df, int) or isinstance(model_df, bool) or not 0 <= model_df < lags:
        raise ValueError("model_df must satisfy 0 <= model_df < lags")
    if any(not math.isfinite(value) for value in series):
        raise ValueError("observations must be finite")
    if len(series) <= lags:
        return math.nan, math.nan
    correlations = acf(series, lags)[1:]
    if any(not math.isfinite(correlation) for correlation in correlations):
        return math.nan, math.nan
    n = len(series)
    q = n * (n + 2) * math.fsum(
        correlation * correlation / (n - lag)
        for lag, correlation in enumerate(correlations, start=1)
    )
    return q, chi_square_sf(q, lags - model_df)


def wilson_interval(successes: int, trials: int) -> tuple[float, float]:
    """Return a 95% Wilson interval for a binomial Monte Carlo proportion."""
    z = 1.959963984540054
    proportion = successes / trials
    denominator = 1.0 + z * z / trials
    center = (proportion + z * z / (2.0 * trials)) / denominator
    half_width = z * math.sqrt(proportion * (1.0 - proportion) / trials + z * z / (4.0 * trials * trials)) / denominator
    return max(0.0, center - half_width), min(1.0, center + half_width)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(*arguments: str) -> str:
    """Return auditable repository metadata without making Git a dependency."""
    completed = subprocess.run(
        ["git", "-C", str(COURSEWORK.parent), *arguments],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if completed.returncode == 0:
        return completed.stdout.strip()
    detail = completed.stderr.strip().replace("\r\n", "\n")
    return f"unavailable (exit {completed.returncode}): {detail}"


def write_text_lf(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text.replace("\r\n", "\n"))


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_sha256_manifest(output_dir: Path) -> None:
    files = sorted(
        path for path in output_dir.iterdir() if path.is_file() and path.name != "SHA256SUMS"
    )
    write_text_lf(
        output_dir / "SHA256SUMS",
        "".join(f"{sha256(path)}  {path.name}\n" for path in files),
    )


def _process_values(process: str, phi: float | None, n: int, seed: int, *labels: object) -> list[float]:
    rng = random.Random(stable_seed(seed, *labels))
    if process == "white_noise":
        return simulate_white_noise(n, rng)
    if phi is not None:
        return simulate_ar1(n, phi, rng)
    raise ValueError(f"unknown process {process!r}")


def acf_experiment(seed: int, reps: int) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    raw: list[dict[str, object]] = []
    by_key: dict[tuple[str, int], list[float]] = {}
    theory: dict[str, float] = {}
    for process, phi in PROCESSES:
        theory[process] = 0.0 if phi is None else phi
        for rep in range(reps):
            values = _process_values(process, phi, 300, seed, "acf", process, rep)
            correlations = acf(values, MAX_LAG)
            oracle = FullSampleKeyedStats.from_pairs(enumerate(values))
            for lag in range(1, MAX_LAG + 1):
                target = 0.0 if phi is None else phi**lag
                observed = correlations[lag]
                oracle_observed = oracle.autocorrelation(lag)
                if not math.isclose(observed, oracle_observed, rel_tol=1e-12, abs_tol=1e-12):
                    raise AssertionError(f"ACF cross-check failed for {process=}, {rep=}, {lag=}")
                raw.append(
                    {
                        "process": process,
                        "rep": rep,
                        "lag": lag,
                        "theoretical_acf": target,
                        "acf": observed,
                    }
                )
                by_key.setdefault((process, lag), []).append(observed)

    summary: list[dict[str, object]] = []
    for process, _phi in PROCESSES:
        for lag in range(1, MAX_LAG + 1):
            values = by_key[(process, lag)]
            target = 0.0 if theory[process] == 0.0 else theory[process] ** lag
            empirical = fmean(values)
            summary.append(
                {
                    "process": process,
                    "lag": lag,
                    "reps": reps,
                    "theoretical_acf": target,
                    "empirical_mean": empirical,
                    "bias": empirical - target,
                    "rmse": math.sqrt(fmean((value - target) ** 2 for value in values)),
                }
            )
    return raw, summary


def ljung_box_experiment(seed: int, reps: int) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    raw: list[dict[str, object]] = []
    summary: list[dict[str, object]] = []
    for process, phi in PROCESSES:
        for n in SAMPLE_SIZES:
            rejected = 0
            for rep in range(reps):
                values = _process_values(process, phi, n, seed, "ljung_box", process, n, rep)
                statistic, p_value = ljung_box(values, MAX_LAG, MODEL_DF)
                oracle_result = FullSampleKeyedStats.from_pairs(enumerate(values)).ljung_box(MAX_LAG, MODEL_DF)
                if not math.isclose(statistic, oracle_result.statistic, rel_tol=1e-12, abs_tol=1e-12):
                    raise AssertionError(f"Ljung--Box statistic cross-check failed for {process=}, {n=}, {rep=}")
                if not math.isclose(p_value, oracle_result.p_value, rel_tol=1e-12, abs_tol=1e-12):
                    raise AssertionError(f"Ljung--Box p-value cross-check failed for {process=}, {n=}, {rep=}")
                is_rejected = int(p_value < ALPHA)
                rejected += is_rejected
                raw.append(
                    {
                        "process": process,
                        "n": n,
                        "rep": rep,
                        "lags": MAX_LAG,
                        "model_df": MODEL_DF,
                        "degrees_of_freedom": DEGREES_OF_FREEDOM,
                        "statistic": statistic,
                        "p_value": p_value,
                        "alpha": ALPHA,
                        "rejected": is_rejected,
                    }
                )
            interval_low, interval_high = wilson_interval(rejected, reps)
            rejection_rate = rejected / reps
            summary.append(
                {
                    "process": process,
                    "n": n,
                    "reps": reps,
                    "lags": MAX_LAG,
                    "model_df": MODEL_DF,
                    "degrees_of_freedom": DEGREES_OF_FREEDOM,
                    "alpha": ALPHA,
                    "rejections": rejected,
                    "rejection_rate": rejection_rate,
                    "monte_carlo_standard_error": math.sqrt(rejection_rate * (1.0 - rejection_rate) / reps),
                    "wilson_95_low": interval_low,
                    "wilson_95_high": interval_high,
                    "p_value_method": "reference.chi_square_sf",
                }
            )
    return raw, summary


def markdown_summary(
    path: Path,
    seed: int,
    reps: int,
    acf_summary: list[dict[str, object]],
    lb_summary: list[dict[str, object]],
    runtime_seconds: float,
) -> None:
    selected_lags = {1, 5, 10, 20}
    lines = [
        "# Baseline ACF and Ljung--Box sensitivity experiments",
        "",
        f"- Seed: `{seed}`; repetitions: `{reps}`; ACF simulation length: `300`.",
        f"- Ljung--Box sample sizes: `{','.join(str(n) for n in SAMPLE_SIZES)}`; lags: `{MAX_LAG}`; model_df: `{MODEL_DF}`; degrees of freedom: `{DEGREES_OF_FREEDOM}`; alpha: `{ALPHA}`.",
        f"- Runtime: `{runtime_seconds:.3f}` seconds.",
        "- ACF uses the stable, biased sample-mean-centered baseline contract; every simulated result is cross-checked against `FullSampleKeyedStats`.",
        "- Ljung--Box p-values use the dependency-free `reference.chi_square_sf` implementation.",
        "",
        "## ACF snapshots",
        "",
        "The complete 60-row positive-lag table (lags 1--20) is in `acf_lag_summary.csv`; the selected lags below make the theoretical comparison easy to inspect.",
        "",
        "| process | lag | theoretical | empirical mean | bias | RMSE |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in acf_summary:
        if int(row["lag"]) in selected_lags:
            lines.append(
                f"| {row['process']} | {row['lag']} | {float(row['theoretical_acf']):.6f} | "
                f"{float(row['empirical_mean']):.6f} | {float(row['bias']):.6f} | {float(row['rmse']):.6f} |"
            )
    lines.extend(
        [
            "",
            "## Ljung--Box rejection-rate sensitivity",
            "",
            "These are finite-sample Monte Carlo estimates using the asymptotic chi-square calibration, not universal test properties. White noise is the null false-positive reference; AR(1) rows are serial-correlation alternatives.",
            "",
            "| process | n | repetitions | rejections | rejection rate | Monte Carlo SE | 95% Wilson interval |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for row in lb_summary:
        lines.append(
            f"| {row['process']} | {row['n']} | {row['reps']} | {row['rejections']} | "
            f"{float(row['rejection_rate']):.4f} | {float(row['monte_carlo_standard_error']):.4f} | "
            f"[{float(row['wilson_95_low']):.4f}, {float(row['wilson_95_high']):.4f}] |"
        )
    lines.extend(
        [
            "",
            "Raw observations are in `acf_lag_raw.csv` and `ljung_box_raw.csv`; summary CSVs contain the reproducible aggregates.",
            "",
        ]
    )
    write_text_lf(path, "\n".join(lines))


def run(seed: int, reps: int, output_dir: Path) -> dict[str, object]:
    if reps < 1:
        raise ValueError("repetitions must be positive")
    if output_dir.exists():
        raise FileExistsError(f"output directory must be fresh and absent: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()

    acf_raw, acf_summary = acf_experiment(seed, reps)
    lb_raw, lb_summary = ljung_box_experiment(seed, reps)
    write_csv(
        output_dir / "acf_lag_raw.csv",
        ["process", "rep", "lag", "theoretical_acf", "acf"],
        acf_raw,
    )
    write_csv(
        output_dir / "acf_lag_summary.csv",
        ["process", "lag", "reps", "theoretical_acf", "empirical_mean", "bias", "rmse"],
        acf_summary,
    )
    write_csv(
        output_dir / "ljung_box_raw.csv",
        [
            "process",
            "n",
            "rep",
            "lags",
            "model_df",
            "degrees_of_freedom",
            "statistic",
            "p_value",
            "alpha",
            "rejected",
        ],
        lb_raw,
    )
    write_csv(
        output_dir / "ljung_box_summary.csv",
        [
            "process",
            "n",
            "reps",
            "lags",
            "model_df",
            "degrees_of_freedom",
            "alpha",
            "rejections",
            "rejection_rate",
            "monte_carlo_standard_error",
            "wilson_95_low",
            "wilson_95_high",
            "p_value_method",
        ],
        lb_summary,
    )
    runtime_seconds = time.perf_counter() - started
    markdown_summary(output_dir / "summary.md", seed, reps, acf_summary, lb_summary, runtime_seconds)
    metadata = {
        "schema_version": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "config": {
            "seed": seed,
            "reps": reps,
            "acf_n": 300,
            "acf_lags": list(range(1, MAX_LAG + 1)),
            "ljung_box_sample_sizes": list(SAMPLE_SIZES),
            "ljung_box_lags": MAX_LAG,
            "ljung_box_model_df": MODEL_DF,
            "ljung_box_degrees_of_freedom": DEGREES_OF_FREEDOM,
            "alpha": ALPHA,
        },
        "runtime_seconds": runtime_seconds,
        "python": sys.version,
        "platform": platform.platform(),
        "command": [sys.executable, *sys.argv],
        "script_path": str(SCRIPT),
        "script_sha256": sha256(SCRIPT),
        "reference_path": str(REFERENCE / "reference.py"),
        "reference_sha256": sha256(REFERENCE / "reference.py"),
        "git_revision": git_output("rev-parse", "HEAD"),
        "git_branch": git_output("branch", "--show-current"),
        "git_status": git_output("status", "--porcelain=v1").splitlines(),
        "git_submodules": git_output("submodule", "status", "--recursive").splitlines(),
        "p_value_method": "reference.chi_square_sf",
        "reproducibility_scope": "Seeded numerical outputs are reproducible; timestamps, runtime, absolute paths, and repository status are provenance and may vary.",
        "row_counts": {
            "acf_lag_raw": len(acf_raw),
            "acf_lag_summary": len(acf_summary),
            "ljung_box_raw": len(lb_raw),
            "ljung_box_summary": len(lb_summary),
        },
    }
    write_text_lf(
        output_dir / "metadata.json",
        json.dumps(metadata, indent=2, sort_keys=True, allow_nan=False) + "\n",
    )
    write_sha256_manifest(output_dir)
    return metadata


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="new, previously absent output directory")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--reps", type=int, default=DEFAULT_REPS)
    args = parser.parse_args(argv)
    metadata = run(args.seed, args.reps, args.output_dir)
    print(
        json.dumps(
            {
                "output_dir": str(args.output_dir),
                "runtime_seconds": metadata["runtime_seconds"],
                "row_counts": metadata["row_counts"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
