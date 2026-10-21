# `Std.Parallel`: a worker pool and `forChunks` on native (docs/67 G8, #7947, D202)

- `lyric-rt/src/lyric_parallel.c`: `lyric_parallel_for`, `lyric_parallel_threads` (pool, `LYRIC_THREADS`);
  `test/lyric_parallel_test.c` (each index once, publication of writes, nesting, concurrent callers) run
  plain, serial and under ThreadSanitizer (`make -C lyric-rt test test-tsan`).
- `Std.Parallel` (`lyric-stdlib/std/parallel.l`) with native, dotnet and JVM kernels; `parallel_tests.l`
  (10 tests) and `parallel_tsan_main.l`.
- `lyric_posix.c`: the protected-type monitor's `owner`/`depth` are atomics (a data race ThreadSanitizer found).
- `benchmarks/bench_parallel.l`; `scripts/ci/parallel-e2e.sh` (unit tests, native tests, ThreadSanitizer on
  the generated IR, scaling >= 1.5x), wired into `native-backend-self-tests.sh`.
- Docs: D202, docs/67, native/plan/06, book chapter 13, CLAUDE.md. Open: a multi-threaded coroutine
  scheduler for `async` tasks, zero-copy chunk windows, pools on the managed targets.
