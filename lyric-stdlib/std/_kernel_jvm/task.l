//! std/_kernel_jvm/task.l — JVM host boundary for async task primitives
//! and cancellation tokens.
//!
//! Mirrors _kernel/task.l for the JVM target.
//!
//! Fixes a phantom-kernel landmine (matching the pattern already fixed for
//! Std.File/Std.Console/Std.Time/Std.Parse, Std.Math/Std.Uuid/Std.Char/
//! Std.Json, and other stdlib modules): the previous version of this file
//! declared `extern type Scope = "lyric.runtime.LyricTaskScope"` and
//! `extern package lyric.stdlib.jvm.TaskScopeHost { ... }` against classes
//! that do not exist anywhere in the runtime — every call threw
//! `NoClassDefFoundError`/`ClassNotFoundException`.  Rewritten as pure
//! Lyric directly over real JDK classes via the JVM auto-FFI.
//!
//! Two hard constraints shaped this rewrite (both verified empirically,
//! not assumed):
//!
//!   1. The JVM auto-FFI class-file reader intentionally skips
//!      `ACC_INTERFACE` class files (`Jvm.ClassReader.parseClass`), so
//!      instance methods on JDK *interfaces* — `java.util.concurrent
//!      .ExecutorService`, `Future`, `Executor` — have no metadata-backed
//!      resolution path; calling them falls through to the legacy blind
//!      guess and throws `IncompatibleClassChangeError` at runtime.  Only
//!      *concrete* JDK classes (`java.util.concurrent.atomic.AtomicBoolean`
//!      / `AtomicReference`, `java.lang.Thread`, `java.lang.System`) are
//!      usable from this file.
//!   2. Lyric closures have no bridge to arbitrary JDK functional
//!      interfaces (`Runnable`/`Callable`/`Supplier`) — that adaptation
//!      exists only inside the compiler's own `spawn`/`scope { }` keyword
//!      codegen (a package-private synthesized `Callable`), not as
//!      something a plain `.l` source file can invoke for a library API.
//!      So the *only* way to get genuine concurrent execution of an
//!      arbitrary `() -> Unit` value from pure Lyric here is the
//!      `spawn`/`scope`/`await` language keywords themselves.
//!
//! Consequences of (1) + (2) for this module's design:
//!
//!   - `Scope.scopeSpawn` defers each action into a plain `List[() ->
//!     Unit]` rather than launching it immediately (unlike .NET's
//!     `Task.Run`, there is no interface-free way to hand a closure to a
//!     background executor outside `awaitAll`).  `awaitAll` is where the
//!     actions actually run: it opens one `scope { }` and `spawn`s each
//!     pending action (JDK 21 virtual threads under the hood), so
//!     independently-`scopeSpawn`ed children genuinely run concurrently.
//!     A caller cannot observe "did this start yet" without `awaitAll`,
//!     but the documented contract — spawn children, then `await
//!     awaitAll(scope)` to join them — is unaffected.
//!   - Each spawned action is wrapped so a fault sets the scope's shared
//!     `AtomicBoolean` cancellation flag and records the first failure's
//!     message (via `AtomicReference.compareAndSet`, so only the first
//!     fault wins); cooperative siblings checking `isCancelled`/
//!     `throwIfCancelled` observe the cancellation while still running —
//!     the same cooperative-cancellation contract `_kernel/task.l`
//!     documents (never a forced interrupt).  `awaitAll` re-panics with
//!     the first failure's message once every spawned action has joined.
//!   - `delay`/`delayWithCancel` block the calling (virtual) thread
//!     directly (`Thread.sleep`, chunked so a cancellation token or a
//!     `makeCancelSourceTimeout` deadline is observed promptly rather than
//!     only after the full duration) — matching this file's own
//!     previously-declared (never-shipped) intent ("Both variants run on
//!     the calling virtual thread").  A `Task` value produced this way is
//!     therefore always already-resolved by the time the caller holds it;
//!     `scopeAdd` (registering a pre-existing `Task`) is consequently a
//!     structural no-op on this target — there is nothing left to track.
//!     `scopeSpawn` is the concurrency primitive on this target.
//!   - `makeCancelSourceTimeout`'s auto-cancel is a *lazy* deadline check
//!     (`now >= deadline`) folded into `isCancelled`/`throwIfCancelled`
//!     rather than an eagerly-scheduled background canceller — the latter
//!     would need exactly the Runnable-bridging (2) rules out.  This is
//!     equivalent for every consumer here, since cancellation is
//!     cooperative-poll-based throughout this API.
//!   - The ambient token slot uses `java.lang.ThreadLocal` (not
//!     `ScopedValue`, which is still a JDK 21 preview API — the same
//!     reason D120 rejected `StructuredTaskScope` for the `scope`/`spawn`
//!     keyword codegen) and, unlike .NET's real `AsyncLocal<T>` flow, does
//!     NOT automatically propagate into a `scopeSpawn`-launched virtual
//!     thread; pass the token explicitly to spawned children (the
//!     canonical usage pattern below already does this).
//!
//! KNOWN GAP found while verifying this rewrite end-to-end (not introduced
//! by it — reproduced with a standalone two-package repro carrying no
//! dependency on this file): a closure literal passed as a `() -> Unit`
//! argument into a function declared in ANOTHER package, stored, and later
//! invoked via `spawn` from inside that other package's own body throws
//! `ClassCastException` — the closure implements the calling package's own
//! synthesized `<callerPkg>/Lyric$Lambda` interface, but the callee
//! checkcasts to `<calleePkg>/Lyric$Lambda` before invoking it (every
//! lambda-related check in `lyric-compiler/jvm/codegen/*.l` keys off
//! `ctx.pkgName`, the package currently being lowered, with no cross-
//! package interface adaptation).  A same-package consumer of `Scope`
//! (verified working) or a direct, non-deferred `spawn action()` cross-
//! package call (also verified working — the mismatch is specific to the
//! store-then-spawn-via-a-different-function shape `scopeSpawn`/`awaitAll`
//! split into) are unaffected.  This is a pre-existing, general JVM-backend
//! gap — not specific to `Std.Task` — and out of scope to fix here; a
//! dedicated follow-up is needed before `Scope` is reliable for genuine
//! cross-package consumers on this target.  `task_tests.l` documents the
//! same finding against the real package boundary.
@runtime_checked
package Std.Task

