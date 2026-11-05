# Native async scheduler: per-thread deques with work stealing, and a task-throughput benchmark (#8493)

D372. The multi-threaded mode of `lyric-rt/src/lyric_async.c` (`LYRIC_ASYNC_THREADS=N`, D217) no
longer keeps every ready task in one queue under one lock:

- each scheduler thread owns a work deque; spawns, woken waiters and expired sleepers go on the
  deque of the thread that made them ready, the owner takes the newest end and idle threads steal
  the oldest end of another thread's deque; every 61st take reads the oldest end and the injection
  queue first, so nothing at the bottom of a busy deque starves;
- a task's waiters are a lock-free stack closed by its completion, so await registration and
  completion take no scheduler lock (the two-phase registration of D217 is unchanged);
- a spawn runs hot on the spawner, as under the cooperative scheduler, when every thread is busy and
  the spawner's deque already holds four tasks for thieves; otherwise it is queued as before;
- one `g_active` count of ready and running tasks replaces `g_running` for deadlock detection (a ramp
  inside a resumed task is covered by that task and not counted), and the thread that brings it to
  zero wakes idle `block_on` callers so a deadlock is reported instead of sleeping forever;
- idle threads search the deques, yielding, before they park; a thread that makes a task ready
  signals a parked thread only when nobody is searching, a completion wakes parked threads only when
  a `block_on` caller waits for that task, and parking re-checks after announcing itself, so no
  wakeup is lost. New runtime function `lyric_thread_yield` (POSIX `sched_yield`, Windows
  `SwitchToThread`, a no-op on wasm32-wasi).

Tests: `lyric_async_mt_test.c` gains a steal-heavy recursive fork-join case (`fib(18)`, three
rounds), run by `make -C lyric-rt test`, `test-tsan` and `test-asan-async`.
`benchmarks/bench_async_tasks.l` (fork-join `fib(25)`, 100000 empty spawns, 1024 sleeping leaves woken
together) runs from `scripts/ci/async-mt-e2e.sh` at `LYRIC_ASYNC_THREADS` 1, 2, 4 and all cores, prints tasks
per second, and fails if fork-join on all cores is slower than on one thread. The single-threaded
default and the generated code are unchanged.
