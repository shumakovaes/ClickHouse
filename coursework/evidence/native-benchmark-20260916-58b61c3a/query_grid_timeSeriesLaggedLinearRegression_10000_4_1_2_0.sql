SELECT timeSeriesLaggedLinearRegression(4, 10000)(toUInt64(number), sin(number / 10.0)) FROM numbers(10000) SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
