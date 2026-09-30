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
//!   1. At the time of this rewrite the JVM auto-FFI class-file reader
//!      skipped `ACC_INTERFACE` class files, so instance methods on JDK
//!      *interfaces* — `java.util.concurrent.ExecutorService`, `Future`,
//!      `Executor` — had no metadata-backed resolution path.  That reader
//!      limitation is gone (`Jvm.ClassReader.parseClass` handles interfaces
//!      and enums, D-progress-640/643, with interface receivers dispatched
//!      via `invokeinterface`), but this file's design predates it and
//!      still uses only *concrete* JDK classes
//!      (`java.util.concurrent.atomic.AtomicBoolean` / `AtomicReference`,
//!      `java.lang.Thread`, `java.lang.System`).
//!   2. A Lyric closure is not itself a JDK functional interface
//!      (`Runnable`/`Callable`/`Supplier`).  A plain record holding the
//!      closure can implement `java.lang.Runnable` through an
//!      `impl JRunnable for ...` block (docs/51), and that record is what
//!      `scopeSpawn` and `runActionWithin` hand to `java.lang.Thread`.
//!
//! Consequences of (1) + (2) for this module's design:
//!
//!   - `Scope.scopeSpawn` starts each action at once on a virtual thread
//!     (`Thread.startVirtualThread`), as `_kernel/task.l` starts it at once
//!     on the thread pool (`Task.Run`); `awaitAll` joins every thread
//!     started so far.
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
//!     (`System.nanoTime() - deadline >= 0`, monotonic and wrap-safe —
//!     not wall-clock `currentTimeMillis()`, which would diverge from
//!     .NET's real timer under an NTP step or manual clock change, #5348)
//!     folded into `isCancelled`/`throwIfCancelled` rather than an
//!     eagerly-scheduled background canceller — the latter would need
//!     exactly the Runnable-bridging (2) rules out.  This is equivalent
//!     for every consumer here, since cancellation is cooperative-poll-
//!     based throughout this API.
//!   - The ambient token slot uses `java.lang.ThreadLocal` (not
//!     `ScopedValue`, which is still a JDK 21 preview API — the same
//!     reason D120 rejected `StructuredTaskScope` for the `scope`/`spawn`
//!     keyword codegen) and, unlike .NET's real `AsyncLocal<T>` flow, does
//!     NOT automatically propagate into a `scopeSpawn`-launched virtual
//!     thread; pass the token explicitly to spawned children (the
//!     canonical usage pattern below already does this).
//!
@runtime_checked
@io
package Std.Task

import Std.Core
import Std.CollectionsHost

extern type JAtomicBoolean = "java.util.concurrent.atomic.AtomicBoolean"

extern type JAtomicReference = "java.util.concurrent.atomic.AtomicReference"

extern type JThread = "java.lang.Thread"

extern type JSystem = "java.lang.System"

extern type JThreadLocal = "java.lang.ThreadLocal"

extern type JRunnable = "java.lang.Runnable"

extern type JReentrantLock = "java.util.concurrent.locks.ReentrantLock"

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

// The single shared flag every `noCancellation()` token carries (#5331):
// `hasAmbient()` recognises this exact reference to mean "no ambient
// cancellation source," matching .NET's `CancellationToken.CanBeCanceled`
// semantics (false for `CancellationToken.None`) — not `JAtomicBoolean`
// identity of *some* fresh flag, which a round-tripped `noCancellation()`
// token would also have and so couldn't be told apart from a real one.
val __noCancellationFlag: JAtomicBoolean = JAtomicBoolean.new(false)

