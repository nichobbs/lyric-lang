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
