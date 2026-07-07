//! Std.Task JVM ambient-cancellation-slot regression tests (#5342).
//!
//! Covers `installToken`/`currentToken`/`restoreToken`/`hasAmbient` in
//! `lyric-stdlib/std/_kernel_jvm/task.l` directly — the ~30-line region
//! this PR fixed two real bugs in (#5320: deadlineMs silently dropped;
//! #5331: install+restore could never return to "nothing installed").
//! Neither bug had a regression test before now.
//!
//! **JVM-only, deliberately not run on `--target dotnet`**: calling
//! `installToken` on .NET crashes on its very first call in a process
//! (a pre-existing, separate bug, filed as #5330) — see
//! `lyric-stdlib/tests/task_tests.l`'s header for the full story. Wire
//! this file into `ci.yml`'s JVM step only, alongside the other
//! `Std.Task` coverage; do not add a dotnet step for it until #5330 is
//! fixed.
package Std.Task.AmbientTests

import Std.Core
import Std.Task
import Std.Testing

func testHasAmbientFalseBeforeAnyInstall(): Unit {
  assertFalse(hasAmbient(), "a thread that never called installToken reports no ambient")
}

func testInstallMakesHasAmbientTrue(): Unit {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  val previous = installToken(tok)
  assertTrue(hasAmbient(), "installing a real cancellable token makes hasAmbient true")
  restoreToken(previous)
}

func testAmbientTokenRoundTripsDeadline(): Unit {
  // Regression for #5320: the ambient slot only threaded the
  // AtomicBoolean flag through install/current/restore, silently
  // dropping a makeCancelSourceTimeout token's deadlineMs.
  val src = makeCancelSourceTimeout(50000)
  val tok = sourceToken(src)
  val previous = installToken(tok)
  val ambient = currentToken()
  assertTrue(ambient.deadlineMs > 0i64, "ambient token retains its deadlineMs across installToken/currentToken")
  restoreToken(previous)
}

func testRestoreReturnsToNoAmbientWhenNothingWasInstalledBefore(): Unit {
  // Regression for #5331: currentToken() synthesized a fresh
  // noCancellation() token when nothing was installed, so restoring to
  // that synthesized "previous" value left the ThreadLocal holding a
  // real, non-null flag forever after -- hasAmbient() then incorrectly
  // reported true for the rest of the thread's lifetime.
  assertFalse(hasAmbient(), "precondition: nothing installed yet on this thread")
  val src = makeCancelSource()
  val tok = sourceToken(src)
  val previous = installToken(tok)
  assertTrue(hasAmbient(), "a real token is now ambient")
  restoreToken(previous)
  assertFalse(hasAmbient(), "restoring to the pre-install state reports no ambient again, not stuck true")
}

func testNestedInstallRestoreRoundTrips(): Unit {
  val outerSrc = makeCancelSource()
  val outerTok = sourceToken(outerSrc)
  val outerPrevious = installToken(outerTok)
  assertTrue(hasAmbient(), "outer install is ambient")

  val innerSrc = makeCancelSourceTimeout(50000)
  val innerTok = sourceToken(innerSrc)
  val innerPrevious = installToken(innerTok)
  val innerAmbient = currentToken()
  assertTrue(innerAmbient.deadlineMs > 0i64, "inner ambient carries its own deadline")

  restoreToken(innerPrevious)
  val restoredOuter = currentToken()
  assertEqualInt(
    if restoredOuter.deadlineMs == 0i64 { 0 } else { 1 },
    0,
    "restoring the inner install brings back the outer token, not a fresh no-op one"
  )
  assertTrue(hasAmbient(), "outer token is still ambient after the inner restore")

  restoreToken(outerPrevious)
  assertFalse(hasAmbient(), "restoring the outer install returns to no ambient")
}

func main(): Int {
  testHasAmbientFalseBeforeAnyInstall()
  testInstallMakesHasAmbientTrue()
  testAmbientTokenRoundTripsDeadline()
  testRestoreReturnsToNoAmbientWhenNothingWasInstalledBefore()
  testNestedInstallRestoreRoundTrips()
  println("task ambient jvm tests: ok")
  return 0
}
