#!/usr/bin/env bash
# Resource-conscious ClickHouse build helper for WSL2 Ubuntu 24.04.
#
# This script deliberately performs no work unless an action is supplied.  In
# particular, package installation is opt-in via the `install` action.
set -Eeuo pipefail

CH_SOURCE_DIR="${CH_SOURCE_DIR:-/work/clickhouse}"
CH_BUILD_DIR="${CH_BUILD_DIR:-${CH_SOURCE_DIR}/build}"
CH_JOBS="${CH_JOBS:-1}"
CH_BUILD_LOG="${CH_BUILD_LOG:-${CH_BUILD_DIR}/build.log}"
CH_BUILD_TARGET="${CH_BUILD_TARGET:-clickhouse_aggregate_functions}"
CH_ENABLE_LIBRARIES="${CH_ENABLE_LIBRARIES:-OFF}"
CH_ENABLE_TESTS="${CH_ENABLE_TESTS:-OFF}"
CH_BUILD_TYPE="${CH_BUILD_TYPE:-Debug}"
CH_MIN_CLANG="${CH_MIN_CLANG:-21}"
CH_MIN_CMAKE="${CH_MIN_CMAKE:-3.25}"
CH_REPO_URL="${CH_REPO_URL:-https://github.com/ClickHouse/ClickHouse.git}"
# Set this to the branch or tag that contains the coursework patch. The
# upstream default branch does not contain these changes.
CH_REPO_REF="${CH_REPO_REF:-}"
CH_COPY_FROM="${CH_COPY_FROM:-}"
CH_TEST_PATTERN="${CH_TEST_PATTERN:-}"
CH_TEST_QUERY_DIR="${CH_TEST_QUERY_DIR:-}"
CH_ENV_FILE="${CH_ENV_FILE:-${CH_BUILD_DIR}/environment.txt}"
CH_CC="${CC:-clang-21}"
CH_CXX="${CXX:-clang++-21}"
CH_LD="${LD:-ld.lld-21}"
CH_AR="${AR:-llvm-ar-21}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "this action needs root; invoke WSL with: wsl -d Ubuntu -u root -- bash ..."
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (run the install action first)"
}

require_any_cmd() {
    local candidate
    for candidate in "$@"; do
        if command -v "$candidate" >/dev/null 2>&1; then return 0; fi
    done
    die "missing one of these commands: $*"
}

