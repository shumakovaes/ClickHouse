# Standalone C++ comparison validation

This directory records reproducible validation of the quarantined,
dependency-free comparison program in
`comparison/standalone_cpp/standalone.cpp`. It is not validation of the
ClickHouse aggregate-function integration. No generated binaries are included.

## Source and environment

- Source SHA-256: `5c88f938471530c5bec76a91452186da82bcf574f183fcf1b6db05a80dae52cb`
- Environment: Ubuntu WSL
- Compiler: `Ubuntu clang version 21.1.8 (++20251221032922+2078da43e25a-1~exp1~20251221153059.70)`
- Working directory used by the recorded commands:
  `/mnt/c/Users/79261/Documents/Codex/2026-09-10/re/work/standalone_cpp`

## Optimized warning-clean run

Command:

```sh
clang++-21 -std=c++23 -O2 -Wall -Wextra -Werror standalone.cpp -o /tmp/standalone_tests
/tmp/standalone_tests
rm -f /tmp/standalone_tests
```

Observed output:

```text
PASS: 1764 checks
Covered: ACF, Ljung-Box, Durbin-Watson, AR(1), KPSS, random merge trees, key validation, duplicates, round-trips
```

Exit status: `0`.

## AddressSanitizer and UndefinedBehaviorSanitizer run

Command:

```sh
clang++-21 -std=c++23 -O1 -g -fsanitize=address,undefined \
  -fno-omit-frame-pointer -Wall -Wextra -Werror \
  standalone.cpp -o /tmp/standalone_tests_san
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
  /tmp/standalone_tests_san
rm -f /tmp/standalone_tests_san
```

Observed output:

```text
PASS: 1764 checks
Covered: ACF, Ljung-Box, Durbin-Watson, AR(1), KPSS, random merge trees, key validation, duplicates, round-trips
```

Exit status: `0`. No AddressSanitizer or UndefinedBehaviorSanitizer finding
was emitted, and leak detection was enabled.

## Revalidation during the report update

On 2026-09-18 both builds were repeated against the source file with the same
SHA-256 shown above. The optimized run and the ASan/UBSan run again reported
`PASS: 1764 checks` with the same coverage line; the sanitizer run emitted no
finding. The temporary binaries were not retained.

These runs cover the comparison prototype's ACF, Ljung--Box, Durbin--Watson,
AR(1), and KPSS calculations, randomized merge trees, key validation,
duplicate/gap checks, and serialization round-trips. The production keyed
ClickHouse state has a separate native build and functional-test record.
