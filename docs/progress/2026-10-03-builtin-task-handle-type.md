# 2026-10-03 - Built-in `Task[T]` handle type (docs/68 slice 2, D166)

`spawn e` now has the type `Task[R]`; `await t` yields `R`.

- Checker: built-in `Task[T]` (`typechecker_types.l`, resolver and `spawn`/`await` arms in
  `typechecker_exprs.l`), recorded per spawn span for the middle end.
- Mono: reads the handle type from the checker; the #8026 `asyncCallSites` special case is gone.
- MSIL: `Task[X]` lowering in all four type-lowering functions, completed-task wrapping for a
  `spawn` of a resolved value, pre-scan typing of `await ts[i]`.
- JVM: `Task[T]` lowers to `Future`; `Std.Task`'s JVM `record Task` no longer captures it.
- Tests: `Task[T] spawn handles` cases in `async_spawn_self_test.l` (dotnet and jvm), checker and
  mono self-tests.

Open (docs/68): the `Std.Task` API, `V0035`, the MSIL scope-exit join, native.
