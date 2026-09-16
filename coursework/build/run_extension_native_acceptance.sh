#!/usr/bin/env bash
# Collect a fresh, auditable Release acceptance ledger for the coursework
# extension.  This runner consumes an already-built checkout; it never builds
# targets and it refuses to use a non-empty output directory.
set -Eeuo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  run_extension_native_acceptance.sh --repo DIR --build DIR --output DIR [--gtest PATH] [--port PORT] [--http-port PORT]

The repository and build directories must already contain a configured Release
checkout/build. The optional GoogleTest path overrides target discovery. The
output directory must not exist or must be empty.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

REPO_ARG=''
BUILD_ARG=''
OUTPUT_ARG=''
GTEST_ARG=''
PORT_ARG="${CLICKHOUSE_ACCEPTANCE_PORT:-${CLICKHOUSE_PORT_TCP:-9000}}"
HTTP_PORT_ARG="${CLICKHOUSE_ACCEPTANCE_HTTP_PORT:-${CLICKHOUSE_PORT_HTTP:-}}"
while (($#)); do
    case "$1" in
        --repo|--repo-dir|-r)
            (($# >= 2)) || die "missing value for $1"
            REPO_ARG=$2
            shift 2
            ;;
        --build|--build-dir|-b)
            (($# >= 2)) || die "missing value for $1"
            BUILD_ARG=$2
            shift 2
            ;;
        --output|--output-dir|-o)
            (($# >= 2)) || die "missing value for $1"
            OUTPUT_ARG=$2
            shift 2
            ;;
        --gtest|--gtest-path|-g)
            (($# >= 2)) || die "missing value for $1"
            GTEST_ARG=$2
            shift 2
            ;;
        --port)
            (($# >= 2)) || die "missing value for $1"
            PORT_ARG=$2
            shift 2
            ;;
        --http-port)
            (($# >= 2)) || die "missing value for $1"
            HTTP_PORT_ARG=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$REPO_ARG" && -n "$BUILD_ARG" && -n "$OUTPUT_ARG" ]] || {
    usage
    die '--repo, --build, and --output are all required'
}
[[ "$PORT_ARG" =~ ^[0-9]+$ && "$PORT_ARG" -ge 1 && "$PORT_ARG" -le 65535 ]] || die "invalid server port: $PORT_ARG"
if [[ -z "$HTTP_PORT_ARG" ]]; then
    (( PORT_ARG < 65535 )) || die '--http-port is required when --port is 65535'
    HTTP_PORT_ARG=$((PORT_ARG + 1))
fi
[[ "$HTTP_PORT_ARG" =~ ^[0-9]+$ && "$HTTP_PORT_ARG" -ge 1 && "$HTTP_PORT_ARG" -le 65535 ]] || die "invalid HTTP port: $HTTP_PORT_ARG"
[[ "$HTTP_PORT_ARG" != "$PORT_ARG" ]] || die 'native and HTTP ports must differ'

# Accept paths copied from a Windows prompt when wslpath is available, while
# retaining ordinary POSIX paths.  realpath -m also handles a not-yet-created
# output path without changing the caller's requested location.
normalise_path() {
    local value=$1
    case "$value" in
        [A-Za-z]:[\\/]*|\\\\*)
            command -v wslpath >/dev/null 2>&1 || die "Windows path needs wslpath in WSL: $value"
            value=$(wslpath -u -- "$value")
            ;;
    esac
    realpath -m -- "$value"
}

REPO_DIR=$(normalise_path "$REPO_ARG")
BUILD_DIR=$(normalise_path "$BUILD_ARG")
OUTPUT_DIR=$(normalise_path "$OUTPUT_ARG")
[[ ! -L "$OUTPUT_ARG" && ! -L "$OUTPUT_DIR" ]] || die "refusing a symlink output path (would risk overwriting another evidence directory): $OUTPUT_ARG"

[[ -d "$REPO_DIR" && -f "$REPO_DIR/CMakeLists.txt" ]] || die "not a ClickHouse repository: $REPO_DIR"
[[ -d "$BUILD_DIR" && -f "$BUILD_DIR/CMakeCache.txt" ]] || die "build directory lacks CMakeCache.txt: $BUILD_DIR"
command -v git >/dev/null 2>&1 || die 'git is required to identify the source checkout'
command -v cmake >/dev/null 2>&1 || die 'cmake is required to inspect configured targets'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required for the evidence ledger'
command -v stat >/dev/null 2>&1 || die 'stat is required for binary identity'
command -v tee >/dev/null 2>&1 || die 'tee is required to preserve complete command logs'

git_root=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) || die "not a git checkout: $REPO_DIR"
git_root=$(realpath -e -- "$git_root")
[[ "$git_root" == "$REPO_DIR" ]] || die "--repo must name the git checkout root: $REPO_DIR"

CLICKHOUSE_BINARY="$BUILD_DIR/programs/clickhouse"
[[ -x "$CLICKHOUSE_BINARY" ]] || die "Release ClickHouse binary is not executable: $CLICKHOUSE_BINARY"

if [[ -n "$GTEST_ARG" ]]; then
    GTEST_BINARY=$(normalise_path "$GTEST_ARG")
    [[ -x "$GTEST_BINARY" ]] || die "requested --gtest binary is not executable: $GTEST_BINARY"
else
    GTEST_BINARY=''
    # Prefer the coursework target, retaining the legacy target as fallback.
    for candidate in \
        "$BUILD_DIR/src/unit_tests_time_series_diagnostics" \
        "$BUILD_DIR/unit_tests_time_series_diagnostics" \
        "$BUILD_DIR/programs/unit_tests_time_series_diagnostics" \
        "$BUILD_DIR/src/unit_tests_dbms" "$BUILD_DIR/unit_tests_dbms" "$BUILD_DIR/programs/unit_tests_dbms"; do
        if [[ -x "$candidate" ]]; then GTEST_BINARY=$candidate; break; fi
    done
    [[ -n "$GTEST_BINARY" ]] || die "no supported GoogleTest binary is executable below: $BUILD_DIR"
fi
GTEST_BINARY=$(realpath -e -- "$GTEST_BINARY")
GTEST_TARGET=${GTEST_BINARY##*/}

SQL_RUNNER="$REPO_DIR/tests/clickhouse-test"
[[ -f "$SQL_RUNNER" ]] || die "functional test runner is missing: $SQL_RUNNER"
[[ -f "$REPO_DIR/programs/server/config.xml" ]] || die "server config is missing: $REPO_DIR/programs/server/config.xml"
[[ -f "$REPO_DIR/programs/server/users.xml" ]] || die "server users config is missing: $REPO_DIR/programs/server/users.xml"
[[ -f "$REPO_DIR/tests/config/config.d/clusters.xml" ]] || die "test cluster configuration is missing"

cache_value() {
    local key=$1
    sed -n -E "s/^${key}:[^=]*=(.*)$/\1/p" "$BUILD_DIR/CMakeCache.txt" | tail -n 1
}

CMAKE_BUILD_TYPE=$(cache_value CMAKE_BUILD_TYPE)
[[ "${CMAKE_BUILD_TYPE^^}" == RELEASE ]] || die "build is not Release (CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-unset})"
CMAKE_GENERATOR=$(cache_value CMAKE_GENERATOR)
CMAKE_C_COMPILER=$(cache_value CMAKE_C_COMPILER)
CMAKE_CXX_COMPILER=$(cache_value CMAKE_CXX_COMPILER)
[[ -n "$CMAKE_C_COMPILER" && -x "$CMAKE_C_COMPILER" ]] || die "configured C compiler is unavailable: ${CMAKE_C_COMPILER:-unset}"
[[ -n "$CMAKE_CXX_COMPILER" && -x "$CMAKE_CXX_COMPILER" ]] || die "configured C++ compiler is unavailable: ${CMAKE_CXX_COMPILER:-unset}"

# Capture source identity before creating evidence below the checkout.  This
# avoids counting this new directory as part of the recorded pre-run status
# when callers place --output inside their checkout.
SOURCE_REVISION=$(git -C "$REPO_DIR" rev-parse HEAD)
SOURCE_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD || printf 'DETACHED')
SOURCE_STATUS=$(git -C "$REPO_DIR" status --porcelain=v1)
SOURCE_SUBMODULES=$(git -C "$REPO_DIR" submodule status --recursive 2>&1 || true)

if [[ -e "$OUTPUT_DIR" ]]; then
    [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || die "output path is not a real directory: $OUTPUT_DIR"
    [[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]] || die "output directory must be new or empty (refusing to overwrite): $OUTPUT_DIR"
else
    mkdir -p -- "$OUTPUT_DIR"
    [[ ! -L "$OUTPUT_DIR" ]] || die "output directory unexpectedly became a symlink: $OUTPUT_DIR"
fi

RUNNER_PATH=$(realpath -e -- "$0")
cp -- "$RUNNER_PATH" "$OUTPUT_DIR/runner.sh"
RUNNER_SHA256=$(sha256sum "$OUTPUT_DIR/runner.sh" | awk '{print $1}')
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
STARTED_UTC=$(date -u +%FT%TZ)
OVERALL_RC=0

printf 'kind\tname\tstatus\tcommand_exit_code\ttee_exit_code\texit_code\tstarted_utc\tfinished_utc\tduration_seconds\tlog\tdetails\n' >"$OUTPUT_DIR/ledger.tsv"
printf 'name\tcommand_exit_code\tstarted_utc\tfinished_utc\tduration_seconds\tlog\tcommand\n' >"$OUTPUT_DIR/commands.tsv"
printf 'key\tvalue\n' >"$OUTPUT_DIR/metadata.tsv"
MANIFEST_WRITTEN=0
MANIFEST_IN_PROGRESS=0

timestamp() {
    date -u +%FT%TZ
}

duration() {
    local start=$1 end=$2
    printf '%s' "$((end - start))"
}

record_command() {
    local name=$1 command_rc=$2 started=$3 finished=$4 elapsed=$5 log=$6 command_text=$7
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$command_rc" "$started" "$finished" "$elapsed" "$log" "$command_text" >>"$OUTPUT_DIR/commands.tsv"
}

record_ledger() {
    local kind=$1 name=$2 status=$3 command_rc=$4 tee_rc=$5 started=$6 finished=$7 elapsed=$8 log=$9 details=${10:-}
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$name" "$status" "$command_rc" "$tee_rc" "$((command_rc != 0 || tee_rc != 0 ? command_rc != 0 ? command_rc : tee_rc : 0))" \
        "$started" "$finished" "$elapsed" "$log" "$details" >>"$OUTPUT_DIR/ledger.tsv"
}

runtime_parent=${TMPDIR:-/tmp}
runtime_root=''
server_pid=''
server_cleaned=0
EVIDENCE_RC=0

rewrite_final_metadata_failure() {
    local metadata_tmp="$OUTPUT_DIR/.metadata.tsv.tmp.$$"
    [[ -f "$OUTPUT_DIR/metadata.tsv" ]] || return 0
    if awk -F '\t' '$1 != "finished_utc" && $1 != "overall_status" && $1 != "overall_exit_code"' \
        "$OUTPUT_DIR/metadata.tsv" >"$metadata_tmp" && {
        printf 'finished_utc\t%s\noverall_status\tFAIL\noverall_exit_code\t1\n' "$(timestamp)" >>"$metadata_tmp"
    } && mv -- "$metadata_tmp" "$OUTPUT_DIR/metadata.tsv"; then
        return 0
    fi
    rm -f -- "$metadata_tmp"
    return 1
}

emit_manifest() {
    local final_rc=$1 manifest_path=$2 final_status=FAIL
    (( final_rc == 0 )) && final_status=PASS
    {
        printf 'schema_version\t1\n'
        printf 'run_id\t%s\nrunner\trunner.sh\nrunner_sha256\t%s\n' "$RUN_ID" "$RUNNER_SHA256"
        printf 'repo\t%s\nbuild\t%s\noutput\t%s\n' "$REPO_DIR" "$BUILD_DIR" "$OUTPUT_DIR"
        printf 'source_revision\t%s\nsource_branch\t%s\n' "$SOURCE_REVISION" "$SOURCE_BRANCH"
        printf 'cmake_build_type\t%s\ncmake_generator\t%s\n' "$CMAKE_BUILD_TYPE" "${CMAKE_GENERATOR:-unset}"
        printf 'gtest_target\t%s\ngtest_binary\t%s\nserver_port\t%s\nserver_http_port\t%s\n' "$GTEST_TARGET" "$GTEST_BINARY" "$PORT_ARG" "$HTTP_PORT_ARG"
        printf 'clickhouse_binary_sha256\t%s\ngtest_binary_sha256\t%s\n' \
            "$(sha256sum "$CLICKHOUSE_BINARY" 2>/dev/null | awk '{print $1}' || printf unavailable)" \
            "$(sha256sum "$GTEST_BINARY" 2>/dev/null | awk '{print $1}' || printf unavailable)"
        printf 'expected_gtest_total\t38\nexpected_gtest_baseline\t15\nexpected_gtest_extension\t23\n'
        printf 'started_utc\t%s\nfinished_utc\t%s\nrun_status\t%s\nexit_code\t%s\n' \
            "$STARTED_UTC" "$(timestamp)" "$final_status" "$final_rc"
    } >"$manifest_path" 2>/dev/null
}

cleanup_server() {
    local wait_round server_log
    (( server_cleaned == 0 )) || return 0
    server_cleaned=1
    set +e
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        for wait_round in $(seq 1 20); do
            kill -0 "$server_pid" 2>/dev/null || break
            sleep 0.25
        done
        if kill -0 "$server_pid" 2>/dev/null; then kill -KILL "$server_pid" 2>/dev/null || true; fi
    fi
    [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true
    server_pid=''
    if [[ -n "$runtime_root" && -d "$runtime_root" && ! -L "$runtime_root" ]]; then
        if ! mkdir -p -- "$OUTPUT_DIR/config"; then
            printf 'error: unable to create required config evidence directory: %s\n' "$OUTPUT_DIR/config" >&2
            EVIDENCE_RC=1
        else
            if [[ ! -f "$runtime_root/config/config.xml" ]] || ! cp -L -- "$runtime_root/config/config.xml" "$OUTPUT_DIR/config/server-base.xml"; then
                printf 'error: unable to preserve required server base config evidence\n' >&2
                EVIDENCE_RC=1
            fi
            if [[ ! -f "$runtime_root/config/users.xml" ]] || ! cp -L -- "$runtime_root/config/users.xml" "$OUTPUT_DIR/config/users-base.xml"; then
                printf 'error: unable to preserve required users config evidence\n' >&2
                EVIDENCE_RC=1
            fi
            if [[ ! -f "$runtime_root/config/config.d/runtime.xml" ]] || ! cp -- "$runtime_root/config/config.d/runtime.xml" "$OUTPUT_DIR/config/server-runtime.xml"; then
                printf 'error: unable to preserve required runtime config evidence\n' >&2
                EVIDENCE_RC=1
            fi
            if [[ ! -f "$runtime_root/config/config.d/clusters.xml" ]] || ! cp -- "$runtime_root/config/config.d/clusters.xml" "$OUTPUT_DIR/config/clusters.xml"; then
                printf 'error: unable to preserve required cluster config evidence\n' >&2
                EVIDENCE_RC=1
            fi
            if [[ ! -f "$runtime_root/config/client.xml" ]] || ! cp -- "$runtime_root/config/client.xml" "$OUTPUT_DIR/config/client.xml"; then
                printf 'error: unable to preserve required client config evidence\n' >&2
                EVIDENCE_RC=1
            fi
        fi
        for server_log in server.log server.err.log server-console.log; do
            [[ -f "$runtime_root/logs/$server_log" ]] && cp -- "$runtime_root/logs/$server_log" "$OUTPUT_DIR/$server_log" || true
        done
        case "$runtime_root" in
            "${runtime_parent%/}"/clickhouse-coursework-acceptance.*) rm -rf -- "$runtime_root" ;;
            *) printf 'refusing to remove unexpected temporary path: %s\n' "$runtime_root" >&2 ;;
        esac
    fi
}

write_manifest() {
    local final_rc=$1 manifest_tmp sums_tmp
    (( EVIDENCE_RC != 0 )) && final_rc=1
    (( MANIFEST_IN_PROGRESS == 0 && MANIFEST_WRITTEN == 0 )) || return 0
    MANIFEST_IN_PROGRESS=1
    manifest_tmp="$OUTPUT_DIR/.manifest.tsv.tmp.$$"
    sums_tmp="$OUTPUT_DIR/.SHA256SUMS.tmp.$$"
    if emit_manifest "$final_rc" "$manifest_tmp" && [[ -f "$manifest_tmp" ]] && \
        mv -- "$manifest_tmp" "$OUTPUT_DIR/manifest.tsv"; then
        MANIFEST_WRITTEN=1
    else
        rm -f -- "$manifest_tmp"
        EVIDENCE_RC=1
        rewrite_final_metadata_failure || true
        MANIFEST_IN_PROGRESS=0
        return 1
    fi
    if (
        cd "$OUTPUT_DIR"
        find . -type f ! -name SHA256SUMS ! -name '.SHA256SUMS.tmp.*' -print0 | sort -z | xargs -0 -r sha256sum
    ) >"$sums_tmp" 2>/dev/null && mv -- "$sums_tmp" "$OUTPUT_DIR/SHA256SUMS"; then
        :
    else
        rm -f -- "$sums_tmp"
        printf 'error: unable to write complete SHA256SUMS\n' >&2
        EVIDENCE_RC=1
        rewrite_final_metadata_failure || true
        MANIFEST_WRITTEN=0
        if emit_manifest 1 "$manifest_tmp" && [[ -f "$manifest_tmp" ]] && \
            mv -- "$manifest_tmp" "$OUTPUT_DIR/manifest.tsv"; then
            MANIFEST_WRITTEN=1
        else
            rm -f -- "$manifest_tmp"
        fi
        MANIFEST_IN_PROGRESS=0
        return 1
    fi
    MANIFEST_IN_PROGRESS=0
}

finalize_on_exit() {
    local rc=$? final_status=FAIL
    trap - EXIT
    set +e
    cleanup_server || true
    (( EVIDENCE_RC != 0 )) && rc=1
    (( rc == 0 )) && final_status=PASS
    if (( MANIFEST_WRITTEN == 0 )); then
        printf 'finished_utc\t%s\noverall_status\t%s\noverall_exit_code\t%s\n' "$(timestamp)" "$final_status" "$rc" >>"$OUTPUT_DIR/metadata.tsv"
        write_manifest "$rc" || true
        (( EVIDENCE_RC != 0 )) && rc=1
    fi
    exit "$rc"
}
trap finalize_on_exit EXIT

write_toolchain_identity() {
    {
        printf 'captured_utc=%s\n' "$(timestamp)"
        printf 'host=%s\n' "$(hostname 2>/dev/null || printf unknown)"
        printf 'uname=%s\n' "$(uname -srvm 2>/dev/null || printf unknown)"
        printf 'wslpath=%s\n' "$(command -v wslpath 2>/dev/null || printf unavailable)"
        printf 'cmake_path=%s\n' "$(command -v cmake 2>/dev/null || printf unavailable)"
        cmake --version 2>&1 | head -n 1 || true
        printf 'cmake_generator=%s\n' "${CMAKE_GENERATOR:-unset}"
        printf 'configured_c_compiler=%s\n' "$CMAKE_C_COMPILER"
        "$CMAKE_C_COMPILER" --version 2>&1 | head -n 1 || true
        printf 'configured_cxx_compiler=%s\n' "$CMAKE_CXX_COMPILER"
        "$CMAKE_CXX_COMPILER" --version 2>&1 | head -n 1 || true
        printf 'ninja_path=%s\n' "$(command -v ninja 2>/dev/null || printf unavailable)"
        ninja --version 2>&1 || true
        printf 'ld_path=%s\n' "$(command -v ld.lld 2>/dev/null || command -v ld 2>/dev/null || printf unavailable)"
        ld.lld --version 2>&1 | head -n 1 || true
        printf 'git_path=%s\n' "$(command -v git 2>/dev/null || printf unavailable)"
        git --version 2>&1 || true
    } >"$OUTPUT_DIR/toolchain.txt"
}

write_toolchain_identity
printf 'run_id\t%s\n' "$RUN_ID" >>"$OUTPUT_DIR/metadata.tsv"
printf 'started_utc\t%s\n' "$STARTED_UTC" >>"$OUTPUT_DIR/metadata.tsv"
printf 'repo_arg\t%s\nrepo_dir\t%s\n' "$REPO_ARG" "$REPO_DIR" >>"$OUTPUT_DIR/metadata.tsv"
printf 'build_arg\t%s\nbuild_dir\t%s\n' "$BUILD_ARG" "$BUILD_DIR" >>"$OUTPUT_DIR/metadata.tsv"
printf 'output_arg\t%s\noutput_dir\t%s\n' "$OUTPUT_ARG" "$OUTPUT_DIR" >>"$OUTPUT_DIR/metadata.tsv"
printf 'source_revision\t%s\nsource_branch\t%s\n' "$SOURCE_REVISION" "$SOURCE_BRANCH" >>"$OUTPUT_DIR/metadata.tsv"
printf 'cmake_build_type\t%s\ncmake_generator\t%s\nenable_tests\t%s\nenable_libraries\t%s\n' \
    "$CMAKE_BUILD_TYPE" "${CMAKE_GENERATOR:-unset}" "$(cache_value ENABLE_TESTS)" "$(cache_value ENABLE_LIBRARIES)" >>"$OUTPUT_DIR/metadata.tsv"
printf 'clickhouse_binary\t%s\nclickhouse_binary_sha256\t%s\ngtest_target\t%s\ngtest_binary\t%s\ngtest_binary_sha256\t%s\nserver_port\t%s\nserver_http_port\t%s\nrunner\trunner.sh\nrunner_sha256\t%s\n' \
    "$(realpath -e -- "$CLICKHOUSE_BINARY")" "$(sha256sum "$CLICKHOUSE_BINARY" | awk '{print $1}')" \
    "$GTEST_TARGET" "$(realpath -e -- "$GTEST_BINARY")" "$(sha256sum "$GTEST_BINARY" | awk '{print $1}')" "$PORT_ARG" "$HTTP_PORT_ARG" "$RUNNER_SHA256" >>"$OUTPUT_DIR/metadata.tsv"
printf 'source_status_sha256\t%s\n' "$(printf '%s\n' "$SOURCE_STATUS" | sha256sum | awk '{print $1}')" >>"$OUTPUT_DIR/metadata.tsv"
printf 'submodules_status_sha256\t%s\n' "$(printf '%s\n' "$SOURCE_SUBMODULES" | sha256sum | awk '{print $1}')" >>"$OUTPUT_DIR/metadata.tsv"
printf 'ci_environment\t%s\n' "${CI:-unset}" >>"$OUTPUT_DIR/metadata.tsv"
printf '%s\n' "$SOURCE_STATUS" >"$OUTPUT_DIR/source-status.txt"
printf '%s\n' "$SOURCE_SUBMODULES" >"$OUTPUT_DIR/submodules-status.txt"
git -C "$REPO_DIR" diff --binary --full-index >"$OUTPUT_DIR/source-unstaged.patch"
git -C "$REPO_DIR" diff --cached --binary --full-index >"$OUTPUT_DIR/source-staged.patch"
printf '%s\n' "$(sha256sum "$BUILD_DIR/CMakeCache.txt" | awk '{print $1}')" >"$OUTPUT_DIR/cmake-cache.sha256"
printf '%s\n' "$(sha256sum "$CLICKHOUSE_BINARY" | awk '{print $1}')" >"$OUTPUT_DIR/clickhouse.sha256"
printf '%s\n' "$(sha256sum "$GTEST_BINARY" | awk '{print $1}')" >"$OUTPUT_DIR/gtest.sha256"
{
    printf 'clickhouse_path=%s\n' "$(realpath -e -- "$CLICKHOUSE_BINARY")"
    printf 'clickhouse_sha256=%s\n' "$(sha256sum "$CLICKHOUSE_BINARY" | awk '{print $1}')"
    "$CLICKHOUSE_BINARY" --version 2>&1 || true
    printf 'gtest_target=%s\n' "$GTEST_TARGET"
    printf 'gtest_path=%s\n' "$(realpath -e -- "$GTEST_BINARY")"
    printf 'gtest_sha256=%s\n' "$(sha256sum "$GTEST_BINARY" | awk '{print $1}')"
    printf 'gtest_size_bytes=%s\n' "$(stat -c '%s' "$GTEST_BINARY")"
} >"$OUTPUT_DIR/binary-identity.txt"
printf 'build_invocation\tnot-run (prebuilt targets are required)\nbuild_provenance\tconfigured Release build; no build command was executed\nserver_port\t%s\nserver_http_port\t%s\n' "$PORT_ARG" "$HTTP_PORT_ARG" >>"$OUTPUT_DIR/metadata.tsv"
printf 'key\tvalue\nselected_gtest_target\t%s\nselected_gtest_binary\t%s\nconfigured_build\t%s\nbuild_action\tnot-run\n' \
    "$GTEST_TARGET" "$GTEST_BINARY" "$BUILD_DIR" >"$OUTPUT_DIR/build-provenance.tsv"

TARGET_HELP_LOG='target-help.txt'
target_help_started=$(timestamp)
target_help_start=$(date +%s)
set +e
cmake --build "$BUILD_DIR" --target help >"$OUTPUT_DIR/$TARGET_HELP_LOG" 2>&1
target_help_rc=$?
set -e
target_help_finished=$(timestamp)
target_help_end=$(date +%s)
record_command target-help "$target_help_rc" "$target_help_started" "$target_help_finished" \
    "$(duration "$target_help_start" "$target_help_end")" "$TARGET_HELP_LOG" \
    "cmake --build $BUILD_DIR --target help"
(( target_help_rc == 0 )) || die "CMake target inspection failed; see $OUTPUT_DIR/$TARGET_HELP_LOG"
target_regex=$(printf '%s' "$GTEST_TARGET" | sed 's/[.[\(*^$+?{|\\]/\\&/g')
grep -Eq "(^|[[:space:]/])${target_regex}([[:space:]:]|$)" "$OUTPUT_DIR/$TARGET_HELP_LOG" || die "CMake target list does not contain selected GoogleTest target: $GTEST_TARGET"
grep -Eq '(^|[[:space:]/])clickhouse([[:space:]:]|$)' "$OUTPUT_DIR/$TARGET_HELP_LOG" || die "CMake target list does not contain clickhouse"

GTEST_FILTER='TimeSeriesDiagnosticsState.*:TimeSeriesStatisticalExtensionsState.*:TimeSeriesStatisticalExtensionsAggregate.*'
printf 'expected_total\t38\nexpected_baseline\t15\nexpected_extension\t23\nfilter\t%s\n' "$GTEST_FILTER" >"$OUTPUT_DIR/gtest-counts.tsv"

run_local_smoke() {
    local log='local-smoke.log' output='local-smoke.tsv' started finished start end elapsed command_rc tee_rc status
    started=$(timestamp); start=$(date +%s)
    set +e
    "$CLICKHOUSE_BINARY" local --multiquery --query \
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
        --format TSVRaw 2>&1 | tee "$OUTPUT_DIR/$log" >"$OUTPUT_DIR/$output"
    local -a pipeline_status=("${PIPESTATUS[@]}")
    set -e
    command_rc=${pipeline_status[0]:-125}; tee_rc=${pipeline_status[1]:-125}
    finished=$(timestamp); end=$(date +%s); elapsed=$(duration "$start" "$end")
    status=FAIL
    if (( command_rc == 0 && tee_rc == 0 )); then status=PASS; else OVERALL_RC=1; fi
    record_command local-smoke "$command_rc" "$started" "$finished" "$elapsed" "$log" 'clickhouse local --multiquery coursework smoke'
    record_ledger smoke local "$status" "$command_rc" "$tee_rc" "$started" "$finished" "$elapsed" "$log" 'isolated local smoke'
}

port_in_use() {
    local checked_port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn | awk -v port="$checked_port" '$4 ~ ":" port "$" { found=1 } END { exit !found }'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v port="$checked_port" '$4 ~ ":" port "$" { found=1 } END { exit !found }'
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$checked_port" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
sys.exit(0)
PY
    else
        return 2
    fi
}

start_server() {
    runtime_root=$(mktemp -d "${runtime_parent%/}/clickhouse-coursework-acceptance.XXXXXXXX")
    mkdir -p -- "$runtime_root/config/config.d" "$runtime_root/logs" "$runtime_root/data" "$runtime_root/tmp" \
        "$runtime_root/user_files" "$runtime_root/format_schemas" "$runtime_root/caches" "$runtime_root/access"
    ln -s "$REPO_DIR/programs/server/config.xml" "$runtime_root/config/config.xml"
    ln -s "$REPO_DIR/programs/server/users.xml" "$runtime_root/config/users.xml"
    sed "s#<port>9000</port>#<port>${PORT_ARG}</port>#g" "$REPO_DIR/tests/config/config.d/clusters.xml" >"$runtime_root/config/config.d/clusters.xml"
    cat >"$runtime_root/config/client.xml" <<EOF
<config>
    <host>127.0.0.1</host>
    <port>${PORT_ARG}</port>
</config>
EOF
    cat >"$runtime_root/config/config.d/runtime.xml" <<EOF
<clickhouse>
    <tcp_port>${PORT_ARG}</tcp_port>
    <http_port>${HTTP_PORT_ARG}</http_port>
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
    <user_directories><local_directory><path>${runtime_root}/access/</path></local_directory></user_directories>
</clickhouse>
EOF
    set +e
    port_in_use "$PORT_ARG"
    local port_rc=$?
    set -e
    (( port_rc == 0 )) && die "port ${PORT_ARG} is already in use; choose --port or stop its listener"
    (( port_rc == 2 )) && die 'cannot verify that the requested server port is free (need ss, netstat, or python3)'
    set +e
    port_in_use "$HTTP_PORT_ARG"
    local http_port_rc=$?
    set -e
    (( http_port_rc == 0 )) && die "HTTP port ${HTTP_PORT_ARG} is already in use; choose --http-port or stop its listener"
    (( http_port_rc == 2 )) && die 'cannot verify that the requested HTTP port is free (need ss, netstat, or python3)'
    if "$CLICKHOUSE_BINARY" client --host 127.0.0.1 --port "$PORT_ARG" --query 'SELECT 1 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1' >/dev/null 2>&1; then
        die "port ${PORT_ARG} already has a ClickHouse server; choose --port or stop it"
    fi
    "$CLICKHOUSE_BINARY" server --config-file="$runtime_root/config/config.xml" >"$runtime_root/logs/server-console.log" 2>&1 &
    server_pid=$!
    local ready=0
    for _ in $(seq 1 60); do
        kill -0 "$server_pid" 2>/dev/null || break
        if "$CLICKHOUSE_BINARY" client --host 127.0.0.1 --port "$PORT_ARG" --query 'SELECT 1 SETTINGS enable_time_series_aggregate_functions = 1, max_threads = 1' >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    if (( ready != 1 )); then
        tail -n 80 "$runtime_root/logs/server-console.log" >&2 || true
        die 'isolated ClickHouse server did not become ready'
    fi
    printf 'server_pid\t%s\nserver_port\t%s\nserver_http_port\t%s\nserver_config\tconfig/server-base.xml\nserver_runtime_config\tconfig/server-runtime.xml\nclient_config\tconfig/client.xml\ncluster_config\tconfig/clusters.xml\n' \
        "$server_pid" "$PORT_ARG" "$HTTP_PORT_ARG" >>"$OUTPUT_DIR/metadata.tsv"
}

run_gtest() {
    local log='gtest-focused.log' started finished start end elapsed command_rc tee_rc total passed baseline ext_state ext_aggregate ext_total status details
    started=$(timestamp)
    start=$(date +%s)
    set +e
    (cd "$REPO_DIR" && "$GTEST_BINARY" --gtest_color=no --gtest_filter="$GTEST_FILTER") 2>&1 | tee "$OUTPUT_DIR/$log"
    local -a pipeline_status=("${PIPESTATUS[@]}")
    set -e
    command_rc=${pipeline_status[0]:-125}
    tee_rc=${pipeline_status[1]:-125}
    finished=$(timestamp)
    end=$(date +%s)
    elapsed=$(duration "$start" "$end")
    # Parse canonical GoogleTest summary lines, not suite names or timing text.
    total=$(sed -nE 's/^\[==========\] Running ([0-9]+) tests from.*/\1/p' "$OUTPUT_DIR/$log" | tail -n 1 || true)
    passed=$(sed -nE 's/^\[  PASSED  \] ([0-9]+) tests\..*/\1/p' "$OUTPUT_DIR/$log" | tail -n 1 || true)
    baseline=$(sed -nE 's/^\[----------\] ([0-9]+) tests from TimeSeriesDiagnosticsState( .*)?$/\1/p' "$OUTPUT_DIR/$log" | tail -n 1 || true)
    ext_state=$(sed -nE 's/^\[----------\] ([0-9]+) tests from TimeSeriesStatisticalExtensionsState( .*)?$/\1/p' "$OUTPUT_DIR/$log" | tail -n 1 || true)
    ext_aggregate=$(sed -nE 's/^\[----------\] ([0-9]+) tests from TimeSeriesStatisticalExtensionsAggregate( .*)?$/\1/p' "$OUTPUT_DIR/$log" | tail -n 1 || true)
    ext_total=$(( ${ext_state:-0} + ${ext_aggregate:-0} ))
    printf 'observed_total\t%s\nobserved_passed\t%s\nobserved_baseline\t%s\nobserved_extension_state\t%s\nobserved_extension_aggregate\t%s\nobserved_extension\t%s\n' \
        "${total:-unset}" "${passed:-unset}" "${baseline:-unset}" "${ext_state:-unset}" "${ext_aggregate:-unset}" "$ext_total" >>"$OUTPUT_DIR/gtest-counts.tsv"
    status=FAIL
    details="expected_total=38 observed_total=${total:-unset}; expected_baseline=15 observed_baseline=${baseline:-unset}; expected_extension=23 observed_extension=$ext_total"
    if (( command_rc == 0 && tee_rc == 0 )) && [[ "$total" == 38 && "$passed" == 38 && "$baseline" == 15 && "$ext_total" == 23 ]]; then
        status=PASS
    else
        OVERALL_RC=1
    fi
    record_command focused-gtest "$command_rc" "$started" "$finished" "$elapsed" "$log" \
        "$GTEST_BINARY --gtest_color=no --gtest_filter=$GTEST_FILTER"
    record_ledger gtest focused "$status" "$command_rc" "$tee_rc" "$started" "$finished" "$elapsed" "$log" "$details"
}

run_sql_fixture() {
    local fixture=$1 log="sql/${1}.log" started finished start end elapsed command_rc tee_rc status
    mkdir -p -- "$OUTPUT_DIR/sql"
    started=$(timestamp)
    start=$(date +%s)
    set +e
    if [[ -x "$SQL_RUNNER" ]]; then
        (cd "$REPO_DIR" && CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT_TCP="$PORT_ARG" CLICKHOUSE_PORT_HTTP="$HTTP_PORT_ARG" CLICKHOUSE_CONFIG="$runtime_root/config/config.xml" CLICKHOUSE_CONFIG_CLIENT="$runtime_root/config/client.xml" "$SQL_RUNNER" -q tests/queries -b "$CLICKHOUSE_BINARY" --configserver "$runtime_root/config/config.xml" --configclient "$runtime_root/config/client.xml" --no-long --no-random-settings -j 1 "$fixture") 2>&1 | tee "$OUTPUT_DIR/$log"
    else
        (cd "$REPO_DIR" && CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT_TCP="$PORT_ARG" CLICKHOUSE_PORT_HTTP="$HTTP_PORT_ARG" CLICKHOUSE_CONFIG="$runtime_root/config/config.xml" CLICKHOUSE_CONFIG_CLIENT="$runtime_root/config/client.xml" bash "$SQL_RUNNER" -q tests/queries -b "$CLICKHOUSE_BINARY" --configserver "$runtime_root/config/config.xml" --configclient "$runtime_root/config/client.xml" --no-long --no-random-settings -j 1 "$fixture") 2>&1 | tee "$OUTPUT_DIR/$log"
    fi
    local -a pipeline_status=("${PIPESTATUS[@]}")
    set -e
    command_rc=${pipeline_status[0]:-125}
    tee_rc=${pipeline_status[1]:-125}
    finished=$(timestamp)
    end=$(date +%s)
    elapsed=$(duration "$start" "$end")
    status=FAIL
    if (( command_rc == 0 && tee_rc == 0 )); then
        status=PASS
    else
        OVERALL_RC=1
    fi
    record_command "sql-$fixture" "$command_rc" "$started" "$finished" "$elapsed" "$log" \
        "CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT_TCP=$PORT_ARG CLICKHOUSE_PORT_HTTP=$HTTP_PORT_ARG tests/clickhouse-test --configserver $runtime_root/config/config.xml --configclient $runtime_root/config/client.xml -q tests/queries -b $CLICKHOUSE_BINARY --no-long --no-random-settings -j 1 $fixture"
    record_ledger sql "$fixture" "$status" "$command_rc" "$tee_rc" "$started" "$finished" "$elapsed" "$log" 'one fixture per log; one isolated server; pipefail pipeline'
}

run_local_smoke
start_server
run_gtest
for fixture in \
    05161_time_series_diagnostics \
    05162_time_series_statistical_extensions \
    05163_time_series_statistical_extensions_distributed \
    05164_time_series_statistical_extensions_aggregating_merge_tree; do
    [[ -f "$REPO_DIR/tests/queries/0_stateless/${fixture}.sql" ]] || die "missing SQL fixture: $fixture.sql"
    [[ -f "$REPO_DIR/tests/queries/0_stateless/${fixture}.reference" ]] || die "missing SQL reference: $fixture.reference"
    run_sql_fixture "$fixture"
done

if (( OVERALL_RC == 0 )); then
    RUN_STATUS=PASS
else
    RUN_STATUS=FAIL
fi
printf 'run_status\t%s\n' "$RUN_STATUS" >>"$OUTPUT_DIR/gtest-counts.tsv"

# EXIT cleanup stops the server before writing the manifest and hashes. Since
# the output directory was required to be empty, these artifacts are unique to
# this run and cannot replace prior evidence.
exit "$OVERALL_RC"
