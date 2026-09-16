-- Tags: stateful
-- Persistence coverage for all four statistical extension aggregate states.

SET enable_time_series_aggregate_functions = 1;
SET max_threads = 1;
SET max_block_size = 2;

DROP TABLE IF EXISTS time_series_statistical_extensions_mt;
CREATE TABLE time_series_statistical_extensions_mt
(
    series UInt8,
    regression AggregateFunction(timeSeriesLaggedLinearRegression(1), UInt64, Float64),
    adf AggregateFunction(timeSeriesADFStatistic(0, 'constant'), UInt64, Float64),
    kpss AggregateFunction(timeSeriesKPSSTest('level', 0), UInt64, Float64),
    change_point AggregateFunction(timeSeriesMeanShiftChangePoint(2), UInt64, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY series;

-- Separate inserts create separate parts; the odd/even timestamps are interleaved.
SYSTEM STOP MERGES time_series_statistical_extensions_mt;
INSERT INTO time_series_statistical_extensions_mt
SELECT 0,
       timeSeriesLaggedLinearRegressionState(1)(key, value),
       timeSeriesADFStatisticState(0, 'constant')(key, value),
       timeSeriesKPSSTestState('level', 0)(key, value),
       timeSeriesMeanShiftChangePointState(2)(key, value)
FROM values('key UInt64, value Float64',
    (0, 1.), (2, 1.2), (4, 1.4));
INSERT INTO time_series_statistical_extensions_mt
SELECT 0,
       timeSeriesLaggedLinearRegressionState(1)(key, value),
       timeSeriesADFStatisticState(0, 'constant')(key, value),
       timeSeriesKPSSTestState('level', 0)(key, value),
       timeSeriesMeanShiftChangePointState(2)(key, value)
FROM values('key UInt64, value Float64',
    (1, 1.5), (3, 1.8), (5, 2.));

SELECT '--- unmerged parts and merged aggregate states ---';
SELECT count() FROM time_series_statistical_extensions_mt;
SELECT
    timeSeriesLaggedLinearRegressionMerge(1)(regression) = (SELECT timeSeriesLaggedLinearRegression(1)(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.))),
    timeSeriesADFStatisticMerge(0, 'constant')(adf) = (SELECT timeSeriesADFStatistic(0, 'constant')(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.))),
    timeSeriesKPSSTestMerge('level', 0)(kpss) = (SELECT timeSeriesKPSSTest('level', 0)(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.))),
    timeSeriesMeanShiftChangePointMerge(2)(change_point) = (SELECT timeSeriesMeanShiftChangePoint(2)(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.)))
FROM time_series_statistical_extensions_mt;

SYSTEM START MERGES time_series_statistical_extensions_mt;
OPTIMIZE TABLE time_series_statistical_extensions_mt FINAL;
SELECT count() FROM time_series_statistical_extensions_mt;
SELECT
    finalizeAggregation(regression) = (SELECT timeSeriesLaggedLinearRegression(1)(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.))),
    finalizeAggregation(adf) = (SELECT timeSeriesADFStatistic(0, 'constant')(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.))),
    finalizeAggregation(kpss) = (SELECT timeSeriesKPSSTest('level', 0)(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.))),
    finalizeAggregation(change_point) = (SELECT timeSeriesMeanShiftChangePoint(2)(key, value) FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.)))
FROM time_series_statistical_extensions_mt;

DROP TABLE time_series_statistical_extensions_mt;

DROP TABLE IF EXISTS time_series_statistical_extensions_duplicate_mt;
CREATE TABLE time_series_statistical_extensions_duplicate_mt
(
    series UInt8,
    regression AggregateFunction(timeSeriesLaggedLinearRegression(1), UInt64, Float64),
    adf AggregateFunction(timeSeriesADFStatistic(0, 'constant'), UInt64, Float64),
    kpss AggregateFunction(timeSeriesKPSSTest('level', 0), UInt64, Float64),
    change_point AggregateFunction(timeSeriesMeanShiftChangePoint(2), UInt64, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY series;
SYSTEM STOP MERGES time_series_statistical_extensions_duplicate_mt;
INSERT INTO time_series_statistical_extensions_duplicate_mt
SELECT 0,
       timeSeriesLaggedLinearRegressionState(1)(key, value),
       timeSeriesADFStatisticState(0, 'constant')(key, value),
       timeSeriesKPSSTestState('level', 0)(key, value),
       timeSeriesMeanShiftChangePointState(2)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (2, 4.));
INSERT INTO time_series_statistical_extensions_duplicate_mt
SELECT 0,
       timeSeriesLaggedLinearRegressionState(1)(key, value),
       timeSeriesADFStatisticState(0, 'constant')(key, value),
       timeSeriesKPSSTestState('level', 0)(key, value),
       timeSeriesMeanShiftChangePointState(2)(key, value)
FROM values('key UInt64, value Float64', (2, 4.), (4, 16.));
SELECT '--- duplicate persisted states remain separate ---';
SELECT count() FROM time_series_statistical_extensions_duplicate_mt;
SELECT timeSeriesLaggedLinearRegressionMerge(1)(regression)
FROM time_series_statistical_extensions_duplicate_mt; -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesADFStatisticMerge(0, 'constant')(adf)
FROM time_series_statistical_extensions_duplicate_mt; -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesKPSSTestMerge('level', 0)(kpss)
FROM time_series_statistical_extensions_duplicate_mt; -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesMeanShiftChangePointMerge(2)(change_point)
FROM time_series_statistical_extensions_duplicate_mt; -- { serverError BAD_ARGUMENTS }
DROP TABLE time_series_statistical_extensions_duplicate_mt;