check_toolchain() {
    local compiler compiler_path c_compiler c_compiler_path version_line c_version_line major c_major
    local cmake_line cmake_version cmake_major cmake_minor min_cmake_major min_cmake_minor linker_path ar_path
    local linker_version ar_version linker_major ar_major
    require_cmd cmake
    require_cmd ninja
    cmake_line="$(cmake --version 2>&1 | head -1)"
    cmake_version="$(printf '%s\n' "$cmake_line" | sed -nE 's/.*version ([0-9]+\.[0-9]+).*/\1/p')"
    cmake_major="${cmake_version%%.*}"
    cmake_minor="${cmake_version##*.}"
    [[ "$cmake_major" =~ ^[0-9]+$ && "$cmake_minor" =~ ^[0-9]+$ ]] || die "cannot parse CMake version from: $cmake_line"
    min_cmake_major="${CH_MIN_CMAKE%%.*}"
    min_cmake_minor="${CH_MIN_CMAKE##*.}"
    [[ "$min_cmake_major" =~ ^[0-9]+$ && "$min_cmake_minor" =~ ^[0-9]+$ ]] || die "CH_MIN_CMAKE must be a major.minor version: $CH_MIN_CMAKE"
    if (( cmake_major < min_cmake_major || (cmake_major == min_cmake_major && cmake_minor < min_cmake_minor) )); then
        die "ClickHouse master requires CMake >= ${CH_MIN_CMAKE}; found ${cmake_line}"
    fi
    compiler="$CH_CXX"
    c_compiler="$CH_CC"
    compiler_path="$(command -v -- "$compiler" || true)"
    [[ -n "$compiler_path" ]] || die "CXX compiler not found: $compiler"
    c_compiler_path="$(command -v -- "$c_compiler" || true)"
    [[ -n "$c_compiler_path" ]] || die "CC compiler not found: $c_compiler"
    [[ "$(basename "$compiler_path")" == clang++* ]] || die "CXX must be Clang (expected clang++-21 or newer): $compiler_path"
    [[ "$(basename "$c_compiler_path")" == clang-* || "$(basename "$c_compiler_path")" == clang ]] || die "CC must be Clang (expected clang-21 or newer): $c_compiler_path"
    version_line="$($compiler_path --version 2>&1 | head -1)"
    major="$(printf '%s\n' "$version_line" | sed -nE 's/.*version ([0-9]+).*/\1/p')"
    if [[ -z "$major" ]]; then
        major="$($compiler_path -dumpversion 2>/dev/null | sed -nE 's/^([0-9]+).*/\1/p')"
    fi
    [[ "$major" =~ ^[0-9]+$ ]] || die "cannot parse compiler version from: $version_line"
    if (( major < CH_MIN_CLANG )); then
        die "ClickHouse master requires Clang >= ${CH_MIN_CLANG}; found ${version_line}. Ubuntu 24.04's default Clang 18 is too old."
    fi
    c_version_line="$($c_compiler_path --version 2>&1 | head -1)"
    c_major="$(printf '%s\n' "$c_version_line" | sed -nE 's/.*version ([0-9]+).*/\1/p')"
    [[ "$c_major" == "$major" ]] || die "CC and CXX must use the same Clang major; found $c_version_line and $version_line"
    linker_path="$(command -v -- "$CH_LD" || true)"
    [[ -n "$linker_path" ]] || die "missing LLD linker for Clang $major: $CH_LD"
    linker_version="$($linker_path --version 2>&1 | head -1)"
    linker_major="$(printf '%s\n' "$linker_version" | sed -nE 's/.*[^0-9]([0-9]+)\.[0-9]+.*/\1/p')"
    [[ "$linker_major" == "$major" ]] || die "LLD major must match Clang $major; found $linker_version"
    ar_path="$(command -v -- "$CH_AR" || true)"
    [[ -n "$ar_path" ]] || die "missing LLVM archiver for Clang $major: $CH_AR"
    ar_version="$($ar_path --version 2>&1 | head -1)"
    ar_major="$(printf '%s\n' "$ar_version" | sed -nE 's/.*version ([0-9]+)\..*/\1/p')"
    [[ "$ar_major" == "$major" ]] || die "LLVM archiver major must match Clang $major; found $ar_version"
    require_cmd objcopy
    require_cmd nm
    require_cmd strip
    note "Using C compiler: $c_compiler_path ($c_version_line)"
    note "Using C++ compiler: $compiler_path ($version_line)"
    note "Using linker: $linker_path; archiver: $ar_path"
}

source_root() {
    [[ -d "$CH_SOURCE_DIR" ]] || die "source directory does not exist: $CH_SOURCE_DIR"
    [[ -f "$CH_SOURCE_DIR/CMakeLists.txt" ]] || die "not a ClickHouse source tree: $CH_SOURCE_DIR"
}

sync_submodules() {
    require_cmd git
    source_root
    [[ -d "$CH_SOURCE_DIR/.git" || -f "$CH_SOURCE_DIR/.git" ]] || die "source is not a git checkout: $CH_SOURCE_DIR"
    note "Initializing all pinned ClickHouse submodules"
    git -C "$CH_SOURCE_DIR" submodule update --init --recursive
}

binary_path() {
    local binary="${CH_BUILD_DIR}/programs/clickhouse"
    [[ -x "$binary" ]] || die "built binary not found: $binary"
    printf '%s' "$binary"
}

install_deps() {
    require_cmd apt-get
    note "Installing the WSL build toolchain (explicit opt-in)"
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential cmake ninja-build clang-21 lld-21 llvm-21 git python3 perl pkg-config ccache nasm yasm \
        libssl-dev libicu-dev libreadline-dev libunwind-dev libzstd-dev liblz4-dev \
        libcurl4-openssl-dev libxml2-dev
}