import Std.Core
import Std.CollectionsHost

extern type JAtomicBoolean = "java.util.concurrent.atomic.AtomicBoolean"

extern type JAtomicReference = "java.util.concurrent.atomic.AtomicReference"

extern type JThread = "java.lang.Thread"

extern type JSystem = "java.lang.System"

extern type JThreadLocal = "java.lang.ThreadLocal"

// =====================================================================
// Cancellation tokens.  `CancellationTokenSource`/`CancellationToken`
// share one mutable `AtomicBoolean` flag (the source owns write access,
// both can read it) plus an optional absolute-epoch-ms deadline for
// `makeCancelSourceTimeout`'s lazy auto-cancel (see module header).
// =====================================================================
pub record CancellationTokenSource {
  flag: JAtomicBoolean
  deadlineMs: Long
}

pub record CancellationToken {
  flag: JAtomicBoolean
  deadlineMs: Long
}

/// A token that's never cancelled — equivalent to
/// `CancellationToken.None` on .NET.  Use as the "no cancellation
/// requested" sentinel when an API requires a token but the caller
/// has no source.
pub func noCancellation(): CancellationToken {
  CancellationToken(flag = JAtomicBoolean.new(false), deadlineMs = 0i64)
}

/// Create a fresh `CancellationTokenSource`.  Project its token via
/// `sourceToken`; call `cancelSource` when you want cancellable
/// operations observing it to abort.
pub func makeCancelSource(): CancellationTokenSource {
  CancellationTokenSource(flag = JAtomicBoolean.new(false), deadlineMs = 0i64)
}

/// Same as `makeCancelSource` but auto-cancels after `ms`
/// milliseconds.  Implemented as a lazy deadline check folded into
/// `isCancelled`/`throwIfCancelled` (module header) rather than an
/// eagerly-scheduled background canceller.
pub func makeCancelSourceTimeout(ms: in Int): CancellationTokenSource {
  CancellationTokenSource(flag = JAtomicBoolean.new(false), deadlineMs = JSystem.currentTimeMillis() + intToLong(ms))
}

/// Project a token from a source.  The token shares the source's
/// flag reference, so an explicit `cancelSource` call is always
/// visible through any token derived from it.
pub func sourceToken(source: in CancellationTokenSource): CancellationToken {
  CancellationToken(flag = source.flag, deadlineMs = source.deadlineMs)
}

/// Request cancellation.  Idempotent: subsequent calls are no-ops.
pub func cancelSource(source: in CancellationTokenSource): Unit {
  source.flag.set(true)
}

