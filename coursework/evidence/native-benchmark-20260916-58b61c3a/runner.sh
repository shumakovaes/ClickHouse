#!/usr/bin/env bash
# Reproducible, isolated benchmark harness for the four extension workloads.
# This script does not build ClickHouse. Set CH_BINARY to a Release binary.
set -Eeuo pipefail

CH_BINARY=${CH_BINARY:?Set CH_BINARY to the Release programs/clickhouse binary}
OUTPUT_DIR=${OUTPUT_DIR:-"$(pwd)/extension-benchmark"}
EXTENSIONS=${EXTENSIONS:-"timeSeriesLaggedLinearRegression,timeSeriesADFStatistic,timeSeriesKPSSTest,timeSeriesMeanShiftChangePoint"}
N_VALUES=${N_VALUES:-"1000,10000"}
ORDER_VALUES=${ORDER_VALUES:-"1,4,8"}
ADF_ORDER_VALUES=${ADF_ORDER_VALUES:-"0,2,4"}
KPSS_Q_VALUES=${KPSS_Q_VALUES:-"1,4"}
MIN_SEGMENT_VALUES=${MIN_SEGMENT_VALUES:-"1,60"}
REPETITIONS=${REPETITIONS:-3}
WARMUP=${WARMUP:-1}
PORT=${PORT:-19000}
CH_SOURCE_DIR=${CH_SOURCE_DIR:-}
CH_BUILD_DIR=${CH_BUILD_DIR:-${CMAKE_BUILD_DIR:-}}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-0}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -x "$CH_BINARY" ]] || die "CH_BINARY is not executable: $CH_BINARY"
CH_BINARY=$(readlink -f "$CH_BINARY")
[[ -x "$CH_BINARY" ]] || die "resolved CH_BINARY is not executable: $CH_BINARY"
[[ ! -L "$OUTPUT_DIR" ]] || die "OUTPUT_DIR must not be a symbolic link: $OUTPUT_DIR"
[[ ! -e "$OUTPUT_DIR" || -d "$OUTPUT_DIR" ]] || die "OUTPUT_DIR exists but is not a directory: $OUTPUT_DIR"
[[ ! -e "$OUTPUT_DIR" || -z "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]] || die "OUTPUT_DIR must not be non-empty: $OUTPUT_DIR"

if [[ -z "$CH_BUILD_DIR" ]]; then
  _build_probe=$(dirname "$CH_BINARY")
  while [[ "$_build_probe" != "/" && ! -f "$_build_probe/CMakeCache.txt" ]]; do
    _build_probe=$(dirname "$_build_probe")
  done
  [[ -f "$_build_probe/CMakeCache.txt" ]] || die "could not derive a CMake build directory from CH_BINARY; set CH_BUILD_DIR"
  CH_BUILD_DIR=$_build_probe
else
  CH_BUILD_DIR=$(readlink -f "$CH_BUILD_DIR")
fi
[[ -d "$CH_BUILD_DIR" ]] || die "CH_BUILD_DIR is not a directory: $CH_BUILD_DIR"
case "$CH_BINARY" in
  "$CH_BUILD_DIR"/*) ;;
  *) die "CH_BINARY is not inside selected CH_BUILD_DIR: $CH_BINARY (build dir: $CH_BUILD_DIR)" ;;
esac
CMAKE_CACHE_FILE="$CH_BUILD_DIR/CMakeCache.txt"
[[ -f "$CMAKE_CACHE_FILE" ]] || die "CH_BUILD_DIR lacks CMakeCache.txt: $CH_BUILD_DIR"
CMAKE_BUILD_TYPE=$(sed -n -E 's/^CMAKE_BUILD_TYPE:[^=]*=(.*)$/\1/p' "$CMAKE_CACHE_FILE" | tail -n 1)
[[ "${CMAKE_BUILD_TYPE^^}" == RELEASE ]] || die "benchmark requires an explicit Release CMake build; found CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-unset} in $CMAKE_CACHE_FILE"
CMAKE_HOME_DIRECTORY=$(sed -n -E 's/^CMAKE_HOME_DIRECTORY:[^=]*=(.*)$/\1/p' "$CMAKE_CACHE_FILE" | tail -n 1)
[[ -n "$CMAKE_HOME_DIRECTORY" && -d "$CMAKE_HOME_DIRECTORY" ]] || die "selected cache has no usable CMAKE_HOME_DIRECTORY"
CMAKE_HOME_DIRECTORY=$(readlink -f "$CMAKE_HOME_DIRECTORY")
if [[ -n "$CH_SOURCE_DIR" ]]; then
  CH_SOURCE_DIR=$(readlink -f "$CH_SOURCE_DIR")
  [[ "$CH_SOURCE_DIR" == "$CMAKE_HOME_DIRECTORY" ]] || die "CH_SOURCE_DIR does not match CMAKE_HOME_DIRECTORY from the selected build"
else
  CH_SOURCE_DIR=$CMAKE_HOME_DIRECTORY
fi
command -v git >/dev/null 2>&1 || die "git is required to identify the build source"
SOURCE_ROOT=$(git -C "$CH_SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null) || die "CMAKE_HOME_DIRECTORY is not a Git checkout/worktree: $CH_SOURCE_DIR"
SOURCE_ROOT=$(readlink -f "$SOURCE_ROOT")
[[ "$CH_SOURCE_DIR" == "$SOURCE_ROOT" ]] || die "CMAKE_HOME_DIRECTORY must name the checkout/worktree root: $CH_SOURCE_DIR"
SOURCE_REVISION=$(git -C "$CH_SOURCE_DIR" rev-parse HEAD)
SOURCE_STATUS=$(git -C "$CH_SOURCE_DIR" status --porcelain=v1)
CMAKE_TOOLCHAIN_FILE=$(sed -n -E 's/^CMAKE_TOOLCHAIN_FILE:[^=]*=(.*)$/\1/p' "$CMAKE_CACHE_FILE" | tail -n 1)
if [[ -n "$CMAKE_TOOLCHAIN_FILE" && "$CMAKE_TOOLCHAIN_FILE" != /* ]]; then
  CMAKE_TOOLCHAIN_FILE="$CH_BUILD_DIR/$CMAKE_TOOLCHAIN_FILE"
fi
if [[ -n "$CMAKE_TOOLCHAIN_FILE" ]]; then
  [[ -f "$CMAKE_TOOLCHAIN_FILE" ]] || die "CMAKE_TOOLCHAIN_FILE from selected cache does not exist: $CMAKE_TOOLCHAIN_FILE"
fi

validate_uint() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || die "$name must be a canonical unsigned base-10 integer without leading zeroes: $value"
  (( value >= minimum && value <= maximum )) || die "$name must be in [$minimum,$maximum]: $value"
}

validate_uint_list() {
  local name=$1 values=$2 minimum=$3 maximum=$4 item
  [[ -n "$values" ]] || die "$name must not be empty"
  [[ "$values" != ,* && "$values" != *, && "$values" != *,,* ]] || die "$name contains an empty list item: $values"
  IFS=',' read -ra items <<< "$values"
  for item in "${items[@]}"; do validate_uint "$name" "$item" "$minimum" "$maximum"; done
}

validate_unique_list() {
  local name=$1 values=$2 i j
  local -a unique_items
  IFS=',' read -ra unique_items <<< "$values"
  for ((i = 0; i < ${#unique_items[@]}; ++i)); do
    for ((j = i + 1; j < ${#unique_items[@]}; ++j)); do
      [[ "${unique_items[i]}" != "${unique_items[j]}" ]] || die "$name contains duplicate value: ${unique_items[i]}"
    done
  done
}

validate_uint PORT "$PORT" 1 65535
validate_uint REPETITIONS "$REPETITIONS" 1 1000
validate_uint WARMUP "$WARMUP" 0 1000
validate_uint TIMEOUT_SECONDS "$TIMEOUT_SECONDS" 0 86400
validate_uint_list N_VALUES "$N_VALUES" 2 10000000
validate_uint_list ORDER_VALUES "$ORDER_VALUES" 1 16
validate_uint_list ADF_ORDER_VALUES "$ADF_ORDER_VALUES" 0 16
validate_uint_list KPSS_Q_VALUES "$KPSS_Q_VALUES" 0 1024
validate_uint_list MIN_SEGMENT_VALUES "$MIN_SEGMENT_VALUES" 1 5000000
validate_unique_list N_VALUES "$N_VALUES"
validate_unique_list ORDER_VALUES "$ORDER_VALUES"
validate_unique_list ADF_ORDER_VALUES "$ADF_ORDER_VALUES"
validate_unique_list KPSS_Q_VALUES "$KPSS_Q_VALUES"
validate_unique_list MIN_SEGMENT_VALUES "$MIN_SEGMENT_VALUES"
[[ -n "$EXTENSIONS" && "$EXTENSIONS" != ,* && "$EXTENSIONS" != *, && "$EXTENSIONS" != *,,* ]] || die "EXTENSIONS contains an empty list item"
validate_unique_list EXTENSIONS "$EXTENSIONS"
IFS=',' read -ra exts <<< "$EXTENSIONS"
[[ ${#exts[@]} -gt 0 ]] || die "EXTENSIONS must not be empty"
for ext in "${exts[@]}"; do
  case "$ext" in
    timeSeriesLaggedLinearRegression|timeSeriesADFStatistic|timeSeriesKPSSTest|timeSeriesMeanShiftChangePoint) ;;
    *) die "unsupported extension: $ext" ;;
  esac
done

extension_selected() {
  local selected
  for selected in "${exts[@]}"; do [[ "$selected" == "$1" ]] && return 0; done
  return 1
}

IFS=',' read -ra ns <<< "$N_VALUES"
IFS=',' read -ra orders <<< "$ORDER_VALUES"
IFS=',' read -ra adf_orders <<< "$ADF_ORDER_VALUES"
IFS=',' read -ra qs <<< "$KPSS_Q_VALUES"
IFS=',' read -ra mins <<< "$MIN_SEGMENT_VALUES"
if extension_selected timeSeriesLaggedLinearRegression; then
  for n in "${ns[@]}"; do for order in "${orders[@]}"; do
    (( n > 2 * order + 1 )) || die "regression n=$n must be greater than 2 * order + 1 (order=$order) to leave positive residual degrees of freedom"
  done; done
fi
if extension_selected timeSeriesADFStatistic; then
  for n in "${ns[@]}"; do for order in "${adf_orders[@]}"; do
    (( n >= 2 * order + 4 )) || die "constant ADF n=$n must be at least 2 * augmentation_lags + 4 (augmentation_lags=$order) for fixed-lag admission and positive residual degrees of freedom"
  done; done
fi
if extension_selected timeSeriesKPSSTest; then
  for n in "${ns[@]}"; do for q in "${qs[@]}"; do
    (( q < n )) || die "KPSS bandwidth=$q must be below n=$n"
  done; done
fi
if extension_selected timeSeriesMeanShiftChangePoint; then
  for n in "${ns[@]}"; do for minseg in "${mins[@]}"; do
    (( minseg <= n / 2 )) || die "mean-shift min_segment=$minseg must be at most floor(n/2) for n=$n"
  done; done
fi

mkdir -p "$OUTPUT_DIR"
runtime_parent=${TMPDIR:-/tmp}
ROOT=$(mktemp -d "${runtime_parent%/}/clickhouse-extension-bench.XXXXXXXX")
PID=''
RUN_STATE=starting
RUN_START_UTC=$(date -u +%FT%TZ)
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
    "${runtime_parent%/}"/clickhouse-extension-bench.*) [[ -d "$ROOT" ]] && rm -rf -- "$ROOT" ;;
    *) printf 'refusing to remove unexpected temporary path: %s\n' "$ROOT" >&2 ;;
  esac
}
write_exit_manifest() {
  local rc=$1 status completed
  status=failed
  [[ "$rc" == 0 && "$RUN_STATE" == completed ]] && status=completed
  completed=$(date -u +%FT%TZ)
  if [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]]; then
    {
      printf 'key\tvalue\n'
      printf 'status\t%s\n' "$status"
      printf 'exit_code\t%s\n' "$rc"
      printf 'started_utc\t%s\n' "$RUN_START_UTC"
      printf 'completed_utc\t%s\n' "$completed"
      printf 'build_dir\t%s\n' "$CH_BUILD_DIR"
      printf 'binary\t%s\n' "$CH_BINARY"
    } >"$OUTPUT_DIR/exit-manifest.tsv.tmp" 2>/dev/null && mv -f -- "$OUTPUT_DIR/exit-manifest.tsv.tmp" "$OUTPUT_DIR/exit-manifest.tsv"
    {
      printf 'key\tvalue\n'
      printf 'status\t%s\n' "$status"
      printf 'exit_code\t%s\n' "$rc"
      printf 'started_utc\t%s\n' "$RUN_START_UTC"
      printf 'completed_utc\t%s\n' "$completed"
    } >"$OUTPUT_DIR/run-status.tsv.tmp" 2>/dev/null && mv -f -- "$OUTPUT_DIR/run-status.tsv.tmp" "$OUTPUT_DIR/run-status.tsv"
    if command -v sha256sum >/dev/null 2>&1 && command -v find >/dev/null 2>&1; then
      (cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name '*.tmp' -printf '%P\0' | sort -z | xargs -0 sha256sum) >"$OUTPUT_DIR/SHA256SUMS.tmp" 2>/dev/null && mv -f -- "$OUTPUT_DIR/SHA256SUMS.tmp" "$OUTPUT_DIR/SHA256SUMS" || true
    fi
  fi
}
on_exit() {
  local rc=$?
  set +e
  cleanup
  write_exit_manifest "$rc"
  exit "$rc"
}
runner_script=$(readlink -f "$0")
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$runner_script" "$OUTPUT_DIR/runner.sh"
mkdir -p "$ROOT"/{data,tmp,logs,config,user_files,format_schemas,access,caches}
cat >"$ROOT/users.xml" <<'EOF'
<clickhouse><profiles><default/></profiles><users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users><quotas><default/></quotas></clickhouse>
EOF

cat >"$ROOT/config.xml" <<EOF
<clickhouse><logger><level>error</level><log>$ROOT/logs/server.log</log><errorlog>$ROOT/logs/server.err.log</errorlog><console>false</console></logger><users_config>$ROOT/users.xml</users_config><path>$ROOT/data/</path><tmp_path>$ROOT/tmp/</tmp_path><user_files_path>$ROOT/user_files/</user_files_path><format_schema_path>$ROOT/format_schemas/</format_schema_path><access_control_path>$ROOT/access/</access_control_path><custom_cached_disks_base_directory>$ROOT/caches/</custom_cached_disks_base_directory><listen_host>127.0.0.1</listen_host><tcp_port>$PORT</tcp_port></clickhouse>
EOF

SETTING_CLAUSE='SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1'
run_client_query() {
  local query_id=$1 query=$2
  shift 2
  local -a client_args=(client --host 127.0.0.1 --port "$PORT" --query_id "$query_id" --query "$query")
  (( TIMEOUT_SECONDS > 0 )) && client_args+=(--max_execution_time "$TIMEOUT_SECONDS")
  client_args+=("$@")
  if (( TIMEOUT_SECONDS > 0 )); then
    command -v timeout >/dev/null 2>&1 || die "TIMEOUT_SECONDS requires the timeout command"
    timeout --signal=TERM --kill-after=5 "${TIMEOUT_SECONDS}s" "$CH_BINARY" "${client_args[@]}"
  else
    "$CH_BINARY" "${client_args[@]}"
  fi
}

if command -v ss >/dev/null && ss -H -ltn | awk -v suffix=":$PORT" '$4 ~ suffix "$" { found=1 } END { exit !found }'; then
  die "TCP port is already in use: $PORT"
fi
if run_client_query benchmark_probe_port "SELECT 1 $SETTING_CLAUSE" >/dev/null 2>&1; then
  die "TCP port already has a ClickHouse server: $PORT"
fi
"$CH_BINARY" server --config-file "$ROOT/config.xml" >"$ROOT/logs/server.stdout" 2>"$ROOT/logs/server.stderr" & PID=$!
for _ in $(seq 1 120); do
  kill -0 "$PID" 2>/dev/null || die "server exited; see $ROOT/logs/server.stderr"
  if run_client_query benchmark_probe_ready "SELECT 1 $SETTING_CLAUSE" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
run_client_query benchmark_probe_ready_final "SELECT 1 $SETTING_CLAUSE" >/dev/null 2>&1 || die "server did not become ready"

printf 'case_tag\textension\tn\tparameter\tmin_segment\trepetition\twarmup\texpected_result\tobserved_result\tclient_wall_seconds\tclient_user_seconds\tclient_system_seconds\tclient_max_rss_kb\tserver_vmrss_snapshot_before_kb\tserver_vmhwm_snapshot_before_kb\tserver_vmrss_snapshot_after_kb\tserver_vmhwm_snapshot_after_kb\texit_code\tstdout_sha256\tquery_id\n' >"$OUTPUT_DIR/results.tsv"
printf 'key\tvalue\n' >"$OUTPUT_DIR/metadata.tsv"
record_metadata() { printf '%s\t%s\n' "$1" "$2" >>"$OUTPUT_DIR/metadata.tsv"; }
record_metadata date_utc "$(date -u +%FT%TZ)"
record_metadata benchmark "native extension benchmark"
record_metadata build_type "$CMAKE_BUILD_TYPE"
record_metadata cmake_build_dir "$CH_BUILD_DIR"
record_metadata cmake_cache "$CMAKE_CACHE_FILE"
record_metadata cmake_toolchain "${CMAKE_TOOLCHAIN_FILE:-unset}"
record_metadata cmake_cache_sha256 "$(sha256sum "$CMAKE_CACHE_FILE" | awk '{print $1}')"
if [[ -n "$CMAKE_TOOLCHAIN_FILE" ]]; then record_metadata cmake_toolchain_sha256 "$(sha256sum "$CMAKE_TOOLCHAIN_FILE" | awk '{print $1}')"; fi
record_metadata binary "$CH_BINARY"
record_metadata binary_sha256 "$(sha256sum "$CH_BINARY" | awk '{print $1}')"
record_metadata runner_sha256 "$(sha256sum "$OUTPUT_DIR/runner.sh" | awk '{print $1}')"
record_metadata output_dir "$OUTPUT_DIR"
record_metadata host "$(hostname)"
record_metadata uname "$(uname -srvm)"
record_metadata binary_version "$(run_client_query benchmark_version "SELECT version() $SETTING_CLAUSE" --format TSVRaw)"
record_metadata extensions "$EXTENSIONS"
record_metadata port "$PORT"
record_metadata timeout_seconds "$TIMEOUT_SECONDS"
record_metadata setting_clause "$SETTING_CLAUSE"
record_metadata n_values "$N_VALUES"
record_metadata order_values "$ORDER_VALUES"
record_metadata adf_order_values "$ADF_ORDER_VALUES"
record_metadata kpss_q_values "$KPSS_Q_VALUES"
record_metadata min_segment_values "$MIN_SEGMENT_VALUES"
record_metadata repetitions "$REPETITIONS"
record_metadata warmup "$WARMUP"
record_metadata max_threads 1
record_metadata source_dir "$CH_SOURCE_DIR"
record_metadata cmake_home_directory "$CMAKE_HOME_DIRECTORY"
record_metadata source_revision "$SOURCE_REVISION"
printf '%s' "$SOURCE_STATUS" >"$OUTPUT_DIR/source-status.txt"
record_metadata source_status_porcelain_sha256 "$(sha256sum "$OUTPUT_DIR/source-status.txt" | awk '{print $1}')"
grep -E '^(CMAKE_BUILD_TYPE|CMAKE_CXX_COMPILER|CMAKE_GENERATOR|CMAKE_TOOLCHAIN_FILE):' "$CMAKE_CACHE_FILE" >"$OUTPUT_DIR/cmake-cache-selected.txt" || true

result_class() {
  local ext=$1 out=$2 raw
  [[ -s "$out" ]] || { printf empty; return; }
  raw=$(tr -d '\r\n' <"$out")
  [[ -n "${raw//[[:space:]]/}" ]] || { printf empty; return; }
  case "$ext" in
    timeSeriesLaggedLinearRegression) [[ "$raw" =~ ^\([^,]+,\[[^]]*\]\)$ ]] || { printf malformed; return; } ;;
    timeSeriesADFStatistic|timeSeriesKPSSTest) [[ "$raw" =~ ^\([^,]+,[^,]+,[^,]+\)$ ]] || { printf malformed; return; } ;;
    timeSeriesMeanShiftChangePoint) [[ "$raw" =~ ^\([^,]+,[^,]+,[^,]+,[^,]+,[^,]+\)$ ]] || { printf malformed; return; } ;;
    *) printf malformed; return ;;
  esac
  if grep -Eiq '(^|[^[:alpha:]])nan([^[:alpha:]]|$)' <<<"$raw"; then
    printf nan
  elif grep -Eiq '(^|[^[:alpha:]])-inf([^[:alpha:]]|$)' <<<"$raw"; then
    printf inf
  elif grep -Eiq '(^|[^[:alpha:]])\+?inf([^[:alpha:]]|$)' <<<"$raw"; then
    printf +inf
  else
    printf finite
  fi
}

result_matches() {
  local ext=$1 expected=$2 observed=$3
  [[ "$observed" != empty && "$observed" != malformed ]] || return 1
  case "$expected" in
    any) return 0 ;;
    finite) [[ "$observed" == finite || ( "$ext" == timeSeriesMeanShiftChangePoint && "$observed" == +inf ) ]] ;;
    nan) [[ "$observed" == nan ]] ;;
    *) return 1 ;;
  esac
}

run_one() {
  local tag=$1 ext=$2 n=$3 parameter=$4 minseg=$5 rep=$6 warm=$7 expected=${8:-any}
  local query_id query out err rc wall user sys rss before_rss before_hwm after_rss after_hwm stdout_sha observed
  local -a client_args timeout_prefix
  query_id="${tag}_${ext}_${n}_${parameter}_${minseg}_${rep}_${warm}"
  case "$ext" in
    timeSeriesLaggedLinearRegression) query="SELECT timeSeriesLaggedLinearRegression($parameter, $n)(toUInt64(number), sin(number / 10.0)) FROM numbers($n)" ;;
    timeSeriesADFStatistic) query="SELECT timeSeriesADFStatistic($parameter, 'constant', $n)(toUInt64(number), sin(number / 10.0)) FROM numbers($n)" ;;
    timeSeriesKPSSTest) query="SELECT timeSeriesKPSSTest('trend', $parameter, $n)(toUInt64(number), toFloat64(cityHash64(number) % 1000003)) FROM numbers($n)" ;;
    timeSeriesMeanShiftChangePoint) query="SELECT timeSeriesMeanShiftChangePoint($minseg, $n)(toUInt64(number), if(number < $((n / 2)), 0.0, 1.0)) FROM numbers($n)" ;;
    *) die "unsupported extension: $ext" ;;
  esac
  query+=" $SETTING_CLAUSE"
  printf '%s\n' "$query" >"$OUTPUT_DIR/query_${query_id}.sql"
  before_rss=$(awk '/VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  before_hwm=$(awk '/VmHWM:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  out="$OUTPUT_DIR/stdout_${query_id}.tsv"
  err="$OUTPUT_DIR/stderr_${query_id}.txt"
  client_args=(client --host 127.0.0.1 --port "$PORT" --query_id "$query_id" --query "$query" --format TSVRaw)
  timeout_prefix=()
  if (( TIMEOUT_SECONDS > 0 )); then
    timeout_prefix=(timeout --signal=TERM --kill-after=5 "${TIMEOUT_SECONDS}s")
    client_args+=(--max_execution_time "$TIMEOUT_SECONDS")
  fi
  if command -v /usr/bin/time >/dev/null; then
    set +e; /usr/bin/time -f '%e\t%U\t%S\t%M' -o "$ROOT/time.txt" "${timeout_prefix[@]}" "$CH_BINARY" "${client_args[@]}" >"$out" 2>"$err"; rc=$?; set -e
    if ! IFS=$'\t' read -r wall user sys rss < "$ROOT/time.txt"; then wall=NA; user=NA; sys=NA; rss=NA; fi
  else
    set +e; "${timeout_prefix[@]}" "$CH_BINARY" "${client_args[@]}" >"$out" 2>"$err"; rc=$?; set -e; wall=NA; user=NA; sys=NA; rss=NA
  fi
  after_rss=$(awk '/VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  after_hwm=$(awk '/VmHWM:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  (( rc == 0 )) || die "query failed ($query_id); see $err"
  observed=$(result_class "$ext" "$out")
  result_matches "$ext" "$expected" "$observed" || die "query $query_id produced $observed; expected $expected"
  stdout_sha=$(sha256sum "$out" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$ext" "$n" "$parameter" "$minseg" "$rep" "$warm" "$expected" "$observed" "${wall:-NA}" "${user:-NA}" "${sys:-NA}" "${rss:-NA}" "$before_rss" "$before_hwm" "$after_rss" "$after_hwm" "$rc" "$stdout_sha" "$query_id" >>"$OUTPUT_DIR/results.tsv"
}

IFS=',' read -ra ns <<< "$N_VALUES"; IFS=',' read -ra qs <<< "$KPSS_Q_VALUES"; IFS=',' read -ra mins <<< "$MIN_SEGMENT_VALUES"
for ext in "${exts[@]}"; do for n in "${ns[@]}"; do
  params=1
  [[ "$ext" == timeSeriesLaggedLinearRegression ]] && params=$(IFS=,; echo "${ORDER_VALUES[*]}")
  [[ "$ext" == timeSeriesADFStatistic ]] && params=$(IFS=,; echo "${ADF_ORDER_VALUES[*]}")
  [[ "$ext" == timeSeriesKPSSTest ]] && params=$(IFS=,; echo "${qs[*]}")
  IFS=',' read -ra ps <<< "$params"
  minlist=1; [[ "$ext" == timeSeriesMeanShiftChangePoint ]] && minlist=$(IFS=,; echo "${mins[*]}"); IFS=',' read -ra ms <<< "$minlist"
  for parameter in "${ps[@]}"; do for minseg in "${ms[@]}"; do
    for warm in $(seq 1 "$WARMUP"); do run_one grid "$ext" "$n" "$parameter" "$minseg" 0 "$warm" any; done
    for rep in $(seq 1 "$REPETITIONS"); do run_one grid "$ext" "$n" "$parameter" "$minseg" "$rep" 0 any; done
  done; done
done; done
if extension_selected timeSeriesKPSSTest; then
  # Work-cap boundary: n*q <= 100000000 is admitted; exceeding it returns a
  # NaN result (the query itself is not rejected).
  for rep in $(seq 1 "$REPETITIONS"); do run_one kpss_workcap timeSeriesKPSSTest 97656 1024 1 "$rep" 0 finite; done
  for rep in $(seq 1 "$REPETITIONS"); do run_one kpss_workcap timeSeriesKPSSTest 97657 1024 1 "$rep" 0 nan; done
fi
if extension_selected timeSeriesMeanShiftChangePoint; then
  for n in 10000 100000; do for rep in $(seq 1 "$REPETITIONS"); do run_one changepoint_scaling timeSeriesMeanShiftChangePoint "$n" 1 60 "$rep" 0 finite; done; done
fi

RUN_STATE=completed
stop_server
cp "$ROOT/logs/server.log" "$OUTPUT_DIR/server.log" 2>/dev/null || true
cp "$ROOT/logs/server.err.log" "$OUTPUT_DIR/server.err.log" 2>/dev/null || true
cp "$ROOT/logs/server.stderr" "$OUTPUT_DIR/server-process.stderr" 2>/dev/null || true
cp "$ROOT/logs/server.stdout" "$OUTPUT_DIR/server-process.stdout" 2>/dev/null || true
printf 'Server VmRSS/VmHWM are process-wide coarse snapshots (not per-query peaks; reset is impossible). End-to-end wall time waits for the server; client CPU/RSS accounting excludes server work. KPSS work-cap boundary (when selected): n*q <= 100000000 is admitted and larger work returns NaN; n=97656,q=1024 is within the cap and n=97657,q=1024 exceeds it. Mean-shift scaling boundary (when selected): n=10000,100000. A +Inf mean-shift SSE is a documented valid result; NaN fields indicate an undefined/no-improvement result.\n' >"$OUTPUT_DIR/analysis-boundary.txt"
(cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum) >"$OUTPUT_DIR/SHA256SUMS"
printf 'Wrote benchmark evidence to %s\n' "$OUTPUT_DIR"