clone_source() {
    local -a clone_args
    require_cmd git
    [[ ! -e "$CH_SOURCE_DIR" ]] || die "refusing to clone over existing path: $CH_SOURCE_DIR"
    mkdir -p "$(dirname "$CH_SOURCE_DIR")"
    note "Cloning into WSL ext4: $CH_SOURCE_DIR"
    clone_args=(--depth=1 --no-tags --recurse-submodules --shallow-submodules)
    if [[ -n "$CH_REPO_REF" ]]; then
        clone_args+=(--branch "$CH_REPO_REF")
        note "Using repository ref: $CH_REPO_REF"
    else
        note "Using the repository default branch; it must already contain the coursework patch"
    fi
    git clone "${clone_args[@]}" "$CH_REPO_URL" "$CH_SOURCE_DIR"
}

copy_source() {
    require_cmd cp
    [[ -n "$CH_COPY_FROM" ]] || die 'set CH_COPY_FROM to a Windows-mounted source tree'
    [[ -d "$CH_COPY_FROM" ]] || die "copy source does not exist: $CH_COPY_FROM"
    [[ ! -e "$CH_SOURCE_DIR" ]] || die "refusing to copy over existing path: $CH_SOURCE_DIR"
    mkdir -p "$(dirname "$CH_SOURCE_DIR")"
    note "Copying source from $CH_COPY_FROM to WSL ext4: $CH_SOURCE_DIR"
    mkdir "$CH_SOURCE_DIR"
    cp -a "$CH_COPY_FROM"/. "$CH_SOURCE_DIR"/
}

configure_build() {
    source_root
    check_toolchain
    mkdir -p "$CH_BUILD_DIR"
    note "Configuring target $CH_BUILD_TARGET (CMake >= 3.25 required)"
    cmake -S "$CH_SOURCE_DIR" -B "$CH_BUILD_DIR" -G Ninja \
        -DCMAKE_C_COMPILER="$CH_CC" \
        -DCMAKE_CXX_COMPILER="$CH_CXX" \
        -DCMAKE_LINKER="$CH_LD" \
        -DCMAKE_AR="$CH_AR" \
        -DCMAKE_BUILD_TYPE="$CH_BUILD_TYPE" \
        -DENABLE_TESTS="$CH_ENABLE_TESTS" \
        -DENABLE_BENCHMARKS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_THINLTO=OFF \
        -DENABLE_RUST=OFF \
        -DENABLE_XRAY=OFF \
        -DSPLIT_DEBUG_SYMBOLS=OFF \
        -DENABLE_LIBRARIES="$CH_ENABLE_LIBRARIES"
}

build_clickhouse() {
    source_root
    require_cmd cmake
    [[ "$CH_JOBS" =~ ^[1-9][0-9]*$ ]] || die "CH_JOBS must be a positive integer"
    [[ -f "$CH_BUILD_DIR/build.ninja" ]] || die "build is not configured: run configure first"
    mkdir -p "$(dirname "$CH_BUILD_LOG")"
    note "Building target $CH_BUILD_TARGET with $CH_JOBS job(s); log: $CH_BUILD_LOG"
    CMAKE_BUILD_PARALLEL_LEVEL="$CH_JOBS" cmake --build "$CH_BUILD_DIR" --target "$CH_BUILD_TARGET" 2>&1 | tee "$CH_BUILD_LOG"
}

smoke() {
    local binary
    binary="$(binary_path)"
    note "Running local SELECT 1 smoke test"
    "$binary" local --query 'SELECT 1'
}

focused_test() {
    local binary query_dir pattern
    source_root
    require_cmd python3
    binary="$(binary_path)"
    pattern="$CH_TEST_PATTERN"
    [[ -n "$pattern" ]] || die 'set CH_TEST_PATTERN to a test-name regex (for example: 00001_select_1)'
    if [[ -n "$CH_TEST_QUERY_DIR" ]]; then
        query_dir="$CH_TEST_QUERY_DIR"
    else
        query_dir="${CH_SOURCE_DIR}/tests/queries/0_stateless"
    fi
    [[ -d "$query_dir" ]] || die "query directory does not exist: $query_dir"
    note "Running one stateless functional-test pattern: $pattern"
    # One worker, no long tests, and no settings randomizer keep this usable
    # within the 7.6 GiB WSL memory limit. Do not pass --no-stateful here:
    # the focused diagnostics test creates an AggregatingMergeTree table and
    # is intentionally tagged stateful.
    python3 "$CH_SOURCE_DIR/tests/clickhouse-test" \
        --binary "$binary" \
        --queries "$query_dir" \
        --no-long --no-random-settings \
        --jobs 1 "$pattern"
}

