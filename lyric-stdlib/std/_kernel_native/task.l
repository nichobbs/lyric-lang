//! std/_kernel_native/task.l — native-target twin of `_kernel/task.l`:
//! cancellation tokens, structured-concurrency scopes, an ambient token and
//! bounded waits, over `pthread` threads from lyric-rt.
//!
//! The public surface is the `Std.Task` surface on the other two targets; the
//! native loader picks this file by basename.  The design follows the JVM twin
//! (`_kernel_jvm/task.l`), adapted to what native has:
//!
//!   - **No unwinding (D-N-003).**  A panic ends the process, so there is no
//!     fault to record or rethrow: a child that panics takes the program down
//!     with it, `awaitAll` never has a failure to report, and `runWithin` does
//!     not capture a panic from its closure.  `throwIfCancelled` panics, as it
//!     does on the other targets, but a panic cannot be caught here.
//!     `delayWithCancel` therefore returns early when its token is cancelled
//!     (callers test `isCancelled` afterwards) instead of panicking, since a
//!     routine cancellation must not end the process.
//!   - **Tasks are already resolved.**  `Task` is a record: `delay`,
//!     `delayWithCancel` and `awaitAll` block the calling thread and return a
//!     finished `Task`, and `scopeAdd` is a no-op.  `scopeSpawn` is the
//!     concurrency primitive: it starts the action on its own thread at once.
//!   - **No module state in a bundled stdlib package**, and no condition
//!     variables: every flag and child list is guarded by lyric-rt's one global
//!     lock (`lyric_global_lock`, held only for a read or a write) and waits poll
//!     at one-millisecond steps.
//!   - **Deadlines are lazy.**  `makeCancelSourceTimeout` stores a monotonic
//!     deadline that `isCancelled` compares against; no timer thread exists.
//!   - **The ambient token is per thread** (a lyric-rt thread slot).  A child
//!     started by `scopeSpawn` inherits its parent's ambient token, as an
//!     `AsyncLocal` flows into `Task.Run` on .NET.
//!
//! Only `Std.Task` should import this.
@axiom("lyric_global_lock/unlock, lyric_thread_ref_*, lyric_thread_spawn_detached and lyric_monotonic_nanos (lyric-rt) conform to their documented contracts; lyric_retain/lyric_release are the ARC primitives")
@runtime_checked
@io
package Std.Task

import Std.Core
import Std.Collections
import Std.TimeHost

extern func rtGlobalLock(): Unit = "lyric_global_lock"

extern func rtGlobalUnlock(): Unit = "lyric_global_unlock"

extern func rtThreadRefSet(obj: CancellationTokenSource): Unit = "lyric_thread_ref_set"

extern func rtThreadRefClear(): Unit = "lyric_thread_ref_clear"

extern func rtThreadRefGet(): CancellationTokenSource = "lyric_thread_ref_get"

extern func rtThreadRefHas(): Int = "lyric_thread_ref_has"

extern func rtMonotonicNanos(): Long = "lyric_monotonic_nanos"

extern func rtRetain(p: NativePtr[Byte]): Unit = "lyric_retain"

extern func rtRelease(p: NativePtr[Byte]): Unit = "lyric_release"

