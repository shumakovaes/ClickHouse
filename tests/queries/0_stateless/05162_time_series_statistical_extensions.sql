-- Tags: stateful
-- Functional coverage for the four private-preview statistical extensions.

SELECT '--- private preview gate ---';
SELECT timeSeriesLaggedLinearRegression(1)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError UNKNOWN_AGGREGATE_FUNCTION }
SELECT timeSeriesADFStatistic(0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError UNKNOWN_AGGREGATE_FUNCTION }
SELECT timeSeriesKPSSTest('level', 0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError UNKNOWN_AGGREGATE_FUNCTION }
SELECT timeSeriesMeanShiftChangePoint(1)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError UNKNOWN_AGGREGATE_FUNCTION }

SET enable_time_series_aggregate_functions = 1;
SET max_threads = 1;
SET max_block_size = 2;

SELECT '--- timestamp and value dispatch ---';
SELECT toTypeName(timeSeriesKPSSTest('level', 0)(timestamp, value)),
       isFinite(tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'observations')
FROM values('timestamp UInt32, value Float32', (0, 1), (1, 2), (2, 4), (3, 8));
SELECT toTypeName(timeSeriesKPSSTest('level', 0)(timestamp, value)),
       isFinite(tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'observations')
FROM values('timestamp DateTime, value Int16',
    (toDateTime('2020-01-01 00:00:00'), 1), (toDateTime('2020-01-01 00:00:01'), 2),
    (toDateTime('2020-01-01 00:00:02'), 4), (toDateTime('2020-01-01 00:00:03'), 8));
SELECT toTypeName(timeSeriesKPSSTest('level', 0)(timestamp, value)),
       isFinite(tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'observations')
FROM values('timestamp DateTime64(3), value UInt8',
    (toDateTime64('2020-01-01 00:00:00.000', 3), 1), (toDateTime64('2020-01-01 00:00:00.001', 3), 2),
    (toDateTime64('2020-01-01 00:00:00.002', 3), 4), (toDateTime64('2020-01-01 00:00:00.003', 3), 8));
SELECT toTypeName(timeSeriesKPSSTest('level', 0)(timestamp, value)),
       isFinite(tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'observations')
FROM values('timestamp Nullable(UInt32), value Float32', (0, 1), (NULL, 100), (1, 2), (2, 4));

SELECT '--- legacy time-series table gate ---';
SET enable_time_series_aggregate_functions = 0;
SET enable_time_series_table = 1;
SELECT isFinite(tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 0)(timestamp, value), 'observations')
FROM values('timestamp UInt32, value Float32', (0, 1), (1, 2), (2, 4), (3, 8));
SET enable_time_series_table = 0;
SET enable_time_series_aggregate_functions = 1;

SELECT '--- exact tuples, names, and hand fixtures ---';
SELECT timeSeriesLaggedLinearRegression(1)(key, value)
FROM values('key UInt64, value Float64',
    (5, 32.), (1, 2.), (3, 8.), (0, 1.), (2, 4.), (4, 16.));
SELECT toTypeName(tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'intercept')),
       toTypeName(tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'coefficients')),
       tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'intercept'),
       tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'coefficients')
FROM values('key UInt64, value Float64',
    (0, 1.), (1, 2.), (2, 4.), (3, 8.), (4, 16.), (5, 32.));
SELECT toTypeName(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'statistic')),
       toTypeName(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'coefficient')),
       toTypeName(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'observations')),
       round(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'statistic'), 6),
       round(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'coefficient'), 6),
       tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'observations')
FROM values('key UInt64, value Float64',
    (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8),
    (4, 1.4), (5, 2.), (6, 1.6), (7, 2.2));
SELECT toTypeName(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'statistic')),
       toTypeName(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'bandwidth')),
       toTypeName(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'observations')),
       round(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'statistic'), 6),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'observations')
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.), (3, 4.), (4, 5.));
SELECT toTypeName(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'split_index')),
       toTypeName(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'score')),
       toTypeName(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_before')),
       toTypeName(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_after')),
       toTypeName(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'sse')),
       tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'split_index'),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'score'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_before'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_after'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'sse'), 6)
