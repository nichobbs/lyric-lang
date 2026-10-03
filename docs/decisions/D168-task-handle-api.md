# D168 - The `Std.Task` spawn-handle API: `waitFor`, `isDone`, `awaitAll`

**Status:** accepted, implemented (third slice of docs/68)

## Context

D166 gave `spawn e` the type `Task[R]`. docs/68 §5 specifies a small API over
handles. Two parts of it cannot ship yet: `cancel` needs a cancellation token
per spawned task (the `spawn` lowering on both backends installs none today),
and the sketch's `awaitAll` name already belongs to `Std.Task.awaitAll(Scope)`,
and the compiler rejects two same-named functions in one package (T0001).

## Decision

1. **`Std.Task` gains `waitFor[T](t: in Task[T], timeoutMs: in Int): Bool`,
   `isDone[T](t: in Task[T]): Bool` and `awaitAll[T](ts: in List[Task[T]]):
   List[T]`**, with the same public surface on `_kernel/task.l` (dotnet) and
   `_kernel_jvm/task.l` (JVM).
2. **`waitFor`** blocks at most `timeoutMs`, does not consume the task and can
   be repeated. A task that finished by failing or being cancelled counts as
   finished (`true`); the failure is raised by the later `await`. `isDone` is
   `waitFor(t, 0)`. On dotnet it is `Task.Wait(int)` with the exception
   swallowed; on the JVM it is a timed `Future.get`, with `isDone` deciding
   the result after any exception.
3. **`awaitAll`** keeps the name the handle API uses in docs/68. The old
   scope-joining function is renamed `awaitScope` (a public API break; its only
   uses were the two kernels and two stdlib test files).
4. **`awaitAll` semantics in this slice:** results in input order; the empty
   list gives the empty list; the first failure in input order is raised and
   the later tasks are left for the enclosing `scope { }` to join. The sketch's
   fail-fast cancel of the remaining tasks waits for `cancel`.
5. **Type checking:** a `Task[R]` handle is assignable to the
   `java.util.concurrent.Future` extern, the JVM representation of a handle, as
   it already is to the `System.Threading.Tasks.Task` extern.
6. **Deferred, tracked in docs/68:** `cancel`, `awaitAny`, `V0035`, the MSIL
   scope-exit join, the native backend. Spawn-site exceptions on dotnet that
   are thrown before a task's first suspension are #8105.

## Consequences

Generic functions of `Std.Task` are compiled into each calling package, so the
bodies only call `pub` non-generic helpers (`waitTaskDone`, `futureWaitDone`).
`Std.Task` uses the `Task[T]` type in its own source, so the stdlib bundle can
only be built by a seed compiler that has D166 (a release after it).
Verified by `task_handle_api_self_test.l` on `--target dotnet` and
`--target jvm`.
