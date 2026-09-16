#!/usr/bin/env bash
set -euo pipefail

# Archived baseline harness: measures the original three coursework APIs only.
# Its historical evidence is not extension validation.
# Run from the WSL ClickHouse checkout.  The output directory may be on the
# Windows workspace so that the evidence is easy to inspect and package.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
BINARY_PATH="${CLICKHOUSE_BINARY:-${1:-${REPO_ROOT}/tmp/coursework/build-lean/programs/clickhouse}}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/results}"
REPEAT_COUNT="${REPEAT_COUNT:-3}"

if [[ ! -x "$BINARY_PATH" ]]; then
    echo "ClickHouse binary is not executable: $BINARY_PATH" >&2
    exit 2
fi
mkdir -p "$OUTPUT_DIR"
RAW_RESULTS="$OUTPUT_DIR/raw_results.tsv"
METADATA="$OUTPUT_DIR/metadata.txt"
SMOKE_OUTPUT="$OUTPUT_DIR/smoke.tsv"
STATE_RESULTS="$OUTPUT_DIR/state_sizes.tsv"
GROUPED_RESULTS="$OUTPUT_DIR/grouped_results.tsv"
MERGE_RESULTS="$OUTPUT_DIR/merge_results.tsv"

printf 'function\tn\tlag\trepetition\telapsed_seconds\tmax_rss_kb\trows_per_second\n' > "$RAW_RESULTS"
printf 'parts\tinput_rows\tstate_rows\tserialized_bytes\telapsed_seconds\tmax_rss_kb\trows_per_second\n' > "$STATE_RESULTS"
printf 'series\tinput_rows\tlag\trepetition\telapsed_seconds\tmax_rss_kb\trows_per_second\n' > "$GROUPED_RESULTS"
printf 'parts\tinput_rows\tlag\trepetition\telapsed_seconds\tmax_rss_kb\trows_per_second\n' > "$MERGE_RESULTS"
{
    printf 'benchmark_started_at='; date --iso-8601=seconds
    printf 'binary=%s\n' "$BINARY_PATH"
    printf 'binary_version='; "$BINARY_PATH" --version | head -1
    printf 'binary_sha256='; sha256sum "$BINARY_PATH" | cut -d' ' -f1
    printf 'compiler=clang++-21.1.8 (build configuration)\n'
    printf 'build_type=Debug\n'
    printf 'clickhouse_revision='; git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unavailable\n'
    printf 'kernel='; uname -sr
    printf 'cpu='; grep -m1 'model name' /proc/cpuinfo | sed 's/^.*: //'
    printf 'logical_cpus='; nproc
    printf 'memory_bytes='; free -b | awk '/^Mem:/{print $2}'
    printf 'repeat_count=%s\n' "$REPEAT_COUNT"
    printf 'max_threads=1\n'
    printf 'warmup=one visible 1000-row all-function smoke query before timing; no discarded per-case repetitions\n'
    printf 'data_expression=sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number %% 11)\n'
    printf 'timing=/usr/bin/time wall-clock seconds and maximum resident set size per clickhouse local process\n'
    printf 'output_format=Null after aggregate evaluation\n'
} > "$METADATA"

run_query() {
    local query="$1"
    "$BINARY_PATH" local --multiquery --query "$query" --format TSVRaw
}

# A visible one-row smoke query proves that all three functions execute before
# benchmark output is discarded.  The same fixed expression is used below.
SMOKE_QUERY="SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; SELECT round(timeSeriesAutocorrelation(8)(toUInt64(number), sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11)), 8), tupleElement(timeSeriesLjungBoxTest(8)(toUInt64(number), sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11)), 'statistic'), round(timeSeriesDurbinWatson()(toUInt64(number), sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11)), 8) FROM numbers(1000);"
run_query "$SMOKE_QUERY" > "$SMOKE_OUTPUT"

for function in acf ljung_box durbin_watson; do
    for n in 1000 10000 50000; do
        for lag in 1 8 64; do
            # The lag parameter is not used by Durbin-Watson, but retaining a
            # common matrix makes the raw file easy to compare across funcs.
            case "$function" in
                acf)
                    aggregate="round(timeSeriesAutocorrelation(${lag})(toUInt64(number), value), 8)" ;;
                ljung_box)
                    aggregate="tupleElement(timeSeriesLjungBoxTest(${lag})(toUInt64(number), value), 'statistic')" ;;
                durbin_watson)
                    aggregate="round(timeSeriesDurbinWatson()(toUInt64(number), value), 8)" ;;
            esac
            query="SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; SELECT ${aggregate} FROM (SELECT number, sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11) AS value FROM numbers(${n})) FORMAT Null;"
            for repetition in $(seq 1 "$REPEAT_COUNT"); do
                time_file="$OUTPUT_DIR/.time"
                LC_ALL=C /usr/bin/time -f '%e\t%M' -o "$time_file" "$BINARY_PATH" local --multiquery --query "$query" > /dev/null
                IFS=$'\t' read -r elapsed max_rss_kb < "$time_file"
                rows_per_second="$(awk -v rows="$n" -v seconds="$elapsed" 'BEGIN { if (seconds > 0) printf "%.3f", rows / seconds; else print "nan" }')"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$function" "$n" "$lag" "$repetition" "$elapsed" "$max_rss_kb" "$rows_per_second" >> "$RAW_RESULTS"
            done
        done
    done
