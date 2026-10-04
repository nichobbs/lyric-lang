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
