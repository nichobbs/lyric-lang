//! std/task.l — Async task primitives + cancellation tokens.
//!
//! Phase C / D-progress-068.  Wraps the BCL's
//! `System.Threading.Tasks.Task`,
//! `System.Threading.CancellationTokenSource`, and
//! `System.Threading.CancellationToken` so Lyric programs can
//! thread cancellation through their async chains.
//!
//! Cooperative semantics: an awaited operation only honours
//! cancellation if it accepts a token (e.g. `delayWithCancel(ms,
//! token)` instead of `delay(ms)`).  A cancelled token causes
//! `Task.Delay` and friends to throw `OperationCanceledException`
//! at the suspend's resume point; the user's `try { ... } catch
//! Exception { ... }` traps it.  Real `OperationCanceled`
//! distinguishability is a Phase 4 follow-up.
//!
//! Structured concurrency lives in `withScope` / `withTimeout`
//! (separate combinators in this module): each creates a fresh
//! source, runs the user closure, and disposes the source on
//! exit so spawned children don't leak.
//!
//! Group C / D-progress-stdlib-expand (2026-05):
//!   - `extern type Scope = "Lyric.Stdlib.LyricTaskScope"` retired.
//!     `Scope` is now a native Lyric `protected type` backed by a
//!     `CancellationTokenSource` + `List[Task]`.  `TaskScopeHost`
//!     statics are replaced by thin Lyric wrapper functions calling
//!     the protected type's entry/func methods.
//!
//! D119 slice S3 (sibling-cancel-on-first-fault) — investigated, NOT
//! shipped; the module remains as before (`awaitAll` propagates the first
//! fault via `Task.WhenAll`; there is no eager cross-sibling cancel).  Three
//! independent, pre-existing MSIL-backend bugs were found while attempting
//! this, each confirmed with a standalone repro outside `Std.Task` (so none
//! of them are specific to this module):
//!
//!   1. `Task.ContinueWith(Action<Task>)` can never bind: Lyric closures
//!      erase every generic delegate type argument to `System.Object`
//!      (Epic #1877's closure ABI), so a `(Task) -> Unit` handler always
//!      presents as `Action<Object>` at the call site — never
//!      `Action<Task>` — and no BCL `ContinueWith` overload matches;
//!      both the metadata auto-FFI resolver and the table-driven
//!      `@externTarget` resolver fall back to a guessed signature that
//!      throws `MissingMethodException` at runtime.
//!   2. An alternative using `Task.GetAwaiter().OnCompleted(Action)`
//!      (a *non-generic*, arity-0 delegate — the one shape already proven
//!      to bind, per (3) below) compiles the call correctly, but as soon
//!      as any closure appears in a function that also calls
//!      `GetAwaiter`/`OnCompleted`, the whole compilation unit's MSIL
//!      lowering panics: `Msil.Lowering: MNewobjByName could not resolve
//!      .ctor for type '<pkg>.__Closure_N'` — the closure class's own
//!      TypeDef/`.ctor` registration is not visible by the time lowering
//!      reaches it.  Reproduced with a `() -> Unit` local closing only
//!      over a `Task` and a `protected type` value (never over another
//!      closure), so this is not the generic-erasure issue from (1) — it
//!      is a second, independent gap in closure-class registration
//!      ordering when `TaskAwaiter`/`GetAwaiter` participate.
//!   3. Most significant: even the *existing*, already-shipped
//!      `Task.Run(Action[, CancellationToken])` binding used by
//!      `scopeSpawn` below never actually invokes the passed closure on
//!      this backend — confirmed with a minimal repro with no dependency
//!      on this file at all (`taskRunPlain({ -> println(...) }); t.Wait()`
//!      prints nothing and returns immediately).  This means
//!      `Scope.scopeSpawn`'s concurrent-execution primitive itself does
//!      not run user code on `--target dotnet` today, independent of
//!      sibling-cancel — a materially bigger gap than the missing
//!      cancel-on-fault feature this slice set out to restore, and out of
//!      scope for this change to root-cause and fix.  Needs its own
//!      dedicated investigation and issue.
//!
//! What *did* ship from this investigation: `await` on any extern-declared
//! `Task`-typed value (`delay`, `delayWithCancel`, `awaitAll` below) did not
//! actually suspend/block at all before this change — `isTaskTypeMsil`
//! compared the awaited expression's TypeRef row against the compiler's own
//! eagerly-registered `cctx.trTask`/`cctx.trTask1` rows, which are never
//! seeded into the `ffiTypeRefs` cache `extern type Task = "System.Threading
//! .Tasks.Task"` interns through, so the two never matched and `await`
//! silently fell through to the "already-resolved" pass-through branch
//! (verified with `await delay(3000)`: ~0.9s total runtime before the fix,
//! ~3.9s after).  Fixed in `Msil.Codegen.isTaskTypeMsil`
//! (`lyric-compiler/msil/codegen.l`) by also recognizing a TypeRef cached
//! under the matching FFI key.  This is a real, load-bearing fix
//! independent of the three items above — every `Std.Task` consumer that
//! `await`s a `Task` value now actually waits.
//!
//! Group D1 / D-progress-stdlib-expand (2026-05):
//!   - `@externTarget("Lyric.Stdlib.AmbientSlot.Slot")` retired.
//!     The ambient `AsyncLocal[CancellationToken]` slot is now
//!     declared with `@asyncLocal val __ambientSlot` so the emitter
//!     synthesises the static `AsyncLocal<T>` field + `.cctor` init
//!     directly on this package's program type.
@runtime_checked
package Std.Task

