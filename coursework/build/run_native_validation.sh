#!/usr/bin/env bash
# Start an isolated ClickHouse server and run the coursework smoke/SQL fixture.
set -Eeuo pipefail

CH_SOURCE_DIR="${CH_SOURCE_DIR:-$(pwd)}"
CH_BUILD_DIR="${CH_BUILD_DIR:-${CH_SOURCE_DIR}/tmp/coursework/build-lean}"
CH_BINARY="${CH_BINARY:-${CH_BUILD_DIR}/programs/clickhouse}"
CH_TEST_PATTERN="${CH_TEST_PATTERN:-^0516[1-4]_}"
CH_VALIDATION_OUTPUT="${CH_VALIDATION_OUTPUT:-${CH_SOURCE_DIR}/coursework/reproduced/native-validation}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "${CH_SOURCE_DIR}/CMakeLists.txt" ]] || die "run from a ClickHouse checkout or set CH_SOURCE_DIR"
[[ -x "$CH_BINARY" ]] || die "ClickHouse binary is not executable: $CH_BINARY"
[[ -x "${CH_SOURCE_DIR}/tests/clickhouse-test" ]] || die "tests/clickhouse-test is unavailable"
[[ -f "${CH_SOURCE_DIR}/tests/config/config.d/clusters.xml" ]] || die "test cluster configuration is unavailable"

[[ ! -e "$CH_VALIDATION_OUTPUT" || -z "$(find "$CH_VALIDATION_OUTPUT" -mindepth 1 -print -quit 2>/dev/null)" ]] \
    || die "CH_VALIDATION_OUTPUT must be a new or empty directory: $CH_VALIDATION_OUTPUT"
mkdir -p "$CH_VALIDATION_OUTPUT"
runner_script="$(readlink -f "$0")"
cp "$runner_script" "$CH_VALIDATION_OUTPUT/runner.sh"
runtime_parent="${TMPDIR:-/tmp}"
runtime_root="$(mktemp -d "${runtime_parent%/}/clickhouse-coursework-validation.XXXXXXXX")"
server_pid=""
cleaned=0

cleanup() {
    local wait_round
    (( cleaned == 0 )) || return 0
    cleaned=1
    set +e
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        # Signal only the isolated process we started. `SYSTEM SHUTDOWN` can
        # terminate the surrounding WSL job before the test runner propagates
        # its exit status and copies the evidence logs.
        kill -TERM "$server_pid" 2>/dev/null || true
        for wait_round in $(seq 1 20); do
            kill -0 "$server_pid" 2>/dev/null || break
            sleep 0.25
        done
        if kill -0 "$server_pid" 2>/dev/null; then
            kill -KILL "$server_pid" 2>/dev/null || true
        fi
    fi
    [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true
    server_pid=""
    cp "$runtime_root/logs/server.log" "$CH_VALIDATION_OUTPUT/server.log" 2>/dev/null || true
    cp "$runtime_root/logs/server.err.log" "$CH_VALIDATION_OUTPUT/server.err.log" 2>/dev/null || true
    case "$runtime_root" in
        "${runtime_parent%/}"/clickhouse-coursework-validation.*)
            rm -rf -- "$runtime_root"
            ;;
        *)
            printf 'refusing to remove unexpected temporary path: %s\n' "$runtime_root" >&2
            ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for fixture in 05161_time_series_diagnostics 05162_time_series_statistical_extensions \
    05163_time_series_statistical_extensions_distributed 05164_time_series_statistical_extensions_aggregating_merge_tree; do
    [[ -f "${CH_SOURCE_DIR}/tests/queries/0_stateless/${fixture}.sql" ]] || die "missing SQL fixture: ${fixture}.sql"
    [[ -f "${CH_SOURCE_DIR}/tests/queries/0_stateless/${fixture}.reference" ]] || die "missing SQL reference: ${fixture}.reference"
done

mkdir -p \
    "$runtime_root/config/config.d" \
    "$runtime_root/logs" \
    "$runtime_root/data" \
    "$runtime_root/tmp" \
    "$runtime_root/user_files" \
    "$runtime_root/format_schemas" \
    "$runtime_root/caches" \
    "$runtime_root/access"

ln -s "${CH_SOURCE_DIR}/programs/server/config.xml" "$runtime_root/config/config.xml"
ln -s "${CH_SOURCE_DIR}/programs/server/users.xml" "$runtime_root/config/users.xml"
ln -s "${CH_SOURCE_DIR}/tests/config/config.d/clusters.xml" "$runtime_root/config/config.d/clusters.xml"

cat > "$runtime_root/config/config.d/runtime.xml" <<EOF
<clickhouse>
    <http_port remove="remove"/>
    <mysql_port remove="remove"/>
    <postgresql_port remove="remove"/>
    <interserver_http_port remove="remove"/>
    <logger>
        <level>information</level>
        <log>${runtime_root}/logs/server.log</log>
        <errorlog>${runtime_root}/logs/server.err.log</errorlog>
        <console>false</console>
    </logger>
    <path>${runtime_root}/data/</path>
    <tmp_path>${runtime_root}/tmp/</tmp_path>
    <user_files_path>${runtime_root}/user_files/</user_files_path>
    <format_schema_path>${runtime_root}/format_schemas/</format_schema_path>
    <custom_cached_disks_base_directory>${runtime_root}/caches/</custom_cached_disks_base_directory>
    <user_directories>
        <local_directory>
            <path>${runtime_root}/access/</path>
        </local_directory>
    </user_directories>
