# D202 - `Std.Parallel`: a native worker pool and `forChunks`

**Status:** accepted, implemented (docs/67 phase G8, #7947); builds on D185 to D187

## Decision

1. **A fork-join pool in `lyric-rt`.** `lyric_parallel_for(count, body, userdata)` runs `body(i)`
   for every `i` in `[0, count)` across a pool of OS threads plus the calling thread and returns
   when every call has finished. Indices are claimed from an atomic counter, so uneven work
   balances. The pool is created on first use with `LYRIC_THREADS - 1` workers (default: the
   processor count; `1` means no pool, a serial loop; wasm32-wasi has no threads and is always
   serial). One loop runs at a time (a second caller on another thread waits), and a body that
   starts a loop runs it serially, so nesting cannot deadlock. A worker holds the job only between
   taking it and finishing its share, both under the pool mutex, and the caller waits for
   `done == count and no active worker` before returning, so no worker touches a finished job.
2. **`Std.Parallel`** (`threadCount`, `forRange`, `forChunks`) is the public surface on every
   target. The native kernel (`_kernel_native/parallel_host.l`) passes the loop body to the pool as
   a C callback with a trailing user-data slot (the closure itself, as `Std.Task` does for
   `lyric_thread_spawn_detached`). The managed kernels (`_kernel/`, `_kernel_jvm/`) run the loop in
   order on the calling thread: a correct implementation of the contract, which promises only that
   every body runs once and has finished on return. A program computes the same results on every
   target; only native is faster.
3. **`forChunks(inout b, chunkSize, body)`** splits a `buffer[T]` into disjoint chunks and hands
   `body(start, chunk)` a private copy of each chunk; the body returns the chunk's new contents
   (the same length, checked), and the results are copied back into `b` once every body has
   finished. The runtime owns the split, so chunks cannot overlap, and a body never sees `b`, so
   copy-on-write (D186) is never involved: no worker writes shared storage. This is docs/67 §4.4's
   "structured stdlib primitive whose disjointness only the runtime can guarantee".
   A body may read what it captured and must not mutate shared reference-typed state (a `List`, a
   `Map`); shared mutable state goes in a `protected type`, as everywhere.
4. **ThreadSanitizer.** `make -C lyric-rt test-tsan` runs the pool's unit tests with the pool
   compiled `-fsanitize=thread`. `scripts/ci/parallel-e2e.sh` also builds a Lyric driver program,
   marks every function of its LLVM IR `sanitize_thread` (clang adds no instrumentation for an
   `.ll` input by itself), links the runtime built from source with the sanitizer, and runs it at 2
   and 4 threads. Doing so found a real race: `lyric_monitor_held_by_me` (the reentrant monitor
   under every `protected type`) read the owner thread id without synchronisation. `owner` and
   `depth` are now atomics, with the owner written before the depth is released and the depth
   acquired before the owner is read.
5. **Scaling.** `benchmarks/bench_parallel.l` runs a heavy per-element kernel over a
   million-element buffer through `forChunks`; the script requires at least 1.5x on all cores
   against `LYRIC_THREADS=1` (2.9x on four cores locally; 191 ms against 65 ms).

## Not in this decision

- The `async` coroutine scheduler (`lyric_async.c`) is still single-threaded and cooperative:
  a coroutine frame does not migrate between threads, and `spawn` inside a `scope` still completes
  at the spawn site on native (D-N-021). Making tasks run on the pool needs thread-safe task
  state, ARC retains across suspend points on a migrating frame, and a work-stealing queue; it is
  tracked in the follow-up issue and is separable from the data-parallel primitive above.
- `forChunks` copies each chunk in and out (parallel, so it scales when the body does real work).
  A zero-copy window needs the buffer representation to carry a data pointer, because a
  `LyricBuffer` stores its elements inline after its header.
- The managed targets run in order; a pool for dotnet (`System.Threading.Tasks.Parallel`) and the
  JVM (`ForkJoinPool`) is a performance follow-up, not a semantic one.
