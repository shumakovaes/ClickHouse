#!/usr/bin/env bash
# Native Release benchmark for the four statistical extension APIs.
#
# This is intentionally separate from run_extension_benchmark.sh.  It measures
# direct finalization, serialized AggregateFunction state size, and true
# partial-state merge work using pre-materialized ENGINE=Memory states.
set -Eeuo pipefail

CH_BINARY=${CH_BINARY:?Set CH_BINARY to an explicit Release programs/clickhouse binary}
OUTPUT_DIR=${OUTPUT_DIR:-"$(pwd)/extension-state-merge-benchmark"}
CH_SOURCE_DIR=${CH_SOURCE_DIR:-}
CMAKE_BUILD_DIR=${CMAKE_BUILD_DIR:-}
N_VALUES=${N_VALUES:-"1000,10000,100000,1000000"}
MAX_SAMPLES=${MAX_SAMPLES:-1000000}
PARAMETER_N=${PARAMETER_N:-100000}
DIRECT_REGRESSION_ORDER=${DIRECT_REGRESSION_ORDER:-4}
DIRECT_ADF_ORDER=${DIRECT_ADF_ORDER:-2}
DIRECT_KPSS_BANDWIDTH=${DIRECT_KPSS_BANDWIDTH:-8}
DIRECT_MIN_SEGMENT=${DIRECT_MIN_SEGMENT:-60}
REGRESSION_ORDER_VALUES=${REGRESSION_ORDER_VALUES:-"1,4,8,16"}
ADF_ORDER_VALUES=${ADF_ORDER_VALUES:-"0,2,4,8,16"}
KPSS_BANDWIDTH_VALUES=${KPSS_BANDWIDTH_VALUES:-"0,8,32,128,1024"}
MIN_SEGMENT_VALUES=${MIN_SEGMENT_VALUES:-"1,60,1000"}
ROW_STATE_PARTS_VALUES=${ROW_STATE_PARTS_VALUES:-"1,4,16"}
PARAMETER_STATE_PARTS_VALUES=${PARAMETER_STATE_PARTS_VALUES:-"1,4,16,64"}
MERGE_PARTS_VALUES=${MERGE_PARTS_VALUES:-"1,4,16,64"}
ORDER_MODE_VALUES=${ORDER_MODE_VALUES:-"ascending,descending"}
REPETITIONS=${REPETITIONS:-3}
WARMUP=${WARMUP:-1}
PORT=${PORT:-19001}
MIN_FREE_KB=${MIN_FREE_KB:-2097152}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -x "$CH_BINARY" ]] || die "CH_BINARY is not executable: $CH_BINARY"
CH_BINARY=$(readlink -f "$CH_BINARY")
if [[ -z "$CMAKE_BUILD_DIR" ]]; then
    CMAKE_BUILD_DIR=$(realpath -m "$(dirname "$CH_BINARY")/..")
