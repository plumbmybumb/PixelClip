#!/bin/sh
# Build core + tests with AddressSanitizer and UndefinedBehaviorSanitizer and run the suite.
# Usage: core/tests/run_asan.sh   (from anywhere; build dir: build/core-asan)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/core-asan"
GEN=""
command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
cmake -S "$ROOT/core" -B "$BUILD" $GEN -DCMAKE_BUILD_TYPE=Debug -DHCA_SANITIZE=ON -DHCA_BUILD_TOOLS=ON >/dev/null
cmake --build "$BUILD"
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
    ctest --test-dir "$BUILD" --output-on-failure
