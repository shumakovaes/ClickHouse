-- Tags: stateful, distributed
-- Functional test for the registered time-series diagnostics aggregates.
-- The companion reference is source-derived and checked for contract
-- consistency below.

SELECT '--- preview gate and call-shape validation ---';
SELECT timeSeriesAutocorrelation(1)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError UNKNOWN_AGGREGATE_FUNCTION }

SET enable_time_series_aggregate_functions = 1;
SET max_threads = 1;
SET max_block_size = 2;

SELECT timeSeriesAutocorrelation(1)(key)
FROM values('key UInt64', (0), (1)); -- { serverError NUMBER_OF_ARGUMENTS_DOESNT_MATCH }
SELECT timeSeriesDurbinWatson(2, 3)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError NUMBER_OF_ARGUMENTS_DOESNT_MATCH }

SELECT '--- exact outputs, lag zero, and named Ljung-Box tuple ---';
SELECT round(timeSeriesAutocorrelation(0)(key, value), 6),
       round(timeSeriesAutocorrelation(1)(key, value), 6),
       round(timeSeriesAutocorrelation(2)(key, value), 6),
       round(timeSeriesAutocorrelation(3)(key, value), 6)
FROM values('key UInt64, value Float64',
    (40, 4.), (10, 1.), (30, 3.), (20, 2.));
SELECT round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key UInt64, value Float64',
    (40, 4.), (10, 1.), (30, 3.), (20, 2.));
SELECT round(tupleElement(timeSeriesLjungBoxTest(2, 0)(key, value), 'statistic'), 6),
       round(tupleElement(timeSeriesLjungBoxTest(2, 0)(key, value), 'p_value'), 6)
FROM values('key UInt64, value Float64',
    (40, 4.), (10, 1.), (30, 3.), (20, 2.));
SELECT toTypeName(tupleElement(timeSeriesLjungBoxTest(2)(key, value), 'statistic')),
       toTypeName(tupleElement(timeSeriesLjungBoxTest(2)(key, value), 'p_value')),
       round(tupleElement(timeSeriesLjungBoxTest(2, 1)(key, value), 'statistic'), 6),
       round(tupleElement(timeSeriesLjungBoxTest(2, 1)(key, value), 'p_value'), 6)
FROM values('key UInt64, value Float64',
    (40, 4.), (10, 1.), (30, 3.), (20, 2.));

SELECT '--- insufficient, constant, and zero-denominator results ---';
SELECT isNaN(timeSeriesAutocorrelation(0)(key, value)),
       isNaN(timeSeriesAutocorrelation(1)(key, value)),
       isNaN(timeSeriesDurbinWatson()(key, value))
FROM values('key UInt64, value Float64', (0, 7.));
SELECT isNaN(timeSeriesAutocorrelation(0)(key, value)),
       isNaN(timeSeriesAutocorrelation(1)(key, value)),
       isNaN(tupleElement(timeSeriesLjungBoxTest(1)(key, value), 'statistic')),
       isNaN(timeSeriesDurbinWatson()(key, value))
FROM values('key UInt64, value Float64', (0, 5.), (1, 5.), (2, 5.));
SELECT isNaN(timeSeriesAutocorrelation(1)(key, value)),
       isNaN(tupleElement(timeSeriesLjungBoxTest(2)(key, value), 'statistic')),
       isNaN(tupleElement(timeSeriesLjungBoxTest(2)(key, value), 'p_value'))
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.));
SELECT isNaN(timeSeriesAutocorrelation(0)(key, value)),
       isNaN(timeSeriesDurbinWatson()(key, value))
FROM values('key UInt64, value Float64', (0, 0.))
WHERE 0;
SELECT isNaN(timeSeriesDurbinWatson()(key, value))
FROM values('key UInt64, value Float64', (0, 0.), (1, 0.), (2, 0.));

SELECT '--- arbitrary input order and final allowed scalar types ---';
SELECT round(timeSeriesAutocorrelation(1)(key, value), 6)
FROM values('key UInt64, value Float64',
    (3, 4.), (1, 2.), (4, 5.), (0, 1.), (2, 3.));
SELECT round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key UInt32, value Int32',
    (2, 3), (0, 1), (3, 4), (1, 2));
SELECT round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key DateTime, value Float32',
    (toDateTime('2020-01-01 00:00:02'), 3.),
    (toDateTime('2020-01-01 00:00:00'), 1.),
    (toDateTime('2020-01-01 00:00:03'), 4.),
    (toDateTime('2020-01-01 00:00:01'), 2.));
SELECT round(timeSeriesAutocorrelation(1)(key, value), 6)
FROM values('key DateTime64(3), value Float64',
    (toDateTime64('2020-01-01 00:00:00.002', 3), 3.00),
    (toDateTime64('2020-01-01 00:00:00.000', 3), 1.00),
    (toDateTime64('2020-01-01 00:00:00.003', 3), 4.00),
    (toDateTime64('2020-01-01 00:00:00.001', 3), 2.00));