</clickhouse>
EOF

if command -v ss >/dev/null && ss -H -ltn | awk '$4 ~ /:9000$/ { found=1 } END { exit !found }'; then
    die "port 9000 is already in use; stop its listener before isolated validation"
fi
if "$CH_BINARY" client --host localhost --port 9000 --query 'SELECT 1' >/dev/null 2>&1; then
    die "port 9000 already has a ClickHouse server; stop it before isolated validation"
fi

"$CH_BINARY" local --multiquery --query \
    "SET enable_time_series_aggregate_functions = 1;
     SELECT 'baseline', round(timeSeriesAutocorrelation(2)(toUInt64(number), toFloat64(number)), 12),
            tupleElement(timeSeriesLjungBoxTest(2)(toUInt64(number), toFloat64(number)), 1),
            round(timeSeriesDurbinWatson()(toUInt64(number), toFloat64(number)), 12)
     FROM numbers(5);
     SELECT 'lagged_regression', timeSeriesLaggedLinearRegression(1)(key, value)
     FROM values('key UInt64, value Float64', (0, 1.), (1, 2.), (2, 4.), (3, 8.), (4, 16.), (5, 32.));
     SELECT 'adf', timeSeriesADFStatistic(0, 'constant')(key, value)
     FROM values('key UInt64, value Float64', (0, 1.), (1, 1.5), (2, 1.2), (3, 1.8), (4, 1.4), (5, 2.), (6, 1.6), (7, 2.2));
     SELECT 'kpss', timeSeriesKPSSTest('level', 0)(toUInt64(number), toFloat64(number)) FROM numbers(5);
     SELECT 'mean_shift', timeSeriesMeanShiftChangePoint(2)(key, value)
     FROM values('key UInt64, value Float64', (0, 1.), (1, 1.), (2, 1.), (3, 5.), (4, 5.), (5, 5.))" \
    --format TSVRaw > "$CH_VALIDATION_OUTPUT/local-smoke.tsv"

"$CH_BINARY" server --config-file="$runtime_root/config/config.xml" \
    > "$CH_VALIDATION_OUTPUT/server-console.log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 60); do
    kill -0 "$server_pid" 2>/dev/null || break
    if "$CH_BINARY" client --host localhost --port 9000 --query 'SELECT 1' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
[[ "$ready" -eq 1 ]] || {
    tail -n 80 "$CH_VALIDATION_OUTPUT/server-console.log" >&2 || true
    die "isolated ClickHouse server did not become ready"
}

cd "$CH_SOURCE_DIR"
printf 'key\tvalue\n' >"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'started_utc\t%s\n' "$(date -u +%FT%TZ)" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'source_revision\t%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unknown)" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'source_branch\t%s\n' "$(git branch --show-current 2>/dev/null || true)" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
git status --porcelain=v1 >"$CH_VALIDATION_OUTPUT/source-status.txt" 2>/dev/null || true
printf 'source_status_sha256\t%s\n' "$(sha256sum "$CH_VALIDATION_OUTPUT/source-status.txt" | awk '{print $1}')" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'binary\t%s\n' "$(readlink -f "$CH_BINARY")" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'binary_sha256\t%s\n' "$(sha256sum "$CH_BINARY" | awk '{print $1}')" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'runner_sha256\t%s\n' "$(sha256sum "$CH_VALIDATION_OUTPUT/runner.sh" | awk '{print $1}')" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'binary_version\t%s\n' "$("$CH_BINARY" client --host localhost --port 9000 --query 'SELECT version()' --format TSVRaw)" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
printf 'test_pattern\t%s\n' "$CH_TEST_PATTERN" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"
if [[ -f "$CH_BUILD_DIR/CMakeCache.txt" ]]; then
    grep -E '^(CMAKE_BUILD_TYPE|ENABLE_TESTS|ENABLE_LIBRARIES):' "$CH_BUILD_DIR/CMakeCache.txt" >"$CH_VALIDATION_OUTPUT/cmake-cache-selection.txt" || true
fi

set +e
tests/clickhouse-test -q tests/queries \
    -b "$CH_BINARY" \
    --no-long --no-random-settings -j 1 \
    "$CH_TEST_PATTERN" 2>&1 | tee "$CH_VALIDATION_OUTPUT/functional-test.txt"
functional_rc=${PIPESTATUS[0]}
set -e
printf '%s\n' "$functional_rc" >"$CH_VALIDATION_OUTPUT/functional-exit-code.txt"
printf 'finished_utc\t%s\n' "$(date -u +%FT%TZ)" >>"$CH_VALIDATION_OUTPUT/metadata.tsv"

cleanup
trap - EXIT
(cd "$CH_VALIDATION_OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum) >"$CH_VALIDATION_OUTPUT/SHA256SUMS"
exit "$functional_rc"
