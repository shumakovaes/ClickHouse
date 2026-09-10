"""Run on Windows with: py -3 -m unittest -v test_reference"""
import math
import random
import unittest

from reference import FullSampleKeyedStats, OrderedStats, UINT64_MAX, chi_square_sf, same_float


def assert_float_equal(case, got, expected, tol=2e-10):
    case.assertTrue(same_float(got, expected, tol), f"{got!r} != {expected!r}")


class OrderedStatsProperties(unittest.TestCase):
    def compare(self, a, b):
        self.assertEqual(a.n, b.n)
        for x, y in zip(a.acf(12), b.acf(12)): assert_float_equal(self, x, y)
        for x, y in [(a.ljung_box(12), b.ljung_box(12)), (a.durbin_watson(), b.durbin_watson()), (a.kpss(), b.kpss())]:
            assert_float_equal(self, x, y)
        aa, bb = a.ar1(4), b.ar1(4)
        for k in aa: assert_float_equal(self, aa[k], bb[k])

    def test_seeded_all_split_merge_tree_shapes_equal_direct(self):
        rng = random.Random(0xC0DEC0DE)
        for n in range(0, 80):
            vals = [rng.gauss(0, 3) + (1e9 if i % 13 == 0 else 0.0) for i in range(n)]
            direct = OrderedStats.from_values(vals, -50)
            pieces = [OrderedStats.from_pairs([(k, v)]) for k, v in direct.points]
            while len(pieces) > 1:
                i = rng.randrange(len(pieces) - 1)
                pieces[i:i + 2] = [pieces[i].merge(pieces[i + 1])]
            merged = pieces[0] if pieces else OrderedStats()
            self.compare(direct, merged)
            for cut in range(n + 1):
                left, right = direct.split_at(cut)
                self.compare(direct, left.merge(right))

    def test_json_is_canonical_and_round_trips(self):
        s = OrderedStats.from_pairs([(-4, -0.0), (2, 1.25), (99, -3.5)])
        encoded = s.to_json()
        self.assertEqual(encoded, '{"version":1,"points":[[-4,-0.0],[2,1.25],[99,-3.5]]}')
        self.assertEqual(OrderedStats.from_json(encoded), s)

    def test_invalid_order_overlap_and_values_rejected(self):
        with self.assertRaises(ValueError): OrderedStats.from_pairs([(2, 1), (1, 2)])
        with self.assertRaises(ValueError): OrderedStats.from_pairs([(1, math.inf)])
        with self.assertRaises(ValueError): OrderedStats.from_values([1]).merge(OrderedStats.from_pairs([(0, 2)]))

    def test_adversarial_degenerate_cases(self):
        empty, one = OrderedStats(), OrderedStats.from_values([4])
        self.assertTrue(math.isnan(empty.durbin_watson()))
        self.assertTrue(math.isnan(one.ljung_box(3)))
        constant = OrderedStats.from_values([7.0] * 9)
        self.assertTrue(all(math.isnan(x) for x in constant.acf(3)))
        self.assertTrue(math.isnan(constant.ljung_box(3)))
        self.assertTrue(math.isnan(constant.ar1()["phi"]))
        zeros = OrderedStats.from_values([0.0] * 4)
        self.assertTrue(math.isnan(zeros.durbin_watson()))

    def test_hand_checked_statistics(self):
        s = OrderedStats.from_values([1, 2, 3, 4])
        acf = s.acf(3)
        for got, want in zip(acf, [1.0, 0.25, -0.3, -0.45]): assert_float_equal(self, got, want)
        assert_float_equal(self, s.durbin_watson(), 3 / 30)
        ar = s.ar1(2)
        assert_float_equal(self, ar["phi"], 1.0)
        assert_float_equal(self, ar["intercept"], 1.0)
        assert_float_equal(self, ar["forecast"], 6.0)

    def test_optional_numpy_statsmodels_cross_checks(self):
        """Skipped cleanly without optional packages; validates convention if present."""
        try:
            import numpy as np
            from statsmodels.stats.diagnostic import acorr_ljungbox
            from statsmodels.tsa.stattools import acf, kpss
        except ImportError:
            self.skipTest("optional numpy/statsmodels not installed")
        rng = random.Random(20260910)
        vals = [rng.gauss(0, 1) for _ in range(90)]
        s = OrderedStats.from_values(vals)
        theirs = acf(np.asarray(vals), nlags=12, fft=False, adjusted=False)
        for got, want in zip(s.acf(12), theirs): assert_float_equal(self, got, float(want), 3e-12)
        want_q = float(acorr_ljungbox(vals, lags=[12], return_df=True)["lb_stat"].iloc[0])
        assert_float_equal(self, s.ljung_box(12), want_q, 3e-10)
        # The oracle intentionally uses floor(12*(n/100)**0.25).  Recent
        # statsmodels releases changed legacy='legacy' to use ceil, so pass
        # the oracle bandwidth explicitly to compare the same convention.
        bandwidth = int(12.0 * (len(vals) / 100.0) ** 0.25)
        want_kpss = float(kpss(vals, regression="c", nlags=bandwidth)[0])
        assert_float_equal(self, s.kpss(), want_kpss, 3e-10)