/// A token that's never cancelled — equivalent to
/// `CancellationToken.None` on .NET.  Use as the "no cancellation
/// requested" sentinel when an API requires a token but the caller
/// has no source.
pub func noCancellation(): CancellationToken {
  CancellationToken(flag = __noCancellationFlag, deadlineMs = 0i64)
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
///
/// `deadlineMs` (field name kept for API parity with the record's other
/// constructors) actually stores a `System.nanoTime()`-relative deadline
/// in nanoseconds, not epoch milliseconds — `System.currentTimeMillis()`
/// is wall-clock and subject to NTP steps, leap-second smears, and manual
/// clock changes, which would fire this timeout early or late relative to
/// .NET's `CancellationTokenSource` timer (#5348).  `System.nanoTime()` is
/// monotonic and immune to all of that.  On the real target platform
/// (Linux/OpenJDK), `nanoTime()` is boot-relative and always a large
/// positive number, so a freshly computed deadline colliding with the
/// `deadlineMs == 0` "no deadline" sentinel used by `isCancelled` below is
/// not a practical concern.
pub func makeCancelSourceTimeout(ms: in Int): CancellationTokenSource {
  val deadlineNanos = JSystem.nanoTime() + ms.toLong() * 1000000i64
  CancellationTokenSource(flag = JAtomicBoolean.new(false), deadlineMs = deadlineNanos)
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
///
/// The deadline comparison is written as a subtraction
/// (`nanoTime() - deadline >= 0`) rather than a direct `>=` against two
/// independently-read `nanoTime()` values: `System.nanoTime()` is only
/// guaranteed monotonic and can wrap around `Long` after ~292 years of
/// continuous uptime.  Subtraction-then-compare is the standard idiom
/// (matching `System.nanoTime()`'s own Javadoc) because two's-complement
/// wraparound still yields the correct signed difference across the wrap
/// boundary, whereas a direct `>=` would not.
pub func isCancelled(token: in CancellationToken): Bool {
  if token.flag.get() {
    true
  } else if token.deadlineMs > 0i64 {
    JSystem.nanoTime() - token.deadlineMs >= 0i64
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
  JThread.sleep(ms.toLong())
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
    JThread.sleep(step.toLong())
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
// Structured concurrency.  `scopeSpawn` starts each action at once on a
// virtual thread (`Thread.startVirtualThread` over a `Runnable` record),
// as `_kernel/task.l` starts it at once with `Task.Run`.  The scope keeps
// the started threads in a list guarded by a `ReentrantLock`, since
// actions may spawn further actions from their own threads, and
// `awaitAll` joins every thread started so far.
//
// Sibling-cancel-on-first-fault mirrors `_kernel/task.l`'s `runGuardedNet`:
// each action is wrapped so a fault sets the shared cancellation flag and
// (first-fault-wins, via `AtomicBoolean.compareAndSet`) records the
// failure message; awaitAll re-panics with it once every action has
// joined.
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
  threads: List[JThread]
  guard: JReentrantLock
  flag: JAtomicBoolean
  hasFault: JAtomicBoolean
  firstFault: JAtomicReference
}

/// Construct a fresh scope.  Start children with `scopeSpawn`, then
/// `await awaitAll(scope)` to join them.
pub func makeScope(): Scope {
  Scope(
    threads = newList(),
    guard = JReentrantLock.new(),
    flag = JAtomicBoolean.new(false),
    hasFault = JAtomicBoolean.new(false),
    firstFault = JAtomicReference.new("")
  )
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

// One `scopeSpawn`ed action, run on its own virtual thread.
record ScopeJob {
  action: () -> Unit
  owner: Scope
}

impl JRunnable for ScopeJob {
  func run(): Unit {
    runGuardedJvm(self.action, self.owner.flag, self.owner.hasFault, self.owner.firstFault)
  }
}

// Tail-position forms: a discarded auto-FFI instance call whose receiver
// is a parameter emits no invoke on this backend (#5379).
func scopeLock(g: in JReentrantLock): Unit {
  g.lock()
}

func scopeUnlock(g: in JReentrantLock): Unit {
  g.unlock()
}

func scopeThreadJoin(t: in JThread): Unit {
  t.join()
}

/// Start a zero-arg closure on a virtual thread, scoped to `s`.  It can
/// poll `isCancelled(scopeToken(s))` to honour cancellation.
///
/// Named `scopeSpawn` rather than the more idiomatic `spawn` because
/// `spawn` is a soft keyword reserved for the `spawn expr` syntactic
/// form (`ESpawn` in the parser AST).
pub func scopeSpawn(s: in Scope, action: in () -> Unit): Unit {
  val t: JThread = JThread.startVirtualThread(ScopeJob(action = action, owner = s))
  scopeLock(s.guard)
  defer {
    scopeUnlock(s.guard)
  }
  // Drop the threads that have finished, so a long-lived scope that spawns
  // without joining (a UI session running its effects) holds only its
  // running children.  A failure is already recorded in `firstFault`.
  var i = 0
  while i < s.threads.count {
    if scopeThreadAlive(s.threads[i]) {
      i = i + 1
    } else {
      s.threads.removeAt(i)
    }
  }
  s.threads.add(t)
}

func scopeThreadAlive(t: in JThread): Bool {
  t.isAlive()
}

/// The number of children the scope still tracks: those still running.  A
/// child that finished is dropped the next time the scope spawns; a failure
/// stays recorded for `awaitAll`.
pub func scopePendingCount(s: in Scope): Int {
  scopeLock(s.guard)
  defer {
    scopeUnlock(s.guard)
  }
  s.threads.count
}

// Run `action`; on a caught exception, record the first failure's
// message (first-fault-wins, guarded by `hasFault` rather than an
// empty-string sentinel on `firstFault` — a sibling panicking with an
// empty message must still be treated as a real fault, #5327) and set
// the scope's cancellation flag so cooperative siblings still running
// observe it.  Swallows the exception: `awaitAll` inspects
// `firstFault`/`hasFault` itself after every action has joined.
func runGuardedJvm(
  action: in () -> Unit,
  flag: in JAtomicBoolean,
  hasFault: in JAtomicBoolean,
  firstFault: in JAtomicReference,
): Unit {
  try {
    action()
  } catch Bug as b {
    if hasFault.compareAndSet(false, true) {
      firstFault.set(b.message)
    }
    flag.set(true)
  }
}

// The threads started so far, copied under the scope's lock.
func scopeThreads(s: in Scope): List[JThread] {
  val copy: List[JThread] = newList()
  scopeLock(s.guard)
  defer {
    scopeUnlock(s.guard)
  }
  for t in s.threads {
    copy.add(t)
  }
  copy
}

/// Join every action started by `scopeSpawn` so far.  When any faulted,
/// `flag` has been cancelled for cooperative siblings and the first
/// failure's message is re-panicked once every action has completed —
/// matching `_kernel/task.l`'s "rethrows the underlying exception"
/// contract.
pub func awaitAll(s: in Scope): Task {
  for t in scopeThreads(s) {
    scopeThreadJoin(t)
  }
  if not s.hasFault.get() {
    Task(done = true)
  } else {
    val msg: String = s.firstFault.get()
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

/// True when the ambient slot holds a token that can actually be
/// cancelled — false both when nothing has ever been installed on this
/// thread AND when the ambient has been explicitly installed/restored to
/// `noCancellation()` (#5331; matches .NET's `CancellationToken
/// .CanBeCanceled`, which is false for `CancellationToken.None` too, not
/// an identity/"was install ever called" check).
pub func hasAmbient(): Bool {
  val v: JAtomicBoolean = __ambientSlot.get()
  not (v == __ambientNullProbe.get()) and not (v == __noCancellationFlag)
}

// =====================================================================
// Bounded-wait single-closure execution (#7461, D-progress-1021).
//
// Unlike `scopeSpawn`/`awaitAll` above, `runWithin` does NOT go through
// the `spawn`/`scope { }` keywords: their join is an unconditional full
// wait with no bounded/timeout variant (module header), so they cannot
// give a real preemptive bound. Instead this mirrors the daemon-thread
// idiom `Std.ConsoleHost`'s bounded stdin reader already ships
// (`_kernel_jvm/console_host.l`'s `StdinReadJob` / `startJob` /
// `joinStdinRead`, #7451): a plain record implements `java.lang.Runnable`
// via `impl` (the docs/51 FFI-interfaces mechanism — verified working on
// this target by that same file), runs on a `new Thread(Runnable)`
// (real concurrent execution, not the closure-to-JDK-functional-
// interface bridge the module header says doesn't exist for a *generic*
// stdlib API), and the calling thread bounds its wait with the real
// `Thread.join(long millis)` — which genuinely stops blocking once
// `millis` elapses, giving the preemptive enforcement `#7461` asks for.
//
// `T` never crosses the JDK boundary: `RunWithinJob`'s `action` field is
// a plain `() -> Unit` closure that writes its result (or a panic
// message) into a captured `List` used as a one-slot cell, so the
// `Runnable` implementation itself stays untyped in `T`.
// =====================================================================
// One `action` run on a daemon thread; `done` flips only after `action`
// (and therefore any `add` into its captured result `List`) has
// returned, so a caller that observes `done == true` sees a fully
// published result — no separate memory-visibility mechanism is needed
// beyond `AtomicBoolean`'s own happens-before guarantee.
record RunWithinJob {
  action: () -> Unit
  done: JAtomicBoolean
}

impl JRunnable for RunWithinJob {
  func run(): Unit {
    self.action()
    runWithinDoneSet(self.done, true)
  }
}

// Tail-position forms: a discarded auto-FFI instance call whose receiver
// is a parameter emits no invoke on this backend (#5379) — same
// workaround `_kernel_jvm/console_host.l`'s `atomicBoolSet`/
// `threadJoinMs`/`threadSetDaemon`/`threadStart` already use.
func runWithinDoneSet(a: in JAtomicBoolean, v: in Bool): Unit {
  a.set(v)
}

func runWithinDoneGet(a: in JAtomicBoolean): Bool {
  a.get()
}

func runWithinThreadJoinMs(t: in JThread, ms: in Long): Unit {
  t.join(ms)
}

func runWithinThreadSetDaemon(t: in JThread, on: in Bool): Unit {
  t.setDaemon(on)
}

func runWithinThreadStart(t: in JThread): Unit {
  t.start()
}

/// Run `action` on a daemon platform thread and block the calling thread
/// for at most `timeoutMs` milliseconds (`Thread.join(long)`); returns
/// `true` when `action` completed within the budget, `false` on timeout.
/// The non-generic engine `runWithin[T]` builds on — kept `pub` (rather
/// than `RunWithinJob`/the raw `Thread` helpers above) so a generic
/// function's per-caller specialisation only ever needs one exported
/// name. `timeoutMs == 0` never calls `Thread.join(0)` — that overload
/// means "wait forever," not "don't wait," on the JDK — so a zero
/// budget is implemented as an immediate, un-joined check of whether
/// `action` happened to already finish.
pub func runActionWithin(action: in () -> Unit, timeoutMs: in Int): Bool
  requires: timeoutMs >= 0
{
  val done: JAtomicBoolean = JAtomicBoolean.new(false)
  val job = RunWithinJob(action = action, done = done)
  val t: JThread = JThread.new(job)
  runWithinThreadSetDaemon(t, true)
  runWithinThreadStart(t)
  if timeoutMs > 0 {
    runWithinThreadJoinMs(t, timeoutMs.toLong())
  }
  return runWithinDoneGet(done)
}

/// Run `f` on a daemon platform thread and block the calling thread for
/// at most `timeoutMs` milliseconds (`Thread.join(long)`).
///
/// Returns `Some(result)` when `f` completes within the budget, or
/// `None` on timeout. A timed-out computation keeps running in the
/// background: there is no JDK API to forcibly abort a running thread,
/// so a slow `f` continues running on its daemon thread after
/// `runWithin` has already returned `None` to its caller (a daemon
/// thread never keeps the JVM process alive on its own, but it is not
/// killed either).
///
/// `timeoutMs == 0` never calls `Thread.join(0)` — that overload means
/// "wait forever," not "don't wait," on the JDK — so a zero budget is
/// implemented as an immediate, un-joined check of whether `f` happened
/// to already finish.
///
/// A panic inside `f` is captured on the background thread and, once
/// observed here (which only happens if it occurs before the deadline),
/// is **re-raised on the calling thread** — `runWithin` itself panics
/// with the same message, exactly as a direct call to `f()` would.
/// Panics are never swallowed; a caller that wants panic isolation on
/// top of the timeout wraps the call in its own
/// `try { ... } catch Bug as b { ... }` (the pattern `Health`'s
/// `runCheckIsolated` uses). A panic that occurs only after the deadline
/// has already elapsed is unobservable — the same "keeps running in the
/// background" caveat above.
pub func runWithin[T](timeoutMs: in Int, f: in () -> T): Option[T]
  requires: timeoutMs >= 0
{
  val results: List[T] = newList()
  val panics: List[String] = newList()
  val action: () -> Unit = { -> try { results.add(f()) } catch Bug as b { panics.add(b.message) } }
  val completed = runActionWithin(action, timeoutMs)
  if not completed {
    return None
  }
  if panics.count > 0 {
    panic(panics[0])
  }
  if results.count > 0 {
    return Some(results[0])
  }
  return None
}