FROM values('key UInt64, value Float64', (0, 1.), (1, 1.), (2, 1.), (3, 5.), (4, 5.), (5, 5.));

SELECT '--- shuffled rows and undefined results ---';
SELECT timeSeriesLaggedLinearRegression(1)(key, value)
FROM values('key UInt64, value Float64', (3, 8.), (0, 1.), (5, 32.), (2, 4.), (4, 16.), (1, 2.));
SELECT isNaN(tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'intercept')),
       isNaN(tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'coefficients')[1])
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.));
SELECT isNaN(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'statistic')),
       tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'observations')
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.));
SELECT isNaN(tupleElement(timeSeriesKPSSTest('trend', 0)(key, value), 'statistic'))
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.), (3, 4.), (4, 5.));
SELECT tupleElement(timeSeriesMeanShiftChangePoint(1)(key, value), 'split_index'),
       isNaN(tupleElement(timeSeriesMeanShiftChangePoint(1)(key, value), 'score')),
       isNaN(tupleElement(timeSeriesMeanShiftChangePoint(1)(key, value), 'mean_before'))
FROM values('key UInt64, value Float64', (0, 7.), (1, 7.), (2, 7.), (3, 7.));

SELECT '--- numerical and statistical boundaries ---';
SELECT isNaN(tupleElement(timeSeriesADFStatistic(0, 'none')(key, value), 'statistic')),
       isNaN(tupleElement(timeSeriesADFStatistic(0, 'none')(key, value), 'coefficient')),
       tupleElement(timeSeriesADFStatistic(0, 'none')(key, value), 'observations')
FROM values('key UInt64, value Float64', (4, 16.), (0, 1.), (3, 8.), (1, 2.), (2, 4.));
SELECT isNaN(tupleElement(timeSeriesADFStatistic(0, 'trend')(key, value), 'statistic')),
       tupleElement(timeSeriesADFStatistic(0, 'trend')(key, value), 'observations')
FROM values('key UInt64, value Float64', (4, 5.), (0, 1.), (3, 4.), (1, 2.), (2, 3.));
SELECT round(tupleElement(timeSeriesKPSSTest('trend', 2)(key, value), 'statistic'), 12),
       tupleElement(timeSeriesKPSSTest('trend', 2)(key, value), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('trend', 2)(key, value), 'observations')
FROM values('key UInt64, value Float64',
    (7, 6.), (0, 3.), (4, 5.), (1, 1.), (6, 2.), (2, 4.), (5, 9.), (3, 1.));
SELECT round(tupleElement(timeSeriesKPSSTest('level')(number, toFloat64((number * number + 3 * number + 7) % 17) - 8), 'statistic'), 12),
       tupleElement(timeSeriesKPSSTest('level')(number, toFloat64((number * number + 3 * number + 7) % 17) - 8), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level')(number, toFloat64((number * number + 3 * number + 7) % 17) - 8), 'observations')
FROM numbers(101);
SELECT round(tupleElement(timeSeriesKPSSTest('level', 4)(key, value), 'statistic'), 12),
       tupleElement(timeSeriesKPSSTest('level', 4)(key, value), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level', 4)(key, value), 'observations'),
       isNaN(tupleElement(timeSeriesKPSSTest('level', 5)(key, value), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 5)(key, value), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level', 5)(key, value), 'observations')
FROM values('key UInt64, value Float64', (4, 5.), (0, 1.), (3, 4.), (1, 2.), (2, 3.));
SELECT isNaN(tupleElement(timeSeriesKPSSTest('level', 1024)(number, toFloat64(number % 7)), 'statistic')),
       tupleElement(timeSeriesKPSSTest('level', 1024)(number, toFloat64(number % 7)), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level', 1024)(number, toFloat64(number % 7)), 'observations')
FROM numbers(97657);
SELECT tupleElement(timeSeriesMeanShiftChangePoint(1)(key, value), 'split_index'),
       round(tupleElement(timeSeriesMeanShiftChangePoint(1)(key, value), 'score'), 12),
       round(tupleElement(timeSeriesMeanShiftChangePoint(1)(key, value), 'sse'), 12)
FROM values('key UInt64, value Float64',
    (0, 0.), (1, 0.), (2, 0.), (3, 1.), (4, 0.), (5, 0.), (6, 1.), (7, 0.), (8, 1.));

SELECT '--- NULL combinator ---';
SELECT toTypeName(timeSeriesKPSSTest('level', 0)(key, value)),
       round(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'statistic'), 6),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'observations')
FROM values('key UInt64, value Nullable(Float64)',
    (0, 1.), (1, NULL), (2, 3.), (3, 4.));
SELECT toTypeName(timeSeriesMeanShiftChangePoint(1)(key, value)),
       isNull(timeSeriesMeanShiftChangePoint(1)(key, value))
FROM values('key UInt64, value Nullable(Float64)', (0, NULL), (1, NULL));

SELECT '--- State, Merge, MergeState, and interleaved partial states ---';
WITH states AS
(
    SELECT part, timeSeriesLaggedLinearRegressionState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 4.), (0, 4, 16.),
        (1, 1, 2.), (1, 3, 8.), (1, 5, 32.))
    GROUP BY part
    ORDER BY part
)
SELECT timeSeriesLaggedLinearRegressionMerge(1)(state) FROM states;
WITH states AS
(
    SELECT part, timeSeriesADFStatisticState(0, 'constant')(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 1.2), (0, 4, 1.4), (0, 6, 1.6),
        (1, 1, 1.5), (1, 3, 1.8), (1, 5, 2.), (1, 7, 2.2))
    GROUP BY part
    ORDER BY part DESC
)
SELECT round(tupleElement(timeSeriesADFStatisticMerge(0, 'constant')(state), 'statistic'), 6),
       round(tupleElement(timeSeriesADFStatisticMerge(0, 'constant')(state), 'coefficient'), 6),
       tupleElement(timeSeriesADFStatisticMerge(0, 'constant')(state), 'observations')
