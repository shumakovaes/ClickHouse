import math
import random
import unittest

from extensions import (
    adf_statistic,
    kpss_test,
    lagged_linear_regression,
    single_mean_shift_change_point,
)


class ExtensionOracleTests(unittest.TestCase):
    def test_lagged_regression_hand_fixture(self):
        # y[t] = 1 + 2*y[t-1], exactly.
        result = lagged_linear_regression([1, 3, 7, 15, 31, 63, 127], 1)
        self.assertAlmostEqual(result.intercept, 1.0, places=12)
        self.assertAlmostEqual(result.lags[0], 2.0, places=12)
        self.assertAlmostEqual(result.sse, 0.0, places=12)

    def test_lagged_regression_short_constant_and_validation(self):
        with self.assertRaises(ValueError): lagged_linear_regression([1, 2, 3], 1)
        with self.assertRaises(ValueError): lagged_linear_regression([2] * 10, 1)
        with self.assertRaises(ValueError): lagged_linear_regression([1, 2, 3], 0)
        with self.assertRaises(ValueError): lagged_linear_regression([1, math.inf, 2], 1)

    def test_lagged_regression_deterministic_random_property(self):
        rng = random.Random(42)
        y = [0.25]
        for _ in range(80):
            y.append(0.7 * y[-1] + 1.5 + rng.uniform(-0.1, 0.1))
        result = lagged_linear_regression(y, 1)
        self.assertAlmostEqual(result.intercept, 1.5, delta=0.08)
        self.assertAlmostEqual(result.lags[0], 0.7, delta=0.03)

    def test_adf_direction_and_validation(self):
        stationary = [0.0]
        rng = random.Random(9)
        for _ in range(120): stationary.append(0.4 * stationary[-1] + rng.gauss(0, 1))
        walk = [0.0]
        for _ in range(120): walk.append(walk[-1] + rng.gauss(0, 1))
        self.assertLess(adf_statistic(stationary, 1), adf_statistic(walk, 1))
        for deterministic in ("none", "constant", "trend"):
            self.assertTrue(math.isfinite(adf_statistic(stationary, 0, deterministic)))
        with self.assertRaises(ValueError): adf_statistic([1] * 20, 0)
        with self.assertRaises(ValueError): adf_statistic([1, 2], 0)
        with self.assertRaises(ValueError): adf_statistic(stationary, 0, "bad")

    def test_kpss_hand_fixture_bandwidth_and_invariances(self):
        base = [1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2]
        got = kpss_test(base, "level", 2)
        self.assertEqual(got.bandwidth, 2)
        self.assertTrue(got.statistic >= 0)
        shifted = kpss_test([x + 1000 for x in base], "level", 2)
        scaled = kpss_test([x * 7 for x in base], "level", 2)
        self.assertAlmostEqual(got.statistic, shifted.statistic, places=12)
        self.assertAlmostEqual(got.statistic, scaled.statistic, places=12)
        self.assertEqual(kpss_test(base, bandwidth="legacy").bandwidth, 7)
        with self.assertRaises(ValueError): kpss_test(base, bandwidth=12)

    def test_kpss_trend_short_and_constant(self):
        trend = [3 + 0.5 * i for i in range(30)]
        self.assertTrue(math.isnan(kpss_test(trend, "trend", 3).statistic))
        self.assertTrue(math.isnan(kpss_test([2] * 10, "level", 2).statistic))
        with self.assertRaises(ValueError): kpss_test([1], "level")
        with self.assertRaises(ValueError): kpss_test([1, 2], "bad")

    def test_change_point_hand_fixture_tie_and_min_segment(self):
        result = single_mean_shift_change_point([1, 1, 1, 10, 10, 10])
        self.assertEqual(result.index, 3)
        self.assertAlmostEqual(result.before_mean, 1)
        self.assertAlmostEqual(result.after_mean, 10)
        self.assertAlmostEqual(result.sse, 0)
        self.assertAlmostEqual(result.sse_reduction, 1)
        tie = single_mean_shift_change_point([1, 1, 1, 1], min_segment=1)
        self.assertEqual(tie.index, 1)
        with self.assertRaises(ValueError): single_mean_shift_change_point([1, 2], 2)
        with self.assertRaises(ValueError): single_mean_shift_change_point([1, 2], 0)

    def test_change_point_random_bruteforce_and_score_invariance(self):
        rng = random.Random(123)
        y = [rng.gauss(0, 0.05) for _ in range(20)] + [3 + rng.gauss(0, 0.05) for _ in range(20)]
        result = single_mean_shift_change_point(y, min_segment=3)
        self.assertGreaterEqual(result.index, 3)
        self.assertLessEqual(result.index, 37)
        # An independently written candidate scan verifies the exact SSE.
        candidates = []
        for k in range(3, len(y) - 2 + 1):
            a, b = y[:k], y[k:]
            am, bm = sum(a) / k, sum(b) / len(b)
            candidates.append((sum((x - am) ** 2 for x in a) + sum((x - bm) ** 2 for x in b), k))
        want_sse, want_k = min(candidates)
        self.assertEqual(result.index, want_k)
        self.assertAlmostEqual(result.sse, want_sse, places=10)
        translated = single_mean_shift_change_point([x + 50 for x in y], 3)
        self.assertEqual(translated.index, result.index)
        self.assertAlmostEqual(translated.sse, result.sse, places=8)

    def test_optional_statsmodels_cross_checks(self):
        try:
            import numpy as np
            from statsmodels.tsa.stattools import adfuller, kpss
            from statsmodels.tsa.ar_model import AutoReg
        except ImportError:
            self.skipTest("optional numpy/statsmodels not installed")
        rng = random.Random(20260910)
        y = [rng.gauss(0, 1) for _ in range(100)]
        ours = lagged_linear_regression(y, 2)
        theirs = AutoReg(np.asarray(y), lags=2, trend="c").fit()
        for got, want in zip(ours.coefficients, theirs.params):
            self.assertAlmostEqual(got, float(want), places=9)
        ours_adf = adf_statistic(y, 2, "constant")
        theirs_adf = adfuller(y, maxlag=2, regression="c", autolag=None)
        self.assertAlmostEqual(ours_adf, float(theirs_adf[0]), places=8)
        bandwidth = 4
        ours_kpss = kpss_test(y, "level", bandwidth)
        theirs_kpss = kpss(y, regression="c", nlags=bandwidth)
        self.assertAlmostEqual(ours_kpss.statistic, float(theirs_kpss[0]), places=8)


if __name__ == "__main__":
    unittest.main(verbosity=2)