SELECT round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key UInt64, value UInt64',
    (2, 3), (0, 1), (3, 4), (1, 2));

SELECT '--- non-finite values are rejected; Null combinator skips NULL rows ---';
SELECT timeSeriesAutocorrelation(1)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, nan), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesDurbinWatson()(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, inf), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesDurbinWatson()(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, -inf), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT toTypeName(timeSeriesAutocorrelation(1)(key, value)),
       round(timeSeriesAutocorrelation(1)(key, value), 6)
FROM values('key UInt64, value Nullable(Float64)', (0, 1.), (1, NULL), (2, 3.));
SELECT toTypeName(timeSeriesDurbinWatson()(key, value)),
       round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key Nullable(UInt64), value Float64', (0, 1.), (NULL, 999.), (1, 2.));
SELECT toTypeName(timeSeriesAutocorrelation(1)(key, value)),
       isNull(timeSeriesAutocorrelation(1)(key, value))
FROM values('key UInt64, value Nullable(Float64)', (0, NULL), (1, NULL));
SELECT timeSeriesAutocorrelation(1)(key, value)
FROM values('key DateTime, value Decimal64(2)',
    (toDateTime('2020-01-01 00:00:00'), 1.00),
    (toDateTime('2020-01-01 00:00:01'), 2.00)); -- { serverError ILLEGAL_TYPE_OF_ARGUMENT }
SELECT timeSeriesAutocorrelation(1)(key, value)
FROM values('key Date, value Float64',
    (toDate('2020-01-01'), 1.), (toDate('2020-01-02'), 2.)); -- { serverError ILLEGAL_TYPE_OF_ARGUMENT }

SELECT '--- parameter validation and state-size caps ---';
SELECT round(timeSeriesAutocorrelation(0, 2)(key, value), 6)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.));
SELECT timeSeriesAutocorrelation(0, 2)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT round(timeSeriesDurbinWatson(2)(key, value), 6)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.));
SELECT timeSeriesDurbinWatson(2)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT round(tupleElement(timeSeriesLjungBoxTest(2, 0, 4)(key, value), 'statistic'), 6),
       round(tupleElement(timeSeriesLjungBoxTest(2, 0, 4)(key, value), 'p_value'), 6)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.), (3, 4.));
SELECT timeSeriesLjungBoxTest(2, 0, 4)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.), (3, 4.), (4, 5.)); -- { serverError BAD_ARGUMENTS }
WITH states AS
(
    SELECT part, timeSeriesAutocorrelationState(0, 3)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (1, 1, 2.), (1, 3, 4.))
    GROUP BY part
)
SELECT timeSeriesAutocorrelationMerge(0, 3)(state) FROM states; -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesAutocorrelation(1, 0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesAutocorrelation(1, 10000001)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesAutocorrelation(10001)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesLjungBoxTest(0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesLjungBoxTest(2, 2)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesLjungBoxTest(2, -1)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesDurbinWatson(0)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }
SELECT timeSeriesDurbinWatson(10000001)(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.)); -- { serverError BAD_ARGUMENTS }

SELECT '--- large-offset and extreme-scale numeric stability ---';
SELECT round(timeSeriesAutocorrelation(1)(key, value), 6)
FROM values('key UInt64, value Float64',
    (4, 1000000000000002.), (0, 999999999999998.),
    (3, 1000000000000001.), (1, 999999999999999.),
    (2, 1000000000000000.));
SELECT round(timeSeriesAutocorrelation(1)(key, value), 6),
       round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key UInt64, value Float64',
    (0, -1e300), (1, 1e300), (2, -1e300), (3, 1e300));
SELECT round(timeSeriesAutocorrelation(1)(key, value), 6),
       round(timeSeriesDurbinWatson()(key, value), 6)
FROM values('key UInt64, value Float64',
    (0, -1e-300), (1, 1e-300), (2, -1e-300), (3, 1e-300));

SELECT '--- Distributed engine shard-state merge and duplicate propagation ---';
SET prefer_localhost_replica = 0;
DROP TABLE IF EXISTS time_series_diagnostics_distributed;
DROP TABLE IF EXISTS time_series_diagnostics_distributed_local;
CREATE TABLE time_series_diagnostics_distributed_local
(
    key UInt64,
    value Float64
)
ENGINE = MergeTree
ORDER BY key;
CREATE TABLE time_series_diagnostics_distributed
AS time_series_diagnostics_distributed_local
ENGINE = Distributed('test_cluster_two_shards_localhost', currentDatabase(), time_series_diagnostics_distributed_local, rand());
INSERT INTO time_series_diagnostics_distributed_local VALUES
    (0, 1.), (1, 2.), (2, 3.), (3, 4.);