/// No unmanaged resources to release on this target; kept for API
/// parity with .NET's `CancellationTokenSource.Dispose`.
pub func disposeSource(source: in CancellationTokenSource): Unit {
  ()
}

/// Has cancellation been requested — explicitly, or via an elapsed
/// `makeCancelSourceTimeout` deadline?
pub func isCancelled(token: in CancellationToken): Bool {
  if token.flag.get() {
    true
  } else if token.deadlineMs > 0i64 {
    JSystem.currentTimeMillis() >= token.deadlineMs
  } else {
    false
  }
}

/// Panic (Lyric's `catch Exception` observes it, matching .NET's
/// `OperationCanceledException`) when the token has been cancelled.
pub func throwIfCancelled(token: in CancellationToken): Unit {
  if isCancelled(token) {
    panic("OperationCanceledException: cancellation was requested")
  }
}

// =====================================================================
// Cancellable delay.  Blocks the calling (virtual) thread directly —
// see the module header for why that's the correct model here.
// =====================================================================
func sleepChunkMs(): Int {
  20
}

/// `Thread.sleep(ms)` — non-cancellable.
pub func delay(ms: in Int): Task {
  JThread.sleep(intToLong(ms))
  Task(done = true)
}

/// Chunked `Thread.sleep`, polling `throwIfCancelled` between chunks
/// so an explicit cancel or an elapsed timeout deadline is observed
/// within one chunk instead of only after the full duration.
pub func delayWithCancel(ms: in Int, token: in CancellationToken): Task {
  val chunk = sleepChunkMs()
  var remaining = ms
  while remaining > 0 {
    throwIfCancelled(token)
    val step = if remaining < chunk { remaining } else { chunk }
    JThread.sleep(intToLong(step))
    remaining = remaining - step
  }
  throwIfCancelled(token)
  Task(done = true)
}

// =====================================================================
// `Task` — see the module header: a value produced by any function in
// this file is always already-resolved (the producing call already
// blocked, or `awaitAll` already joined every spawned child) by the
// time the caller holds it.
// =====================================================================
pub record Task {
  done: Bool
}

// =====================================================================
// Structured concurrency.  `Scope` defers `scopeSpawn`ed actions into a
// plain list; `awaitAll` is where they actually run — concurrently, via
// the `spawn`/`scope { }` language keywords (the only closure-to-
// concurrent-execution bridge reachable from pure Lyric on this target;
// see the module header).  Sibling-cancel-on-first-fault mirrors
// `_kernel/task.l`'s `runGuardedNet`: each spawned action is wrapped so a
// fault sets the shared cancellation flag and (first-fault-wins, via
// `AtomicReference.compareAndSet`) records the failure message; awaitAll
// re-panics with it once every action has joined.
//
// The canonical usage pattern is unchanged from `_kernel/task.l`:
//
//     async func parent(): Unit {
//       val scope = makeScope()
//       defer {
//         cancelScope(scope)
//         disposeScope(scope)
//       }
//       val tok = scopeToken(scope)
//       scopeSpawn(scope, { -> child1(tok) })
//       scopeSpawn(scope, { -> child2(tok) })
//       try {
//         await awaitAll(scope)
//       } catch Exception as e {
//         println("at least one child failed")
//       }
//     }
// =====================================================================
pub record Scope {
  actions: List[() -> Unit]
  flag: JAtomicBoolean
}

/// Construct a fresh scope.  Register children via `scopeSpawn`, then
/// `await awaitAll(scope)` to run and join them.
pub func makeScope(): Scope {
  Scope(actions = newList(), flag = JAtomicBoolean.new(false))
}

/// Project the scope's cancellation token.  Pass to child actions so
/// they can cooperatively observe scope-level cancellation (explicit,
/// or triggered by a sibling's fault).
pub func scopeToken(s: in Scope): CancellationToken {
  CancellationToken(flag = s.flag, deadlineMs = 0i64)
}

/// Register an existing `Task` as a child of the scope.  A structural
/// no-op on this target: every `Task` value here is already resolved
/// by construction (module header), so there is nothing left to join.
/// Kept for API parity with `_kernel/task.l`.
pub func scopeAdd(s: in Scope, child: in Task): Unit {
  ()
}

