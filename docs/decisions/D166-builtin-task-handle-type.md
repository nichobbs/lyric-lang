# D166 - A built-in `Task[T]` type for `spawn` handles

**Status:** accepted, implemented (second slice of docs/68)

## Context

The checker typed `spawn f()` as the callee's result `R`. A generic called with
a handle therefore specialised over `R` rather than over the task, which on MSIL
produced a `void` receiver and a startup `TypeLoadException` for a generic
`@externInstance` binding of `Task.Wait` (nichobbs/lyric-lang#8026, fixed by a
mono special case). A parameter, local or list element could not be annotated
with the handle type at all.

## Decision

1. **`Task[T]` is a built-in generic type**, resolved by the checker unless a
   Lyric type or extern named `Task` is in scope. `spawn e` is `Task[R]`;
   `await t` of a `Task[R]` is `R`.
2. **Bare `Task` interoperates, it is not an alias.** A `Task[R]` is assignable
   to an `extern type Task` (so existing `Std.Task` externs keep taking
   handles) and a bare `Task` is assignable to `Task[Unit]`. This resolves
   Q-TASK-003 as assignability rather than full aliasing.
3. **The middle end reads the handle type from the checker.** The checker
   records `Task[R]` at each `spawn` span; mono uses it, replacing the
   `asyncCallSites` special case from #8026.
4. **Lowering.** MSIL: `Task[Unit]` is `System.Threading.Tasks.Task`,
   `Task[X]` is `Task<X>`; a type-parameter result lowers to the base `Task`
   (CLR generics are invariant). A `spawn` of a call that already resolved to a
   value (a blocking `@externTarget async` binding) is wrapped as a completed
   task. The Phase B pre-scan types `await ts[i]` over a `List[Task[T]]`. JVM:
   `Task[T]` is the `Future` a scope's executor returns, and never resolves to
   `Std.Task`'s JVM kernel `record Task`.
5. **Not in this slice:** the `Std.Task` API (`waitFor`, `isDone`, `cancel`,
   `awaitAll` over handles), the escape rule `V0035`, the MSIL scope-exit join
   and the native backend. They remain docs/68 §5, §4.1, §7 and are tracked
   there.

## Consequences

A generic over a handle is an ordinary generic over `Task[R]` on both
backends. `Task[T]` written in a user program no longer needs a
`Std.Task` extern. Verified by `typechecker_self_test.l` (803-810),
`mono_self_test.l` and the `Task[T] spawn handles` cases of
`async_spawn_self_test.l` on `--target dotnet` and `--target jvm`.
