//! Std.Task tests — cancellation tokens, cancellable delay, and (as of
//! #5329's fix) `Std.Task.Scope` structured-concurrency spawn/join. Runs
//! unmodified on both targets (`lyric run lyric-stdlib/tests/task_tests.l`
//! and `lyric run --target jvm lyric-stdlib/tests/task_tests.l`):
//! `Std.Task`'s public surface is identical on `_kernel/task.l` (.NET) and
//! `_kernel_jvm/task.l` (JVM), per D119. Every test below passes on both
//! targets and is wired into CI.
//!
//! `testScopeNormalCompletionRunsEveryChild` and
//! `testScopeWithNoChildrenCompletesImmediately` were split out into
//! `task_scope_known_failures_tests.l` (#5325) pending issue #5329's fix
//! (`scopeSpawn`/`awaitAll` never actually ran a spawned closure on
//! `--target dotnet`, and a separate null-dereference hit the empty-scope
//! case on both targets). Both now pass on both targets and are merged
//! back here per that file's own stated exit condition.
//!
//! `task_scope_known_failures_tests.l` still carries ONE remaining case
//! (`testScopeSiblingObservesCancelOnFault`) — that one tests D119 slice
//! S3's eager sibling-cancel-on-fault, a SEPARATE, not-yet-shipped feature
//! (never part of #5329's own bug list) that passes on `--target jvm`
//! today but not yet on `--target dotnet`; see that file's header and
//! `_kernel/task.l`'s module doc ("D119 slice S3", bugs (1)/(2)) for why.
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

// Regression test for #5330: installToken/currentToken crashed on .NET on
// their very first call in a process (NullReferenceException) because the
// ambient `AsyncLocal<object>` erasure reads `null` before anything is ever
// installed, and the MSIL backend's STVar-return unboxing
// (`emitGenericExternMember` in `msil/codegen.l`) unconditionally emitted
// `unbox.any` against that `null` reference. This MUST be the first ambient-
// token call in the file (and process) to exercise the original crash: prior
// to the fix, this call panicked with NullReferenceException on .NET before
// ever reaching `assertFalse`.  See `docs/03-decision-log.md` D-progress-621
// for the related #5320 (JVM-only) writeup this test was withheld pending.
func testInstallTokenFirstCallDoesNotCrash(): Unit {
  val previous = installToken(noCancellation())
  assertFalse(
    isCancelled(previous),
    "the ambient slot's initial (never-installed) value is the never-cancelled default"
  )
  restoreToken(previous)
}

func testInstallTokenRoundTripsAndRestores(): Unit {
  val outer = installToken(noCancellation())
  assertFalse(hasAmbient(), "installing noCancellation() leaves the ambient slot at its non-cancellable default")
  val src = makeCancelSource()
  val tok = sourceToken(src)
  val previous = installToken(tok)
  assertTrue(hasAmbient(), "installToken sets the ambient slot to a cancellable token")
  assertFalse(isCancelled(previous), "installToken returns the slot's PRIOR value, unchanged by the new install")
  restoreToken(previous)
  assertFalse(hasAmbient(), "restoreToken puts the prior (non-cancellable) token back")
  restoreToken(outer)
}

// Regression test for #5329 (bug 1, the biggest of the reported failures):
// `Task.Run(Action[, CancellationToken])`'s delegate never invoked the
// passed closure on `--target dotnet` — a lambda literal passed directly to
// a stdlib function's `() -> Unit`-typed parameter built a `Func<object>`
// delegate instead of the `System.Action` that parameter's own signature
// requires, so `Task.Run` silently never ran it. Fixed in `Msil.Codegen`
// (ELambda's `returnsVoid` + `registerStdlibFunc`/`registerRestoredFunc`).
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

// Regression test for #5329 (bug 5): `awaitAll` on a scope with zero
// spawned children null-dereferenced on both targets.
func testScopeWithNoChildrenCompletesImmediately(): Unit {
  val sc = makeScope()
  val r = await awaitAll(sc)
  cancelScope(sc)
  disposeScope(sc)
}

func main(): Int {
  testNoCancellationNeverCancelled()
  testInstallTokenFirstCallDoesNotCrash()
  testInstallTokenRoundTripsAndRestores()
  testCancelSourcePropagatesToPriorToken()
  testCancelSourceIsIdempotent()
  testThrowIfCancelledPanicsOnceCancelled()
  testThrowIfCancelledIsSilentOtherwise()
  testDelayElapsesRoughlyRequestedDuration()
  testDelayWithCancelPanicsWhenAlreadyCancelled()
  testMakeCancelSourceTimeoutEventuallyCancels()
  testScopeNormalCompletionRunsEveryChild()
  testScopeWithNoChildrenCompletesImmediately()
  println("task tests: ok")
  return 0
}
