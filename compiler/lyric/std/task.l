// std/task.l — Async task primitives + cancellation tokens.
//
// Phase C / D-progress-068.  Wraps the BCL's
// `System.Threading.Tasks.Task`,
// `System.Threading.CancellationTokenSource`, and
// `System.Threading.CancellationToken` so Lyric programs can
// thread cancellation through their async chains.
//
// Cooperative semantics: an awaited operation only honours
// cancellation if it accepts a token (e.g. `delayWithCancel(ms,
// token)` instead of `delay(ms)`).  A cancelled token causes
// `Task.Delay` and friends to throw `OperationCanceledException`
// at the suspend's resume point; the user's `try { ... } catch
// Exception { ... }` traps it.  Real `OperationCanceled`
// distinguishability is a Phase 4 follow-up.
//
// Structured concurrency lives in `withScope` / `withTimeout`
// (separate combinators in this module): each creates a fresh
// source, runs the user closure, and disposes the source on
// exit so spawned children don't leak.
@runtime_checked
package Std.Task

import Std.Core
import Std.Errors

extern type Task   = "System.Threading.Tasks.Task"
extern type CancellationToken       = "System.Threading.CancellationToken"
extern type CancellationTokenSource = "System.Threading.CancellationTokenSource"
extern type Scope                   = "Lyric.Stdlib.LyricTaskScope"

// =====================================================================
// Construction helpers.
// =====================================================================

/// A token that's never cancelled — equivalent to
/// `CancellationToken.None` in the BCL.  Use as the "no
/// cancellation requested" sentinel when an API requires a
/// token but the caller has no source.
@externTarget("Lyric.Stdlib.CancelHost.None")
pub func noCancellation(): CancellationToken = ()

/// Create a fresh `CancellationTokenSource`.  Pass its token
/// (`source.token()`) into cancellable async operations; call
/// `source.cancel()` when you want them to abort.  Sources own
/// unmanaged resources — wrap usage in `defer { source.dispose()
/// }` or use `withScope` for automatic cleanup.
@externTarget("Lyric.Stdlib.CancelHost.MakeSource")
pub func makeCancelSource(): CancellationTokenSource = ()

/// Same as `makeCancelSource` but auto-cancels the resulting
/// source after `ms` milliseconds — convenient for deadline-
/// shaped scopes.
@externTarget("Lyric.Stdlib.CancelHost.MakeSourceTimeout")
pub func makeCancelSourceTimeout(ms: in Int): CancellationTokenSource = ()

// =====================================================================
// Source operations.
// =====================================================================

/// Project a token from a source.  Multiple calls return the
/// same token (BCL semantics).
@externTarget("Lyric.Stdlib.CancelHost.SourceToken")
pub func sourceToken(source: in CancellationTokenSource): CancellationToken = ()

/// Request cancellation.  Idempotent: subsequent calls are no-ops.
/// Spawned async work observing the source's token will see
/// `isCancelled == true` (and any `delayWithCancel` / similar in
/// flight will throw `OperationCanceledException` at the next
/// resume point).
@externTarget("Lyric.Stdlib.CancelHost.Cancel")
pub func cancelSource(source: in CancellationTokenSource): Unit = ()

/// Release the source's unmanaged resources.  Always safe to
/// call after the source's last consumer has resumed.
@externTarget("Lyric.Stdlib.CancelHost.Dispose")
pub func disposeSource(source: in CancellationTokenSource): Unit = ()

// =====================================================================
// Token observation.
// =====================================================================

/// Has cancellation been requested for this token's source?
/// Async loops can poll this between iterations as a cheap
/// alternative to `throwIfCancelled`.
@externTarget("Lyric.Stdlib.CancelHost.IsCancellationRequested")
pub func isCancelled(token: in CancellationToken): Bool = ()

/// Throw `OperationCanceledException` (which Lyric catches as
/// `Exception`) when the token has been cancelled.  Use as a
/// cooperative cancellation point inside long-running synchronous
/// stretches that can't naturally suspend.
@externTarget("Lyric.Stdlib.CancelHost.ThrowIfCancellationRequested")
pub func throwIfCancelled(token: in CancellationToken): Unit = ()

// =====================================================================
// Cancellable delay.
// =====================================================================

/// `Task.Delay(ms)` — non-cancellable timer.  Pre-Phase-C
/// callers continue to use this; the SM will suspend until `ms`
/// elapses.
@externTarget("Lyric.Stdlib.TaskHost.Delay")
pub func delay(ms: in Int): Task = ()

