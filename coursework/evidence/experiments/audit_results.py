"""Create a concise, source-grounded interpretation of experiment CSVs."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def f(row: dict[str, str], key: str) -> str:
    value = float(row[key])
    return "NA" if not math.isfinite(value) else f"{value:.4f}"


def create_analysis(input_dir: Path, output: Path) -> None:
    repeat = read_rows(input_dir / "repeat_summary.csv")
    by_kind = {r["process"]: r for r in repeat}
    environment = json.loads((input_dir / "environment.json").read_text(encoding="utf-8"))
    lb_provenance = (
        "SciPy was unavailable, so Ljung–Box p-values use the Wilson–Hilferty chi-square survival approximation"
        if not environment["scipy_available"]
        else "SciPy was available, so Ljung–Box p-values use SciPy's chi-square survival function"
    )
    with output.open("w", encoding="utf-8") as out:
        out.write("# Archived baseline measured-results audit\n\n")
        out.write("This is archived baseline exploratory evidence predating the four registered extensions (`timeSeriesLaggedLinearRegression`, `timeSeriesADFStatistic`, `timeSeriesKPSSTest`, and `timeSeriesMeanShiftChangePoint`). These statements describe the generated CSVs, not theoretical guarantees. All rates use the fixed-seed run (`n=300`, `reps=200`, seed `20260910`). A 5% rejection rate is the decision rule (`p < 0.05`).\n\n")
        out.write("Scope: the three implemented baseline diagnostics are ACF, Ljung–Box, and Durbin–Watson. AR(1) fit/forecast and KPSS values are archived exploratory outputs from before the four registered extensions, reported separately and not counted as one of the three core diagnostics. The runtime and p-value provenance are recorded in `environment.json`.\n\n")
        out.write("## Formula audit\n\n")
        out.write(f"The ACF uses a demeaned series and the common (biased) denominator `sum(z²)`. Ljung–Box uses `n(n+2) * sum(rho_k²/(n-k))` over the requested lags, with a chi-square survival probability. Durbin–Watson is `sum(diff(x)²)/sum(x²)` for the supplied sequence; here it is descriptive because no residual model is supplied. AR(1) is OLS with an intercept, and the generator uses stationary initialization for |phi|<1. KPSS removes either a level or linear trend and estimates long-run variance with a Bartlett/Newey–West window; its p-values are critical-value interpolations because the KPSS null distribution is non-standard. {lb_provenance}; this is recorded in `environment.json`.\n\n")
        out.write("## False-positive and detection rates\n\n")
        out.write("For Ljung–Box, white noise is the serial-correlation null; its rejection rate is a false-positive estimate. AR(1), random walk, trend, and mean-shift rows are detection rates, but only the AR(1) cases are stationary alternatives. For KPSS, white noise is level-stationary, while trend-stationary is trend-stationary after a linear trend is removed; those are the false-positive reference cases for level (`c`) and trend (`ct`) KPSS respectively.\n\n")
        out.write("| process | Ljung–Box reject | KPSS level reject | KPSS trend reject |\n|---|---:|---:|---:|\n")
        for r in repeat:
            out.write(f"| {r['process']} | {float(r['ljung_box_rejection_rate_5pct']):.3f} | {float(r['kpss_level_rejection_rate_5pct']):.3f} | {float(r['kpss_trend_rejection_rate_5pct']):.3f} |\n")
        out.write(f"\nThe measured Ljung–Box false-positive rate is {float(by_kind['white_noise']['ljung_box_rejection_rate_5pct']):.3f} (white noise), with detection {float(by_kind['ar1_phi_0.5']['ljung_box_rejection_rate_5pct']):.3f} and {float(by_kind['ar1_phi_0.9']['ljung_box_rejection_rate_5pct']):.3f} for the AR(1) settings. KPSS level false-positive rate is {float(by_kind['white_noise']['kpss_level_rejection_rate_5pct']):.3f} for white noise; the trend-KPSS false-positive rate is {float(by_kind['trend_stationary']['kpss_trend_rejection_rate_5pct']):.3f} for the trend-stationary process. The random walk and mean shift are structural/nonstationary alternatives, not independent draws from a stationary null.\n\n")
        out.write("## ACF and archived baseline AR(1) recovery\n\n")
        out.write("The theoretical lag-1 autocorrelation is defined here only for white noise (0) and AR(1) (`phi`). The random walk, mean shift, and deterministic trend do not have a single stationary ACF target, so their theory-error fields are intentionally `NA`.\n\n")
        out.write("| process | ACF(1) theory | ACF(1) mean | ACF bias | ACF RMSE | AR(1) phi theory | phi mean | phi bias | phi RMSE |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|\n")
        for r in repeat:
            out.write("| " + r["process"] + " | " + " | ".join(f(r, c) for c in ["acf1_theory", "acf1_mean", "acf1_bias", "acf1_rmse", "ar1_phi_theory", "ar1_phi_mean", "ar1_phi_bias", "ar1_phi_rmse"]) + " |\n")
        out.write(f"\nFor the supplied {by_kind['ar1_phi_0.5']['reps']} repetitions, AR(1) phi RMSE is {f(by_kind['ar1_phi_0.5'], 'ar1_phi_rmse')} at phi=0.5 and {f(by_kind['ar1_phi_0.9'], 'ar1_phi_rmse')} at phi=0.9; the corresponding mean biases are {f(by_kind['ar1_phi_0.5'], 'ar1_phi_bias')} and {f(by_kind['ar1_phi_0.9'], 'ar1_phi_bias')}. The ACF(1) RMSEs are {f(by_kind['white_noise'], 'acf1_rmse')} (white noise), {f(by_kind['ar1_phi_0.5'], 'acf1_rmse')} (phi=0.5), and {f(by_kind['ar1_phi_0.9'], 'acf1_rmse')} (phi=0.9). These are Monte Carlo summaries, not confidence intervals.\n\n")
        out.write("## Change-point caveat\n\n")
        out.write("The midpoint mean shift is deliberately not a formal change-point test. ACF, Ljung–Box, Durbin–Watson, and KPSS can all react to a level break, but they do not identify its location or distinguish it reliably from other forms of nonstationarity. Use a dedicated change-point method and report its assumptions if locating or testing the break matters.\n\n")
        out.write("## Exact commands\n\n")
        out.write("```powershell\npy -m unittest discover -s evidence/experiments -p \"test_*.py\"\npy evidence/experiments/run_experiments.py --n 300 --reps 200 --seed 20260910 --output-dir evidence/experiments/results\npy evidence/experiments/audit_results.py --input-dir evidence/experiments/results --output evidence/experiments/results/analysis.md\n```\n\n")
        out.write("The single-run values used by the original diagnostic table are in `results.csv`; repeated summaries and theory-error calculations are in `repeat_summary.csv`.\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=Path(__file__).resolve().parent / "results")
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    output = args.output or args.input_dir / "analysis.md"
    create_analysis(args.input_dir, output)
    print(f"Wrote analysis to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
