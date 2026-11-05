# D403 - Per-thread work deques with stealing in the native async scheduler (#8493)

**Status:** accepted, implemented (docs/67 phase G8); builds on D217, which it amends only in where a
ready task is queued and which lock guards what. The ready-queue placement in D217 rule 4 is
superseded; rules 2, 3, 5 and 6 stand.

## Context

D217's multi-threaded scheduler (`LYRIC_ASYNC_THREADS=N`) kept every ready task in one FIFO queue
and every scheduler structure under one `lyric_mutex`. Each spawn, each await registration and each
completion took that lock, so fine-grained fork-join (recursive `fib`, where nearly every task does
no work of its own) serialised on it.

## Decision

1. **A deque per scheduler thread.** Every thread that makes a task ready in multi-threaded mode
   (the workers, a thread in `lyric_task_block_on`, a thread that spawns) gets a work deque on first
   use, guarded by its own small lock. A spawn, a woken waiter and an expired sleeper go on the
   deque of the thread that made them ready, so a wake runs where its data is warm. The owner takes
   the newest end; a thread with nothing of its own takes the oldest end of another thread's deque,
   starting at a pseudo-random victim. Up to 512 threads get a deque; a later thread uses the shared
   injection queue (the old FIFO, now under the scheduler lock).
2. **Fairness.** Every 61st take by an owner looks at the injection queue first and then takes the
   oldest end of its own deque, so a task at the bottom of a busy deque runs even when no thread is
   idle to steal it.
3. **Waiter lists are lock-free stacks.** A task's `waiters` field is an atomic stack. Completion
   swaps in a closed sentinel and makes what it took ready, oldest registration first (the #5082
   order is kept). A registration that finds the sentinel sends the waiter to a deque. Completion and
   await registration therefore take no scheduler lock; the two-phase registration of D217 rule 3 is
   unchanged, so a frame is never resumed before it has finished suspending.
4. **A spawn runs hot when every thread is busy.** A spawn is queued on the spawner's deque, as in
   D217, while that deque holds fewer than four tasks or some thread is idle or searching for work.
   Otherwise its body runs on the spawner until its first suspension, as it would under the
   cooperative scheduler: every thread already has work, the spawner's deque already has tasks for a
   thief to take, and queueing would add only a hand-off. Recursive fork-join then costs about as
   much per task as a plain call, and the oldest (largest) pending subproblems are what thieves take.
   A program whose spawned tasks can make progress only by running at the same time must therefore
   not rely on more than the queued ones starting, which is already true of the cooperative default.
5. **One count for deadlock detection.** `g_active` counts tasks that are ready or running, with a
   per-task `counted` flag. Every transition adds before it subtracts (a completion adds its woken
   waiters before it removes itself), so the count is never below the true number, and moving a task
   between ready and running needs no update. A ramp that runs inside a resumed task is not counted:
   the resumed task's own count covers its thread until the ramp returns, and the ramp's task is
   counted if it later becomes ready. A thread in `lyric_task_block_on` reports the existing deadlock
   panic only when the count is zero and no task sleeps; the thread that brings the count to zero
   wakes the idle threads so that check runs, where D217 could leave a `block_on` caller asleep
   instead of reporting the deadlock.
6. **Idle parking without lost wakeups.** A thread with nothing to take first searches the deques a
   few times, yielding (`lyric_thread_yield`, new in the runtime: `sched_yield`, `SwitchToThread`, a
   no-op on wasm32-wasi). It then stops searching, takes the scheduler lock, raises `g_idle`, checks
   every deque, the injection queue and its root once more, and waits on the condition variable. A
   thread that makes a task ready publishes it and then signals one parked thread, under the lock,
   only when no thread is searching (a searcher will find the task) and some thread is parked; the
   last searcher to find work passes the search on when more work is queued. A `block_on` caller
   marks its root task `joined` before it parks, and only the completion of a joined task wakes the
   parked threads. All of these use sequentially consistent operations on both sides, so one side
   always sees the other. A sleeper re-times the parked threads only when it becomes the earliest.
   The scheduler lock now guards only the injection queue, the sleeper list and idle parking.
7. **Evidence.** `lyric_async_mt_test.c` adds a steal-heavy case (three rounds of a recursive
   fork-join `fib(18)`, 8361 tasks each, checking that other threads ran spawned children and that
   every frame is destroyed exactly once), run plain, under ThreadSanitizer and under
   AddressSanitizer. `benchmarks/bench_async_tasks.l` measures fork-join `fib(25)` (242785 tasks),
   100000 empty spawns and 20 rounds of 1024 sleeping leaves woken together; `scripts/ci/async-mt-e2e.sh` prints tasks per second
   for each at `LYRIC_ASYNC_THREADS` 1, 2, 4 and all cores and fails when fork-join on all cores is
   slower than on one thread.

## Not in this decision

- The single-threaded default is unchanged: one FIFO queue, no lock, FIFO wake order.
- No language or code-generation change. `LyricTask` gains two fields at its end (`counted`,
  `joined`) and its `waiters` field became atomic; generated code never reads its fields, and only
  the runtime allocates it.
- Making the processor count the default thread count is #8492; blocking kernels that hold a
  scheduler thread are #8494.