done

# Measure the serialized state emitted by the RowBinary format, plus the
# end-to-end cost of constructing and merging 1, 4, and 16 partial states.
# RowBinary avoids text formatting and gives a directly measurable byte count.
for parts in 1 4 16; do
    n=50000
    state_file="$OUTPUT_DIR/.state"
    time_file="$OUTPUT_DIR/.time"
    state_query="SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; SELECT timeSeriesAutocorrelationState(8)(toUInt64(number), value) FROM (SELECT number, sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11) AS value FROM numbers(${n})) GROUP BY number % ${parts} ORDER BY number % ${parts} FORMAT RowBinary;"
    LC_ALL=C /usr/bin/time -f '%e\t%M' -o "$time_file" "$BINARY_PATH" local --multiquery --query "$state_query" > "$state_file"
    IFS=$'\t' read -r elapsed max_rss_kb < "$time_file"
    state_rows="$parts"
    serialized_bytes="$(stat -c '%s' "$state_file")"
    rows_per_second="$(awk -v rows="$n" -v seconds="$elapsed" 'BEGIN { if (seconds > 0) printf "%.3f", rows / seconds; else print "nan" }')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$parts" "$n" "$state_rows" "$serialized_bytes" "$elapsed" "$max_rss_kb" "$rows_per_second" >> "$STATE_RESULTS"

    merge_query="SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; SELECT timeSeriesAutocorrelationMerge(8)(state) FROM (SELECT timeSeriesAutocorrelationState(8)(toUInt64(number), value) AS state FROM (SELECT number, sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11) AS value FROM numbers(${n})) GROUP BY number % ${parts}) FORMAT Null;"
    LC_ALL=C /usr/bin/time -f '%e\t%M' -o "$time_file" "$BINARY_PATH" local --multiquery --query "$merge_query" > /dev/null
    IFS=$'\t' read -r elapsed max_rss_kb < "$time_file"
    rows_per_second="$(awk -v rows="$n" -v seconds="$elapsed" 'BEGIN { if (seconds > 0) printf "%.3f", rows / seconds; else print "nan" }')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$parts" "$n" 8 1 "$elapsed" "$max_rss_kb" "$rows_per_second" >> "$MERGE_RESULTS"
done

# One-series versus grouped-series case.  This isolates the cost of building
# multiple aggregate states while keeping total input rows fixed.
for series in 1 4 16; do
    n=50000
    lag=8
    query="SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; SELECT timeSeriesAutocorrelation(${lag})(toUInt64(number), value) FROM (SELECT number, sin(number * 0.017) + 0.25 * cos(number * 0.071) + 0.001 * (number % 11) AS value FROM numbers(${n})) GROUP BY number % ${series} FORMAT Null;"
    for repetition in $(seq 1 "$REPEAT_COUNT"); do
        time_file="$OUTPUT_DIR/.time"
        LC_ALL=C /usr/bin/time -f '%e\t%M' -o "$time_file" "$BINARY_PATH" local --multiquery --query "$query" > /dev/null
        IFS=$'\t' read -r elapsed max_rss_kb < "$time_file"
        rows_per_second="$(awk -v rows="$n" -v seconds="$elapsed" 'BEGIN { if (seconds > 0) printf "%.3f", rows / seconds; else print "nan" }')"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$series" "$n" "$lag" "$repetition" "$elapsed" "$max_rss_kb" "$rows_per_second" >> "$GROUPED_RESULTS"
    done
done
rm -f "$OUTPUT_DIR/.time"
rm -f "$OUTPUT_DIR/.state"
printf 'benchmark_finished_at=' >> "$METADATA"
date --iso-8601=seconds >> "$METADATA"
printf 'raw_results=%s\nstate_results=%s\ngrouped_results=%s\nmerge_results=%s\nsmoke_output=%s\n' "$RAW_RESULTS" "$STATE_RESULTS" "$GROUPED_RESULTS" "$MERGE_RESULTS" "$SMOKE_OUTPUT"
