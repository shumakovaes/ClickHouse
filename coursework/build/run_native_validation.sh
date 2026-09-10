#!/usr/bin/env bash
# Start an isolated ClickHouse server and run the coursework smoke/SQL fixture.
set -Eeuo pipefail

CH_SOURCE_DIR="${CH_SOURCE_DIR:-$(pwd)}"
CH_BUILD_DIR="${CH_BUILD_DIR:-${CH_SOURCE_DIR}/tmp/coursework/build-lean}"
CH_BINARY="${CH_BINARY:-${CH_BUILD_DIR}/programs/clickhouse}"
CH_TEST_PATTERN="${CH_TEST_PATTERN:-05161_time_series_diagnostics}"
CH_VALIDATION_OUTPUT="${CH_VALIDATION_OUTPUT:-${CH_SOURCE_DIR}/coursework/reproduced/native-validation}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "${CH_SOURCE_DIR}/CMakeLists.txt" ]] || die "run from a ClickHouse checkout or set CH_SOURCE_DIR"
[[ -x "$CH_BINARY" ]] || die "ClickHouse binary is not executable: $CH_BINARY"
[[ -x "${CH_SOURCE_DIR}/tests/clickhouse-test" ]] || die "tests/clickhouse-test is unavailable"
[[ -f "${CH_SOURCE_DIR}/tests/config/config.d/clusters.xml" ]] || die "test cluster configuration is unavailable"

mkdir -p "$CH_VALIDATION_OUTPUT"
runtime_parent="${TMPDIR:-/tmp}"
runtime_root="$(mktemp -d "${runtime_parent%/}/clickhouse-coursework-validation.XXXXXXXX")"
server_pid=""

cleanup() {
    local wait_round
    set +e
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        "$CH_BINARY" client --host localhost --port 9000 --query 'SYSTEM SHUTDOWN' >/dev/null 2>&1
        for wait_round in $(seq 1 20); do
            kill -0 "$server_pid" 2>/dev/null || break
            sleep 0.25
        done
        kill "$server_pid" 2>/dev/null || true
    fi
    [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true
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
trap cleanup EXIT INT TERM

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

if "$CH_BINARY" client --host localhost --port 9000 --query 'SELECT 1' >/dev/null 2>&1; then
    die "port 9000 already has a ClickHouse server; stop it before isolated validation"
fi

"$CH_BINARY" local --multiquery --query \
    'SET enable_time_series_aggregate_functions = 1;
     SELECT round(timeSeriesAutocorrelation(2)(toUInt64(number), toFloat64(number)), 12),
            tupleElement(timeSeriesLjungBoxTest(2)(toUInt64(number), toFloat64(number)), 1),
            round(timeSeriesDurbinWatson()(toUInt64(number), toFloat64(number)), 12)
     FROM numbers(5)' \
    --format TSVRaw > "$CH_VALIDATION_OUTPUT/local-smoke.tsv"

"$CH_BINARY" server --config-file="$runtime_root/config/config.xml" \
    > "$CH_VALIDATION_OUTPUT/server-console.log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 60); do
    if "$CH_BINARY" client --host localhost --port 9000 --query 'SELECT 1' >/dev/null 2>&1; then
        ready=1
        break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 1
done
[[ "$ready" -eq 1 ]] || {
    tail -n 80 "$CH_VALIDATION_OUTPUT/server-console.log" >&2 || true
    die "isolated ClickHouse server did not become ready"
}

cd "$CH_SOURCE_DIR"
tests/clickhouse-test -q tests/queries \
    -b "$CH_BINARY" \
    --no-long --no-random-settings -j 1 \
    "$CH_TEST_PATTERN" 2>&1 | tee "$CH_VALIDATION_OUTPUT/functional-test.txt"