import Std.Core
import Std.Errors
import Std.CollectionsHost

extern type Task = "System.Threading.Tasks.Task"

extern type CancellationToken = "System.Threading.CancellationToken"

extern type CancellationTokenSource = "System.Threading.CancellationTokenSource"

extern type AsyncLocal[T] = "System.Threading.AsyncLocal`1"

// =====================================================================
// Construction helpers.
// =====================================================================
/// A token that's never cancelled — equivalent to
/// `CancellationToken.None` in the BCL.  Use as the "no
/// cancellation requested" sentinel when an API requires a
/// token but the caller has no source.
@externTarget("System.Threading.CancellationToken.None")
pub func noCancellation(): CancellationToken = ()

/// Create a fresh `CancellationTokenSource`.  Pass its token
/// (`source.token()`) into cancellable async operations; call
/// `source.cancel()` when you want them to abort.  Sources own
/// unmanaged resources — wrap usage in `defer { source.dispose()
/// }` or use `withScope` for automatic cleanup.
@externTarget("System.Threading.CancellationTokenSource..ctor")
pub func makeCancelSource(): CancellationTokenSource = ()

/// Same as `makeCancelSource` but auto-cancels the resulting
/// source after `ms` milliseconds — convenient for deadline-
/// shaped scopes.  Routes through the `(int millisecondsDelay)`
/// constructor overload.
@externTarget("System.Threading.CancellationTokenSource..ctor")
pub func makeCancelSourceTimeout(ms: in Int): CancellationTokenSource = ()

// =====================================================================
// Source operations.
// =====================================================================
/// Project a token from a source.  Multiple calls return the
/// same token (BCL semantics).
@externTarget("System.Threading.CancellationTokenSource.Token")
pub func sourceToken(source: in CancellationTokenSource): CancellationToken = ()

/// Request cancellation.  Idempotent: subsequent calls are no-ops.
/// Spawned async work observing the source's token will see
/// `isCancelled == true` (and any `delayWithCancel` / similar in
/// flight will throw `OperationCanceledException` at the next
/// resume point).
@externTarget("System.Threading.CancellationTokenSource.Cancel")
pub func cancelSource(source: in CancellationTokenSource): Unit = ()

/// Release the source's unmanaged resources.  Always safe to
/// call after the source's last consumer has resumed.
@externTarget("System.Threading.CancellationTokenSource.Dispose")
pub func disposeSource(source: in CancellationTokenSource): Unit = ()

// =====================================================================
// Token observation.
// =====================================================================
/// Has cancellation been requested for this token's source?
/// Async loops can poll this between iterations as a cheap
/// alternative to `throwIfCancelled`.
@externTarget("System.Threading.CancellationToken.IsCancellationRequested")
pub func isCancelled(token: in CancellationToken): Bool = ()