/// `Task.Delay(ms, token)` — cancellable timer.  When the token
/// is cancelled before the timer fires, the awaiting state
/// machine resumes with `OperationCanceledException` (caught as
/// `Exception` on the Lyric side).  Phase C / D-progress-068.
@externTarget("Lyric.Stdlib.TaskHost.DelayWithCancel")
pub func delayWithCancel(ms: in Int, token: in CancellationToken): Task = ()

// =====================================================================
// Structured concurrency.  Phase C / D-progress-069.
//
// A `Scope` owns a `CancellationTokenSource` and a list of spawned
// child tasks.  Spawning a task registers it as a child; if any
// child fails, the scope's source is cancelled so siblings observe
// and bail.  The canonical pattern:
//
//     async func parent(): Unit {
//       val scope = makeScope()
//       defer {
//         cancelScope(scope)
//         disposeScope(scope)
//       }
//       val tok = scopeToken(scope)
//       spawn(scope, child1(tok))
//       spawn(scope, child2(tok))
//       try {
//         await awaitAll(scope)
//       } catch Exception as e {
//         println("at least one child failed")
//       }
//     }
//
// Bootstrap-grade scope: only Unit-returning child tasks (`Task`,
// not `Task[T]`) are accepted by `spawn`; typed-result aggregation
// remains a Phase 4 follow-up.  AsyncLocal flow (so children see
// the scope's token without explicit threading) is deferred.
// =====================================================================

/// Construct a fresh scope.  The scope owns a cancellation source
/// and an empty children list; spawn child tasks against it via
/// `spawn`, then `await awaitAll(scope)` to join them.  Always
/// pair construction with `defer { cancelScope(scope);
/// disposeScope(scope) }` so the source is released on scope exit.
@externTarget("Lyric.Stdlib.TaskScopeHost.MakeScope")
pub func makeScope(): Scope = ()

/// Project the scope's cancellation token.  Pass to child tasks
/// so they observe scope-level cancellation requests.
@externTarget("Lyric.Stdlib.TaskScopeHost.ScopeToken")
pub func scopeToken(s: in Scope): CancellationToken = ()

/// Register an existing `Task` as a child of the scope.  Lyric's
/// type system doesn't yet surface `Task` values from async-func
/// calls (the typechecker erases the wrapper), so this overload
/// is mainly used for tasks the user obtains via host helpers
/// such as `delayWithCancel(ms, token)` whose declared return
/// type is `Task`.  Phase 4 follow-up: surface Task[T] from
/// async-func calls so this is the primary spawn path.
@externTarget("Lyric.Stdlib.TaskScopeHost.Add")
pub func scopeAdd(s: in Scope, child: in Task): Unit = ()

/// Spawn a zero-arg closure on the thread pool, scoped to `scope`.
/// The closure runs synchronously on a thread-pool thread; it can
/// poll `isCancelled(scopeToken(scope))` or call
/// `throwIfCancelled(scopeToken(scope))` to honour cancellation.
///
/// Named `scopeSpawn` rather than the more idiomatic `spawn`
/// because `spawn` is a soft keyword reserved for the future
/// `spawn expr` syntactic form (`ESpawn` in the parser AST).
///
/// Bootstrap-grade scope: closures can't `await` directly (the
/// Phase B state machine doesn't synthesise async lambdas), so
/// async I/O inside the closure auto-awaits via the M1.4 blocking
/// shim — which still runs concurrently with siblings since each
/// closure has its own thread-pool task.  Phase 4 follow-up: real
/// async lambdas with cooperative suspension.
@externTarget("Lyric.Stdlib.TaskScopeHost.SpawnAction")
pub func scopeSpawn(s: in Scope, action: in () -> Unit): Unit = ()

/// Wait for every registered child to complete.  When any child
/// fails the call rethrows the underlying exception so the
/// caller's `try/catch` surfaces it; the scope's source has
/// already been cancelled at the moment of failure (eagerly, via
/// a per-child continuation in the host) so siblings observing
/// the token will have started winding down.
@externTarget("Lyric.Stdlib.TaskScopeHost.AwaitAll")
pub func awaitAll(s: in Scope): Task = ()

/// Explicitly cancel the scope's source.  Idempotent.  Useful
/// for defer-based cleanup that signals children to abort.
@externTarget("Lyric.Stdlib.TaskScopeHost.Cancel")
pub func cancelScope(s: in Scope): Unit = ()

/// Release the scope's underlying source.  Always safe to call
/// from a `defer { ... }`.
@externTarget("Lyric.Stdlib.TaskScopeHost.Dispose")
pub func disposeScope(s: in Scope): Unit = ()
