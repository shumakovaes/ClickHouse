#!/usr/bin/env python3
"""Bounded, reproducible Python-oracle finalizer benchmark for extensions.

This is deliberately *not* a ClickHouse benchmark.  It measures the
independent batch-reference finalizers in ``coursework/reference/python``:
lagged AR regression, fixed-lag ADF, fixed-bandwidth trend KPSS, and the
single-mean-shift change-point scan.  Input generation is outside the timed
region; each recorded sample contains wall time and Python ``tracemalloc``
peak allocation for one finalizer call.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.metadata
import json
import math
import platform
import random
import statistics
import subprocess
import sys
import time
import tracemalloc
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
COURSEWORK_ROOT = SCRIPT_DIR.parents[1]
REFERENCE_DIR = COURSEWORK_ROOT / "reference" / "python"
sys.path.insert(0, str(REFERENCE_DIR))

from extensions import (  # noqa: E402  (intentional local reference import)
    adf_statistic,
    kpss_test,
    lagged_linear_regression,
    single_mean_shift_change_point,
)


SCHEMA_VERSION = 1
MAX_SERIES_N = 8_192
MAX_CHANGE_POINT_N = 4_096


@dataclass(frozen=True)
class Sample:
    benchmark: str
    n: int
    order: int | None
    bandwidth: int | None
    regression: str | None
    min_segment: int | None
    seed: int
    repetition: int
    wall_ms: float
    tracemalloc_peak_bytes: int
    result_checksum: str


def parse_int_list(raw: str, *, minimum: int, option: str) -> list[int]:
    try:
        values = [int(item.strip()) for item in raw.split(",") if item.strip()]
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{option} must be comma-separated integers") from exc
    if not values or any(value < minimum for value in values):
        raise argparse.ArgumentTypeError(f"{option} must contain integers >= {minimum}")
    return sorted(set(values))


def args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=SCRIPT_DIR / "extensions-20260915",
        help="new directory for results (default: %(default)s)",
    )
    parser.add_argument("--seed", type=int, default=20260915)
    parser.add_argument("--n", default="256,1024,4096", help="AR/ADF/KPSS sizes")
    parser.add_argument("--ar-orders", default="1,4,8")
    parser.add_argument("--adf-orders", default="0,2,4")
    parser.add_argument("--kpss-bandwidths", default="0,8,32")
    parser.add_argument("--change-point-n", default="256,1024,4096")
    parser.add_argument("--min-segment", type=int, default=8)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=3)
    parsed = parser.parse_args()
    parsed.n = parse_int_list(parsed.n, minimum=8, option="--n")
    parsed.ar_orders = parse_int_list(parsed.ar_orders, minimum=1, option="--ar-orders")
    parsed.adf_orders = parse_int_list(parsed.adf_orders, minimum=0, option="--adf-orders")
    parsed.kpss_bandwidths = parse_int_list(parsed.kpss_bandwidths, minimum=0, option="--kpss-bandwidths")
    parsed.change_point_n = parse_int_list(parsed.change_point_n, minimum=2, option="--change-point-n")
    if parsed.warmup < 0 or parsed.repetitions < 1:
        parser.error("--warmup must be non-negative and --repetitions must be positive")
    if parsed.min_segment < 1:
        parser.error("--min-segment must be positive")
    if max(parsed.n) > MAX_SERIES_N:
        parser.error(f"--n is capped at {MAX_SERIES_N} to keep this Python benchmark bounded")
    if max(parsed.change_point_n) > MAX_CHANGE_POINT_N:
        parser.error(
            f"--change-point-n is capped at {MAX_CHANGE_POINT_N}; the independent reference is an O(n^2) scan"
        )
    if any(n < 2 * parsed.min_segment for n in parsed.change_point_n):
        parser.error("every --change-point-n value must be at least 2 * --min-segment")
    if any(order >= n - 2 for order in parsed.ar_orders for n in parsed.n):
        parser.error("AR orders require enough observations for the reference fit")
    if any(order >= n // 2 for order in parsed.adf_orders for n in parsed.n):
        parser.error("ADF orders require enough observations for the reference fit")
    if any(q >= n for q in parsed.kpss_bandwidths for n in parsed.n):
        parser.error("every KPSS bandwidth must be smaller than every --n value")
    return parsed


def stable_seed(root_seed: int, label: str, n: int) -> int:
    digest = hashlib.sha256(f"{root_seed}:{label}:{n}".encode("ascii")).digest()
    return int.from_bytes(digest[:8], "big")


def time_series(n: int, seed: int) -> tuple[float, ...]:
    """Non-degenerate, mildly autocorrelated input for AR/ADF/KPSS."""
    rng = random.Random(seed)
    values = [rng.gauss(0.0, 1.0)]
    for index in range(1, n):
        values.append(0.63 * values[-1] + 0.002 * index + rng.gauss(0.0, 1.0))
    return tuple(values)


def change_point_series(n: int, seed: int) -> tuple[float, ...]:
    rng = random.Random(seed)
    split = n // 2
    return tuple((-1.0 if index < split else 1.0) + rng.gauss(0.0, 0.25) for index in range(n))


def checksum(value: object) -> str:
    """Prove the measured call produced a concrete finalizer result."""
    if hasattr(value, "__dataclass_fields__"):
        payload: Any = asdict(value)
    elif isinstance(value, float):
        payload = {"float": "NaN" if math.isnan(value) else format(value, ".17g")}
    else:
        payload = repr(value)
    encoded = json.dumps(payload, sort_keys=True, default=str, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()[:16]


def measure(call: Callable[[], object]) -> tuple[float, int, str]:
    tracemalloc.start()
    started = time.perf_counter_ns()
    value = call()
    elapsed_ns = time.perf_counter_ns() - started
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    return elapsed_ns / 1_000_000.0, peak, checksum(value)


def sample_case(
    *,
    benchmark: str,
    n: int,
    seed: int,
    warmup: int,
    repetitions: int,
    call: Callable[[], object],
    order: int | None = None,
    bandwidth: int | None = None,
    regression: str | None = None,
    min_segment: int | None = None,
) -> list[Sample]:
    for _ in range(warmup):
        call()
    rows: list[Sample] = []
    for repetition in range(1, repetitions + 1):
        wall_ms, peak, digest = measure(call)
        rows.append(
            Sample(
                benchmark=benchmark,
                n=n,
                order=order,
                bandwidth=bandwidth,
                regression=regression,
                min_segment=min_segment,
                seed=seed,
                repetition=repetition,
                wall_ms=wall_ms,
                tracemalloc_peak_bytes=peak,
                result_checksum=digest,
            )
        )
    return rows


def run(config: argparse.Namespace) -> list[Sample]:
    results: list[Sample] = []
    for n in config.n:
        series_seed = stable_seed(config.seed, "series", n)
        values = time_series(n, series_seed)
        for order in config.ar_orders:
            results.extend(
                sample_case(
                    benchmark="lagged_linear_regression",
                    n=n,
                    seed=series_seed,
                    order=order,
                    warmup=config.warmup,
                    repetitions=config.repetitions,
                    call=lambda values=values, order=order: lagged_linear_regression(values, order),
                )
            )
        for order in config.adf_orders:
            results.extend(
                sample_case(
                    benchmark="adf_statistic",
                    n=n,
                    seed=series_seed,
                    order=order,
                    regression="constant",
                    warmup=config.warmup,
                    repetitions=config.repetitions,
                    call=lambda values=values, order=order: adf_statistic(values, order, "constant"),
                )
            )
        for bandwidth in config.kpss_bandwidths:
            results.extend(
                sample_case(
                    benchmark="kpss_test",
                    n=n,
                    seed=series_seed,
                    bandwidth=bandwidth,
                    regression="trend",
                    warmup=config.warmup,
                    repetitions=config.repetitions,
                    call=lambda values=values, bandwidth=bandwidth: kpss_test(values, "trend", bandwidth),
                )
            )
    for n in config.change_point_n:
        series_seed = stable_seed(config.seed, "change-point", n)
        values = change_point_series(n, series_seed)
        results.extend(
            sample_case(
                benchmark="single_mean_shift_change_point",
                n=n,
                seed=series_seed,
                min_segment=config.min_segment,
                warmup=config.warmup,
                repetitions=config.repetitions,
                call=lambda values=values, minimum=config.min_segment: single_mean_shift_change_point(values, minimum),
            )
        )
    return results


def git_revision() -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(COURSEWORK_ROOT.parent), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def git_status() -> list[str] | None:
    try:
        output = subprocess.check_output(
            ["git", "-C", str(COURSEWORK_ROOT.parent), "status", "--short"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        return output.splitlines()
    except (OSError, subprocess.CalledProcessError):
        return None


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


def write_csv(path: Path, samples: Iterable[Sample]) -> None:
    fieldnames = list(Sample.__dataclass_fields__)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for sample in samples:
            writer.writerow(asdict(sample))


def grouped(samples: list[Sample]) -> list[dict[str, Any]]:
    buckets: dict[tuple[Any, ...], list[Sample]] = {}
    for sample in samples:
        key = (sample.benchmark, sample.n, sample.order, sample.bandwidth, sample.regression, sample.min_segment)
        buckets.setdefault(key, []).append(sample)
    rows = []
    for key in sorted(buckets, key=str):
        values = buckets[key]
        timings = [sample.wall_ms for sample in values]
        rows.append(
            {
                "benchmark": key[0],
                "n": key[1],
                "order": key[2],
                "bandwidth": key[3],
                "regression": key[4],
                "min_segment": key[5],
                "samples": len(values),
                "median_wall_ms": statistics.median(timings),
                "min_wall_ms": min(timings),
                "max_wall_ms": max(timings),
                "median_peak_bytes": int(statistics.median(sample.tracemalloc_peak_bytes for sample in values)),
                "checksums": sorted({sample.result_checksum for sample in values}),
            }
        )
    return rows


def markdown_summary(config: argparse.Namespace, aggregates: list[dict[str, Any]]) -> str:
    lines = [
        "# Statistical-extension Python-oracle benchmark",
        "",
        "This is a local Python reference benchmark, **not ClickHouse native throughput, allocation, or query-plan evidence**.",
        "It times only independent batch-oracle finalizer calls; deterministic input construction and warmups are outside each timed sample.",
        "",
        f"- Seed: `{config.seed}`",
        f"- Warmups per case: `{config.warmup}`; timed repetitions per case: `{config.repetitions}`",
        f"- AR/ADF/KPSS n: `{','.join(map(str, config.n))}`",
        f"- AR p: `{','.join(map(str, config.ar_orders))}`; ADF p: `{','.join(map(str, config.adf_orders))}`",
        f"- KPSS trend q: `{','.join(map(str, config.kpss_bandwidths))}`",
        f"- Change-point n: `{','.join(map(str, config.change_point_n))}`, min segment `{config.min_segment}`",
        "",
        "`tracemalloc_peak_bytes` is Python-traced allocation during one call, not process RSS or a native allocator measurement.",
        "The change-point oracle is an intentionally direct O(n²) reference scan, so its size cap is stricter than the other cases.",
        "",
        "| finalizer | n | p | q | regression | min segment | median ms | min–max ms | median traced peak bytes | checksum |",
        "|---|---:|---:|---:|---|---:|---:|---:|---:|---|",
    ]
    for row in aggregates:
        order = "" if row["order"] is None else str(row["order"])
        bandwidth = "" if row["bandwidth"] is None else str(row["bandwidth"])
        regression = row["regression"] or ""
        segment = "" if row["min_segment"] is None else str(row["min_segment"])
        checksums = ", ".join(row["checksums"])
        lines.append(
            f"| {row['benchmark']} | {row['n']} | {order} | {bandwidth} | {regression} | {segment} | "
            f"{row['median_wall_ms']:.3f} | {row['min_wall_ms']:.3f}–{row['max_wall_ms']:.3f} | "
            f"{row['median_peak_bytes']} | `{checksums}` |"
        )
    lines.extend(
        [
            "",
            "Raw repetitions are in `results.csv`; machine/runtime/configuration metadata and the same rows are in `results.json`.",
        ]
    )
    return "\n".join(lines) + "\n"


def prepare_output(path: Path) -> None:
    if path.exists() and any(path.iterdir()):
        raise SystemExit(f"refusing to overwrite non-empty output directory: {path}")
    path.mkdir(parents=True, exist_ok=True)


def main() -> None:
    config = args()
    prepare_output(config.output_dir)
    started = datetime.now(timezone.utc)
    samples = run(config)
    aggregates = grouped(samples)
    metadata = {
        "schema_version": SCHEMA_VERSION,
        "benchmark_kind": "independent Python batch-oracle finalizer microbenchmark; not native ClickHouse throughput",
        "started_at_utc": started.isoformat(),
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
        "python": sys.version,
        "command": [sys.executable, *sys.argv],
        "optional_package_versions": optional_package_versions(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "git_revision": git_revision(),
        "git_status": git_status(),
        "script_sha256": sha256(Path(__file__).resolve()),
        "oracle_sha256": sha256(REFERENCE_DIR / "extensions.py"),
        "reference_module": str(REFERENCE_DIR / "extensions.py"),
        "configuration": {
            "seed": config.seed,
            "n": config.n,
            "ar_orders": config.ar_orders,
            "adf_orders": config.adf_orders,
            "kpss_bandwidths": config.kpss_bandwidths,
            "kpss_regression": "trend",
            "change_point_n": config.change_point_n,
            "min_segment": config.min_segment,
            "warmup": config.warmup,
            "repetitions": config.repetitions,
        },
        "aggregate_results": aggregates,
        "samples": [asdict(sample) for sample in samples],
    }
    write_csv(config.output_dir / "results.csv", samples)
    write_text_lf(config.output_dir / "results.json", json.dumps(metadata, indent=2, allow_nan=False) + "\n")
    write_text_lf(config.output_dir / "summary.md", markdown_summary(config, aggregates))
    write_sha256_manifest(config.output_dir)
    print(f"wrote {len(samples)} timed samples to {config.output_dir}")


if __name__ == "__main__":
    main()
