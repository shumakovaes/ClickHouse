import csv
import math
import tempfile
import unittest
from pathlib import Path

import numpy as np

from run_experiments import (
    ExperimentConfig,
    acf,
    capture_environment,
    durbin_watson,
    fit_ar1_forecast,
    generate_series,
    kpss_statistic,
    ljung_box,
    run,
)


class ExperimentTests(unittest.TestCase):
    def test_ar1_generation_is_reproducible_and_acf_is_positive(self):
        a = generate_series("ar1", 500, np.random.default_rng(7), phi=0.8)
        b = generate_series("ar1", 500, np.random.default_rng(7), phi=0.8)
        self.assertTrue(np.array_equal(a, b))
        self.assertGreater(acf(a, 1)[1], 0.5)

    def test_known_diagnostics(self):
        x = np.ones(20)
        self.assertTrue(np.isnan(acf(x, 3)[0]))
        self.assertAlmostEqual(durbin_watson(np.arange(20.0)), 19 / sum(i * i for i in range(20)), places=12)
        q, p = ljung_box(np.random.default_rng(1).normal(size=100), 5)
        self.assertGreaterEqual(q, 0)
        self.assertGreaterEqual(p, 0)
        self.assertLessEqual(p, 1)

    def test_ar1_fit_recovers_reasonable_phi(self):
        x = generate_series("ar1", 2000, np.random.default_rng(2), phi=0.6)
        _, phi, forecast = fit_ar1_forecast(x)
        self.assertAlmostEqual(phi, 0.6, delta=0.08)
        self.assertTrue(np.isfinite(forecast))

    def test_kpss_separates_random_walk_from_white_noise(self):
        rng = np.random.default_rng(3)
        stationary = generate_series("white_noise", 500, rng)
        walk = generate_series("random_walk", 500, rng)
        self.assertGreater(kpss_statistic(walk), kpss_statistic(stationary))

    def test_run_shapes_and_determinism(self):
        cfg = ExperimentConfig(n=80, reps=5, seed=123, max_lag=8)
        rows1, repeat1 = run(cfg)
        rows2, repeat2 = run(cfg)
        self.assertEqual(rows1, rows2)
        for left, right in zip(repeat1, repeat2):
            self.assertEqual(left.keys(), right.keys())
            for key in left:
                if isinstance(left[key], float) and math.isnan(left[key]) and math.isnan(right[key]):
                    continue
                self.assertEqual(left[key], right[key])
        self.assertEqual(len(rows1), 6)
        self.assertEqual(len(repeat1), 6)
        for row in repeat1:
            self.assertEqual(row["reps"], 5)
            self.assertGreaterEqual(row["ljung_box_rejection_rate_5pct"], 0)
            self.assertLessEqual(row["ljung_box_rejection_rate_5pct"], 1)

    def test_environment_records_configuration_and_provenance(self):
        cfg = ExperimentConfig(n=80, reps=5, seed=123, max_lag=8)
        env = capture_environment(cfg, command="test command")
        self.assertEqual(env["command"], "test command")
        self.assertEqual((env["n"], env["reps"], env["seed"]), (80, 5, 123))
        self.assertEqual(env["config"]["max_lag"], 8)
        self.assertIn("numpy", env["packages"])
        self.assertIsInstance(env["scipy_available"], bool)
        self.assertIn("ljung_box", env["p_value_provenance"])


if __name__ == "__main__":
    unittest.main()
