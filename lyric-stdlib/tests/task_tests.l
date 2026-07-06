//! Std.Task tests — cancellation tokens, cancellable delay, and
//! `Scope` structured concurrency (normal completion + D119 slice S3
//! sibling-cancel-on-first-fault).  Runs unmodified on both targets
//! (`lyric test lyric-stdlib/tests/task_tests.l` and `lyric test
//! --target jvm lyric-stdlib/tests/task_tests.l`): `Std.Task`'s public
//! surface is identical on `_kernel/task.l` (.NET) and
//! `_kernel_jvm/task.l` (JVM), per D119.
//!
//! Status (2026-07-06): every token/cancellation/delay test below passes on
//! both targets.  The two `Scope`-based tests
//! (`testScopeNormalCompletionRunsEveryChild`,
//! `testScopeSiblingObservesCancelOnFault`) currently FAIL on both — not
//! because `Scope`'s logic in either kernel file is wrong, but because each
//! backend has its own pre-existing, deeper bug that keeps a
//! cross-package-consumed `scopeSpawn` action from ever running at all:
//! on .NET, `Task.Run(Action[, CancellationToken])`'s delegate never
//! invokes the passed closure (reproduced with no dependency on
//! `Std.Task`); on JVM, a closure stored via `scopeSpawn` and later
//! invoked via `spawn` inside `awaitAll` throws `ClassCastException`
//! (calling package's `Lyric$Lambda` vs. `Std.Task`'s own — see the header
//! of `_kernel_jvm/task.l`).  Both are documented in
//! `docs/03-decision-log.md` as follow-up work; this file is left wired in
//! (not skipped) so a future fix flips these two assertions green without
//! anyone having to first rediscover the gap.
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

// ─── Scope: normal completion ────────────────────────────────────────────────
func testScopeNormalCompletionRunsEveryChild(): Unit {
  val sc = makeScope()
  var a = 0
  var b = 0
  scopeSpawn(sc, { -> a = 1 })
  scopeSpawn(sc, { -> b = 2 })
  val r = await awaitAll(sc)
  cancelScope(sc)
  disposeScope(sc)
  assertEqualInt(a, 1, "first scopeSpawn'd action ran")
  assertEqualInt(b, 2, "second scopeSpawn'd action ran")
}

func testScopeWithNoChildrenCompletesImmediately(): Unit {
  val sc = makeScope()
  val r = await awaitAll(sc)
  cancelScope(sc)
  disposeScope(sc)
}

// ─── Scope: D119 slice S3 sibling-cancel-on-first-fault ──────────────────────
// One sibling panics; the other polls the scope's token in a loop.  awaitAll
// must still surface the fault (pre-existing `Task.WhenAll` behaviour on
// .NET; this backend's own join loop on JVM), and — the D119 S3 guarantee —
// the polling sibling must observe the cancellation and stop before its loop
// runs to completion.
func testScopeSiblingObservesCancelOnFault(): Unit {
  val sc = makeScope()
  val tok = scopeToken(sc)
  var observedCancel = false
  var ranToCompletion = false
  scopeSpawn(sc, { -> panic("boom") })
  scopeSpawn(
    sc,
    { ->
      var i = 0
      var stopped = false
      while i < 500 and not stopped {
        if isCancelled(tok) {
          observedCancel = true
          stopped = true
        } else {
          sleepMillis(2)
          i = i + 1
        }
      }
      if not stopped {
        ranToCompletion = true
      }
    }
  )
  assertPanics("awaitAll rethrows the faulting sibling's panic", { -> val r = await awaitAll(sc) })
  cancelScope(sc)
  disposeScope(sc)
  assertTrue(observedCancel, "the non-faulting sibling observed cancellation while still running")
  assertFalse(ranToCompletion, "the non-faulting sibling stopped early rather than running its full loop")
}

func main(): Int {
  testNoCancellationNeverCancelled()
  testCancelSourcePropagatesToPriorToken()
  testCancelSourceIsIdempotent()
  testThrowIfCancelledPanicsOnceCancelled()
  testThrowIfCancelledIsSilentOtherwise()
  testDelayElapsesRoughlyRequestedDuration()
  testDelayWithCancelPanicsWhenAlreadyCancelled()
  testMakeCancelSourceTimeoutEventuallyCancels()
  testScopeNormalCompletionRunsEveryChild()
  testScopeWithNoChildrenCompletesImmediately()
  testScopeSiblingObservesCancelOnFault()
  println("task tests: ok")
  return 0
}