/// Throw `OperationCanceledException` (which Lyric catches as
/// `Exception`) when the token has been cancelled.  Use as a
/// cooperative cancellation point inside long-running synchronous
/// stretches that can't naturally suspend.
@externTarget("System.Threading.CancellationToken.ThrowIfCancellationRequested")
pub func throwIfCancelled(token: in CancellationToken): Unit = ()

// =====================================================================
// Cancellable delay.
// =====================================================================
/// `Task.Delay(ms)` — non-cancellable timer.  Pre-Phase-C
/// callers continue to use this; the SM will suspend until `ms`
/// elapses.
@externTarget("System.Threading.Tasks.Task.Delay")
pub func delay(ms: in Int): Task = ()

/// `Task.Delay(ms, token)` — cancellable timer.  When the token
/// is cancelled before the timer fires, the awaiting state
/// machine resumes with `OperationCanceledException` (caught as
/// `Exception` on the Lyric side).  Phase C / D-progress-068.
@externTarget("System.Threading.Tasks.Task.Delay")
pub func delayWithCancel(ms: in Int, token: in CancellationToken): Task = ()

// =====================================================================
// BCL primitives used by structured-concurrency wrappers.
// =====================================================================
/// `Task.Run(action, token)` — schedule a `() -> Unit` closure
/// on the thread pool with scope-level cancellation.  Lyric's
/// `() -> Unit` closures lower to `System.Action`, so the BCL
/// `Task.Run(Action, CancellationToken)` overload is targeted.
@externTarget("System.Threading.Tasks.Task.Run")
func taskRunWithCancel(action: in () -> Unit, token: in CancellationToken): Task = ()

/// `Task.WhenAll(tasks)` — returns a task that completes when
/// every element of `tasks` completes.  Throws the first failure
/// exception when any child faults.
@externTarget("System.Threading.Tasks.Task.WhenAll")
func taskWhenAll(tasks: in slice[Task]): Task = ()

// =====================================================================
// Structured concurrency.  Group C / D-progress-stdlib-expand.
//
// `Scope` is now a native Lyric `protected type` rather than an
// extern alias for `Lyric.Stdlib.LyricTaskScope`.  It holds:
//   - `source`: a `CancellationTokenSource` for scope-level cancel
//   - `tasks`:  the list of registered child tasks
//
// Lock flavour: `PLRwLock` (has both `entry` and `func` members).
// Entry methods (addChild, cancel, dispose) acquire the write lock;
// func methods (token, snapshot) acquire the read lock.
//
// D119 slice S3 (sibling-cancel-on-first-fault) is NOT shipped here — see
// the module header for the three pre-existing MSIL-backend bugs found
// while investigating it.  `awaitAll` below still surfaces the first
// child's fault to the caller via `Task.WhenAll`; there is no eager
// cross-sibling cancel yet.
//
// The canonical usage pattern is unchanged:
//
//     async func parent(): Unit {
//       val scope = makeScope()
//       defer {
//         cancelScope(scope)
//         disposeScope(scope)
//       }
//       val tok = scopeToken(scope)
//       scopeSpawn(scope, child1(tok))
//       scopeSpawn(scope, child2(tok))
//       try {
//         await awaitAll(scope)
//       } catch Exception as e {
//         println("at least one child failed")
//       }
//     }
// =====================================================================
pub protected type Scope {
  var source: CancellationTokenSource = makeCancelSource()
  var tasks: List[Task] = newList()
  entry addChild(t: in Task): Unit {

    tasks.add(t)
  }
  func token(): CancellationToken {
    return sourceToken(source)
  }
  func snapshot(): slice[Task] {
    return tasks.toArray()
  }
  entry cancel(): Unit {
    cancelSource(source)
  }
  entry dispose(): Unit {
    disposeSource(source)
  }
}

/// Construct a fresh scope.  The scope owns a cancellation source
/// and an empty children list; spawn child tasks against it via
/// `scopeSpawn`, then `await awaitAll(scope)` to join them.  Always
/// pair construction with `defer { cancelScope(scope);
/// disposeScope(scope) }` so the source is released on scope exit.
pub func makeScope(): Scope {
  return Scope()
}

/// Project the scope's cancellation token.  Pass to child tasks
/// so they observe scope-level cancellation requests.
pub func scopeToken(s: in Scope): CancellationToken {
  return s.token()
}

