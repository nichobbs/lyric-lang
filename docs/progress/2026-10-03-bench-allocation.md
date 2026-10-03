# `lyric bench` reports allocation; Vec3 arithmetic allocates nothing on native (docs/67 G1)

`lyric bench` now prints the heap bytes each benchmark allocates per run and
runs on `--target native`. `benchmarks/bench_vec3.l` shows the docs/67 G1
exit criterion: `Vec3` arithmetic does not allocate on native.

## Stdlib

- **`Std.Bench.allocatedBytes(): Long`** (`@experimental`): the bytes the
  current thread has allocated on the heap. Kernel trio, one package
  `Std.BenchHost`:
  - `_kernel/bench_host.l`: `System.GC.GetAllocatedBytesForCurrentThread()`.
  - `_kernel_jvm/bench_host.l`:
    `com.sun.management.ThreadMXBean.getCurrentThreadAllocatedBytes()` on the
    bean `ManagementFactory.getThreadMXBean()` returns.
  - `_kernel_native/bench_host.l`: `lyric_rt_allocated_bytes()`.
- **`lyric_rt`**: `lyric_alloc`, the native backend's single allocation path,
  adds each request to a `_Thread_local` total that
  `lyric_rt_allocated_bytes()` returns; `lyric_rt_test.c` covers it.

## CLI

- The synthesised harness (`Lyric.BenchSynth`) runs each bench `--runs` more
  times, untimed, between two `allocatedBytes()` readings, so timing and
  allocation are measured separately, and prints
  `name  min=Xms  max=Xms  mean=Xms  alloc=NB/run`. It adds `import Std.Time`
  and `import Std.Bench` when the module lacks them.
- `--runs` must be at least 1 and `--warmup` at least 0; anything else is a
  usage error (exit 64) rather than a division by zero in the harness. The
  documented defaults are corrected to the real ones, 100 runs and 5 warmup
  runs.
- `--target native` builds the bench module with the native backend and runs
  the executable. `--target jvm`, documented as blocked on `Std.Time`
  (#3302), works and the stale note is removed.

## Results

`benchmarks/bench_vec3.l` (derived `+`/`-` on a `Float` record, scaling and a
dot product, an inline `array[8, Vec3]` integrated in place), bytes per run:

| bench | dotnet | JVM | native |
|---|---|---|---|
| `benchVec3AddSub` | 640096 | 480230 | 0 |
| `benchVec3ScaleDot` | 640064 | 480206 | 0 |
| `benchVec3ArrayIntegrate` | 256240 | 192286 | 0 |

## Tests

- `scripts/ci/bench-vec3-alloc.sh` (native CI lane) requires a result line
  with `alloc=0B/run` for every `@bench` in `bench_vec3.l`.
- `bench_alloc_self_test.l` (3 cases, dotnet, JVM and native): the counter is
  non-negative, never decreases and counts heap work.
- `lyric_rt_test.c`: `test_allocated_bytes`.
- `bench.yml` runs `bench_vec3.l` with the other suites.
- The existing `bench_numeric`, `bench_collections` and `bench_string` suites
  run unchanged with the new column.
