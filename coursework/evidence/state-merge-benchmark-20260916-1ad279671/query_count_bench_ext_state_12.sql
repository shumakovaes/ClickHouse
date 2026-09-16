SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; SELECT count() FROM bench_ext_state_12 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
