-- Tags: stateful, distributed
-- Two-shard Distributed coverage for the four statistical extensions.

SET enable_time_series_aggregate_functions = 1;
SET max_threads = 1;
SET max_block_size = 2;
SET prefer_localhost_replica = 0;

SELECT '--- canonical reference ---';
SELECT round(tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'intercept'), 6),
       arrayMap(x -> round(x, 6), tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'coefficients'))
FROM values('key UInt64, value Float64',
    (7, 2.2), (2, 1.2), (5, 2.), (0, 1.),
    (6, 1.6), (3, 1.8), (1, 1.5), (4, 1.4));
SELECT round(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'statistic'), 6),
       round(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'coefficient'), 6),
       tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'observations')
FROM values('key UInt64, value Float64',
    (7, 2.2), (2, 1.2), (5, 2.), (0, 1.),
    (6, 1.6), (3, 1.8), (1, 1.5), (4, 1.4));
SELECT round(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'statistic'), 6),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'observations')
FROM values('key UInt64, value Float64',
    (7, 2.2), (2, 1.2), (5, 2.), (0, 1.),
    (6, 1.6), (3, 1.8), (1, 1.5), (4, 1.4));
SELECT tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'split_index'),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'score'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_before'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_after'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'sse'), 6)
FROM values('key UInt64, value Float64',
    (7, 2.2), (2, 1.2), (5, 2.), (0, 1.),
    (6, 1.6), (3, 1.8), (1, 1.5), (4, 1.4));

SELECT '--- distributed aggregate merge across shards ---';
DROP TABLE IF EXISTS time_series_stat_ext_distributed;
DROP TABLE IF EXISTS time_series_stat_ext_distributed_local;
CREATE TABLE time_series_stat_ext_distributed_local
(
    key UInt64,
    value Float64,
    route UInt8
)
ENGINE = MergeTree
ORDER BY key;
CREATE TABLE time_series_stat_ext_distributed
AS time_series_stat_ext_distributed_local
ENGINE = Distributed('test_cluster_two_shards_localhost', currentDatabase(), time_series_stat_ext_distributed_local, route);
-- The localhost test cluster points both logical shards at this one server.
-- Store one physical copy, then partition it with _shard_num in each remote
-- query so the coordinator really merges two disjoint partial states.
INSERT INTO time_series_stat_ext_distributed_local VALUES
    (0, 1., 0), (1, 1.5, 1), (2, 1.2, 0), (3, 1.8, 1),
    (4, 1.4, 0), (5, 2., 1), (6, 1.6, 0), (7, 2.2, 1);
SELECT round(tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'intercept'), 6),
       arrayMap(x -> round(x, 6), tupleElement(timeSeriesLaggedLinearRegression(1)(key, value), 'coefficients'))
FROM time_series_stat_ext_distributed
WHERE route = _shard_num - 1;
SELECT round(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'statistic'), 6),
       round(tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'coefficient'), 6),
       tupleElement(timeSeriesADFStatistic(0, 'constant')(key, value), 'observations')
FROM time_series_stat_ext_distributed
WHERE route = _shard_num - 1;
SELECT round(tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'statistic'), 6),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'bandwidth'),
       tupleElement(timeSeriesKPSSTest('level', 0)(key, value), 'observations')
FROM time_series_stat_ext_distributed
WHERE route = _shard_num - 1;
SELECT tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'split_index'),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'score'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_before'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'mean_after'), 6),
       round(tupleElement(timeSeriesMeanShiftChangePoint(2)(key, value), 'sse'), 6)
FROM time_series_stat_ext_distributed
WHERE route = _shard_num - 1;

SELECT '--- serialized partial state merge through Distributed ---';
SELECT round(tupleElement(timeSeriesLaggedLinearRegressionMerge(1)(state), 'intercept'), 6),
       arrayMap(x -> round(x, 6), tupleElement(timeSeriesLaggedLinearRegressionMerge(1)(state), 'coefficients'))
FROM
(
    SELECT timeSeriesLaggedLinearRegressionState(1)(key, value) AS state
    FROM time_series_stat_ext_distributed
    WHERE route = _shard_num - 1
    GROUP BY route
);
SELECT round(tupleElement(timeSeriesADFStatisticMerge(0, 'constant')(state), 'statistic'), 6),
       round(tupleElement(timeSeriesADFStatisticMerge(0, 'constant')(state), 'coefficient'), 6),
       tupleElement(timeSeriesADFStatisticMerge(0, 'constant')(state), 'observations')
FROM
(
    SELECT timeSeriesADFStatisticState(0, 'constant')(key, value) AS state
    FROM time_series_stat_ext_distributed
    WHERE route = _shard_num - 1
    GROUP BY route
);
SELECT round(tupleElement(timeSeriesKPSSTestMerge('level', 0)(state), 'statistic'), 6)
FROM
(
    SELECT timeSeriesKPSSTestState('level', 0)(key, value) AS state
    FROM time_series_stat_ext_distributed
    WHERE route = _shard_num - 1
    GROUP BY route
);
SELECT tupleElement(timeSeriesMeanShiftChangePointMerge(2)(state), 'split_index'),
       round(tupleElement(timeSeriesMeanShiftChangePointMerge(2)(state), 'score'), 6)
FROM
(
    SELECT timeSeriesMeanShiftChangePointState(2)(key, value) AS state
    FROM time_series_stat_ext_distributed
    WHERE route = _shard_num - 1
    GROUP BY route
);

SELECT '--- duplicate key propagated from separate shards ---';
DROP TABLE IF EXISTS time_series_stat_ext_duplicates;
DROP TABLE IF EXISTS time_series_stat_ext_duplicates_local;
CREATE TABLE time_series_stat_ext_duplicates_local
(
    key UInt64,
    value Float64,
    route UInt8
)
ENGINE = MergeTree
ORDER BY key;
CREATE TABLE time_series_stat_ext_duplicates
AS time_series_stat_ext_duplicates_local
ENGINE = Distributed('test_cluster_two_shards_localhost', currentDatabase(), time_series_stat_ext_duplicates_local, route);
INSERT INTO time_series_stat_ext_duplicates_local VALUES
    (0, 1., 0), (0, 2., 1), (1, 3., 0), (2, 4., 1);
SELECT timeSeriesKPSSTest('level', 0)(key, value)
FROM time_series_stat_ext_duplicates
WHERE route = _shard_num - 1; -- { serverError BAD_ARGUMENTS }

DROP TABLE time_series_stat_ext_duplicates;
DROP TABLE time_series_stat_ext_duplicates_local;
DROP TABLE time_series_stat_ext_distributed;
DROP TABLE time_series_stat_ext_distributed_local;
