//! Std.Task on `--target native`: the cases of `task_tests.l` that do not
//! depend on catching a panic (native has no unwinding, D-N-003), plus the
//! native-only behaviour: `delayWithCancel` returns early instead of
//! panicking, a scope cancelled before a child starts never runs it, and a
//! child inherits its parent's ambient token.
//!
//!   lyric test --target native lyric-stdlib/tests/task_native_tests.l
@test_module
package Std.Task.NativeTests

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing
import Std.Time

record Point {
  x: Int
  y: Int
}

test "noCancellation is never cancelled" {
  assertFalse(isCancelled(noCancellation()), "noCancellation() token is never cancelled")
  throwIfCancelled(noCancellation())
}

test "a source's cancellation is seen through a token taken beforehand" {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  assertFalse(isCancelled(tok), "fresh source starts uncancelled")
  cancelSource(src)
  cancelSource(src)
  assertTrue(isCancelled(tok), "cancelling is observed, and a second cancel is a no-op")
  disposeSource(src)
}

test "delay blocks for about the requested time" {
  val start = monotonicNanos()
  val r = await delay(200)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(elapsedMs >= 150i64, "delay(200) blocks for at least ~150ms (elapsed=" + toString(elapsedMs) + "ms)")
}

test "delayWithCancel returns early once the token is cancelled" {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  val start = monotonicNanos()
  val r = await delayWithCancel(5000, tok)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(
    elapsedMs < 1000i64,
    "an already-cancelled token ends the delay promptly (elapsed=" + toString(elapsedMs) + "ms)"
  )
  assertTrue(isCancelled(tok), "the token is still cancelled afterwards")
}

test "a timeout source cancels itself after its deadline" {
  val src = makeCancelSourceTimeout(50)
  val tok = sourceToken(src)
  assertFalse(isCancelled(tok), "a fresh deadline source has not elapsed yet")
  val r = await delay(200)
  assertTrue(isCancelled(tok), "the token reports cancelled once the deadline has passed")
}

test "installToken and restoreToken round-trip the ambient token" {
  val outer = installToken(noCancellation())
  assertFalse(hasAmbient(), "noCancellation() leaves no cancellable ambient")
  val src = makeCancelSource()
  val previous = installToken(sourceToken(src))
  assertTrue(hasAmbient(), "a cancellable token is now ambient")
  assertFalse(isCancelled(previous), "installToken returns the prior value")
  cancelSource(src)
  assertTrue(isCancelled(currentToken()), "currentToken is the installed token")
  restoreToken(previous)
  assertFalse(hasAmbient(), "restoreToken puts the prior token back")
  restoreToken(outer)
}

test "a scope runs every child and awaitAll joins them" {
  val sc = makeScope()
  val first: List[Int] = newList()
  val second: List[Int] = newList()
  scopeSpawn(sc, { -> first.add(1) })
  scopeSpawn(sc, { -> second.add(2) })
  val r = await awaitAll(sc)
  assertEqualInt(first.count + second.count, 2, "both children ran before awaitAll returned")
  cancelScope(sc)
  disposeScope(sc)
}

test "awaitAll on an empty scope returns at once" {
  val sc = makeScope()
  val r = await awaitAll(sc)
  assertEqualInt(scopePendingCount(sc), 0, "no children are tracked")
}

test "scopeSpawn starts the action without awaitAll" {
  val sc = makeScope()
  val ran: List[Int] = newList()
  scopeSpawn(sc, { -> ran.add(1) })
  var waited = 0
  while ran.count == 0 and waited < 10000 {
    sleepMillis(10)
    waited = waited + 10
  }
  assertEqualInt(ran.count, 1, "the action ran on its own")
  val r = await awaitAll(sc)
}

test "a scope drops finished children when it next spawns" {
  val sc = makeScope()
  var k = 0
  while k < 20 {
    scopeSpawn(sc, { -> () })
    sleepMillis(5)
    k = k + 1
  }
  var tries = 0
  while scopePendingCount(sc) > 1 and tries < 200 {
    sleepMillis(10)
    scopeSpawn(sc, { -> () })
    tries = tries + 1
  }
  assertTrue(scopePendingCount(sc) <= 1, "finished children are dropped")
  val r = await awaitAll(sc)
}

test "a child sees cancelScope through the scope token" {
  val sc = makeScope()
  val tok = scopeToken(sc)
  val seen: List[Int] = newList()
  scopeSpawn(
    sc,
    { ->
      var waited = 0
      while not isCancelled(tok) and waited < 10000 {
        sleepMillis(5)
        waited = waited + 5
      }
      if isCancelled(tok) {
        seen.add(1)
      }
    }
  )
  sleepMillis(30)
  cancelScope(sc)
  val r = await awaitAll(sc)
  assertEqualInt(seen.count, 1, "the child observed the cancellation and finished")
}

test "a scope cancelled before a child starts never runs it" {
  val sc = makeScope()
  cancelScope(sc)
  val ran: List[Int] = newList()
  scopeSpawn(sc, { -> ran.add(1) })
  val r = await awaitAll(sc)
  assertEqualInt(ran.count, 0, "the action did not run")
}

test "a child inherits its parent's ambient token" {
  val src = makeCancelSource()
  val previous = installToken(sourceToken(src))
  val sc = makeScope()
  val inherited: List[Bool] = newList()
  scopeSpawn(sc, { -> inherited.add(hasAmbient()) })
  val r = await awaitAll(sc)
  restoreToken(previous)
  assertEqualInt(inherited.count, 1, "the child ran")
  assertTrue(inherited[0], "the child saw the parent's ambient token")
}

