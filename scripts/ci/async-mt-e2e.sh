#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# async-mt-e2e.sh: the multi-threaded native coroutine scheduler (docs/67 G8, D217).
#   - the scheduler's C unit tests, plain, under ThreadSanitizer and under AddressSanitizer
#     (`make -C lyric-rt test test-tsan test-asan-async`);
#   - a driver program (recursive fork-join, sleepers and await chains resumed on other threads)
#     compiled with ThreadSanitizer: the generated LLVM IR gets `sanitize_thread` on every function
#     (clang does not add it for an .ll input) and links the runtime built from source with
#     -fsanitize=thread, so a race in generated code or in the scheduler fails the run;
#   - the same driver as a plain build at LYRIC_ASYNC_THREADS = 1 (the cooperative default), 2, 4 and 8;
#   - task throughput (`benchmarks/bench_async_tasks.l`, #8493): tasks per second for fork-join `fib(25)`,
#     100k empty spawns and 1024 sleeping leaves woken together at LYRIC_ASYNC_THREADS = 1, 2, 4 and all cores, failing
#     when the fastest fork-join run on all cores is slower than the fastest on one thread.
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
cores="$(getconf _NPROCESSORS_ONLN)"
echo "=== task throughput (benchmarks/bench_async_tasks.l) ==="
bench_at() {
  LYRIC_ASYNC_THREADS="$1" "$LYRIC_BIN" bench --target native benchmarks/bench_async_tasks.l --runs 10 --warmup 2 2>&1 |
    tee "$work/bench_$1.txt"
}
for threads in $(printf "%s\n" 1 2 4 "$cores" | sort -nu); do
  bench_at "$threads" > /dev/null
done
python3 -I - "$work" "$cores" <<'PY'
import re, sys
work, cores = sys.argv[1], int(sys.argv[2])
# Tasks each bench runs (see the header of benchmarks/bench_async_tasks.l).
tasks = {"benchForkJoinFib": 242785, "benchSpawnEmpty": 110001, "benchFanIn": 61421}
scale = {"s": 1000.0, "ms": 1.0, "µs": 0.001, "us": 0.001}
def stat(threads, which):
    out = {}
    with open("%s/bench_%s.txt" % (work, threads), encoding="utf-8") as f:
        for line in f:
            m = re.match(r"(bench\w+)\b.*\b" + which + r"=([0-9.]+)(ms|s|µs|us)", line)
            if m and m.group(1) in tasks:
                out[m.group(1)] = float(m.group(2)) * scale[m.group(3)]
    missing = sorted(set(tasks) - set(out))
    if missing:
        sys.exit("bench_async_tasks: no %s for %s at %s threads" % (which, ", ".join(missing), threads))
    return out
counts = sorted({1, 2, 4, cores})
results = {t: stat(t, "mean") for t in counts}
fastest = {t: stat(t, "min") for t in counts}
for name in tasks:
    row = ", ".join("%d: %.0f tasks/s" % (t, tasks[name] / (results[t][name] / 1000.0)) for t in counts)
    print("%-17s %s" % (name, row))
if cores >= 2:
    # The gate compares the fastest of ten runs, which a busy CI host perturbs least.
    one, alln = fastest[1]["benchForkJoinFib"], fastest[cores]["benchForkJoinFib"]
    print("fork-join (fastest run): %.1f ms on 1 thread, %.1f ms on %d threads" % (one, alln, cores))
    if alln > one:
        sys.exit("fork-join fib(25) is slower on %d scheduler threads than on 1" % cores)
PY
echo "async multi-threaded scheduler e2e passed"