class FullSampleKeyedProductionContract(unittest.TestCase):
    def compare(self, got, expected):
        self.assertEqual(got.points, expected.points)
        for lag in range(13): assert_float_equal(self, got.autocorrelation(lag), expected.autocorrelation(lag))
        a, b = got.ljung_box(12, 2), expected.ljung_box(12, 2)
        for x, y in [(a.statistic, b.statistic), (a.p_value, b.p_value), (got.durbin_watson(), expected.durbin_watson())]:
            assert_float_equal(self, x, y)

    def test_arbitrary_row_order_is_canonical_and_json_round_trips(self):
        rows = [(UINT64_MAX, -2), (9, 3.5), (0, 1), (42, -0.0)]
        s = FullSampleKeyedStats.from_pairs(rows, max_samples=10)
        self.assertEqual(s.keys, (0, 9, 42, UINT64_MAX))
        self.assertEqual(FullSampleKeyedStats.from_json(s.to_json(), expected_max_samples=10), s)
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_pairs([(1, 3), (1, 4)])
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_pairs([(-1, 3)])
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_pairs([(UINT64_MAX + 1, 3)])

    def test_production_three_function_semantics_and_hand_values(self):
        s = FullSampleKeyedStats.from_pairs([(40, 4), (10, 1), (30, 3), (20, 2)])
        assert_float_equal(self, s.autocorrelation(0), 1.0)
        assert_float_equal(self, s.autocorrelation(1), 0.25)
        assert_float_equal(self, s.autocorrelation(2), -0.3)
        assert_float_equal(self, s.autocorrelation(3), -0.45)
        self.assertTrue(math.isnan(s.autocorrelation(4)))
        result = s.ljung_box(2, model_df=1)
        assert_float_equal(self, result.statistic, 1.58)
        # With one degree of freedom, SF(x) = erfc(sqrt(x/2)).
        assert_float_equal(self, result.p_value, math.erfc(math.sqrt(1.58 / 2)))
        assert_float_equal(self, s.durbin_watson(), 0.1)
        with self.assertRaises(ValueError): s.ljung_box(2, 2)
        with self.assertRaises(ValueError): s.autocorrelation(-1)

    def test_insufficient_constant_and_nonfinite_policy(self):
        empty = FullSampleKeyedStats(max_samples=1)
        one = FullSampleKeyedStats.from_pairs([(3, 4)])
        for state in (empty, one, FullSampleKeyedStats.from_pairs([(1, 5), (2, 5)])):
            self.assertTrue(math.isnan(state.autocorrelation(0)))
        self.assertTrue(math.isnan(one.durbin_watson()))
        self.assertTrue(math.isnan(empty.ljung_box(1).statistic))
        self.assertTrue(math.isnan(one.ljung_box(1).p_value))
        self.assertTrue(math.isnan(FullSampleKeyedStats.from_pairs([(1, 7), (2, 7)]).ljung_box(1).statistic))
        zero = FullSampleKeyedStats.from_pairs([(1, 0), (2, 0)])
        self.assertTrue(math.isnan(zero.durbin_watson()))
        for bad in (math.nan, math.inf, -math.inf):
            with self.assertRaises(ValueError): FullSampleKeyedStats.from_pairs([(1, bad)])

    def test_interleaving_merge_trees_equal_direct_sorted_batch(self):
        rng = random.Random(0x51A7E)
        for n in range(0, 100):
            keys = rng.sample(range(1_000_000), n)
            rows = [(keys[i], rng.gauss(0, 2) + (1e10 if i % 17 == 0 else 0)) for i in range(n)]
            direct = FullSampleKeyedStats.from_pairs(rows, max_samples=128)
            # Assign rows randomly to states; each state may have arbitrary
            # ranges and all merges therefore contain interleaved key ranges.
            buckets = [[] for _ in range(max(1, min(13, n + 1)))]
            for row in rows:
                buckets[rng.randrange(len(buckets))].append(row)
            states = [FullSampleKeyedStats.from_pairs(rng.sample(b, len(b)), 128) for b in buckets if b]
            rng.shuffle(states)
            while len(states) > 1:
                i, j = sorted(rng.sample(range(len(states)), 2), reverse=True)
                right, left = states.pop(i), states.pop(j)
                states.append(left.merge(right))
                rng.shuffle(states)
            merged = states[0] if states else FullSampleKeyedStats(max_samples=128)
            self.compare(merged, direct)

    def test_duplicate_across_states_and_cap_fail_regardless_of_range(self):
        left = FullSampleKeyedStats.from_pairs([(10, 1), (30, 3)], 3)
        right = FullSampleKeyedStats.from_pairs([(20, 2)], 3)
        self.assertEqual(left.merge(right).keys, (10, 20, 30))
        with self.assertRaises(ValueError): left.merge(FullSampleKeyedStats.from_pairs([(10, 9)], 3))
        with self.assertRaises(ValueError): left.merge(FullSampleKeyedStats.from_pairs([(20, 2), (40, 4)], 3))
        with self.assertRaises(ValueError): left.merge(FullSampleKeyedStats.from_pairs([(20, 2)], 4))

    def test_cap_and_strict_canonical_deserialization(self):
        with self.assertRaises(ValueError): FullSampleKeyedStats(max_samples=0)
        with self.assertRaises(ValueError): FullSampleKeyedStats(max_samples=10_000_001)
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_pairs([(1, 1), (2, 2)], max_samples=1)
        canonical = FullSampleKeyedStats.from_pairs([(2, 4), (1, 3)], 2).to_json()
        self.assertEqual(FullSampleKeyedStats.from_json(canonical, 2).keys, (1, 2))
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_json(canonical, 3)
        noncanonical = '{"version":2,"kind":"full-sample-keyed","maxSamples":2,"points":[[2,4],[1,3]]}'
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_json(noncanonical)
        duplicate = '{"version":2,"kind":"full-sample-keyed","maxSamples":2,"points":[[1,4],[1,3]]}'
        with self.assertRaises(ValueError): FullSampleKeyedStats.from_json(duplicate)

    def test_chi_square_survival_reference_values(self):
        assert_float_equal(self, chi_square_sf(0.0, 1), 1.0)
        assert_float_equal(self, chi_square_sf(1.0, 1), math.erfc(math.sqrt(0.5)), 2e-13)
        # Known chi-square(2) identity: survival(x) = exp(-x/2).
        assert_float_equal(self, chi_square_sf(7.5, 2), math.exp(-3.75), 2e-13)

    def test_large_offset_keeps_representable_variation(self):
        # The ULP at 1e16 is 2, so these are distinct representable values.
        base = 1e16
        values = [base - 4.0, base - 2.0, base, base + 2.0, base + 4.0]
        s = FullSampleKeyedStats.from_pairs(list(reversed(list(enumerate(values)))))
        assert_float_equal(self, s.autocorrelation(1), 0.4)
        assert_float_equal(self, s.autocorrelation(2), -0.1)
        lb = s.ljung_box(2)
        assert_float_equal(self, lb.statistic, 91.0 / 60.0)
        # DW must remain finite and agree with a direct scale-equivalent form;
        # the raw numerator/denominator would otherwise invite scale artifacts.
        normalized = [value / base for value in values]
        expected_dw = math.fsum((normalized[i] - normalized[i - 1]) ** 2 for i in range(1, 5)) / math.fsum(x * x for x in normalized)
        assert_float_equal(self, s.durbin_watson(), expected_dw, 1e-30)

    def test_extreme_symmetric_scales_have_same_finite_statistics(self):
        # Raw products overflow at 1e200 and underflow at 1e-200, but every
        # production diagnostic is scale invariant and must stay well-defined.
        for scale in (1e200, 1e-200):
            s = FullSampleKeyedStats.from_pairs([(3, -scale), (1, -scale), (4, scale), (2, scale)])
            assert_float_equal(self, s.autocorrelation(1), -0.75)
            assert_float_equal(self, s.autocorrelation(2), 0.5)
            result = s.ljung_box(2)
            assert_float_equal(self, result.statistic, 7.5)
            assert_float_equal(self, result.p_value, math.exp(-3.75), 2e-13)
            assert_float_equal(self, s.durbin_watson(), 3.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