test "runWithin returns the result of a closure that finishes in time" {
  val fast: () -> Int = { -> 42 }
  match runWithin(5000, fast) {
    case Some(v) -> assertEqualInt(v, 42, "Some(result)")
    case None -> assertTrue(false, "a fast closure must not time out")
  }
  val greet: () -> String = { -> "hello" }
  match runWithin(5000, greet) {
    case Some(v) -> assertEqual(v, "hello", "a String result")
    case None -> assertTrue(false, "a fast closure must not time out")
  }
  val mk: () -> Point = { -> Point(x = 1, y = 2) }
  match runWithin(5000, mk) {
    case Some(p) -> assertEqualInt(p.x + p.y, 3, "a record result")
    case None -> assertTrue(false, "a fast closure must not time out")
  }
}

test "runWithin reports None for a closure that overruns its budget" {
  val slow: () -> Int = { -> sleepMillis(1000); 1 }
  match runWithin(50, slow) {
    case Some(v) -> assertTrue(false, "an overrunning closure must time out")
    case None -> assertTrue(true, "None on timeout")
  }
  match runWithin(0, slow) {
    case Some(v) -> assertTrue(false, "a zero budget must not wait")
    case None -> assertTrue(true, "a zero budget reports None at once")
  }
}

test "a runWithin closure inherits the caller's ambient token" {
  val src = makeCancelSource()
  val previous = installToken(sourceToken(src))
  val probe: () -> Bool = { -> hasAmbient() }
  match runWithin(5000, probe) {
    case Some(v) -> assertTrue(v, "the worker saw the caller's ambient token")
    case None -> assertTrue(false, "the closure must finish in time")
  }
  restoreToken(previous)
}

// The waits block on a condition instead of polling: a wake-up comes from the
// event (a cancel, a child finishing) or from the earliest deadline involved.
test "delayWithCancel ends at the token's own deadline when that comes first" {
  val tok = sourceToken(makeCancelSourceTimeout(100))
  val start = monotonicNanos()
  val r = await delayWithCancel(5000, tok)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(elapsedMs >= 80i64, "it waited for the deadline (elapsed=" + toString(elapsedMs) + "ms)")
  assertTrue(elapsedMs < 2000i64, "it did not wait out the 5 s delay (elapsed=" + toString(elapsedMs) + "ms)")
  assertTrue(isCancelled(tok), "the deadline has passed")
}

test "cancelSource from another thread wakes a delayWithCancel that is blocked" {
  val s = makeScope()
  val src = makeCancelSource()
  val tok = sourceToken(src)
  scopeSpawn(s, { -> sleepMillis(100); cancelSource(src) })
  val start = monotonicNanos()
  val r = await delayWithCancel(10000, tok)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  val j = await awaitAll(s)
  assertTrue(isCancelled(tok), "the token was cancelled")
  assertTrue(elapsedMs >= 80i64, "the delay waited for the cancel (elapsed=" + toString(elapsedMs) + "ms)")
  assertTrue(elapsedMs < 3000i64, "the cancel woke the delay long before 10 s (elapsed=" + toString(elapsedMs) + "ms)")
}

test "awaitAll blocks until a slow child finishes, and a second awaitAll returns at once" {
  val s = makeScope()
  val done: List[Int] = newList()
  scopeSpawn(s, { -> sleepMillis(150); done.add(1) })
  val start = monotonicNanos()
  val j = await awaitAll(s)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(elapsedMs >= 120i64, "awaitAll waited for the child (elapsed=" + toString(elapsedMs) + "ms)")
  assertEqualInt(done.count, 1, "the child ran to completion before awaitAll returned")
  val again = monotonicNanos()
  val k = await awaitAll(s)
  assertTrue((monotonicNanos() - again) / 1000000i64 < 100i64, "a finished child does not delay a second awaitAll")
}

test "several threads can await the same scope" {
  val s = makeScope()
  val finished: List[Int] = newList()
  scopeSpawn(s, { -> sleepMillis(150); finished.add(1) })
  val waiters = makeScope()
  scopeSpawn(waiters, { -> val a = await awaitAll(s); finished.add(2) })
  scopeSpawn(waiters, { -> val b = await awaitAll(s); finished.add(3) })
  val w = await awaitAll(waiters)
  val j = await awaitAll(s)
  assertEqualInt(finished.count, 3, "the child and both waiters completed")
  assertEqualInt(finished[0], 1, "the child finished before either waiter returned")
}

test "runActionWithin returns as soon as the action finishes, not at the budget" {
  val start = monotonicNanos()
  val ok = runActionWithin({ -> sleepMillis(100) }, 10000)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(ok, "an action that finishes in time reports true")
  assertTrue(elapsedMs >= 80i64, "it waited for the action (elapsed=" + toString(elapsedMs) + "ms)")
  assertTrue(elapsedMs < 3000i64, "it did not wait out the 10 s budget (elapsed=" + toString(elapsedMs) + "ms)")
}

test "runActionWithin gives up at its budget when the action overruns" {
  val start = monotonicNanos()
  val ok = runActionWithin({ -> sleepMillis(1500) }, 100)
  val elapsedMs = (monotonicNanos() - start) / 1000000i64
  assertFalse(ok, "an overrunning action reports false")
  assertTrue(elapsedMs >= 80i64, "it waited for the budget (elapsed=" + toString(elapsedMs) + "ms)")
  assertTrue(elapsedMs < 1400i64, "it did not wait for the action (elapsed=" + toString(elapsedMs) + "ms)")
}
