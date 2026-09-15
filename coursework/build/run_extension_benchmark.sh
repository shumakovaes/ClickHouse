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

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -x "$CH_BINARY" ]] || die "CH_BINARY is not executable: $CH_BINARY"
[[ ! -e "$OUTPUT_DIR" || -z "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]] || die "OUTPUT_DIR must not be non-empty: $OUTPUT_DIR"

validate_uint() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an unsigned integer: $value"
  (( value >= minimum && value <= maximum )) || die "$name must be in [$minimum,$maximum]: $value"
}

validate_uint_list() {
  local name=$1 values=$2 minimum=$3 maximum=$4 item
  [[ -n "$values" ]] || die "$name must not be empty"
  IFS=',' read -ra items <<< "$values"
  for item in "${items[@]}"; do validate_uint "$name" "$item" "$minimum" "$maximum"; done
}

validate_uint PORT "$PORT" 1 65535
validate_uint REPETITIONS "$REPETITIONS" 1 1000
validate_uint WARMUP "$WARMUP" 0 1000
validate_uint_list N_VALUES "$N_VALUES" 2 10000000
validate_uint_list ORDER_VALUES "$ORDER_VALUES" 1 16
validate_uint_list ADF_ORDER_VALUES "$ADF_ORDER_VALUES" 0 16
validate_uint_list KPSS_Q_VALUES "$KPSS_Q_VALUES" 0 1024
validate_uint_list MIN_SEGMENT_VALUES "$MIN_SEGMENT_VALUES" 1 5000000
IFS=',' read -ra exts <<< "$EXTENSIONS"
[[ ${#exts[@]} -gt 0 ]] || die "EXTENSIONS must not be empty"
for ext in "${exts[@]}"; do
  case "$ext" in
    timeSeriesLaggedLinearRegression|timeSeriesADFStatistic|timeSeriesKPSSTest|timeSeriesMeanShiftChangePoint) ;;
    *) die "unsupported extension: $ext" ;;
  esac
done

mkdir -p "$OUTPUT_DIR"
runner_script=$(readlink -f "$0")
cp "$runner_script" "$OUTPUT_DIR/runner.sh"
runtime_parent=${TMPDIR:-/tmp}
ROOT=$(mktemp -d "${runtime_parent%/}/clickhouse-extension-bench.XXXXXXXX")
PID=''
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$ROOT"/{data,tmp,logs,config,user_files,format_schemas,access,caches}
cat >"$ROOT/users.xml" <<'EOF'
<clickhouse><profiles><default/></profiles><users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users><quotas><default/></quotas></clickhouse>
EOF

cat >"$ROOT/config.xml" <<EOF
<clickhouse><logger><level>error</level><log>$ROOT/logs/server.log</log><errorlog>$ROOT/logs/server.err.log</errorlog><console>false</console></logger><users_config>$ROOT/users.xml</users_config><path>$ROOT/data/</path><tmp_path>$ROOT/tmp/</tmp_path><user_files_path>$ROOT/user_files/</user_files_path><format_schema_path>$ROOT/format_schemas/</format_schema_path><access_control_path>$ROOT/access/</access_control_path><custom_cached_disks_base_directory>$ROOT/caches/</custom_cached_disks_base_directory><listen_host>127.0.0.1</listen_host><tcp_port>$PORT</tcp_port></clickhouse>
EOF

if command -v ss >/dev/null && ss -H -ltn | awk -v suffix=":$PORT" '$4 ~ suffix "$" { found=1 } END { exit !found }'; then
  die "TCP port is already in use: $PORT"
fi
if "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT 1' >/dev/null 2>&1; then
  die "TCP port already has a ClickHouse server: $PORT"
fi
"$CH_BINARY" server --config-file "$ROOT/config.xml" >"$ROOT/logs/server.stdout" 2>"$ROOT/logs/server.stderr" & PID=$!
for _ in $(seq 1 120); do
  kill -0 "$PID" 2>/dev/null || die "server exited; see $ROOT/logs/server.stderr"
  if "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT 1' >/dev/null 2>&1; then break; fi
  sleep 0.25
done
"$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT 1' >/dev/null 2>&1 || die "server did not become ready"

printf 'case_tag\textension\tn\tparameter\tmin_segment\trepetition\twarmup\texpected_result\tobserved_result\tclient_wall_seconds\tclient_user_seconds\tclient_system_seconds\tclient_max_rss_kb\tserver_vmrss_snapshot_before_kb\tserver_vmhwm_snapshot_before_kb\tserver_vmrss_snapshot_after_kb\tserver_vmhwm_snapshot_after_kb\texit_code\tstdout_sha256\tquery_id\n' >"$OUTPUT_DIR/results.tsv"
printf 'key\tvalue\n' >"$OUTPUT_DIR/metadata.tsv"
printf 'date_utc\t%s\n' "$(date -u +%FT%TZ)" >>"$OUTPUT_DIR/metadata.tsv"
printf 'binary\t%s\n' "$(readlink -f "$CH_BINARY")" >>"$OUTPUT_DIR/metadata.tsv"
printf 'binary_sha256\t%s\n' "$(sha256sum "$CH_BINARY" | awk '{print $1}')" >>"$OUTPUT_DIR/metadata.tsv"
printf 'runner_sha256\t%s\n' "$(sha256sum "$OUTPUT_DIR/runner.sh" | awk '{print $1}')" >>"$OUTPUT_DIR/metadata.tsv"
printf 'host\t%s\n' "$(hostname)" >>"$OUTPUT_DIR/metadata.tsv"
printf 'uname\t%s\n' "$(uname -srvm)" >>"$OUTPUT_DIR/metadata.tsv"
printf 'binary_version\t%s\n' "$("$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query 'SELECT version()' --format TSVRaw)" >>"$OUTPUT_DIR/metadata.tsv"
printf 'parameters\tn=%s regression_order=%s adf_order=%s kpss_q=%s min_segment=%s repetitions=%s warmup=%s\n' \
  "$N_VALUES" "$ORDER_VALUES" "$ADF_ORDER_VALUES" "$KPSS_Q_VALUES" "$MIN_SEGMENT_VALUES" "$REPETITIONS" "$WARMUP" >>"$OUTPUT_DIR/metadata.tsv"
if [[ -n "$CH_SOURCE_DIR" && -d "$CH_SOURCE_DIR/.git" ]]; then
  printf 'source_revision\t%s\n' "$(git -C "$CH_SOURCE_DIR" rev-parse HEAD)" >>"$OUTPUT_DIR/metadata.tsv"
  git -C "$CH_SOURCE_DIR" status --porcelain=v1 >"$OUTPUT_DIR/source-status.txt"
  printf 'source_status_porcelain_sha256\t%s\n' "$(sha256sum "$OUTPUT_DIR/source-status.txt" | awk '{print $1}')" >>"$OUTPUT_DIR/metadata.tsv"
fi

run_one() {
  local tag=$1 ext=$2 n=$3 parameter=$4 minseg=$5 rep=$6 warm=$7 expected=${8:-any}
  local query_id query out err rc wall user sys rss before_rss before_hwm after_rss after_hwm stdout_sha observed
  query_id="${tag}_${ext}_${n}_${parameter}_${minseg}_${rep}_${warm}"
  case "$ext" in
    timeSeriesLaggedLinearRegression) query="SELECT timeSeriesLaggedLinearRegression($parameter, $n)(toUInt64(number), sin(number / 10.0)) FROM numbers($n)" ;;
    timeSeriesADFStatistic) query="SELECT timeSeriesADFStatistic($parameter, 'constant', $n)(toUInt64(number), sin(number / 10.0)) FROM numbers($n)" ;;
    timeSeriesKPSSTest) query="SELECT timeSeriesKPSSTest('trend', $parameter, $n)(toUInt64(number), toFloat64(cityHash64(number) % 1000003)) FROM numbers($n)" ;;
    timeSeriesMeanShiftChangePoint) query="SELECT timeSeriesMeanShiftChangePoint($minseg, $n)(toUInt64(number), if(number < $((n / 2)), 0.0, 1.0)) FROM numbers($n)" ;;
    *) die "unsupported extension: $ext" ;;
  esac
  query+=" SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1"
  printf '%s\n' "$query" >"$OUTPUT_DIR/query_${query_id}.sql"
  before_rss=$(awk '/VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  before_hwm=$(awk '/VmHWM:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  out="$OUTPUT_DIR/stdout_${query_id}.tsv"
  err="$OUTPUT_DIR/stderr_${query_id}.txt"
  if command -v /usr/bin/time >/dev/null; then
    set +e; /usr/bin/time -f '%e\t%U\t%S\t%M' -o "$ROOT/time.txt" "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query "$query" --format TSVRaw >"$out" 2>"$err"; rc=$?; set -e
    if ! IFS=$'\t' read -r wall user sys rss < "$ROOT/time.txt"; then wall=NA; user=NA; sys=NA; rss=NA; fi
  else
    set +e; "$CH_BINARY" client --host 127.0.0.1 --port "$PORT" --query "$query" --format TSVRaw >"$out" 2>"$err"; rc=$?; set -e; wall=NA; user=NA; sys=NA; rss=NA
  fi
  after_rss=$(awk '/VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  after_hwm=$(awk '/VmHWM:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo NA)
  (( rc == 0 )) || die "query failed ($query_id); see $err"
  if grep -Eiq '(^|[^[:alpha:]])nan([^[:alpha:]]|$)' "$out"; then observed=nan; else observed=finite; fi
  [[ "$expected" == any || "$expected" == "$observed" ]] || die "query $query_id produced $observed; expected $expected"
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
# Required KPSS work-cap boundary (last admitted and first rejected) and native change-point scaling case.
for rep in $(seq 1 "$REPETITIONS"); do run_one kpss_workcap timeSeriesKPSSTest 97656 1024 1 "$rep" 0 finite; done
for rep in $(seq 1 "$REPETITIONS"); do run_one kpss_workcap timeSeriesKPSSTest 97657 1024 1 "$rep" 0 nan; done
for n in 10000 100000; do for rep in $(seq 1 "$REPETITIONS"); do run_one changepoint_scaling timeSeriesMeanShiftChangePoint "$n" 1 60 "$rep" 0 finite; done; done

stop_server
cp "$ROOT/logs/server.log" "$OUTPUT_DIR/server.log" 2>/dev/null || true
cp "$ROOT/logs/server.err.log" "$OUTPUT_DIR/server.err.log" 2>/dev/null || true
cp "$ROOT/logs/server.stderr" "$OUTPUT_DIR/server-process.stderr" 2>/dev/null || true
cp "$ROOT/logs/server.stdout" "$OUTPUT_DIR/server-process.stdout" 2>/dev/null || true
printf 'Server VmRSS/VmHWM are process-wide coarse snapshots (not per-query peaks; reset is impossible). End-to-end wall time waits for the server; client CPU/RSS accounting excludes server work. KPSS guard: q=1024,n=97656 admitted and n=97657 rejected. Change-point scaling: n=10000,100000.\n' >"$OUTPUT_DIR/analysis-boundary.txt"
(cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum) >"$OUTPUT_DIR/SHA256SUMS"
printf 'Wrote benchmark evidence to %s\n' "$OUTPUT_DIR"