FROM states;
WITH states AS
(
    SELECT part, timeSeriesKPSSTestState('level', 0)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (0, 4, 5.),
        (1, 1, 2.), (1, 3, 4.))
    GROUP BY part
)
SELECT round(tupleElement(timeSeriesKPSSTestMerge('level', 0)(state), 'statistic'), 6)
FROM states;
WITH states AS
(
    SELECT part, timeSeriesMeanShiftChangePointState(2)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 1.), (0, 4, 5.),
        (1, 1, 1.), (1, 3, 5.), (1, 5, 5.))
    GROUP BY part
)
SELECT tupleElement(timeSeriesMeanShiftChangePointMerge(2)(state), 'split_index'),
       round(tupleElement(timeSeriesMeanShiftChangePointMerge(2)(state), 'score'), 6)
FROM states;
WITH states AS
(
    SELECT part, timeSeriesKPSSTestState('level', 0)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (1, 1, 2.), (1, 3, 4.))
    GROUP BY part
)
SELECT length(toString(timeSeriesKPSSTestMergeState('level', 0)(state))) > 0 FROM states;

SELECT '--- invalid parameters, types, non-finite values, and duplicates ---';
SELECT timeSeriesLaggedLinearRegression(0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesADFStatistic(0, 'bad')(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesKPSSTest('level', 1025)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesKPSSTest('level', 4, 4)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesMeanShiftChangePoint(0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesADFStatistic(0, 'constant', 0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesLaggedLinearRegression(1)(key, value)
FROM values('key Date, value Float64', (toDate('2020-01-01'), 1.), (toDate('2020-01-02'), 2.)); -- { serverError ILLEGAL_TYPE_OF_ARGUMENT }
SELECT timeSeriesKPSSTest('level', 0)(key, value)
FROM values('key UInt64, value Decimal64(2)', (0, 1.00), (1, 2.00)); -- { serverError ILLEGAL_TYPE_OF_ARGUMENT }
SELECT timeSeriesADFStatistic(0, 'constant')(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, nan), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesMeanShiftChangePoint(1)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (1, 3.)); -- { serverError BAD_ARGUMENTS }
WITH states AS
(
    SELECT part, timeSeriesLaggedLinearRegressionState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 4.), (1, 2, 8.), (1, 4, 16.))
    GROUP BY part
)
SELECT timeSeriesLaggedLinearRegressionMerge(1)(state) FROM states; -- { serverError BAD_ARGUMENTS }