capture_environment() {
    source_root
    mkdir -p "$(dirname "$CH_ENV_FILE")"
    note "Capturing environment in $CH_ENV_FILE"
    {
        date --iso-8601=seconds
        printf 'host: '; uname -a
        printf 'arch: '; uname -m
        printf 'cpus: '; getconf _NPROCESSORS_ONLN
        printf 'memory:\n'; free -h
        printf 'disk:\n'; df -h "$CH_SOURCE_DIR" "$CH_BUILD_DIR" 2>/dev/null || true
        printf 'source: '; git -C "$CH_SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null || true
        printf 'commit: '; git -C "$CH_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true
        printf 'status:\n'; git -C "$CH_SOURCE_DIR" status --short --branch 2>/dev/null || true
        printf 'cmake: '; cmake --version 2>/dev/null | head -1 || true
        printf 'ninja: '; ninja --version 2>/dev/null || true
        printf 'CC: %s; ' "$CH_CC"; "$CH_CC" --version 2>/dev/null | head -1 || true
        printf 'CXX: %s; ' "$CH_CXX"; "$CH_CXX" --version 2>/dev/null | head -1 || true
        printf 'LD: %s; AR: %s\n' "$CH_LD" "$CH_AR"
        printf 'python: '; python3 --version 2>/dev/null || true
        printf 'build-target: %s\n' "$CH_BUILD_TARGET"
        printf 'enable-libraries: %s\n' "$CH_ENABLE_LIBRARIES"
        printf 'enable-tests: %s\n' "$CH_ENABLE_TESTS"
        printf 'build-type: %s\n' "$CH_BUILD_TYPE"
        printf 'minimum-clang: %s\n' "$CH_MIN_CLANG"
        printf 'minimum-cmake: %s\n' "$CH_MIN_CMAKE"
    } | tee "$CH_ENV_FILE"
}

usage() {
    cat <<'EOF'
Usage: setup_wsl.sh ACTION

Actions:
  install    Install the opt-in apt toolchain (run as WSL root or with sudo)
  clone      Shallow-clone ClickHouse, including shallow submodules, to ext4
  copy       Copy CH_COPY_FROM (for example /mnt/c/.../ClickHouse) to ext4
  submodules Initialize/update all pinned submodules in an existing checkout
  configure  Configure Ninja Debug; default target is AggregateFunctions
  build      Build CH_BUILD_TARGET; defaults to clickhouse_aggregate_functions
  smoke      Run build/programs/clickhouse local --query 'SELECT 1'
  test       Run one stateless pattern from CH_TEST_PATTERN, serially
  capture    Save WSL/toolchain/git information to CH_ENV_FILE
  all        install, clone (or copy), configure, build, capture; smoke if binary exists

Environment overrides:
  CH_SOURCE_DIR, CH_BUILD_DIR, CH_BUILD_LOG, CH_JOBS, CH_BUILD_TARGET, CH_ENABLE_LIBRARIES,
  CH_ENABLE_TESTS, CH_BUILD_TYPE,
  CH_CC, CH_CXX, CH_LD, CH_AR,
  CH_MIN_CLANG, CH_MIN_CMAKE, CH_REPO_URL, CH_REPO_REF, CH_COPY_FROM, CH_TEST_PATTERN, CH_TEST_QUERY_DIR,
  CH_ENV_FILE
EOF
}

action="${1:-help}"
case "$action" in
    install) install_deps ;;
    clone) clone_source ;;
    copy) copy_source ;;
    submodules) sync_submodules ;;
    configure) configure_build ;;
    build) build_clickhouse ;;
    smoke) smoke ;;
    test) focused_test ;;
    capture) capture_environment ;;
    all)
        install_deps
        if [[ -n "$CH_COPY_FROM" ]]; then copy_source; else clone_source; fi
        configure_build
        build_clickhouse
        capture_environment
        if [[ -x "${CH_BUILD_DIR}/programs/clickhouse" ]]; then smoke; else note "Skipping smoke: target $CH_BUILD_TARGET does not produce programs/clickhouse"; fi
        ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "unknown action: $action" ;;
esac
