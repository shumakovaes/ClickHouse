SELECT timeSeriesKPSSTest('trend', 1024, 97657)(toUInt64(number), toFloat64(cityHash64(number) % 1000003)) FROM numbers(97657) SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1
