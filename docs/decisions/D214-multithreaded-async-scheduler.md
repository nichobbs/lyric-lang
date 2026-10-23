# D214 - A multi-threaded scheduler for native `async` tasks

**Status:** accepted, implemented (docs/67 phase G8, #7947; phase 2 of `native/plan/06-async-design.md`); builds on D-N-021, D-N-022 and D202

## Decision

1. **Opt in with `LYRIC_ASYNC_THREADS=N`, default cooperative.** The scheduler in
   `lyric-rt/src/lyric_async.c` runs in one of two modes, chosen once per process on the first
   scheduler call. Unset or `1` (and always on wasm32-wasi): the pre-D214 cooperative,
   single-threaded, hot-task scheduler, with no lock ever taken and the same behaviour as before.
   `N >= 2` (capped at 256): `N - 1` detached worker threads plus every thread blocked in
   `lyric_task_block_on` run ready coroutines from one shared FIFO queue. The default stays
   cooperative because a task that shares a plain `List`, `Map` or record `var` with another task
   is correct only when the two never run at once, and no compile-time check for that exists yet
   (see "Not in this decision"). The processor count is deliberately not the default for the same
   reason that `LYRIC_THREADS` is documented to ignore cgroup quotas: the program, not the runtime,
   knows whether its tasks are thread-safe.
2. **`spawn` starts the task on a worker; a plain call stays hot.** A `spawn` call site raises a
   thread-local hint (`lyric_spawn_hint`) just before the call. Every coroutine prologue calls
   `lyric_task_defer_start` after `lyric_task_new`; when the scheduler is multi-threaded and the hint
   was set it queues the task and the prologue takes a first suspend point, so the whole body runs on
   whichever thread dequeues it, in parallel with the spawner. An awaited call (no hint) is unchanged:
   the body runs on the caller until its first genuine suspension. With one scheduler thread both
   functions return immediately and nothing changes.
3. **Registration is two-phase.** LLVM stores a coroutine's resume index at the suspend point,
   after the call to `lyric_async_await` / `lyric_async_sleep` / the deferred-start park. If that
   call published the task to the shared queues at once, another thread could resume the frame while
   the suspending thread was still writing it. In multi-threaded mode the call only records the intent
   (`park_kind`, `park_dep`) and a thread-local pointer; the thread publishes it (`settle_pending`)
   once the coroutine function has returned: after the resume in `run_one`, after the ramp
   (`lyric_ramp_done`, emitted after every async call), or at the next scheduler entry on that
   thread. Publishing under the lock re-checks the dependency, so an await whose dependency finished
   between the codegen's `is_complete` test and the suspend sends the waiter straight back to the
   ready queue instead of losing the wakeup. (The single-threaded await still panics on that case, as
   it always did, because there it would be a codegen bug.)
4. **One lock, atomic state.** A `lyric_mutex` guards the ready queue, the sleeper list, every waiter
   list, `next` links, `state` and `result` writes, `g_running`, `g_idle` and `g_host_pending`. `state`
   is atomic: `lyric_task_is_complete` and `lyric_task_result` read it without the lock, and the
   `COMPLETE` store is a release that publishes `result`. Idle threads wait on one condition variable
   (timed to the earliest sleeper's deadline when there is one), woken by a ready push, a new
   earliest deadline, or a completion a `block_on` caller may be waiting for.
5. **Frame lifetime.** The scheduler reference taken at registration is held until the stretch that
   registered it ends (`run_one` releases it after the resume returns and the registration is
   published), so an awaiter that wakes on one thread and drops the task cannot free a coroutine
   frame its completer is still leaving on another.
6. **Deadlock detection.** `g_running` counts tasks between the start of a ramp or resume and the
   completion or publication that ends it. A thread blocked in `lyric_task_block_on` panics with the
   existing "deadlock" (or "awaiting a host operation inside a synchronous call") message only when
   nothing is ready, sleeping or running anywhere, so a root waiting on a task running on another
   thread is never misreported.
7. **ARC, async-result kernels, protected types (the issue's re-check).**
   - *ARC.* Strong and weak counts were already atomic (`lyric_retain`/`lyric_release` use a relaxed
     increment, a release decrement and an acquire fence on the last one). ThreadSanitizer does not
     model standalone fences and reported a race on the free of any object whose last reference a
     second thread dropped, so under `-fsanitize=thread` the decrement is `acq_rel`
     (`LYRIC_RC_DEC_ORDER`); normal builds are unchanged.
   - *Async-result kernels.* The in-coroutine process capture and the sleep leaf keep their state in
     the task or a per-call object that one thread touches at a time; the scheduler lock orders the
     hand-off between the thread that parked it and the thread that resumes it. Host tasks
     (`lyric_host_task_*`, the wasm `module` shape) take the same lock, but `lyric_sched_poll` panics
     if called under the multi-threaded scheduler, and wasm never enables it.
   - *Protected types.* The monitor is reentrant per OS thread and entries are synchronous, so a
     lock is always released on the thread that took it. A coroutine does not suspend inside an entry.
     A task blocked on a `when:` barrier holds its thread while it waits: with `N` threads, `N` such
     tasks and nobody to make a barrier true is a deadlock the detector cannot see, because they are
     counted as running.
   - *Not synchronised.* `List`, `Map`, `slice`, `buffer` and record `var` fields are plain memory.
     Tasks that run in parallel must share them only through a `protected type`, or not mutate them.
     Module-level mutable state is likewise unsynchronised.
8. **Sanitizers.** `lyric-rt/test/lyric_async_mt_test.c` drives the scheduler with fake coroutines
   that carry a `busy` flag, set while a thread executes the frame, so a frame resumed on two threads
   or destroyed while running fails the run: fan-out with a measured overlap, 200 waiters on one
   dependency, 1500 rounds of a dependency finishing between the awaiter's check and its
   registration, a 64-link await chain, nested `lyric_task_block_on` inside a body on a worker, and
   dropped handles. `make -C lyric-rt test` runs it plain, `test-tsan` and `test-asan-async` under
   ThreadSanitizer and AddressSanitizer (clang, because gcc's ThreadSanitizer cannot see the ARC
   fence). `scripts/ci/async-mt-e2e.sh` also builds a Lyric fork-join driver, marks every function of
   its IR `sanitize_thread`, links the runtime built from source with the sanitizer, and runs it at 2
   and 4 scheduler threads; `llvm_self_test_async_mt.l` runs real programs (a rendezvous that three
   spawned tasks can only pass by running at once, recursive fork-join `fib`, sleepers resumed on
   other threads, a contended protected counter) under the multi-threaded scheduler and under ASan,
   and the default scheduler on the same sources.

## Not in this decision

- **Work stealing (#8493).** One shared FIFO queue under one lock is enough to prove the design and
  is contention-limited only for very fine-grained tasks; per-thread deques with stealing, and a task
  throughput benchmark, are a throughput follow-up that changes no semantics.
- **A compile-time `Send` check (#8492).** Whether a spawned call's arguments may be shared with the
  spawner needs a structural marker like docs/67's `Plain`; until then thread safety of shared
  reference state is the program's responsibility, which is why the mode is opt-in. The issue also
  covers making the processor count the default once the check ships.
- **Blocking kernels do not yield (#8494).** A synchronous `Std.File`, socket or `when:` wait occupies
  its thread; an async I/O reactor (`poll`/`epoll` in the scheduler, the deferred D-N-023 socket leaf)
  is separate.
- **`Parallel.forChunks` inside tasks.** Unchanged: the data-parallel pool of D202 is independent
  (its own `LYRIC_THREADS`), and a body that runs on a scheduler worker may start a loop as before.
- **Other targets.** The managed targets have their own task runtimes; wasm32 is single-threaded.