fi
[[ -f "$CMAKE_BUILD_DIR/CMakeCache.txt" ]] || die "CMAKE_BUILD_DIR lacks CMakeCache.txt: $CMAKE_BUILD_DIR"
CMAKE_BUILD_DIR=$(realpath -e "$CMAKE_BUILD_DIR")
case "$CH_BINARY" in
    "$CMAKE_BUILD_DIR"/*) ;;
    *) die "CH_BINARY is not below CMAKE_BUILD_DIR: $CH_BINARY" ;;
esac
CMAKE_BUILD_TYPE=$(sed -n -E 's/^CMAKE_BUILD_TYPE:[^=]*=(.*)$/\1/p' "$CMAKE_BUILD_DIR/CMakeCache.txt" | tail -n 1)
[[ "${CMAKE_BUILD_TYPE^^}" == RELEASE ]] || die "benchmark requires a Release build; found CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-unset}"
CMAKE_HOME_DIRECTORY=$(sed -n -E 's/^CMAKE_HOME_DIRECTORY:[^=]*=(.*)$/\1/p' "$CMAKE_BUILD_DIR/CMakeCache.txt" | tail -n 1)
[[ -n "$CMAKE_HOME_DIRECTORY" && -d "$CMAKE_HOME_DIRECTORY" ]] || die "selected build cache has no usable CMAKE_HOME_DIRECTORY"
CMAKE_HOME_DIRECTORY=$(realpath -e "$CMAKE_HOME_DIRECTORY")
if [[ -n "$CH_SOURCE_DIR" ]]; then
    SOURCE_ROOT=$(git -C "$CH_SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null) || die "CH_SOURCE_DIR is not a Git checkout: $CH_SOURCE_DIR"
    CH_SOURCE_DIR=$(realpath -e "$CH_SOURCE_DIR")
    SOURCE_ROOT=$(realpath -e "$SOURCE_ROOT")
    [[ "$CH_SOURCE_DIR" == "$SOURCE_ROOT" ]] || die "CH_SOURCE_DIR must name the checkout root: $CH_SOURCE_DIR"
    [[ "$CH_SOURCE_DIR" == "$CMAKE_HOME_DIRECTORY" ]] || die "CH_SOURCE_DIR does not match CMAKE_HOME_DIRECTORY from the selected build"
else
    CH_SOURCE_DIR=$CMAKE_HOME_DIRECTORY
fi
SOURCE_ROOT=$(git -C "$CH_SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null) || die "CMAKE_HOME_DIRECTORY is not a Git checkout: $CH_SOURCE_DIR"
SOURCE_ROOT=$(realpath -e "$SOURCE_ROOT")
[[ "$CH_SOURCE_DIR" == "$SOURCE_ROOT" ]] || die "CMAKE_HOME_DIRECTORY must name the checkout root: $CH_SOURCE_DIR"
SOURCE_REVISION=$(git -C "$CH_SOURCE_DIR" rev-parse HEAD)
SOURCE_STATUS=$(git -C "$CH_SOURCE_DIR" status --porcelain=v1)
[[ -L "$OUTPUT_DIR" ]] && die "OUTPUT_DIR must not be a symbolic link: $OUTPUT_DIR"
[[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]] && die "OUTPUT_DIR exists but is not a directory: $OUTPUT_DIR"
if [[ -d "$OUTPUT_DIR" ]] && [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    die "OUTPUT_DIR must be fresh or empty: $OUTPUT_DIR"
fi
command -v awk >/dev/null || die "awk is required"
command -v df >/dev/null || die "df is required"
command -v find >/dev/null || die "find is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v stat >/dev/null || die "stat is required"
[[ -x /usr/bin/time ]] || die "/usr/bin/time is required"

validate_uint() {
    local name=$1 value=$2 minimum=$3 maximum=$4
    [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || die "$name must be a canonical unsigned base-10 integer without leading zeroes: $value"
    (( value >= minimum && value <= maximum )) || die "$name must be in [$minimum,$maximum], got $value"
}

validate_uint_list() {
    local name=$1 values=$2 minimum=$3 maximum=$4 item
    [[ -n "$values" ]] || die "$name must not be empty"
    [[ "$values" != ,* && "$values" != *, && "$values" != *,,* ]] \
        || die "$name contains an empty list item: $values"
    local -A seen=()
    IFS=',' read -ra items <<< "$values"
    for item in "${items[@]}"; do
        validate_uint "$name" "$item" "$minimum" "$maximum"
        [[ -z "${seen[$item]+present}" ]] || die "$name contains duplicate item: $item"
        seen[$item]=1
    done
}

validate_csv_words() {
    local name=$1 values=$2 item
    [[ -n "$values" ]] || die "$name must not be empty"
    [[ "$values" != ,* && "$values" != *, && "$values" != *,,* ]] \
        || die "$name contains an empty list item: $values"
    local -A seen=()
    IFS=',' read -ra items <<< "$values"
    for item in "${items[@]}"; do
        case "$item" in
            ascending|descending) ;;
            *) die "$name must contain only ascending or descending, got: $item" ;;
        esac
        [[ -z "${seen[$item]+present}" ]] || die "$name contains duplicate item: $item"
        seen[$item]=1
    done
}

validate_uint MAX_SAMPLES "$MAX_SAMPLES" 1 10000000
validate_uint PARAMETER_N "$PARAMETER_N" 2 "$MAX_SAMPLES"
validate_uint DIRECT_REGRESSION_ORDER "$DIRECT_REGRESSION_ORDER" 1 16
validate_uint DIRECT_ADF_ORDER "$DIRECT_ADF_ORDER" 0 16
validate_uint DIRECT_KPSS_BANDWIDTH "$DIRECT_KPSS_BANDWIDTH" 0 1024
validate_uint DIRECT_MIN_SEGMENT "$DIRECT_MIN_SEGMENT" 1 "$((MAX_SAMPLES / 2))"
validate_uint_list N_VALUES "$N_VALUES" 1 "$MAX_SAMPLES"
validate_uint_list REGRESSION_ORDER_VALUES "$REGRESSION_ORDER_VALUES" 1 16
validate_uint_list ADF_ORDER_VALUES "$ADF_ORDER_VALUES" 0 16
validate_uint_list KPSS_BANDWIDTH_VALUES "$KPSS_BANDWIDTH_VALUES" 0 1024
validate_uint_list MIN_SEGMENT_VALUES "$MIN_SEGMENT_VALUES" 1 "$((MAX_SAMPLES / 2))"
validate_uint_list ROW_STATE_PARTS_VALUES "$ROW_STATE_PARTS_VALUES" 1 "$MAX_SAMPLES"
validate_uint_list PARAMETER_STATE_PARTS_VALUES "$PARAMETER_STATE_PARTS_VALUES" 1 "$MAX_SAMPLES"
validate_uint_list MERGE_PARTS_VALUES "$MERGE_PARTS_VALUES" 1 "$MAX_SAMPLES"
validate_uint REPETITIONS "$REPETITIONS" 1 1000
validate_uint WARMUP "$WARMUP" 0 1000
validate_uint PORT "$PORT" 1 65535
validate_uint MIN_FREE_KB "$MIN_FREE_KB" 1 1099511627776
validate_csv_words ORDER_MODE_VALUES "$ORDER_MODE_VALUES"

IFS=',' read -ra N_ITEMS <<< "$N_VALUES"
IFS=',' read -ra REG_ITEMS <<< "$REGRESSION_ORDER_VALUES"
IFS=',' read -ra ADF_ITEMS <<< "$ADF_ORDER_VALUES"
IFS=',' read -ra KPSS_ITEMS <<< "$KPSS_BANDWIDTH_VALUES"
IFS=',' read -ra MIN_ITEMS <<< "$MIN_SEGMENT_VALUES"
IFS=',' read -ra ROW_PART_ITEMS <<< "$ROW_STATE_PARTS_VALUES"
IFS=',' read -ra PARAM_PART_ITEMS <<< "$PARAMETER_STATE_PARTS_VALUES"
IFS=',' read -ra MERGE_PART_ITEMS <<< "$MERGE_PARTS_VALUES"
for n in "${N_ITEMS[@]}"; do
    for parts in "${ROW_PART_ITEMS[@]}"; do (( parts <= n )) || die "row state partial count $parts exceeds n=$n"; done
done
for parts in "${PARAM_PART_ITEMS[@]}" "${MERGE_PART_ITEMS[@]}"; do
    (( parts <= PARAMETER_N )) || die "partial count $parts exceeds PARAMETER_N=$PARAMETER_N"
done
(( DIRECT_REGRESSION_ORDER < MAX_SAMPLES )) || die "direct regression order must be below MAX_SAMPLES"
(( DIRECT_ADF_ORDER < MAX_SAMPLES )) || die "direct ADF order must be below MAX_SAMPLES"
(( DIRECT_KPSS_BANDWIDTH < MAX_SAMPLES )) || die "direct KPSS bandwidth must be below MAX_SAMPLES"
(( DIRECT_MIN_SEGMENT <= MAX_SAMPLES / 2 )) || die "direct min segment exceeds MAX_SAMPLES/2"

# These admission checks mirror the native finalizers.  The benchmark treats
# a finite expected_result as a contract, so reject configurations that would
# otherwise reach a structurally undefined fit or a documented work cap.
validate_regression_case() {
    local label=$1 n=$2 order=$3 rows work
    rows=$((n - order))
    work=$((order * order))
    (( n >= 2 * order + 2 )) \
        || die "$label requires n >= $((2 * order + 2)) for order=$order; got n=$n"
    (( rows <= 100000000 / work )) \
        || die "$label exceeds regression QR work cap for n=$n, order=$order"
}

validate_adf_case() {
    local label=$1 n=$2 order=$3 rows columns work
    rows=$((n - order - 1))
    columns=$((order + 1))
    work=$((columns * columns))
    # For deterministic='constant', the native admission rule is
    # floor(n/2) >= order + 2, and rows > model_parameters is equivalent to
    # n >= 2*order + 4.
    (( n >= 2 * order + 4 )) \
        || die "$label requires n >= $((2 * order + 4)) for augmentation_lags=$order; got n=$n"
    (( rows <= 100000000 / work )) \
        || die "$label exceeds ADF QR work cap for n=$n, augmentation_lags=$order"
}

validate_kpss_case() {
    local label=$1 n=$2 bandwidth=$3
    # This harness fixes regression='trend'; two samples are fit exactly by
    # the trend and therefore have zero long-run residual variance.
    (( n >= 3 )) || die "$label requires n >= 3 for trend KPSS; got n=$n"
    (( bandwidth < n )) \
        || die "$label requires bandwidth=$bandwidth below n=$n for KPSS"
    # Deliberately allow n * bandwidth above the native work cap here.  Those
    # cases are valid benchmark inputs: the documented result is NaN, and the
    # harness records that boundary through expected_result().
}

validate_mean_shift_case() {
    local label=$1 n=$2 min_segment=$3
    (( n >= 2 )) || die "$label requires n >= 2 for mean shift; got n=$n"
    (( min_segment <= n / 2 )) \
        || die "$label requires min_segment=$min_segment <= floor(n/2) for n=$n"
}

for n in "${N_ITEMS[@]}"; do
    validate_regression_case "direct regression" "$n" "$DIRECT_REGRESSION_ORDER"
    validate_adf_case "direct ADF" "$n" "$DIRECT_ADF_ORDER"
    validate_kpss_case "direct KPSS" "$n" "$DIRECT_KPSS_BANDWIDTH"
    validate_mean_shift_case "direct mean shift" "$n" "$DIRECT_MIN_SEGMENT"
done

for order in "${REG_ITEMS[@]}"; do
    validate_regression_case "regression parameter sweep" "$PARAMETER_N" "$order"
done
for order in "${ADF_ITEMS[@]}"; do
    validate_adf_case "ADF parameter sweep" "$PARAMETER_N" "$order"
done
for bandwidth in "${KPSS_ITEMS[@]}"; do
    validate_kpss_case "KPSS parameter sweep" "$PARAMETER_N" "$bandwidth"
done
for min_segment in "${MIN_ITEMS[@]}"; do
    validate_mean_shift_case "mean-shift parameter sweep" "$PARAMETER_N" "$min_segment"
done

mkdir -p "$OUTPUT_DIR"
available_kb=$(df -Pk "$OUTPUT_DIR" | awk 'NR == 2 { print $4 }')
[[ "$available_kb" =~ ^[0-9]+$ ]] || die "could not determine free space for OUTPUT_DIR"
(( available_kb >= MIN_FREE_KB )) \
    || die "OUTPUT_DIR filesystem has ${available_kb} KiB free; require at least ${MIN_FREE_KB} KiB"
SCRIPT_PATH=$(readlink -f "$0")
cp "$SCRIPT_PATH" "$OUTPUT_DIR/runner.sh"

RUNTIME_PARENT=${TMPDIR:-/tmp}
ROOT=$(mktemp -d "${RUNTIME_PARENT%/}/clickhouse-extension-state-bench.XXXXXXXX")
PID=''
TABLE_COUNTER=0
PREPARED_TABLE=''
RUN_STATE=running
RUN_STARTED_UTC=$(date -u +%FT%TZ)

stop_server() {
    local wait_round
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
        for wait_round in $(seq 1 40); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.25
        done
        if kill -0 "$PID" 2>/dev/null; then kill -KILL "$PID" 2>/dev/null || true; fi
    fi
    [[ -n "$PID" ]] && wait "$PID" 2>/dev/null || true
    PID=''
}

cleanup() {
    set +e
    stop_server
    if [[ -d "$ROOT/logs" && -d "$OUTPUT_DIR" ]]; then
        cp "$ROOT/logs/server.log" "$OUTPUT_DIR/server.log" 2>/dev/null || true
        cp "$ROOT/logs/server.err.log" "$OUTPUT_DIR/server.err.log" 2>/dev/null || true
        cp "$ROOT/logs/server.stderr" "$OUTPUT_DIR/server-process.stderr" 2>/dev/null || true
        cp "$ROOT/logs/server.stdout" "$OUTPUT_DIR/server-process.stdout" 2>/dev/null || true
    fi
    case "$ROOT" in
        "${RUNTIME_PARENT%/}"/clickhouse-extension-state-bench.*)
            [[ -d "$ROOT" ]] && rm -rf -- "$ROOT"
            ;;
        *) printf 'refusing to remove unexpected temporary path: %s\n' "$ROOT" >&2 ;;
    esac
}
finalize_evidence() {
    local rc=$1 status=failed sums_tmp="$OUTPUT_DIR/.SHA256SUMS.tmp.$$"
    [[ "$rc" == 0 && "$RUN_STATE" == completed ]] && status=completed
    {
        printf 'key\tvalue\n'
        printf 'status\t%s\n' "$status"
        printf 'exit_code\t%s\n' "$rc"
        printf 'started_utc\t%s\n' "$RUN_STARTED_UTC"
        printf 'finished_utc\t%s\n' "$(date -u +%FT%TZ)"
        printf 'source_revision\t%s\n' "$SOURCE_REVISION"
        printf 'binary\t%s\n' "$CH_BINARY"
    } > "$OUTPUT_DIR/run-status.tsv" || return 1
    if ! (cd "$OUTPUT_DIR" && find . -type f ! -name SHA256SUMS ! -name '.SHA256SUMS.tmp.*' -print0 | sort -z | xargs -0 -r sha256sum) > "$sums_tmp" \
        || ! mv -- "$sums_tmp" "$OUTPUT_DIR/SHA256SUMS"; then
        rm -f -- "$sums_tmp"
        return 1
    fi
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    cleanup
    if ! finalize_evidence "$rc"; then
        rc=1
        {
            printf 'key\tvalue\nstatus\tfailed\nexit_code\t1\n'
            printf 'started_utc\t%s\nfinished_utc\t%s\n' "$RUN_STARTED_UTC" "$(date -u +%FT%TZ)"
            printf 'source_revision\t%s\nbinary\t%s\n' "$SOURCE_REVISION" "$CH_BINARY"
        } > "$OUTPUT_DIR/run-status.tsv" 2>/dev/null || true
    fi
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$ROOT"/{data,tmp,logs,user_files,format_schemas,access,caches}
cat > "$ROOT/users.xml" <<'EOF'
<clickhouse><profiles><default/></profiles><users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users><quotas><default/></quotas></clickhouse>
EOF
cat > "$ROOT/config.xml" <<EOF
<clickhouse><logger><level>error</level><log>$ROOT/logs/server.log</log><errorlog>$ROOT/logs/server.err.log</errorlog><console>false</console></logger><users_config>$ROOT/users.xml</users_config><path>$ROOT/data/</path><tmp_path>$ROOT/tmp/</tmp_path><user_files_path>$ROOT/user_files/</user_files_path><format_schema_path>$ROOT/format_schemas/</format_schema_path><access_control_path>$ROOT/access/</access_control_path><custom_cached_disks_base_directory>$ROOT/caches/</custom_cached_disks_base_directory><listen_host>127.0.0.1</listen_host><tcp_port>$PORT</tcp_port></clickhouse>
EOF

if command -v ss >/dev/null && ss -H -ltn | awk -v suffix=":$PORT" '$4 ~ suffix "$" { found=1 } END { exit !found }'; then
    die "TCP port is already in use: $PORT"
fi
if "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT 1 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1' >/dev/null 2>&1; then
    die "TCP port already has a ClickHouse server: $PORT"
fi
"$CH_BINARY" server --config-file "$ROOT/config.xml" >"$ROOT/logs/server.stdout" 2>"$ROOT/logs/server.stderr" & PID=$!
for _ in $(seq 1 120); do
    kill -0 "$PID" 2>/dev/null || die "server exited; see $ROOT/logs/server.stderr"
    if "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT 1 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1' >/dev/null 2>&1; then break; fi
    sleep 0.25
done
"$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT 1 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1' >/dev/null 2>&1 || die "server did not become ready"

printf 'case_tag\textension\tn\tparameter_name\tparameter\torder_mode\trepetition\twarmup\twall_seconds\tuser_seconds\tsystem_seconds\tclient_max_rss_kb\trows_per_second\texpected_result\tobserved_result\texit_code\tstdout_sha256\tquery_id\n' > "$OUTPUT_DIR/direct.tsv"
printf 'case_tag\textension\tn\tparameter_name\tparameter\tpartial_states\tinput_rows\tstate_rows\tserialized_bytes\tbytes_per_input_row\tbuild_wall_seconds\tbuild_user_seconds\tbuild_system_seconds\tbuild_max_rss_kb\texit_code\tstdout_sha256\tquery_id\n' > "$OUTPUT_DIR/state_sizes.tsv"
printf 'case_tag\textension\tn\tparameter_name\tparameter\tpartial_states\tinput_rows\tmerge_variant\trepetition\twarmup\twall_seconds\tuser_seconds\tsystem_seconds\tclient_max_rss_kb\tinput_rows_per_second\tstates_per_second\texpected_result\tobserved_result\texit_code\tstdout_sha256\tquery_id\n' > "$OUTPUT_DIR/merge.tsv"

printf 'key\tvalue\n' > "$OUTPUT_DIR/metadata.tsv"
record_metadata() { printf '%s\t%s\n' "$1" "$2" >> "$OUTPUT_DIR/metadata.tsv"; }
record_metadata date_utc "$(date -u +%FT%TZ)"
record_metadata benchmark "native extension state/merge benchmark"
record_metadata build_type "$CMAKE_BUILD_TYPE"
record_metadata binary "$(readlink -f "$CH_BINARY")"
record_metadata binary_sha256 "$(sha256sum "$CH_BINARY" | awk '{print $1}')"
record_metadata runner_sha256 "$(sha256sum "$OUTPUT_DIR/runner.sh" | awk '{print $1}')"
record_metadata host "$(hostname)"
record_metadata uname "$(uname -srvm)"
record_metadata cpu "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || printf unavailable)"
record_metadata logical_cpus "$(command -v nproc >/dev/null && nproc || printf unavailable)"
record_metadata memory_bytes "$(free -b 2>/dev/null | awk '/^Mem:/{print $2}' || printf unavailable)"
record_metadata binary_version "$("$CH_BINARY" --version 2>&1 | head -1)"
record_metadata cmake_version "$(cmake --version 2>/dev/null | head -1 || printf unavailable)"
record_metadata ninja_version "$(ninja --version 2>/dev/null || printf unavailable)"
record_metadata cxx "${CXX:-clang++}"
record_metadata cxx_version "$("${CXX:-clang++}" --version 2>/dev/null | head -1 || printf unavailable)"
record_metadata source_dir "$CH_SOURCE_DIR"
record_metadata cmake_build_dir "$CMAKE_BUILD_DIR"
record_metadata cmake_home_directory "$CMAKE_HOME_DIRECTORY"
record_metadata max_samples "$MAX_SAMPLES"
record_metadata n_values "$N_VALUES"
record_metadata parameter_n "$PARAMETER_N"
record_metadata row_state_parts "$ROW_STATE_PARTS_VALUES"
record_metadata parameter_state_parts "$PARAMETER_STATE_PARTS_VALUES"
record_metadata merge_parts "$MERGE_PARTS_VALUES"
record_metadata repetitions "$REPETITIONS"
record_metadata warmup "$WARMUP"
record_metadata minimum_free_space_kb "$MIN_FREE_KB"
record_metadata available_free_space_kb_at_start "$available_kb"
record_metadata max_threads 1
record_metadata port "$PORT"
record_metadata source_revision "$SOURCE_REVISION"
printf '%s' "$SOURCE_STATUS" > "$OUTPUT_DIR/source-status.txt"
record_metadata source_status_sha256 "$(sha256sum "$OUTPUT_DIR/source-status.txt" | awk '{print $1}')"
if [[ -f "$CMAKE_BUILD_DIR/CMakeCache.txt" ]]; then
    record_metadata cmake_cache_sha256 "$(sha256sum "$CMAKE_BUILD_DIR/CMakeCache.txt" | awk '{print $1}')"
    grep -E '^(CMAKE_BUILD_TYPE|CMAKE_CXX_COMPILER|CMAKE_GENERATOR):' "$CMAKE_BUILD_DIR/CMakeCache.txt" > "$OUTPUT_DIR/cmake-cache-selected.txt" || true
fi

SETTING_CLAUSE='SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1'
REG_VALUE='toFloat64(cityHash64(number) % 1000003) / 1000003.0'
ADF_VALUE='toFloat64(cityHash64(number) % 1000003) / 1000003.0'
KPSS_VALUE='toFloat64(cityHash64(number) % 1000003)'

parameter_name() {
    case "$1" in
        timeSeriesLaggedLinearRegression) printf order ;;
        timeSeriesADFStatistic) printf augmentation_lags ;;
        timeSeriesKPSSTest) printf bandwidth ;;
        timeSeriesMeanShiftChangePoint) printf min_segment ;;
        *) die "unknown extension: $1" ;;
    esac
}

value_expression() {
    local n=$2
    case "$1" in
        timeSeriesLaggedLinearRegression) printf '%s' "$REG_VALUE" ;;
        timeSeriesADFStatistic) printf '%s' "$ADF_VALUE" ;;
        timeSeriesKPSSTest) printf '%s' "$KPSS_VALUE" ;;
        timeSeriesMeanShiftChangePoint) printf 'if(number < %s, 0.0, 1.0)' "$((n / 2))" ;;
        *) die "unknown extension: $1" ;;
    esac
}

function_call() {
    local ext=$1 variant=$2 param=$3 n=$4
    local value; value=$(value_expression "$ext" "$n")
    case "$ext:$variant" in
        timeSeriesLaggedLinearRegression:direct) printf 'timeSeriesLaggedLinearRegression(%s, %s)(toUInt64(number), %s)' "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesADFStatistic:direct) printf "timeSeriesADFStatistic(%s, 'constant', %s)(toUInt64(number), %s)" "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesKPSSTest:direct) printf "timeSeriesKPSSTest('trend', %s, %s)(toUInt64(number), %s)" "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesMeanShiftChangePoint:direct) printf 'timeSeriesMeanShiftChangePoint(%s, %s)(toUInt64(number), %s)' "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesLaggedLinearRegression:state) printf 'timeSeriesLaggedLinearRegressionState(%s, %s)(toUInt64(number), %s)' "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesADFStatistic:state) printf "timeSeriesADFStatisticState(%s, 'constant', %s)(toUInt64(number), %s)" "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesKPSSTest:state) printf "timeSeriesKPSSTestState('trend', %s, %s)(toUInt64(number), %s)" "$param" "$MAX_SAMPLES" "$value" ;;
        timeSeriesMeanShiftChangePoint:state) printf 'timeSeriesMeanShiftChangePointState(%s, %s)(toUInt64(number), %s)' "$param" "$MAX_SAMPLES" "$value" ;;
        *) die "unsupported function call: $ext/$variant" ;;
    esac
}

merge_call() {
    local ext=$1 variant=$2 param=$3
    case "$ext:$variant" in
        timeSeriesLaggedLinearRegression:merge) printf 'timeSeriesLaggedLinearRegressionMerge(%s, %s)(state)' "$param" "$MAX_SAMPLES" ;;
        timeSeriesLaggedLinearRegression:merge_state) printf 'timeSeriesLaggedLinearRegressionMergeState(%s, %s)(state)' "$param" "$MAX_SAMPLES" ;;
        timeSeriesADFStatistic:merge) printf "timeSeriesADFStatisticMerge(%s, 'constant', %s)(state)" "$param" "$MAX_SAMPLES" ;;
        timeSeriesADFStatistic:merge_state) printf "timeSeriesADFStatisticMergeState(%s, 'constant', %s)(state)" "$param" "$MAX_SAMPLES" ;;
        timeSeriesKPSSTest:merge) printf "timeSeriesKPSSTestMerge('trend', %s, %s)(state)" "$param" "$MAX_SAMPLES" ;;
        timeSeriesKPSSTest:merge_state) printf "timeSeriesKPSSTestMergeState('trend', %s, %s)(state)" "$param" "$MAX_SAMPLES" ;;
        timeSeriesMeanShiftChangePoint:merge) printf 'timeSeriesMeanShiftChangePointMerge(%s, %s)(state)' "$param" "$MAX_SAMPLES" ;;
        timeSeriesMeanShiftChangePoint:merge_state) printf 'timeSeriesMeanShiftChangePointMergeState(%s, %s)(state)' "$param" "$MAX_SAMPLES" ;;
        *) die "unsupported merge call: $ext/$variant" ;;
    esac
}

state_type() {
    case "$1" in
        timeSeriesLaggedLinearRegression) printf 'timeSeriesLaggedLinearRegression(%s, %s)' "$2" "$MAX_SAMPLES" ;;
        timeSeriesADFStatistic) printf "timeSeriesADFStatistic(%s, 'constant', %s)" "$2" "$MAX_SAMPLES" ;;
        timeSeriesKPSSTest) printf "timeSeriesKPSSTest('trend', %s, %s)" "$2" "$MAX_SAMPLES" ;;
        timeSeriesMeanShiftChangePoint) printf 'timeSeriesMeanShiftChangePoint(%s, %s)' "$2" "$MAX_SAMPLES" ;;
        *) die "unknown extension: $1" ;;
    esac
}

expected_result() {
    local ext=$1 n=$2 param=$3
    if [[ "$ext" == timeSeriesKPSSTest ]] && (( param > 0 && n > 100000000 / param )); then
        printf nan
    else
        printf finite
    fi
}

RUN_WALL=NA; RUN_USER=NA; RUN_SYS=NA; RUN_RSS=NA; RUN_RC=1; RUN_SHA=''
run_timed() {
    local id=$1 query=$2 out=$3 err=$4 format=$5
    local rc wall user sys rss
    printf '%s\n' "$query" > "$OUTPUT_DIR/query_${id}.sql"
    if [[ "$format" == none ]]; then
        set +e
        /usr/bin/time -f '%e\t%U\t%S\t%M' -o "$ROOT/time.txt" \
            "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query_id "$id" --query "$query" > "$out" 2> "$err"
        rc=$?
        set -e
    else
        set +e
        /usr/bin/time -f '%e\t%U\t%S\t%M' -o "$ROOT/time.txt" \
            "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query_id "$id" --query "$query" --format "$format" > "$out" 2> "$err"
        rc=$?
        set -e
    fi
    if ! IFS=$'\t' read -r wall user sys rss < "$ROOT/time.txt"; then wall=NA; user=NA; sys=NA; rss=NA; fi
    RUN_WALL=${wall:-NA}; RUN_USER=${user:-NA}; RUN_SYS=${sys:-NA}; RUN_RSS=${rss:-NA}; RUN_RC=$rc
    RUN_SHA=$(sha256sum "$out" | awk '{print $1}')
}

run_control() {
    local id=$1 query=$2 out="$OUTPUT_DIR/stdout_${1}.tsv" err="$OUTPUT_DIR/stderr_${1}.txt" rc
    local full_query="SET enable_time_series_aggregate_functions = 1; SET max_threads = 1; $query"
    printf '%s\n' "$full_query" > "$OUTPUT_DIR/query_${id}.sql"
    set +e
    "$CH_BINARY" client --multiquery --host 127.0.0.1 --port "$PORT" --query_id "$id" --query "$full_query" > "$out" 2> "$err"
    rc=$?
    set -e
    (( rc == 0 )) || die "control query failed ($id); see $err"
}

rows_per_second() { awk -v n="$1" -v t="$2" 'BEGIN { if (t ~ /^[0-9.]+$/ && t > 0) printf "%.6f", n / t; else print "NA" }'; }
states_per_second() { awk -v n="$1" -v t="$2" 'BEGIN { if (t ~ /^[0-9.]+$/ && t > 0) printf "%.6f", n / t; else print "NA" }'; }
is_nan_output() { grep -Eiq '(^|[^[:alpha:]])nan([^[:alpha:]]|$)' "$1"; }

run_direct_case() {
    local tag=$1 ext=$2 n=$3 param=$4 mode=$5 rep=$6 warm=$7 expected=$8 record=${9:-1}
    local id="direct_${tag}_${ext}_${n}_${param}_${mode}_${rep}_${warm}" source query out err observed rps
    if [[ "$mode" == ascending ]]; then
        source="FROM numbers($n)"
    else
        source="FROM (SELECT number FROM numbers($n) ORDER BY number DESC)"
    fi
    query="SELECT $(function_call "$ext" direct "$param" "$n") $source $SETTING_CLAUSE"
    out="$OUTPUT_DIR/stdout_${id}.tsv"; err="$OUTPUT_DIR/stderr_${id}.txt"
    run_timed "$id" "$query" "$out" "$err" TSVRaw
    (( RUN_RC == 0 )) || die "direct query failed ($id); see $err"
    if is_nan_output "$out"; then observed=nan; else observed=finite; fi
    [[ "$expected" == "$observed" ]] || die "direct query $id produced $observed, expected $expected"
    rps=$(rows_per_second "$n" "$RUN_WALL")
    if (( record )); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tag" "$ext" "$n" "$(parameter_name "$ext")" "$param" "$mode" "$rep" "$warm" "$RUN_WALL" "$RUN_USER" "$RUN_SYS" "$RUN_RSS" "$rps" "$expected" "$observed" "$RUN_RC" "$RUN_SHA" "$id" >> "$OUTPUT_DIR/direct.tsv"
    fi
}

run_state_case() {
    local tag=$1 ext=$2 n=$3 param=$4 parts=$5 rep=$6
    local id="state_${tag}_${ext}_${n}_${param}_${parts}_${rep}" query out err count_id count_query count_out count bytes bpr rps
    local state_wall state_user state_sys state_rss state_rc state_sha
    query="SELECT $(function_call "$ext" state "$param" "$n") FROM numbers($n) GROUP BY number % $parts ORDER BY number % $parts $SETTING_CLAUSE FORMAT RowBinary"
    # The payload can approach a gigabyte across the default grid. Measure it
    # in the guarded temporary tree and retain its size/hash in state_sizes.tsv
    # instead of bloating the checked-in evidence directory.
    out="$ROOT/stdout_${id}.bin"; err="$OUTPUT_DIR/stderr_${id}.txt"
    run_timed "$id" "$query" "$out" "$err" none
    (( RUN_RC == 0 )) || die "state query failed ($id); see $err"
    state_wall=$RUN_WALL; state_user=$RUN_USER; state_sys=$RUN_SYS; state_rss=$RUN_RSS; state_rc=$RUN_RC; state_sha=$RUN_SHA
    bytes=$(stat -c '%s' "$out")
    (( bytes > 0 )) || die "state query produced an empty serialized payload ($id)"
    rm -f -- "$out"
    count_id="${id}_count"; count_out="$OUTPUT_DIR/stdout_${count_id}.tsv"
    count_query="SELECT count() FROM (SELECT $(function_call "$ext" state "$param" "$n") AS state FROM numbers($n) GROUP BY number % $parts) $SETTING_CLAUSE"
    run_timed "$count_id" "$count_query" "$count_out" "$OUTPUT_DIR/stderr_${count_id}.txt" TSVRaw
    (( RUN_RC == 0 )) || die "state count query failed ($count_id)"
    count=$(tr -d '\r\n' < "$count_out")
    [[ "$count" == "$parts" ]] || die "expected $parts partial states, got '$count' ($id)"
    bpr=$(awk -v bytes="$bytes" -v n="$n" 'BEGIN { printf "%.6f", bytes / n }')
    rps=$(rows_per_second "$n" "$state_wall")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$tag" "$ext" "$n" "$(parameter_name "$ext")" "$param" "$parts" "$n" "$count" "$bytes" "$bpr" "$state_wall" "$state_user" "$state_sys" "$state_rss" "$state_rc" "$state_sha" "$id" >> "$OUTPUT_DIR/state_sizes.tsv"
}

prepare_state_table() {
    local ext=$1 n=$2 param=$3 parts=$4
    TABLE_COUNTER=$((TABLE_COUNTER + 1))
    local table="bench_ext_state_${TABLE_COUNTER}" type insert_query count
    type=$(state_type "$ext" "$param")
    run_control "create_${table}" "DROP TABLE IF EXISTS $table; CREATE TABLE $table (part UInt32, state AggregateFunction($type, UInt64, Float64)) ENGINE = Memory;"
    insert_query="INSERT INTO $table SELECT toUInt32(number % $parts), $(function_call "$ext" state "$param" "$n") FROM numbers($n) GROUP BY number % $parts $SETTING_CLAUSE"
    run_control "insert_${table}" "$insert_query"
    run_control "count_${table}" "SELECT count() FROM $table $SETTING_CLAUSE"
    [[ -f "$OUTPUT_DIR/stdout_count_${table}.tsv" ]] || die "missing state-table count output"
    count=$(tr -d '\r\n' < "$OUTPUT_DIR/stdout_count_${table}.tsv")
    [[ "$count" == "$parts" ]] || die "state table $table has $count rows, expected $parts"
    PREPARED_TABLE=$table
}

run_merge_case() {
    local tag=$1 ext=$2 n=$3 param=$4 parts=$5
    local table merge_state_query merge_query verify_query expected
    prepare_state_table "$ext" "$n" "$param" "$parts"
    table=$PREPARED_TABLE
    expected=$(expected_result "$ext" "$n" "$param")
    merge_state_query="SELECT $(merge_call "$ext" merge_state "$param") FROM $table $SETTING_CLAUSE FORMAT Null"
    merge_query="SELECT $(merge_call "$ext" merge "$param") FROM $table $SETTING_CLAUSE"
    verify_query="SELECT finalizeAggregation($(merge_call "$ext" merge_state "$param")) = $(merge_call "$ext" merge "$param") FROM $table $SETTING_CLAUSE"
    run_control "verify_${table}" "$verify_query"
    [[ "$(tr -d '\r\n' < "$OUTPUT_DIR/stdout_verify_${table}.tsv")" == 1 ]] \
        || die "MergeState finalization disagrees with Merge for $table"
    for warm in $(seq 1 "$WARMUP"); do
        run_timed "mergewarm_${table}_${warm}" "$merge_state_query" "$OUTPUT_DIR/stdout_mergewarm_${table}_${warm}.bin" "$OUTPUT_DIR/stderr_mergewarm_${table}_${warm}.txt" none
        (( RUN_RC == 0 )) || die "merge-state warmup failed ($table)"
        run_timed "finalwarm_${table}_${warm}" "$merge_query" "$OUTPUT_DIR/stdout_finalwarm_${table}_${warm}.tsv" "$OUTPUT_DIR/stderr_finalwarm_${table}_${warm}.txt" TSVRaw
        (( RUN_RC == 0 )) || die "merge finalization warmup failed ($table)"
    done
    for rep in $(seq 1 "$REPETITIONS"); do
        local id out err observed rps sps
        id="merge_${tag}_${ext}_${n}_${param}_${parts}_${rep}_state"
        out="$OUTPUT_DIR/stdout_${id}.bin"; err="$OUTPUT_DIR/stderr_${id}.txt"
        run_timed "$id" "$merge_state_query" "$out" "$err" none
        (( RUN_RC == 0 )) || die "MergeState failed ($id); see $err"
        rps=$(rows_per_second "$n" "$RUN_WALL"); sps=$(states_per_second "$parts" "$RUN_WALL")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tag" "$ext" "$n" "$(parameter_name "$ext")" "$param" "$parts" "$n" merge_state "$rep" 0 "$RUN_WALL" "$RUN_USER" "$RUN_SYS" "$RUN_RSS" "$rps" "$sps" ok ok "$RUN_RC" "$RUN_SHA" "$id" >> "$OUTPUT_DIR/merge.tsv"

        id="merge_${tag}_${ext}_${n}_${param}_${parts}_${rep}_final"
        out="$OUTPUT_DIR/stdout_${id}.tsv"; err="$OUTPUT_DIR/stderr_${id}.txt"
        run_timed "$id" "$merge_query" "$out" "$err" TSVRaw
        (( RUN_RC == 0 )) || die "Merge finalization failed ($id); see $err"
        if is_nan_output "$out"; then observed=nan; else observed=finite; fi
        [[ "$expected" == "$observed" ]] || die "merge finalization $id produced $observed, expected $expected"
        rps=$(rows_per_second "$n" "$RUN_WALL"); sps=$(states_per_second "$parts" "$RUN_WALL")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tag" "$ext" "$n" "$(parameter_name "$ext")" "$param" "$parts" "$n" merge_final "$rep" 0 "$RUN_WALL" "$RUN_USER" "$RUN_SYS" "$RUN_RSS" "$rps" "$sps" "$expected" "$observed" "$RUN_RC" "$RUN_SHA" "$id" >> "$OUTPUT_DIR/merge.tsv"
    done
    run_control "drop_${table}" "DROP TABLE IF EXISTS $table"
}

EXTENSIONS=(timeSeriesLaggedLinearRegression timeSeriesADFStatistic timeSeriesKPSSTest timeSeriesMeanShiftChangePoint)

# Direct row scaling at one safe parameter per API, including the explicit
# ascending/descending input-order comparison at the controlled size.
for ext in "${EXTENSIONS[@]}"; do
    case "$ext" in
        timeSeriesLaggedLinearRegression) direct_param=$DIRECT_REGRESSION_ORDER ;;
        timeSeriesADFStatistic) direct_param=$DIRECT_ADF_ORDER ;;
        timeSeriesKPSSTest) direct_param=$DIRECT_KPSS_BANDWIDTH ;;
        timeSeriesMeanShiftChangePoint) direct_param=$DIRECT_MIN_SEGMENT ;;
    esac
    for n in "${N_ITEMS[@]}"; do
        expected=$(expected_result "$ext" "$n" "$direct_param")
        for warm in $(seq 1 "$WARMUP"); do
            run_direct_case row_scaling "$ext" "$n" "$direct_param" ascending 0 "$warm" "$expected" 0
        done
        for rep in $(seq 1 "$REPETITIONS"); do
            run_direct_case row_scaling "$ext" "$n" "$direct_param" ascending "$rep" 0 "$expected" 1
        done
    done
    for mode in ${ORDER_MODE_VALUES//,/ }; do
        expected=$(expected_result "$ext" "$PARAMETER_N" "$direct_param")
        for warm in $(seq 1 "$WARMUP"); do
            run_direct_case input_order "$ext" "$PARAMETER_N" "$direct_param" "$mode" 0 "$warm" "$expected" 0
        done
        for rep in $(seq 1 "$REPETITIONS"); do
            run_direct_case input_order "$ext" "$PARAMETER_N" "$direct_param" "$mode" "$rep" 0 "$expected" 1
        done
    done
done

# Controlled finalizer parameter sweeps at fixed n.  This isolates p/q/minseg
# from row-count scaling; q=1024 intentionally records the documented KPSS
# work-cap NaN at the default PARAMETER_N=100000.
IFS=',' read -ra REG_ITEMS <<< "$REGRESSION_ORDER_VALUES"
IFS=',' read -ra ADF_ITEMS <<< "$ADF_ORDER_VALUES"
IFS=',' read -ra KPSS_ITEMS <<< "$KPSS_BANDWIDTH_VALUES"
IFS=',' read -ra MIN_ITEMS <<< "$MIN_SEGMENT_VALUES"
for ext in "${EXTENSIONS[@]}"; do
    case "$ext" in
        timeSeriesLaggedLinearRegression) items=("${REG_ITEMS[@]}");;
        timeSeriesADFStatistic) items=("${ADF_ITEMS[@]}");;
        timeSeriesKPSSTest) items=("${KPSS_ITEMS[@]}");;
        timeSeriesMeanShiftChangePoint) items=("${MIN_ITEMS[@]}");;
    esac
    for param in "${items[@]}"; do
        expected=$(expected_result "$ext" "$PARAMETER_N" "$param")
        for warm in $(seq 1 "$WARMUP"); do
            run_direct_case parameter_scaling "$ext" "$PARAMETER_N" "$param" ascending 0 "$warm" "$expected" 0
        done
        for rep in $(seq 1 "$REPETITIONS"); do
            run_direct_case parameter_scaling "$ext" "$PARAMETER_N" "$param" ascending "$rep" 0 "$expected" 1
        done
    done
done

# Serialized state sizes: each row-scaling n uses 1/4/16 partial states;
# controlled n uses 1/4/16/64.  Repetitions are retained as raw evidence.
for ext in "${EXTENSIONS[@]}"; do
    case "$ext" in
        timeSeriesLaggedLinearRegression) state_param=$DIRECT_REGRESSION_ORDER ;;
        timeSeriesADFStatistic) state_param=$DIRECT_ADF_ORDER ;;
        timeSeriesKPSSTest) state_param=$DIRECT_KPSS_BANDWIDTH ;;
        timeSeriesMeanShiftChangePoint) state_param=$DIRECT_MIN_SEGMENT ;;
    esac
    for n in "${N_ITEMS[@]}"; do
        for parts in "${ROW_PART_ITEMS[@]}"; do
            for rep in $(seq 1 "$REPETITIONS"); do
                run_state_case row_scaling "$ext" "$n" "$state_param" "$parts" "$rep"
            done
        done
    done
    for parts in "${PARAM_PART_ITEMS[@]}"; do
        for rep in $(seq 1 "$REPETITIONS"); do
            run_state_case parameter_scaling "$ext" "$PARAMETER_N" "$state_param" "$parts" "$rep"
        done
    done
done

# Materialized-state MergeState isolates in-memory state merge and aggregate-
# state result construction; Merge additionally measures the statistical finalizer.
for ext in "${EXTENSIONS[@]}"; do
    case "$ext" in
        timeSeriesLaggedLinearRegression) merge_param=$DIRECT_REGRESSION_ORDER ;;
        timeSeriesADFStatistic) merge_param=$DIRECT_ADF_ORDER ;;
        timeSeriesKPSSTest) merge_param=$DIRECT_KPSS_BANDWIDTH ;;
        timeSeriesMeanShiftChangePoint) merge_param=$DIRECT_MIN_SEGMENT ;;
    esac
    for parts in "${MERGE_PART_ITEMS[@]}"; do
        run_merge_case merge_only "$ext" "$PARAMETER_N" "$merge_param" "$parts"
    done
done

cat > "$OUTPUT_DIR/phase-notes.txt" <<EOF
Direct rows: synthetic numbers(n) input, one aggregate group, max_threads=1.
Input-order cases: ascending and descending timestamp streams; these measure local canonicalization cost only.
State sizes: AggregateFunction State output is measured as raw RowBinary bytes in the temporary runtime tree; state_rows are verified by a count query, and payload size/hash are retained while the bulky raw bytes are not.
Merge cases: states are materialized before timing in ENGINE=Memory. MergeState measures in-memory state merging and aggregate-state result computation; FORMAT Null suppresses output formatting and transport. Merge includes the same merge work plus statistical finalization and one visible result row.
State payloads retain every timestamp/value sample, so serialized size and retained memory are O(n), not O(parameter).
KPSS work-cap boundary: at n=100000,q=1024 the final statistic is expected to be NaN because n*q exceeds 100000000; state construction and MergeState remain valid.
RSS is client process maximum RSS, not per-query server allocator memory. Wall time includes client/server protocol and deterministic expression evaluation.
No p-values or statistical significance claims are made for ADF or KPSS; all results are implementation/performance measurements only.
EOF

stop_server
cp "$ROOT/logs/server.log" "$OUTPUT_DIR/server.log" 2>/dev/null || true
cp "$ROOT/logs/server.err.log" "$OUTPUT_DIR/server.err.log" 2>/dev/null || true
cp "$ROOT/logs/server.stderr" "$OUTPUT_DIR/server-process.stderr" 2>/dev/null || true
cp "$ROOT/logs/server.stdout" "$OUTPUT_DIR/server-process.stdout" 2>/dev/null || true
record_metadata completed_utc "$(date -u +%FT%TZ)"
RUN_STATE=completed
printf 'Wrote native Release extension state/merge benchmark evidence to %s\n' "$OUTPUT_DIR"