extern func rtThreadSpawnDetached(start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "lyric_thread_spawn_detached"

// =====================================================================
// Cancellation tokens.  A source owns the flag and an optional monotonic
// deadline (0 = none); a token is a view of its source (or of none).
// =====================================================================
pub record CancellationTokenSource {
  var cancelled: Bool = false
  deadlineNanos: Long
}

pub record CancellationToken {
  source: Option[CancellationTokenSource]
}

/// A token that is never cancelled.
pub func noCancellation(): CancellationToken {
  CancellationToken(source = None)
}

/// A fresh source.  Project its token with `sourceToken`; call `cancelSource`
/// to request cancellation.
pub func makeCancelSource(): CancellationTokenSource {
  CancellationTokenSource(deadlineNanos = 0i64)
}

/// A source that cancels itself `ms` milliseconds from now.  The deadline is
/// checked by `isCancelled` against the monotonic clock, so a wall-clock step
/// cannot fire it early or late.
pub func makeCancelSourceTimeout(ms: in Int): CancellationTokenSource {
  CancellationTokenSource(deadlineNanos = rtMonotonicNanos() + ms.toLong() * 1000000i64)
}

pub func sourceToken(source: in CancellationTokenSource): CancellationToken {
  CancellationToken(source = Some(value = source))
}

/// Request cancellation.  Idempotent.
pub func cancelSource(source: in CancellationTokenSource): Unit {
  rtGlobalLock()
  source.cancelled = true
  rtGlobalUnlock()
}

/// Nothing to release on this target; kept for API parity.
pub func disposeSource(source: in CancellationTokenSource): Unit {
  ()
}

func sourceCancelled(src: in CancellationTokenSource): Bool {
  rtGlobalLock()
  val flagged = src.cancelled
  rtGlobalUnlock()
  if flagged {
    true
  } else if src.deadlineNanos > 0i64 {
    // A subtraction, so a clock that wraps still compares correctly.
    rtMonotonicNanos() - src.deadlineNanos >= 0i64
  } else {
    false
  }
}

/// Has cancellation been requested, explicitly or by an elapsed deadline?
pub func isCancelled(token: in CancellationToken): Bool {
  match token.source {
    case Some(src) -> sourceCancelled(src)
    case None -> false
  }
}

/// Panics once the token is cancelled.  Native has no way to catch the panic.
pub func throwIfCancelled(token: in CancellationToken): Unit {
  if isCancelled(token) {
    panic("OperationCanceledException: cancellation was requested")
  }
}

// =====================================================================
// Delay.  Both variants block the calling thread (module header).
// =====================================================================
/// A finished task: every `Task` this module returns has already resolved.
pub record Task {
  done: Bool
}

/// Sleep for `ms` milliseconds.
pub func delay(ms: in Int): Task {
  hostSleepMillis(ms)
  Task(done = true)
}

/// Sleep for `ms` milliseconds in 20 ms steps, returning early once `token` is
/// cancelled (callers check `isCancelled` afterwards).
pub func delayWithCancel(ms: in Int, token: in CancellationToken): Task {
  var remaining = ms
  while remaining > 0 and not isCancelled(token) {
    val step = if remaining < 20 { remaining } else { 20 }
    hostSleepMillis(step)
    remaining = remaining - step
  }
  Task(done = true)
}

// =====================================================================
// Threads.
// =====================================================================
/// One started action; `finished` is read and written under the global lock.
record Job {
  var finished: Bool = false
}

/// Run `work` on its own detached thread.  The closure is retained across the
/// spawn and released by the runtime when the thread ends.
@unsafe_ffi
func startThread(work: in () -> Unit): Unit {
  val worker: () -> NativePtr[Byte] = { -> work(); nativeNullPtr() }
  rtRetain(worker)
  val rc = rtThreadSpawnDetached(worker, worker)
  if rc != 0 {
    rtRelease(worker)
    panic("Std.Task: could not start a thread (errno " + rc.toString() + ")")
  }
}

func jobFinished(job: in Job): Bool {
  rtGlobalLock()
  val f = job.finished
  rtGlobalUnlock()
  f
}

func markFinished(job: in Job): Unit {
  rtGlobalLock()
  job.finished = true
  rtGlobalUnlock()
}

func waitFinished(job: in Job): Unit {
  while not jobFinished(job) {
    hostSleepMillis(1)
  }
}

// =====================================================================
// Structured concurrency.
// =====================================================================
pub record Scope {
  source: CancellationTokenSource
  jobs: List[Job]
}

/// A fresh scope.  Start children with `scopeSpawn`, then `await awaitAll(s)`.
pub func makeScope(): Scope {
  Scope(source = makeCancelSource(), jobs = newList())
}

/// The scope's cancellation token; children poll it to honour `cancelScope`.
pub func scopeToken(s: in Scope): CancellationToken {
  sourceToken(s.source)
}

/// Registering an existing `Task` is a no-op: every `Task` here has already
/// finished.
pub func scopeAdd(s: in Scope, child: in Task): Unit {
  ()
}

/// Start `action` on its own thread at once, scoped to `s`.  It does not run
/// at all if the scope was cancelled before the thread got going, and it
/// inherits the spawning thread's ambient token.
///
/// Named `scopeSpawn` because `spawn` is the keyword form.
pub func scopeSpawn(s: in Scope, action: in () -> Unit): Unit {
  val job = Job()
  val inherited = currentToken()
  val source = s.source
  val work: () -> Unit = { ->
    if not sourceCancelled(source) {
      val previous = installToken(inherited)
      action()
      restoreToken(previous)
    }
    markFinished(job)
  }
  // Drop the children that have finished, so a long-lived scope that spawns
  // without joining holds only its running children.
  rtGlobalLock()
  var i = 0
  while i < s.jobs.count {
    if s.jobs[i].finished {
      s.jobs.removeAt(i)
    } else {
      i = i + 1
    }
  }
  s.jobs.add(job)
  rtGlobalUnlock()
  startThread(work)
}

/// The children the scope still tracks: those not yet dropped by a later spawn.
pub func scopePendingCount(s: in Scope): Int {
  rtGlobalLock()
  val n = s.jobs.count
  rtGlobalUnlock()
  n
}

/// Block until every child started so far has finished.
pub func awaitAll(s: in Scope): Task {
  val snapshot: List[Job] = newList()
  rtGlobalLock()
  for j in s.jobs {
    snapshot.add(j)
  }
  rtGlobalUnlock()
  for j in snapshot {
    waitFinished(j)
  }
  Task(done = true)
}

/// Request cancellation of the scope's token.  Idempotent.
pub func cancelScope(s: in Scope): Unit {
  cancelSource(s.source)
}

pub func disposeScope(s: in Scope): Unit {
  ()
}

// =====================================================================
// Ambient cancellation token (per thread).
// =====================================================================
/// The ambient token; `noCancellation()` when none is installed on this thread.
pub func currentToken(): CancellationToken {
  if rtThreadRefHas() == 1 {
    CancellationToken(source = Some(value = rtThreadRefGet()))
  } else {
    noCancellation()
  }
}

func setAmbient(token: in CancellationToken): Unit {
  match token.source {
    case Some(src) -> rtThreadRefSet(src)
    case None -> rtThreadRefClear()
  }
}

/// Install `token` as the ambient on this thread; returns the previous value
/// to pass to `restoreToken`.
pub func installToken(token: in CancellationToken): CancellationToken {
  val previous = currentToken()
  setAmbient(token)
  previous
}

pub func restoreToken(previous: in CancellationToken): Unit {
  setAmbient(previous)
}

/// True when a cancellable token is installed on this thread.
pub func hasAmbient(): Bool {
  rtThreadRefHas() == 1
}

// =====================================================================
// Bounded waits.
// =====================================================================
/// Run `action` on its own thread (with the caller's ambient token) and wait at
/// most `timeoutMs` milliseconds; true when it finished in time.  A timed-out
/// action keeps running.
pub func runActionWithin(action: in () -> Unit, timeoutMs: in Int): Bool
  requires: timeoutMs >= 0
{
  val job = Job()
  val inherited = currentToken()
  startThread({ -> val previous = installToken(inherited); action(); restoreToken(previous); markFinished(job) })
  val deadline = rtMonotonicNanos() + timeoutMs.toLong() * 1000000i64
  while not jobFinished(job) and rtMonotonicNanos() - deadline < 0i64 {
    hostSleepMillis(1)
  }
  jobFinished(job)
}

/// Run `f` on its own thread and wait at most `timeoutMs` milliseconds:
/// `Some(result)` when it finished in time, `None` on timeout.  A timed-out
/// `f` keeps running.  A panic in `f` ends the process (no unwinding).
pub func runWithin[T](timeoutMs: in Int, f: in () -> T): Option[T]
  requires: timeoutMs >= 0
{
  // The worker appends to `results` outside the global lock; the caller reads
  // it only after `markFinished` (which takes the lock) has run, so the append
  // happens before the read.
  val results: List[T] = newList()
  val action: () -> Unit = { -> results.add(f()) }
  if not runActionWithin(action, timeoutMs) {
    return None
  }
  rtGlobalLock()
  val have = results.count > 0
  rtGlobalUnlock()
  if have {
    return Some(value = results[0])
  }
  None
}
