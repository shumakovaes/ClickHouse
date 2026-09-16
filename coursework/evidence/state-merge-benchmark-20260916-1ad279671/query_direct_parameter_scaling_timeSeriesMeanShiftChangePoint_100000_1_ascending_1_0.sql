SELECT timeSeriesMeanShiftChangePoint(1, 1000000)(toUInt64(number), if(number < 50000, 0.0, 1.0)) FROM numbers(100000) SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
