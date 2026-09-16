SELECT timeSeriesKPSSTest('trend', 1, 1000)(toUInt64(number), toFloat64(cityHash64(number) % 1000003)) FROM numbers(1000) SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
