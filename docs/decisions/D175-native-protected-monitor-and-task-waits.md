# D175 — A protected type's lock is a monitor on native; `Std.Task` waits block (#8154)

**Status:** shipped

Resolves the native half of D-progress-988 (`when:` barriers were rejected on `--target native`)
and the polling that D-N-017 left in the native `Std.Task` kernel.

**Runtime (`lyric-rt`).**
- A general condition-variable API beside the mutex and semaphore ones: `lyric_cond_size/init/
  wait/timedwait/signal/broadcast/destroy`. Timed waits use the monotonic clock (a condattr on
  glibc and musl, `pthread_cond_timedwait_relative_np` on macOS); a non-positive timeout does
  not block, and the result is 1 for a wake-up and 0 for a timeout.
- One global condition, `lyric_global_cond_wait/timedwait/broadcast`, paired with
  `lyric_global_lock`, for a bundled stdlib package that has no module state of its own.
- The buffer `lyric_mutex_size()` reports is now a **monitor**: a mutex, a condition, and the
  owner and nesting depth. It stays reentrant (a member may call a sibling), and
  `lyric_mutex_wait` releases every nested level, blocks, and restores the depth, as a CLR
  `Monitor` or a JVM object monitor does. A pthread recursive mutex cannot do that, because
  `pthread_cond_wait` releases one level. `lyric_mutex_notify_all` wakes the waiters. On
  wasm32-wasi a wait panics, since no other thread could make the barrier true.

**Compiler.** The contract elaborator already rewrites a barrier into `while not (barrier)
{ __lyric_protected_wait() }`, and adds `defer { __lyric_protected_notify() }` to every member
of a type with a barrier (D-progress-988). Native lowers the two intrinsics onto the receiver's
lock buffer (`lowerProtectedBarrierCall`), so no layout changes: a protected type still carries
one trailing buffer. Rejected: a second per-instance condition buffer (more layout, nothing
gained) and notifying only from entries (the #7384 hang).

**`Std.Task` (native kernel).** `awaitAll`, `runActionWithin` and `delayWithCancel` block on
the global condition: a finishing job or a cancelled source broadcasts it, every waiter
re-tests its own predicate, and a timed wait gives up at its deadline (`delayWithCancel` ends
at the earlier of its delay and the token's own deadline). Nothing polls. The remaining
`hostSleepMillis` calls are plain sleeps.

**Capture analysis.** Writing the tests found that a lambda's free-variable walk skipped
`await`, `spawn`, `yield`, `try` and `unsafe`, so a name used only under `await` was not
captured. Fixed alongside.

Tests: the `lyric-rt` C suite (condition variable, monitor at nested depth, global condition,
under clang, gcc and ASan); six cases in `task_native_tests.l`; two barrier cases in
`llvm_project_self_test.l` (a one-slot producer/consumer buffer and a func that opens a gate
for waiting members, one of them through a nested lock); one capture case in
`llvm_self_test_async.l`.