SELECT round(timeSeriesAutocorrelation(1)(key, value), 6),
       round(timeSeriesDurbinWatson()(key, value), 6)
FROM time_series_diagnostics_distributed
WHERE key % 2 = _shard_num - 1;
SELECT timeSeriesAutocorrelation(1)(key, value)
FROM time_series_diagnostics_distributed; -- { serverError BAD_ARGUMENTS }
DROP TABLE time_series_diagnostics_distributed;
DROP TABLE time_series_diagnostics_distributed_local;

SELECT '--- interleaved, reversed, and overlapping state merges ---';
WITH states AS
(
    SELECT part, timeSeriesAutocorrelationState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (0, 4, 5.),
        (1, 1, 2.), (1, 3, 4.), (1, 5, 6.))
    GROUP BY part
    ORDER BY part
)
SELECT round(timeSeriesAutocorrelationMerge(1)(state), 6) FROM states;
WITH states AS
(
    SELECT part, timeSeriesLjungBoxTestState(2, 1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (0, 4, 5.),
        (1, 1, 2.), (1, 3, 4.), (1, 5, 6.))
    GROUP BY part
    ORDER BY part DESC
)
SELECT round(tupleElement(timeSeriesLjungBoxTestMerge(2, 1)(state), 'statistic'), 6),
       round(tupleElement(timeSeriesLjungBoxTestMerge(2, 1)(state), 'p_value'), 6)
FROM states;
WITH states AS
(
    SELECT part, timeSeriesDurbinWatsonState()(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (0, 4, 5.),
        (1, 1, 2.), (1, 3, 4.), (1, 5, 6.))
    GROUP BY part
    ORDER BY part DESC
)
SELECT round(timeSeriesDurbinWatsonMerge()(state), 6) FROM states;
WITH states AS
(
    SELECT part, timeSeriesAutocorrelationState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (1, 1, 2.), (1, 3, 4.))
    GROUP BY part
)
SELECT length(toString(timeSeriesAutocorrelationMergeState(1)(state))) > 0 FROM states;

SELECT '--- duplicate timestamps are rejected in one state and across states ---';
SELECT timeSeriesDurbinWatson()(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (1, 3.)); -- { serverError BAD_ARGUMENTS }
WITH states AS
(
    SELECT part, timeSeriesAutocorrelationState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (1, 1, 2.), (1, 2, 4.))
    GROUP BY part
)
SELECT timeSeriesAutocorrelationMerge(1)(state) FROM states; -- { serverError BAD_ARGUMENTS }

SELECT '--- serialized states and AggregatingMergeTree part merges ---';
WITH
    (SELECT toString(timeSeriesAutocorrelationState(1)(key, value))
     FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 3.), (3, 4.))) AS ordered_state,
    (SELECT toString(timeSeriesAutocorrelationState(1)(key, value))
     FROM values('key UInt64, value Float64', (2, 3.), (0, 1.), (3, 4.), (1, 2.))) AS permuted_state
SELECT ordered_state = permuted_state;
WITH states AS
(
    SELECT part, timeSeriesAutocorrelationState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (1, 1, 2.), (1, 3, 4.))
    GROUP BY part
)
SELECT min(length(toString(state))) > 0 FROM states;
WITH states AS
(
    SELECT part, timeSeriesAutocorrelationState(1)(key, value) AS state
    FROM values('part UInt8, key UInt64, value Float64',
        (0, 0, 1.), (0, 2, 3.), (1, 1, 2.), (1, 3, 4.))
    GROUP BY part
)
SELECT round(timeSeriesAutocorrelationMerge(1)(state), 6) FROM states;

DROP TABLE IF EXISTS time_series_diagnostics_mt;
CREATE TABLE time_series_diagnostics_mt
(
    series UInt8,
    state AggregateFunction(timeSeriesDurbinWatson, UInt64, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY series;
INSERT INTO time_series_diagnostics_mt
SELECT 0, timeSeriesDurbinWatsonState()(key, value)
FROM values('key UInt64, value Float64', (0, 1.), (2, 3.), (4, 5.));
INSERT INTO time_series_diagnostics_mt
SELECT 0, timeSeriesDurbinWatsonState()(key, value)
FROM values('key UInt64, value Float64', (1, 2.), (3, 4.), (5, 6.));
SELECT round(timeSeriesDurbinWatsonMerge()(state), 6)
FROM time_series_diagnostics_mt;
OPTIMIZE TABLE time_series_diagnostics_mt FINAL;
SELECT series, round(finalizeAggregation(state), 6)
FROM time_series_diagnostics_mt;
DROP TABLE time_series_diagnostics_mt;
