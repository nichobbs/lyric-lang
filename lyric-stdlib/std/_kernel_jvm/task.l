// std/_kernel_jvm/task.l - JVM host boundary for async task primitives
// and cancellation tokens.
//
// Mirrors _kernel/task.l for the JVM target.  The JVM async model
// differs from .NET's:
//
//   Default async func  → runs synchronously on a virtual thread
//                         (JEP 444, Java 21).  No state machine.
//   @hot async func     → CompletableFuture<T> lowering.
//   Cancellation        → Thread.interrupt() for virtual threads;
//                         explicit token for CompletableFuture paths.
//   Task                → lyric.runtime.LyricTask wraps
//                         CompletableFuture<Void> for explicit handles.
//   Scope               → lyric.runtime.LyricTaskScope wraps
//                         StructuredTaskScope (JEP 462 / Java 25).
//
// The ambient-token slot uses ScopedValue<T> (JEP 446, Java 21+)
// rather than .NET's AsyncLocal<T>.  ScopedValue flows correctly
// across virtual-thread boundaries; InheritableThreadLocal does not.
@runtime_checked
package Std.Task

import Std.Core
import Std.Errors

// LyricTask wraps CompletableFuture<Void> for explicit task handles.
// Default async funcs lower to synchronous virtual-thread calls and
// do not produce LyricTask values at the source level.
extern type Task                    = "lyric.runtime.LyricTask"
// LyricCancellation: thin wrapper; for virtual-thread-default code
// backed by Thread.interrupted(); for @hot paths an explicit flag.
extern type CancellationToken       = "lyric.runtime.LyricCancellation"
// LyricCancellationSource: owns cancellation state; cancel() sets the
// flag and interrupts registered virtual threads.
extern type CancellationTokenSource = "lyric.runtime.LyricCancellationSource"
// LyricTaskScope: wraps StructuredTaskScope with failure aggregation.
extern type Scope                   = "lyric.runtime.LyricTaskScope"

// =====================================================================
// Cancellation: token construction, source management, observation.
// =====================================================================

extern package lyric.stdlib.jvm.CancelHost {
  // Singleton never-cancelled token (LyricCancellation.NONE).
  pub func noCancellation(): CancellationToken

  pub func makeCancelSource(): CancellationTokenSource

  // Auto-cancels source after ms milliseconds via ScheduledExecutorService.
  pub func makeCancelSourceTimeout(ms: in Int): CancellationTokenSource

  pub func sourceToken(source: in CancellationTokenSource): CancellationToken

  // Idempotent; sets flag and interrupts registered virtual threads.
  pub func cancelSource(source: in CancellationTokenSource): Unit

  // Releases auto-cancel timer if any.
  pub func disposeSource(source: in CancellationTokenSource): Unit

  pub func isCancelled(token: in CancellationToken): Bool

  // For virtual-thread-default code also checks Thread.interrupted()
  // so JDK blocking calls propagate cancellation automatically.
  pub func throwIfCancelled(token: in CancellationToken): Unit
}

// =====================================================================
// Delay.  Both variants run on the calling virtual thread.
// =====================================================================

extern package lyric.stdlib.jvm.TaskHost {
  // Thread.sleep(ms) — non-cancellable.
  pub func delay(ms: in Int): Task

  // Thread.sleep(ms) with interrupt handling; throws Bug(Cancelled)
  // when the token is cancelled before the timer fires.
  pub func delayWithCancel(ms: in Int, token: in CancellationToken): Task
}

// =====================================================================
// Structured concurrency.
//
// LyricTaskScope wraps StructuredTaskScope with failure aggregation
// (all failures reported, not just the first).  Canonical pattern:
//
//     async func parent(): Unit {
//       val scope = makeScope()
//       defer { cancelScope(scope); disposeScope(scope) }
//       val tok = scopeToken(scope)
//       scopeSpawn(scope, { -> child1(tok) })
//       scopeSpawn(scope, { -> child2(tok) })
//       try { await awaitAll(scope) }
//       catch Exception as e { println("a child failed") }
//     }
//
// Bootstrap-grade: only Unit-returning children; typed-result
// aggregation is a Phase 6 follow-up.
// =====================================================================

extern package lyric.stdlib.jvm.TaskScopeHost {
  pub func makeScope(): Scope
  pub func scopeToken(s: in Scope): CancellationToken

  // Register an existing LyricTask as a scope child.
  pub func scopeAdd(s: in Scope, child: in Task): Unit

  // Spawn a zero-arg closure on a new virtual thread, tracked by scope.
  pub func scopeSpawn(s: in Scope, action: in () -> Unit): Unit

  // Block until all children complete; rethrows aggregated failures.
  pub func awaitAll(s: in Scope): Task

  // Cancel the scope's token.  Idempotent.
  pub func cancelScope(s: in Scope): Unit

  // Join outstanding threads and release resources.
  pub func disposeScope(s: in Scope): Unit
}

// =====================================================================
// Ambient-token slot.  Backed by ScopedValue<LyricCancellation>.
//
// Usage:
//     val previous = installToken(scopeToken(sc))
//     defer { restoreToken(previous) }
// =====================================================================

extern package lyric.stdlib.jvm.AmbientHost {
  // Returns noCancellation() when no scope is active.
  pub func currentToken(): CancellationToken

  // Bind token as the ambient; returns previous value for restore.
  pub func installToken(token: in CancellationToken): CancellationToken

  pub func restoreToken(previous: in CancellationToken): Unit

  // True when the ambient holds a non-default token.
  pub func hasAmbient(): Bool
}
