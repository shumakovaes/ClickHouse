SELECT timeSeriesADFStatisticMerge(2, 'constant', 1000000)(state) FROM bench_ext_state_5 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