/// Register an existing `Task` as a child of the scope.
pub func scopeAdd(s: in Scope, child: in Task): Unit {
  s.addChild(child)
}

/// Spawn a zero-arg closure on the thread pool, scoped to `scope`.
/// The closure runs on a thread-pool thread with the scope's token;
/// it can poll `isCancelled(scopeToken(scope))` to honour cancel.
///
/// Named `scopeSpawn` rather than the more idiomatic `spawn`
/// because `spawn` is a soft keyword reserved for the future
/// `spawn expr` syntactic form (`ESpawn` in the parser AST).
pub func scopeSpawn(s: in Scope, action: in () -> Unit): Unit {
  val tok = s.token()
  val t = taskRunWithCancel(action, tok)
  s.addChild(t)
}

/// Wait for every registered child to complete.  When any child
/// faults the call rethrows the underlying exception so the
/// caller's `try/catch` surfaces it.
pub func awaitAll(s: in Scope): Task {
  return taskWhenAll(s.snapshot())
}

/// Explicitly cancel the scope's source.  Idempotent.  Useful
/// for defer-based cleanup that signals children to abort.
pub func cancelScope(s: in Scope): Unit {
  s.cancel()
}

/// Release the scope's underlying source.  Always safe to call
/// from a `defer { ... }`.
pub func disposeScope(s: in Scope): Unit {
  s.dispose()
}

// =====================================================================
// AsyncLocal-backed ambient cancellation (D-progress-071).
//
// Group D1 (D-progress-stdlib-expand, 2026-05):
//   The singleton `AsyncLocal<CancellationToken>` slot that backs
//   this API was previously held by the F# `AmbientSlot` class and
//   accessed via `@externTarget("Lyric.Stdlib.AmbientSlot.Slot")`.
//   It is now declared with `@asyncLocal val __ambientSlot` so the
//   emitter synthesises:
//     static readonly AsyncLocal<CancellationToken> __asynclocal___ambientSlot
//         = new AsyncLocal<CancellationToken>();
//   directly on this package's program type, with no F# involved.
//
// `currentToken()` reads an ambient slot that flows naturally
// across `await` boundaries via .NET's `AsyncLocal<T>`.
// `installToken(token)` writes to that slot and returns the
// previous value so the caller can restore on exit:
//
//     val previous = installToken(scopeToken(sc))
//     defer { restoreToken(previous) }
//
// Async children can then call `currentToken()` to inherit the
// scope's cancellation token without threading it through every
// signature.  `hasAmbient()` returns true when a non-default
// token is installed; useful for libraries that want to fall
// back to "no cancellation" when the caller didn't supply one.
// =====================================================================
@asyncLocal
val __ambientSlot: AsyncLocal[CancellationToken] = ()

@externTarget("System.Threading.AsyncLocal`1.Value")
func ambientValue(slot: in AsyncLocal[CancellationToken]): CancellationToken = ()

@externTarget("System.Threading.AsyncLocal`1.set_Value")
func setAmbientValue(slot: in AsyncLocal[CancellationToken], v: in CancellationToken): Unit = ()

@externTarget("System.Threading.CancellationToken.CanBeCanceled")
func tokenCanBeCanceled(token: in CancellationToken): Bool = ()

/// Read the ambient cancellation token.  Returns the
/// never-cancelled `CancellationToken.None` when no scope is
/// active.
pub func currentToken(): CancellationToken {
  ambientValue(__ambientSlot)
}

/// Install `token` as the ambient.  Returns the previous value;
/// callers should `defer { restoreToken(previous) }` so the slot
/// is restored on scope exit (success or exception).
pub func installToken(token: in CancellationToken): CancellationToken {
  val previous = currentToken()
  setAmbientValue(__ambientSlot, token)
  return previous
}

/// Restore the ambient slot to `previous`.  Idempotent when
/// `previous` is the same value already installed.
pub func restoreToken(previous: in CancellationToken): Unit {
  setAmbientValue(__ambientSlot, previous)
}

/// True when the ambient slot holds a non-default token.  Used by
/// libraries to detect whether to honour the ambient or fall back
/// to no-cancellation semantics.
pub func hasAmbient(): Bool {
  tokenCanBeCanceled(currentToken())
}
