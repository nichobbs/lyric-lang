# D165 — `spawn` is allowed only inside a `scope { }`

**Status:** accepted, implemented (first slice of docs/68)

## Context

docs/01 §7.4 says a scope joins every task spawned in it, cancels siblings on
a failure and carries the first failure. D119 enforced only the consumption
rule: a `spawn` statement whose handle is discarded outside a scope was V0014,
while `val t = spawn f(); ... ; await t` outside a scope was allowed. That
left two problems:

- On the JVM a `spawn` outside a scope has no executor, so it ran
  synchronously at the spawn site and returned the raw result. The handle was
  a `Future` inside a scope and a plain value outside one, which blocks giving
  the handle a single type (docs/68 `Task[T]`).
- A bound handle outside a scope can escape, outlive the code that started it,
  and hide a failure that no `await` observes.

## Decision

1. **A `spawn` is allowed only lexically inside a `scope { }` of the same
   function or lambda body.** Anywhere else it is the error `V0034`, raised
   by the shared mode checker, so it fires identically on every backend.
2. **A lambda body needs a scope of its own.** A lambda may outlive an
   enclosing scope, so a `spawn` in a lambda does not count as inside the
   scope the lambda is written in. This is the rule V0014 already used.
3. **V0014 is unchanged for a discarded `spawn` statement outside a scope,
   and V0034 is not raised for it as well.** One diagnostic per spawn.
4. **No deprecation window.** `V0034` is an error from the release that
   contains it (docs/68 Q-TASK-007, decided by the owner).

## Consequences

- Every `spawn` now forks on the JVM; the degenerate synchronous path can no
  longer be written.
- Code that spawned outside a scope must move the spawn and the `await`s that
  use its handle into a `scope`. In this repository that was three test
  files; the `async_spawn_self_test.l` case that tested the degenerate
  bare-spawn path was removed because the construct is now ill-formed
  (`modechecker_self_test.l` covers the rejection).
- It does not change what a handle is: the typed `Task[T]` handle, the
  `Std.Task` API and escape rules (`V0035`) are later slices of docs/68.

Supersedes the "consumption rule, not a strict spawn-only-inside-scope rule"
note in docs/01 §7.4 and docs/09 §15.2 (D119).
