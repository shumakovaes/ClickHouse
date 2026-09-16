SELECT timeSeriesKPSSTest('trend', 1024, 97656)(toUInt64(number), toFloat64(cityHash64(number) % 1000003)) FROM numbers(97656) SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
