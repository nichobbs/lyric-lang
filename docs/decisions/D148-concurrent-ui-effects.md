# D148 — A session's effects run concurrently

**Status:** accepted, implemented

Resolves #7835; docs/65 §15 finding F-15.

## Context

`Ui.Host` ran the effects of a step one after another, on the connection's
thread and under the instance lock. A slow effect, such as an HTTP call,
therefore held up every later effect and every input from that session
until it finished. docs/65 §4.2 and §8 always specified concurrent effects.

## Decision

1. Each effect runs as a task on the instance's `Std.Task` scope
   (`scopeSpawn`: thread-pool tasks on dotnet, virtual threads on the JVM),
   outside the instance lock.
2. An effect's result message is applied under the instance lock as a step
   of its own: `update`, render, diff, send, then start that step's
   effects. Results therefore apply one at a time, in the order they
   complete, and `update` never runs concurrently with itself.
3. `Instance` gains `close`. `SessionRegistry` calls it when it evicts a
   session to make room and when a session's reconnect grace expires.
   `close` cancels the scope, whose token is also the instance's closed
   flag: a result arriving afterwards is dropped. `close` takes no lock, so
   the registry can call it from inside its own entries without nesting two
   locks.
4. A result arriving while the session is detached updates the model and
   drops the rendered tree again. A detached session keeps only its model
   (D138), and `resume` re-renders it in full.
5. An effect that fails is reported on standard error and produces no
   result. Nothing awaits these tasks, so the failure would otherwise
   vanish.

## Why not a generic protected type

The issue suggested a per-session queue guarded by a generic protected type
(F-10, now D147). `instance` is generic, so its body is compiled into every
package that calls it. A protected type crosses that package boundary as an
opaque type whose members are not callable (the reason the non-generic
`newInstanceLock`/`withLock` wrappers exist). The state therefore stays in
cells that only the instance lock guards, and ordering comes from that lock
instead of a queue.

## Consequences

`start` and `receive` return as soon as their own step is sent. A caller
that needs an effect's result must wait for the message it sends: the host
tests do this with a bounded wait.

## Std.Task fix found on the way

On the JVM, `Std.Task.scopeSpawn` did not start its action: it queued the
closure and `awaitAll` ran the queue. On dotnet it starts the action at
once with `Task.Run`. The host never calls `awaitAll`, so on the JVM no
effect ever ran. The JVM kernel now starts each action at once on a
virtual thread (`Thread.startVirtualThread` with a `Runnable` record, the
mechanism `runWithin` already uses), keeps the threads in a lock-guarded
list, and `awaitAll` joins the threads started so far. The deferral had
been chosen because a cross-package closure stored and later invoked
threw `ClassCastException`; that gap is closed (the lyric-ui host passes
closures across the package boundary on the JVM). `task_tests.l` gains
`testScopeSpawnStartsBeforeAwaitAll`, run on both targets.

The instance's scope lives as long as the session and is never joined, so
both kernels only appending to their child list kept one task or thread per
effect ever run (#7876). A scope now drops its finished children when it
next spawns: on dotnet it keeps the first child that did not succeed, so
`awaitAll` still rethrows its failure; on the JVM the failure is recorded
separately and finished threads are dropped. `scopePendingCount` reports
what is still tracked (`testScopeDropsFinishedChildren`,
`testScopeKeepsFailureAcrossPruning`).

## Compiler fix found on the way

The new host tests constructed a `Ui.Core.Screen` with
`uiEffect = { _: TEffect -> None }` and failed on dotnet with an
`InvalidCastException`: the lambda built `Option_None<object>` where the
field's `Option<UiEffect<TMsg>>` was expected. A lambda written directly as
a constructor argument had no recorded result type, so a bare `None`,
`Some`, `Ok` or `Err` in its body fell back to `object` type arguments. The
MSIL backend now seeds the lambda's result type from the field's declared
function type (substituted with the instantiation's type arguments for a
generic record), and registers those field types for stdlib and restored
records too. The JVM erases these type arguments and was not affected.
`lambda_field_ctor_arg_self_test.l` covers it on both targets.
