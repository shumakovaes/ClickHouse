SELECT timeSeriesMeanShiftChangePoint(60, 1000)(toUInt64(number), if(number < 500, 0.0, 1.0)) FROM numbers(1000) SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
