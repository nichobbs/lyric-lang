//! Std.Task tests — cancellation tokens and cancellable delay. Runs
//! unmodified on both targets (`lyric run lyric-stdlib/tests/task_tests.l`
//! and `lyric run --target jvm lyric-stdlib/tests/task_tests.l`):
//! `Std.Task`'s public surface is identical on `_kernel/task.l` (.NET) and
//! `_kernel_jvm/task.l` (JVM), per D119. Every test below passes on both
//! targets and is wired into CI.
//!
//! `Std.Task.Scope` structured concurrency is tested separately in
//! `task_scope_known_failures_tests.l` — split out (#5325) because it
//! currently has three known, separately-tracked failures (issue #5329)
//! and is deliberately not CI-wired; see that file's header for why.
package Std.Task.Tests

import Std.Core
import Std.Task
import Std.Testing
import Std.Time

func testNoCancellationNeverCancelled(): Unit {
  val tok = noCancellation()
  assertFalse(isCancelled(tok), "noCancellation() token is never cancelled")
}

func testCancelSourcePropagatesToPriorToken(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  assertFalse(isCancelled(tok), "fresh source's token starts uncancelled")
  cancelSource(src)
  assertTrue(isCancelled(tok), "cancelling the source is observed through a token taken beforehand")
}

func testCancelSourceIsIdempotent(): Unit {
  val src = makeCancelSource()
  cancelSource(src)
  cancelSource(src)
  assertTrue(isCancelled(sourceToken(src)), "a second cancelSource call is a harmless no-op")
}

func testThrowIfCancelledPanicsOnceCancelled(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  assertPanics("throwIfCancelled panics once the source is cancelled", { -> throwIfCancelled(tok) })
}

func testThrowIfCancelledIsSilentOtherwise(): Unit {
  val tok = noCancellation()
  // Must not panic; a bare call is the assertion.
  throwIfCancelled(tok)
}

func testDelayElapsesRoughlyRequestedDuration(): Unit {
  val start = monotonicNanos()
  val r = await delay(200)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(elapsedMs >= 150i64, "delay(200) blocks for at least ~150ms (elapsed=" + toString(elapsedMs) + "ms)")
}

func testDelayWithCancelPanicsWhenAlreadyCancelled(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  assertPanics(
    "delayWithCancel panics promptly when the token is already cancelled",
    { -> val r = await delayWithCancel(5000, tok) }
  )
}

func testMakeCancelSourceTimeoutEventuallyCancels(): Unit {
  val src = makeCancelSourceTimeout(50)
  val tok = sourceToken(src)
  assertFalse(isCancelled(tok), "a fresh deadline source hasn't elapsed yet")
  val r = await delay(200)
  assertTrue(isCancelled(tok), "the token reports cancelled once the deadline has passed")
}

// A regression test for #5320 (the JVM ambient slot dropped
// makeCancelSourceTimeout's deadlineMs) belongs here in principle, but
// installToken/currentToken crash on .NET on their very first call in a
// process (NullReferenceException in a minimal repro, a JIT segfault in
// a larger one) — a separate, pre-existing, .NET-only bug this
// investigation surfaced, filed as #5330. Since #5320 was JVM-only (the
// .NET kernel already stores the whole CancellationToken, deadlineMs
// included, in its AsyncLocal), the fix is verified directly against
// _kernel_jvm/task.l instead — see the #5320 writeup in
// docs/03-decision-log.md (D-progress-621) for the verification command
// and output.  Do not add an installToken/currentToken call to this
// CI-wired file until #5330 is fixed.
func main(): Int {
  testNoCancellationNeverCancelled()
  testCancelSourcePropagatesToPriorToken()
  testCancelSourceIsIdempotent()
  testThrowIfCancelledPanicsOnceCancelled()
  testThrowIfCancelledIsSilentOtherwise()
  testDelayElapsesRoughlyRequestedDuration()
  testDelayWithCancelPanicsWhenAlreadyCancelled()
  testMakeCancelSourceTimeoutEventuallyCancels()
  println("task tests: ok")
  return 0
}
