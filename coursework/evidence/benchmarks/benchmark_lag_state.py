#!/usr/bin/env python3
"""Benchmark keyed ACF/Ljung--Box/Durbin--Watson aggregate state designs.

The benchmark models three representations without requiring a database
build. ``compact_ordered`` is an O(L)-per-key prototype for ordered,
contiguous-range merges only. ``exact_store_sort`` stores every row by key and
sorts at finalize, supporting arbitrary partition/interleaving. The
``naive_full_recompute`` baseline stores every row flat and globally sorts and
recomputes at finalize. All finalizers compute actual ACF values through the
requested lag, Ljung--Box Q, and Durbin--Watson; the CSV checksum is derived
from those statistics rather than a toy row checksum.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import platform
import random
import statistics
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence


Row = tuple[int, int, int]  # key, stream ordinal, value
COMPACT = "compact_ordered"
EXACT = "exact_store_sort"
NAIVE = "naive_full_recompute"
DESIGNS = (COMPACT, EXACT, NAIVE)


@dataclass
class KeyStats:
    count: int = 0
    total: int = 0
    sumsq: int = 0
    cross: list[int] | None = None
    dw_numerator: int = 0
    first: int | None = None
    last: int | None = None
    prefix: list[int] | None = None
    suffix: deque[int] | None = None


@dataclass(frozen=True)
class LagStatistics:
    rows: int
    acf: tuple[float, ...]
    ljung_box_q: float
    durbin_watson: float

    def checksum(self) -> str:
        payload = json.dumps(
            {
                "rows": self.rows,
                "acf": [round(value, 12) for value in self.acf],
                "ljung_box_q": round(self.ljung_box_q, 12),
                "durbin_watson": round(self.durbin_watson, 12),
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()[:16]


def new_key_stats(lag: int) -> KeyStats:
    return KeyStats(cross=[0] * (lag + 1), prefix=[], suffix=deque(maxlen=lag))


def add_value(stats: KeyStats, value: int, lag: int) -> None:
    """Update exact online sufficient statistics for one keyed value."""
    if stats.cross is None or stats.prefix is None or stats.suffix is None:
        raise AssertionError("uninitialized key statistics")
    for distance in range(1, min(lag, len(stats.suffix)) + 1):
        stats.cross[distance] += value * stats.suffix[-distance]
    if stats.last is not None:
        stats.dw_numerator += (value - stats.last) ** 2
    stats.count += 1
    stats.total += value
    stats.sumsq += value * value
    if stats.first is None:
        stats.first = value
    stats.last = value
    if len(stats.prefix) < lag:
        stats.prefix.append(value)
    stats.suffix.append(value)


def stats_from_values(values: Sequence[int], lag: int) -> KeyStats:
    stats = new_key_stats(lag)
    for value in values:
        add_value(stats, value, lag)
    return stats


def centered_cross(stats: KeyStats, distance: int) -> float:
    if stats.count <= distance or stats.cross is None or stats.prefix is None or stats.suffix is None:
        return 0.0
    mean = stats.total / stats.count
    prefix_sum = sum(stats.prefix[:distance])
    suffix_sum = sum(list(stats.suffix)[-distance:])
    return stats.cross[distance] - mean * (2 * stats.total - prefix_sum - suffix_sum) + (stats.count - distance) * mean * mean


def aggregate_statistics(per_key: Iterable[KeyStats], lag: int) -> LagStatistics:
    """Pool keyed autocovariance numerators while preserving per-key means."""
    all_stats = list(per_key)
    rows = sum(item.count for item in all_stats)
    variance = sum(item.sumsq - (item.total * item.total / item.count) for item in all_stats if item.count)
    acf: list[float] = []
    for distance in range(1, lag + 1):
        numerator = sum(centered_cross(item, distance) for item in all_stats)
        acf.append(numerator / variance if variance > 0 else 0.0)
    q = 0.0
    for distance, correlation in enumerate(acf, start=1):
        if rows > distance:
            q += correlation * correlation / (rows - distance)
    q *= rows * (rows + 2)
    dw = sum(item.dw_numerator for item in all_stats) / variance if variance > 0 else 0.0
    return LagStatistics(rows, tuple(acf), q, dw)


class CompactOrderedState:
    """Bounded sufficient state; only contiguous ordered ranges may merge."""

    def __init__(self, lag: int) -> None:
        self.lag = lag
        self.by_key: dict[int, KeyStats] = {}
        self.range_start: int | None = None
        self.range_end: int | None = None

    def add(self, row: Row) -> None:
        key, ordinal, value = row
        if self.range_end is not None and ordinal != self.range_end + 1:
            raise ValueError("compact_ordered add requires contiguous ordered rows")
        if self.range_start is None:
            self.range_start = ordinal
        self.range_end = ordinal
        stats = self.by_key.setdefault(key, new_key_stats(self.lag))
        add_value(stats, value, self.lag)

    def merge(self, other: "CompactOrderedState") -> None:
        if self.lag != other.lag:
            raise ValueError("cannot merge different lags")
        if other.range_start is None:
            return
        if self.range_end is not None and other.range_start != self.range_end + 1:
            raise ValueError("compact_ordered merge requires contiguous ranges")
        if self.range_start is None:
            self.range_start = other.range_start
        self.range_end = other.range_end
        for key, right in other.by_key.items():
            left = self.by_key.get(key)
            if left is None:
                self.by_key[key] = right
                continue
            if left.cross is None or right.cross is None or left.prefix is None or right.prefix is None or left.suffix is None or right.suffix is None:
                raise AssertionError("uninitialized key statistics")
            cross = [0] * (self.lag + 1)
            for distance in range(1, self.lag + 1):
                boundary = 0
                left_values = list(left.suffix)
                right_values = right.prefix
                for right_index in range(min(distance, len(right_values))):
                    left_index = len(left_values) - (distance - right_index)
                    if left_index >= 0:
                        boundary += left_values[left_index] * right_values[right_index]
                cross[distance] = left.cross[distance] + right.cross[distance] + boundary
            prefix = (left.prefix + right.prefix)[: self.lag]
            suffix_values = (list(left.suffix) + list(right.suffix))[-self.lag :] if self.lag else []
            combined = KeyStats(
                count=left.count + right.count,
                total=left.total + right.total,
                sumsq=left.sumsq + right.sumsq,
                cross=cross,
                dw_numerator=left.dw_numerator + right.dw_numerator + ((left.last - right.first) ** 2 if left.last is not None and right.first is not None else 0),
                first=left.first,
                last=right.last,
                prefix=prefix,
                suffix=deque(suffix_values, maxlen=self.lag),
            )
            self.by_key[key] = combined

    def finalize(self) -> LagStatistics:
        return aggregate_statistics((self.by_key[key] for key in sorted(self.by_key)), self.lag)


class ExactStoreSortState:
    """Exact O(n) keyed rows, supporting arbitrary partition/interleaving."""

    def __init__(self, lag: int) -> None:
        self.lag = lag
        self.rows_by_key: dict[int, list[tuple[int, int]]] = {}

    def add(self, row: Row) -> None:
        key, ordinal, value = row
        self.rows_by_key.setdefault(key, []).append((ordinal, value))

    def merge(self, other: "ExactStoreSortState") -> None:
        if self.lag != other.lag:
            raise ValueError("cannot merge different lags")
        for key, incoming in other.rows_by_key.items():
            self.rows_by_key.setdefault(key, []).extend(incoming)

    def finalize(self) -> LagStatistics:
        stats = []
        for key in sorted(self.rows_by_key):
            ordered = sorted(self.rows_by_key[key], key=lambda item: item[0])
            stats.append(stats_from_values([value for _, value in ordered], self.lag))
        return aggregate_statistics(stats, self.lag)


class NaiveFullRecomputeState:
    """Flat O(n) rows with global sort and full recomputation at finalize."""

    def __init__(self, lag: int) -> None:
        self.lag = lag
        self.rows: list[Row] = []

    def add(self, row: Row) -> None:
        self.rows.append(row)

    def merge(self, other: "NaiveFullRecomputeState") -> None:
        if self.lag != other.lag:
            raise ValueError("cannot merge different lags")
        self.rows.extend(other.rows)

    def finalize(self) -> LagStatistics:
        ordered = sorted(self.rows, key=lambda row: (row[0], row[1]))
        stats = []
        index = 0
        while index < len(ordered):
            key = ordered[index][0]
            values: list[int] = []
            while index < len(ordered) and ordered[index][0] == key:
                values.append(ordered[index][2])
                index += 1
            stats.append(stats_from_values(values, self.lag))
        return aggregate_statistics(stats, self.lag)


STATE_TYPES = {COMPACT: CompactOrderedState, EXACT: ExactStoreSortState, NAIVE: NaiveFullRecomputeState}


def deep_size(value: object, seen: set[int] | None = None) -> int:
    if seen is None:
        seen = set()
    identity = id(value)
    if identity in seen:
        return 0
    seen.add(identity)
    size = sys.getsizeof(value)
    if isinstance(value, dict):
        size += sum(deep_size(k, seen) + deep_size(v, seen) for k, v in value.items())
    elif isinstance(value, (list, tuple, set, frozenset, deque)):
        size += sum(deep_size(item, seen) for item in value)
    elif hasattr(value, "__dict__"):
        size += deep_size(vars(value), seen)
    return size


def stored_rows(state: object) -> int:
    if isinstance(state, CompactOrderedState):
        return sum(item.count for item in state.by_key.values())
    if isinstance(state, ExactStoreSortState):
        return sum(len(rows) for rows in state.rows_by_key.values())
    return len(state.rows)  # type: ignore[attr-defined]


def parse_ints(raw: str) -> list[int]:
    values = [int(part.strip()) for part in raw.split(",") if part.strip()]
    if not values or any(value < 0 for value in values):
        raise argparse.ArgumentTypeError("expected non-negative comma-separated integers")
    return values


def stream_rows(rows: int, keys: int, seed: int) -> list[Row]:
    rng = random.Random(seed)
    # Bounded values keep all arithmetic exact and avoid floating overflow.
    return [(rng.randrange(keys), ordinal, rng.randrange(1, 1_000_000)) for ordinal in range(rows)]


def split_rows(rows: Sequence[Row], chunks: int, partition: str) -> list[list[Row]]:
    chunks = min(chunks, max(1, len(rows)))
    if partition == "contiguous":
        return [list(rows[len(rows) * i // chunks : len(rows) * (i + 1) // chunks]) for i in range(chunks)]
    if partition == "interleaved":
        parts = [[] for _ in range(chunks)]
        for row in rows:
            parts[row[1] % chunks].append(row)
        return parts
    raise ValueError(f"unknown partition: {partition}")


def build_state(design: str, lag: int, rows: Iterable[Row]):
    state = STATE_TYPES[design](lag)
    for row in rows:
        state.add(row)
    return state


@dataclass(frozen=True)
class Case:
    phase: str
    design: str
    rows: int
    keys: int
    lag: int
    chunks: int
    partition: str
    repeat: int
    seed: int


def make_record(case: Case, elapsed: int, state: object, result: LagStatistics | None, operations: int) -> dict[str, object]:
    return {
        "phase": case.phase,
        "design": case.design,
        "rows": case.rows,
        "keys": case.keys,
        "lag": case.lag,
        "chunks": case.chunks,
        "partition": case.partition,
        "repeat": case.repeat,
        "seed": case.seed,
        "elapsed_ns": elapsed,
        "elapsed_ms": round(elapsed / 1_000_000, 6),
        "operations": operations,
        "ops_per_sec": round(operations * 1_000_000_000 / max(1, elapsed), 3),
        "state_bytes": deep_size(state),
        "state_rows": stored_rows(state),
        "acf_json": json.dumps(result.acf) if result is not None else "",
        "ljung_box_q": result.ljung_box_q if result is not None else "",
        "durbin_watson": result.durbin_watson if result is not None else "",
        "stat_checksum": result.checksum() if result is not None else "",
    }


def timed_add(design: str, lag: int, rows: Sequence[Row]) -> tuple[int, object]:
    state = STATE_TYPES[design](lag)
    started = time.perf_counter_ns()
    for row in rows:
        state.add(row)
    return time.perf_counter_ns() - started, state


def timed_merge(design: str, lag: int, chunks: Sequence[Sequence[Row]]) -> tuple[int, int, object]:
    partials = [build_state(design, lag, part) for part in chunks]
    started = time.perf_counter_ns()
    target = partials[0]
    for partial in partials[1:]:
        target.merge(partial)
    return time.perf_counter_ns() - started, len(partials), target


def timed_finalize(state: object) -> tuple[int, LagStatistics]:
    started = time.perf_counter_ns()
    result = state.finalize()
    return time.perf_counter_ns() - started, result


def add_case(records: list[dict[str, object]], rows: Sequence[Row], args: argparse.Namespace, design: str, repeat: int) -> None:
    seed = args.seed + len(rows)
    case = Case("add", design, len(rows), args.keys, args.lag_for_add, 1, "contiguous", repeat, seed)
    elapsed, state = timed_add(design, args.lag_for_add, rows)
    records.append(make_record(case, elapsed, state, None, len(rows)))
    finalize_case = Case("finalize", design, len(rows), args.keys, args.lag_for_add, 1, "contiguous", repeat, seed)
    finalize_elapsed, result = timed_finalize(state)
    records.append(make_record(finalize_case, finalize_elapsed, state, result, len(rows)))


def merge_case(records: list[dict[str, object]], rows: Sequence[Row], args: argparse.Namespace, lag: int, chunks: int, partition: str, design: str, repeat: int) -> None:
    seed = args.seed + len(rows)
    parts = split_rows(rows, chunks, partition)
    case = Case("merge", design, len(rows), args.keys, lag, chunks, partition, repeat, seed)
    elapsed, actual_chunks, state = timed_merge(design, lag, parts)
    records.append(make_record(case, elapsed, state, None, len(rows) + actual_chunks - 1))
    finalize_case = Case("finalize", design, len(rows), args.keys, lag, chunks, partition, repeat, seed)
    finalize_elapsed, result = timed_finalize(state)
    records.append(make_record(finalize_case, finalize_elapsed, state, result, len(rows)))


def stats_close(left: LagStatistics, right: LagStatistics) -> bool:
    if left.rows != right.rows or len(left.acf) != len(right.acf):
        return False
    values = list(left.acf) + [left.ljung_box_q, left.durbin_watson]
    others = list(right.acf) + [right.ljung_box_q, right.durbin_watson]
    return all(math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-10) for a, b in zip(values, others))


def run_benchmark(args: argparse.Namespace) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for row_count in args.rows:
        rows = stream_rows(row_count, args.keys, args.seed + row_count)
        for repeat in range(args.repeats):
            for design in DESIGNS:
                add_case(records, rows, args, design, repeat)
        for lag in args.lags:
            for chunks in args.chunks:
                for repeat in range(args.repeats):
                    for design in DESIGNS:
                        merge_case(records, rows, args, lag, chunks, "contiguous", design, repeat)
                    # Compact is intentionally not attempted here: its add or
                    # merge precondition rejects interleaved partial ranges.
                    for design in (EXACT, NAIVE):
                        merge_case(records, rows, args, lag, chunks, "interleaved", design, repeat)

    finalized: dict[tuple[object, ...], dict[str, LagStatistics]] = {}
    for record in records:
        if record["phase"] != "finalize":
            continue
        acf = tuple(json.loads(str(record["acf_json"])))
        result = LagStatistics(int(record["rows"]), acf, float(record["ljung_box_q"]), float(record["durbin_watson"]))
        key = (record["rows"], record["lag"], record["chunks"], record["partition"], record["repeat"])
        finalized.setdefault(key, {})[str(record["design"])] = result
    mismatches = []
    for key, values in finalized.items():
        baseline = next(iter(values.values()))
        if any(not stats_close(baseline, result) for result in values.values()):
            mismatches.append((key, list(values)))
    if mismatches:
        raise AssertionError(f"ACF/Q/DW mismatches: {mismatches[:2]}")
    return records


def capture_environment(args: argparse.Namespace) -> dict[str, object]:
    package_root = Path(__file__).resolve().parents[2]
    candidates = [package_root.parent, package_root]
    # Keep compatibility with the former workspace layout while preferring the
    # ClickHouse checkout that contains this package.
    candidates.extend([package_root / "outputs" / "ClickHouse", package_root.parent.parent])
    repo = next((candidate for candidate in candidates if (candidate / ".git").exists()), package_root)
    try:
        git_head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        git_head = "unknown"
    return {
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "command": " ".join(sys.argv),
        "cwd": str(Path.cwd()),
        "repo": str(repo),
        "git_head": git_head,
        "python": sys.version,
        "python_executable": sys.executable,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "cpu_count": os.cpu_count(),
        "implementation": platform.python_implementation(),
        "parameters": {
            "rows": args.rows,
            "keys": args.keys,
            "lags": args.lags,
            "chunks": args.chunks,
            "lag_for_add": args.lag_for_add,
            "repeats": args.repeats,
            "seed": args.seed,
            "partitions": ["contiguous", "interleaved"],
        },
    }


def write_outputs(records: list[dict[str, object]], environment: dict[str, object], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    fields = list(records[0].keys())
    with (output_dir / "results.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(records)
    (output_dir / "environment.json").write_text(json.dumps(environment, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# Keyed ACF/Ljung–Box/Durbin–Watson benchmark",
        "",
        "Generated from `results.csv` by `benchmark_lag_state.py`.",
        "All finalizers compute actual ACF values, Ljung–Box Q, and Durbin–Watson. The compact ordered design is a bounded prototype only for contiguous ordered ranges; it is not a correctness claim for arbitrary ClickHouse plans.",
        "",
        "## Median timings and retained state size",
        "",
        "| phase | design | partition | rows | lag | chunks | median ms | state bytes |",
        "|---|---|---|---:|---:|---:|---:|---:|",
    ]
    groups: dict[tuple[object, ...], list[dict[str, object]]] = {}
    for record in records:
        key = (record["phase"], record["design"], record["partition"], record["rows"], record["lag"], record["chunks"])
        groups.setdefault(key, []).append(record)
    for key in sorted(groups, key=lambda item: (str(item[0]), str(item[1]), str(item[2]), int(item[3]), int(item[4]), int(item[5]))):
        phase, design, partition, rows, lag, chunks = key
        group = groups[key]
        median_ms = statistics.median(float(item["elapsed_ms"]) for item in group)
        median_bytes = int(statistics.median(int(item["state_bytes"]) for item in group))
        lines.append(f"| {phase} | {design} | {partition} | {rows} | {lag} | {chunks} | {median_ms:.3f} | {median_bytes} |")
    lines.extend([
        "",
        "## Interpretation",
        "",
        "* `compact_ordered` results are emitted only for contiguous partitions and retain bounded sufficient statistics plus prefix/suffix boundaries. It rejects interleaved partial states; do not generalize its timing or memory behavior to arbitrary plans.",
        "* `exact_store_sort` retains every keyed row and sorts each key at finalize, making it the correctness reference for arbitrary partition/interleaving.",
        "* `naive_full_recompute` retains every row, globally sorts by key/ordinal, and recomputes all statistics at finalize.",
        "* Add, merge, and finalize are timed separately. ACF/Q/DW fields and `stat_checksum` are populated by finalizers; pre-finalize rows have blank result fields.",
        "",
        "Environment: [`environment.json`](environment.json).",
        "",
    ])
    (output_dir / "summary.md").write_text("\n".join(lines), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "run")
    parser.add_argument("--rows", type=parse_ints, default=[1000, 5000, 10000])
    parser.add_argument("--keys", type=int, default=128)
    parser.add_argument("--lags", type=parse_ints, default=[1, 8, 64])
    parser.add_argument("--chunks", type=parse_ints, default=[1, 4, 16])
    parser.add_argument("--lag-for-add", type=int, default=64)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--seed", type=int, default=20260910)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.keys <= 0 or args.repeats <= 0 or args.lag_for_add < 0:
        raise SystemExit("keys/repeats must be positive and lag non-negative")
    records = run_benchmark(args)
    write_outputs(records, capture_environment(args), args.output_dir)
    print(f"wrote {len(records)} measurements to {args.output_dir}")


if __name__ == "__main__":
    main()
