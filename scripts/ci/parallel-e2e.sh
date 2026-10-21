#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# parallel-e2e.sh: Std.Parallel and the lyric-rt worker pool on the native backend (docs/67 G8).
#   - the pool's C unit tests, plain and under ThreadSanitizer (`make -C lyric-rt test test-tsan`);
#   - the Std.Parallel test module on --target native;
#   - a driver program that hammers forRange and forChunks, compiled with ThreadSanitizer: the
#     generated LLVM IR gets `sanitize_thread` on every function (clang does not add it for an
#     .ll input) and links the runtime built from source with -fsanitize=thread, so a race in
#     generated code, in lyric-rt or in the pool fails the run;
#   - scaling: `forChunks` over a million-element buffer must run at least 1.5x faster on all the
#     cores than on one (skipped on a single-core machine).
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/parallel-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== lyric-rt worker pool: unit tests and ThreadSanitizer ==="
make -C lyric-rt test test-tsan

echo "=== Std.Parallel tests (--target native) ==="
"$LYRIC_BIN" test --target native lyric-stdlib/tests/parallel_tests.l

echo "=== Std.Parallel under ThreadSanitizer ==="
make -C lyric-rt BUILD=build-tsan CFLAGS="-O1 -g -std=c11 -Wall -Wextra -Werror -fPIC -fsanitize=thread" build-tsan/lyric_rt.a
LYRIC_KEEP_LL=1 "$LYRIC_BIN" build --target native lyric-stdlib/tests/parallel_tsan_main.l -o "$work/tsan_main"
[ -f "$work/tsan_main.ll" ] || { echo "::error::LYRIC_KEEP_LL left no IR at $work/tsan_main.ll"; exit 1; }
sed -E 's/^(define .*\)) ?(#[0-9]+)? ?\{$/\1 \2 sanitize_thread {/' "$work/tsan_main.ll" > "$work/tsan_main.tsan.ll"
grep -q sanitize_thread "$work/tsan_main.tsan.ll" || { echo "::error::no function was marked sanitize_thread"; exit 1; }
clang -O1 -g -fsanitize=thread -Wno-override-module "$work/tsan_main.tsan.ll" lyric-rt/build-tsan/lyric_rt.a -lm -lpthread -ldl -o "$work/tsan_main_bin"
for threads in 2 4; do
  LYRIC_THREADS=$threads TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$work/tsan_main_bin"
done

cores="$(nproc)"
if [ "$cores" -lt 2 ]; then
  echo "=== scaling: skipped on a single-core machine ==="
  exit 0
fi
echo "=== scaling on $cores cores ==="
mean_ms() {
  LYRIC_THREADS="$1" "$LYRIC_BIN" bench --target native benchmarks/bench_parallel.l --runs 5 --warmup 1 2>&1 |
    python3 -I -c '
import re, sys
for line in sys.stdin:
    m = re.match(r"benchChunksParallel\b.*\bmean=([0-9.]+)(ms|s|µs|us)", line)
    if m:
        v = float(m.group(1)); u = m.group(2)
        print(v * {"s": 1000.0, "ms": 1.0, "µs": 0.001, "us": 0.001}[u]); sys.exit(0)
sys.exit("no benchChunksParallel result")
'
}
one="$(mean_ms 1)"
all="$(mean_ms "$cores")"
python3 -I - "$one" "$all" "$cores" <<'PY'
import sys
one, allc, cores = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
speedup = one / allc
need = min(1.5, cores * 0.6)
print("forChunks: %.1f ms on 1 thread, %.1f ms on %d threads: %.2fx (need %.2fx)" % (one, allc, cores, speedup, need))
if speedup < need:
    sys.exit("forChunks does not scale across cores")
PY
echo "Std.Parallel e2e passed"
