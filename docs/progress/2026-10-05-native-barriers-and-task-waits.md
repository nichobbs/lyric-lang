# Native: protected-type `when:` barriers; `Std.Task` waits block instead of polling (#8154, D175)

- `lyric-rt` gains condition variables (`lyric_cond_*`), a global condition paired with the global lock
  (`lyric_global_cond_*`), and a monitor for a protected type's lock buffer (`lyric_mutex_wait`,
  `lyric_mutex_notify_all`; reentrant, a wait releases every nested level).
- `--target native` lowers the `when:` barrier intrinsics onto that monitor, so a barrier member waits
  until its barrier is true and every member of a type with a barrier wakes the waiters on exit, as on
  dotnet and the JVM. The build-time rejection (D-N-017) is gone.
- The native `Std.Task` kernel blocks on the global condition: `awaitAll`, `runActionWithin` and
  `delayWithCancel` no longer poll at 1 ms and 20 ms steps.
- A lambda now captures a name used only under `await`, `spawn`, `yield`, `try` or `unsafe`.
- Tests: C tests for the new primitives (clang, gcc, ASan); six `task_native_tests.l` cases; two barrier
  cases in `llvm_project_self_test.l`; one capture case in `llvm_self_test_async.l`.
- Still open: invariant re-checking and generic protected types on native (`N0008`, #7864).
