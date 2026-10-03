# 2026-10-03 - `Std.Task` spawn-handle API (docs/68 slice 3, D168)

`Std.Task` now has `waitFor`, `isDone` and `awaitAll` over `Task[T]` handles on
both targets; the old `awaitAll(Scope)` is `awaitScope`.

- Kernels: `lyric-stdlib/std/_kernel/task.l` (`Task.Wait(int)` via `waitTaskDone`) and
  `_kernel_jvm/task.l` (timed `Future.get` via `futureWaitDone`).
- Checker: a `Task[R]` handle is assignable to the `java.util.concurrent.Future` extern.
- Test: `task_handle_api_self_test.l` (7 cases, dotnet and jvm), wired through both CI batch scripts.
- Needs a seed compiler with D166 to build the stdlib.

Open (docs/68): `cancel`, `awaitAny`, `V0035`, MSIL scope-exit join, native.
Related: #8105 (MSIL exceptions before a task's first suspension).