/// Register a zero-arg closure to run when the scope is joined via
/// `awaitAll`.  Unlike .NET's `Task.Run`-backed `scopeSpawn`, the
/// action does not start immediately (module header); `awaitAll` runs
/// every registered action concurrently and joins them all.
///
/// Named `scopeSpawn` rather than the more idiomatic `spawn` because
/// `spawn` is a soft keyword reserved for the `spawn expr` syntactic
/// form (`ESpawn` in the parser AST).
pub func scopeSpawn(s: in Scope, action: in () -> Unit): Unit {
  s.actions.add(action)
}

// Run `action`; on a caught exception, record the first failure's
// message (first-fault-wins) and set the scope's cancellation flag so
// cooperative siblings still running observe it.  Swallows the
// exception rather than rethrowing: `awaitAll` inspects `firstFault`
// itself after every spawned action has joined, rather than relying on
// the joined `Future`'s own (unreachable via plain auto-FFI; see the
// module header) exception surface.
func runGuardedJvm(action: in () -> Unit, flag: in JAtomicBoolean, firstFault: in JAtomicReference): Unit {
  try {
    action()
  } catch Bug as b {
    val _ = firstFault.compareAndSet("", b.message)
    flag.set(true)
  }
}

/// Run every action registered via `scopeSpawn` concurrently (real
/// virtual threads, via the `spawn`/`scope { }` keywords) and join all
/// of them.  When any faults, `flag` is cancelled for cooperative
/// siblings and the first failure's message is re-panicked once every
/// action has completed — matching `_kernel/task.l`'s "rethrows the
/// underlying exception" contract.
pub func awaitAll(s: in Scope): Task {
  val firstFault: JAtomicReference = JAtomicReference.new("")
  scope {
    var i = 0
    while i < s.actions.count {
      val act = s.actions[i]
      spawn runGuardedJvm(act, s.flag, firstFault)
      i = i + 1
    }
  }
  val msg: String = firstFault.get()
  if msg == "" {
    Task(done = true)
  } else {
    panic(msg)
  }
}

/// Explicitly cancel the scope's flag.  Idempotent.
pub func cancelScope(s: in Scope): Unit {
  s.flag.set(true)
}

/// No unmanaged resources to release on this target; kept for API
/// parity with `_kernel/task.l`'s `disposeScope`.
pub func disposeScope(s: in Scope): Unit {
  ()
}

// =====================================================================
// Ambient cancellation slot.  `java.lang.ThreadLocal`-backed (module
// header explains why not `ScopedValue`); same-thread install/restore
// discipline only — does not auto-propagate into a `scopeSpawn`ed
// virtual thread the way .NET's real `AsyncLocal<T>` does.
// =====================================================================
val __ambientSlot: JThreadLocal = JThreadLocal.new()

// Deadline companion to `__ambientSlot`, always `.set()` in lockstep with
// it (install/restore below) — `flag` alone can't carry a
// `makeCancelSourceTimeout` token's deadline, so a token round-tripped
// through the ambient slot silently lost its auto-cancel (#5320).
val __ambientDeadlineSlot: JThreadLocal = JThreadLocal.new()

// A ThreadLocal that is never `.set()` anywhere, so `.get()` reliably
// returns the JVM-default `null` on any thread — used as a comparison
// sentinel since Lyric has no `null` literal (#4775).
val __ambientNullProbe: JThreadLocal = JThreadLocal.new()

/// Read the ambient cancellation token.  Returns the never-cancelled
/// `noCancellation()` when nothing has been installed on this thread.
pub func currentToken(): CancellationToken {
  val v: JAtomicBoolean = __ambientSlot.get()
  if v == __ambientNullProbe.get() {
    noCancellation()
  } else {
    val d: Long = __ambientDeadlineSlot.get()
    CancellationToken(flag = v, deadlineMs = d)
  }
}

/// Install `token` as the ambient on the calling thread.  Returns the
/// previous value so the caller can restore it on exit.
pub func installToken(token: in CancellationToken): CancellationToken {
  val previous = currentToken()
  __ambientSlot.set(token.flag)
  __ambientDeadlineSlot.set(token.deadlineMs)
  previous
}

/// Restore the ambient slot to `previous`.
pub func restoreToken(previous: in CancellationToken): Unit {
  __ambientSlot.set(previous.flag)
  __ambientDeadlineSlot.set(previous.deadlineMs)
}

/// True when the ambient slot holds an installed token on this
/// thread.
pub func hasAmbient(): Bool {
  val v: JAtomicBoolean = __ambientSlot.get()
  not (v == __ambientNullProbe.get())
}
