# ClickHouse on WSL2: low-memory build helper

> Historical-evidence note: the native validation and benchmark commands in
> this guide document the archived three-API coursework baseline. They are not
> extension validation; preserve their commands and results as baseline
> reproduction material.

This directory contains a helper for the available Windows host: WSL2 Ubuntu
24.04.3, about 7.6 GiB of WSL memory and 2 GiB of swap. It does not modify a
ClickHouse checkout until you explicitly run one of its actions. Package
installation is also opt-in.

Current ClickHouse master requires CMake **3.25 or newer**, Clang **21 or
newer**, and LLVM's LLD linker. Ubuntu 24.04's CMake 3.28 is suitable, but
its stock `clang`/`clang++` is normally Clang 18 and will be rejected by
master. The helper uses the explicitly versioned `clang-21`, `clang++-21`,
`ld.lld-21`, and `llvm-ar-21` commands by default. Select an approved
Clang/LLVM 21+ toolchain before `configure` with `CC`, `CXX`, `LD`, and `AR`
if needed. The C and C++ compilers must report the same Clang major version;
`objcopy`, `nm`, and `strip` must also be on `PATH`.

## Why WSL ext4

ClickHouse is a Linux project and native Windows does not currently have the
required CMake/Ninja/Clang environment. Keep both the source and the build
directory in WSL's Linux filesystem (for example `/work/clickhouse`), not under
`/mnt/c`; the latter is substantially slower for a large C++ tree. The helper
can clone directly into ext4, or copy an existing Windows checkout there once.
Do not run two builds concurrently. The plain upstream default branch does not
contain the coursework patch; a successful clone therefore requires either a
repository/ref that contains this branch or a copy of the already-patched
checkout.

The upstream tree carries many pinned dependencies in `.gitmodules`. CMake
explicitly checks for `contrib/sysroot/README.md`, and a partial checkout can
fail later when compiling. The `clone` action uses
`--recurse-submodules --shallow-submodules`; after copying a Windows checkout,
initialize the same dependency graph explicitly:

```bash
bash build/setup_wsl.sh submodules
git -C /work/clickhouse submodule status --recursive
test -f /work/clickhouse/contrib/sysroot/README.md
```

From PowerShell, check that WSL starts before doing any setup:

```powershell
wsl -l -v
wsl -d Ubuntu -u root -- /bin/echo WSL-ok
```

If WSL or Docker Desktop is stuck, restart that runtime first. Docker is not
required for the source build or local smoke test; it is only useful for a
separate prebuilt-server integration check.

## One-time setup and build

Run these commands from the coursework package root in WSL (the directory that
contains `build/`). The default source path is `/work/clickhouse` and the
default build path is `/work/clickhouse/build`:

```bash
bash build/setup_wsl.sh install
# Recommended once the branch is available on the personal fork:
CH_REPO_URL=https://github.com/<account>/ClickHouse.git \
CH_REPO_REF=coursework/mergeable-time-series-statistics \
bash build/setup_wsl.sh clone
bash build/setup_wsl.sh configure  # requires Clang >= 21
bash build/setup_wsl.sh build
bash build/setup_wsl.sh capture
```

`CH_REPO_REF` is optional but should be set when cloning a fork or other
remote that carries the implementation. The helper passes it to
`git clone --branch`, so it may name a branch or tag. Do not use the unqualified upstream
default branch for this coursework: it is a pristine ClickHouse tree and does
not include the diagnostics aggregates. If the fork is not available yet, use
the patched checkout copy workflow below instead.

`install` invokes `apt-get` with this intentionally small toolchain, including
the versioned `clang-21`, `lld-21`, and `llvm-21` packages, plus the common
SSL/ICU/readline/unwind/compression/XML/Curl headers and the NASM/Yasm
assemblers required by ClickHouse's pinned dependencies. Configure the approved
LLVM package source or toolchain image first if those packages are not
available in the Ubuntu 24.04 repositories. Run it as root if sudo is not
configured:

```powershell
wsl -d Ubuntu -u root -- bash -lc \
  "cd /mnt/c/Users/79261/Documents/Codex/2026-09-10/re/outputs/ClickHouse/coursework && bash build/setup_wsl.sh install"
```

If a checkout already exists on Windows, use a one-time copy instead of clone;
this is the recommended reproducible path until the personal fork branch is
published. Copy the checkout that contains the coursework changes, not a fresh
upstream clone. The destination must not already exist; this prevents accidental
overlay of source or build files:

```bash
export CH_COPY_FROM=/mnt/c/path/to/ClickHouse
export CH_SOURCE_DIR=/work/clickhouse
bash build/setup_wsl.sh copy
bash build/setup_wsl.sh submodules
```

For an existing checkout in WSL, skip `clone`/`copy`, set `CH_SOURCE_DIR` and
use `configure` directly.

## Memory-conscious validation

The default configuration is a low-memory Debug build, disables tests,
examples, benchmarks, ThinLTO, Rust, XRay, split debug symbols, and optional
external libraries, and builds only the
`clickhouse_aggregate_functions` library target. This target is defined by
`src/AggregateFunctions/CMakeLists.txt` and is the right compile check for
changes in that directory without linking the full server. `CH_JOBS` defaults
to **1**; with
7.6 GiB available, try `CH_JOBS=2` only after a successful serial build:

```bash
CH_JOBS=1 bash build/setup_wsl.sh build
```

`CH_JOBS` is passed to CMake through `CMAKE_BUILD_PARALLEL_LEVEL`; the helper
does not add a generator-specific `-j` or `--parallel` option. Build output is
streamed to the terminal and replaced on each run in `CH_BUILD_LOG` (by
default `/work/clickhouse/build/build.log`).

The smoke test does not start a server:

```bash
bash build/setup_wsl.sh smoke
# expected output: 1
```

The AggregateFunctions target does not produce `programs/clickhouse`; run the
smoke test only after explicitly building the unified binary:

```bash
CH_BUILD_TARGET=clickhouse CH_ENABLE_LIBRARIES=OFF bash build/setup_wsl.sh configure
CH_BUILD_TARGET=clickhouse CH_ENABLE_LIBRARIES=OFF bash build/setup_wsl.sh build
bash build/setup_wsl.sh smoke
```

Use `CH_ENABLE_LIBRARIES=ON` for a full-featured binary, with materially more
compile time, disk, and memory use.

The lower-level state GoogleTest is part of `unit_tests_dbms`. Configure a
separate test-enabled build directory so it does not invalidate the lean
production build, then build and filter it serially:

```bash
CH_BUILD_DIR=/work/clickhouse/build-tests CH_ENABLE_TESTS=ON \
  CH_BUILD_TARGET=unit_tests_dbms bash build/setup_wsl.sh configure
CH_BUILD_DIR=/work/clickhouse/build-tests CH_ENABLE_TESTS=ON \
  CH_BUILD_TARGET=unit_tests_dbms CH_JOBS=1 bash build/setup_wsl.sh build
/work/clickhouse/build-tests/src/unit_tests_dbms \
  --gtest_filter='TimeSeriesDiagnosticsState.*'
```

For a focused functional test against an already-running ClickHouse test
server, pass the test-name regex. The harness is restricted to one worker,
excludes long tests, and disables settings randomization. It deliberately
permits stateful tests because the diagnostics fixture exercises
`AggregatingMergeTree` state persistence:

```bash
CH_TEST_PATTERN='05161_time_series_diagnostics' bash build/setup_wsl.sh test
```

Use the pattern accepted by `tests/clickhouse-test`; it is a regex and can
match more than one case. Keep the pattern narrow. The helper never enables
`--record`, so it will not rewrite reference files.

For a self-contained run from the ClickHouse repository root, the companion
runner creates a guarded temporary configuration, starts an isolated server,
executes a seven-function local smoke and the focused SQL/Distributed tests, then
shuts the server down:

```bash
CH_BUILD_DIR="$PWD/build" bash coursework/build/run_native_validation.sh
```

`capture` writes a compact record of kernel, CPU/memory/disk, tool versions,
checkout commit, and working-tree status to `CH_ENV_FILE` (by default
`build/environment.txt`). Attach this file to build reports when diagnosing
resource or toolchain failures.

## Expected limits

ClickHouse is a large C++ build. First configure and compile can take a long
time and may need serial execution. An OOM during compilation is a resource
failure, not evidence of a source failure: keep `CH_JOBS=1`, ensure WSL swap is
available, and retry. Avoid a full `tests/clickhouse-test` run on this VM;
execute only the changed test pattern. Docker Desktop being stopped does not
block the WSL build.
