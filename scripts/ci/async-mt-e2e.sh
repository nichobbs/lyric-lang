#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# async-mt-e2e.sh: the multi-threaded native coroutine scheduler (docs/67 G8, D214).
#   - the scheduler's C unit tests, plain, under ThreadSanitizer and under AddressSanitizer
#     (`make -C lyric-rt test test-tsan test-asan-async`);
#   - a driver program (recursive fork-join, sleepers and await chains resumed on other threads)
#     compiled with ThreadSanitizer: the generated LLVM IR gets `sanitize_thread` on every function
#     (clang does not add it for an .ll input) and links the runtime built from source with
#     -fsanitize=thread, so a race in generated code or in the scheduler fails the run;
#   - the same driver as a plain build at LYRIC_ASYNC_THREADS = 1 (the cooperative default), 2, 4 and 8.
#
# `llvm_self_test_async_mt.l` (real programs under the multi-threaded scheduler and ASan) runs from
# `native-backend-self-tests.sh` with the other compiler-hosted native self-tests.
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/async-mt-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== lyric-rt async scheduler: unit tests, ThreadSanitizer, AddressSanitizer ==="
make -C lyric-rt test test-tsan test-asan-async

echo "=== driver program, plain, at several scheduler thread counts ==="
LYRIC_KEEP_LL=1 "$LYRIC_BIN" build --target native lyric-stdlib/tests/async_mt_tsan_main.l -o "$work/mt_main"
for threads in 1 2 4 8; do
  LYRIC_ASYNC_THREADS=$threads "$work/mt_main"
done

echo "=== driver program under ThreadSanitizer ==="
make -C lyric-rt BUILD=build-tsan-async CFLAGS="-O1 -g -std=c11 -Wall -Wextra -Werror -fPIC -fsanitize=thread" CC=clang build-tsan-async/lyric_rt.a
[ -f "$work/mt_main.ll" ] || { echo "::error::LYRIC_KEEP_LL left no IR at $work/mt_main.ll"; exit 1; }
sed -E 's/^(define .*\)) ?(#[0-9]+)? ?\{$/\1 \2 sanitize_thread {/' "$work/mt_main.ll" > "$work/mt_main.tsan.ll"
grep -q sanitize_thread "$work/mt_main.tsan.ll" || { echo "::error::no function was marked sanitize_thread"; exit 1; }
clang -O1 -g -fsanitize=thread -Wno-override-module "$work/mt_main.tsan.ll" lyric-rt/build-tsan-async/lyric_rt.a -lm -lpthread -ldl -o "$work/mt_main_tsan"
for threads in 2 4; do
  LYRIC_ASYNC_THREADS=$threads TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$work/mt_main_tsan"
done
echo "async multi-threaded scheduler e2e passed"
