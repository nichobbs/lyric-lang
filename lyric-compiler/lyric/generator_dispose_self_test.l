//! generator_dispose_self_test.l — dual-target runtime regression test for a
//! `for` loop that leaves a generator early by any route (#7754, D143).
//!
//! Before the fix only `break` disposed the generator: on `--target dotnet`
//! the `for` loop called `DisposeAsync` after the loop, and on `--target jvm`
//! it called the iterator's `close()` there.  Leaving the loop by `return`, a
//! panic, `?` propagation, or a labelled `break`/`continue` to an enclosing
//! loop skipped that call, so the `finally`/`defer` blocks guarding the
//! generator's suspended `yield` never ran (dotnet) or ran whenever the
//! garbage collector reclaimed the iterator (jvm).  The loop now disposes the
//! generator on every exit, exactly once, before control leaves the loop.
//!
//! Each case asserts the full event log, so the generator's `finally` and
//! `defer` are shown to run once, innermost first, and in order with the
//! consumer's own code.  The cases cover `return` (with a consumer `defer`),
//! a panic caught by the caller, `?` propagation, `break` and `continue` to an
//! outer loop, a generator consumed inside another generator (left by a
//! labelled `continue` in the outer generator, and by the outer generator's
//! consumer stopping while the inner one is suspended), an `await` in the loop body of
//! an `async func`, and the exception precedence: a panic from the generator's
//! `finally` while the consumer's own panic propagates is dropped (dotnet) or
//! suppressed (jvm), and the consumer's panic reaches the caller.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_dispose_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generator_dispose_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorDisposeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

async func genGuarded(log: in List[String]): Int {
  defer {
    log.add("gen defer")
  }
  try {
    yield 1
    yield 2
    yield 3
  } finally {
    log.add("gen finally")
  }
  log.add("gen end")
}

async func genFinallyPanics(log: in List[String]): Int {
  try {
    yield 1
    yield 2
  } finally {
    log.add("gen finally")
    panic("cleanup failed")
  }
}

func joinStrings(xs: in List[String]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + xs[i]
    i = i + 1
  }
  s
}

func firstGuarded(log: in List[String]): Int {
  defer {
    log.add("consumer defer")
  }
  for x in genGuarded(log) {
    log.add("consumer ${x}")
    return x
  }
  -1
}

func panicsAtTwo(log: in List[String]): Int {
  var total = 0
  for x in genGuarded(log) {
    log.add("consumer ${x}")
    if x == 2 {
      panic("consumer failed")
    }
    total = total + x
  }
  total
}

func rejectTwo(x: in Int): Result[Int, String] {
  if x == 2 {
    Err("two")
  } else {
    Ok(x)
  }
}

func sumUntilRejected(log: in List[String]): Result[Int, String] {
  var total = 0
  for x in genGuarded(log) {
    val v = rejectTwo(x)?
    log.add("consumer ${v}")
    total = total + v
  }
  Ok(total)
}

func breakOuter(log: in List[String]): Int {
  var rounds = 0
  outer: for round in [1, 2, 3] {
    rounds = rounds + 1
    for x in genGuarded(log) {
      log.add("round ${round} got ${x}")
      if x == 2 {
        break outer
      }
    }
    log.add("round ${round} unreachable")
  }
  log.add("after outer")
  rounds
}

func continueOuter(log: in List[String]): Int {
  var rounds = 0
  outer: for round in [1, 2] {
    rounds = rounds + 1
    for x in genGuarded(log) {
      log.add("round ${round} got ${x}")
      continue outer
    }
    log.add("round ${round} unreachable")
  }
  rounds
}

// The outer generator leaves its `for` over the inner one with a labelled
// `continue`, starting a new inner generator each round.
async func genContinuesPastInnerLoop(log: in List[String]): Int {
  rounds: for round in [1, 2] {
    for x in genGuarded(log) {
      yield round * 10 + x
      log.add("outer round ${round} continues")
      continue rounds
    }
    log.add("outer unreachable")
  }
  log.add("outer end")
}

// The outer generator suspends inside its `for` over the inner one.
async func genYieldsFromInnerLoop(log: in List[String]): Int {
  try {
    for x in genGuarded(log) {
      yield x * 10
    }
  } finally {
    log.add("outer finally")
  }
}

async func plusOne(x: in Int): Int {
  x + 1
}

async func firstAfterAwait(log: in List[String]): Int {
  for x in genGuarded(log) {
    val y = await plusOne(x)
    log.add("consumer ${y}")
    if y == 3 {
      return y
    }
  }
  -1
}

func returnsWhileFinallyPanics(log: in List[String]): Int {
  for x in genFinallyPanics(log) {
    return x
  }
  -1
}

test "for over a generator: return runs the pending finally and defer once, before the consumer's defer" {
  val log: List[String] = newList()
  val r = firstGuarded(log)
  assertTrue(r == 1, "returned the first value")
  assertEqual(joinStrings(log), "consumer 1,gen finally,gen defer,consumer defer", "event order")
}

test "for over a generator: a panic in the body runs the pending finally and defer once" {
  val log: List[String] = newList()
  var caught = ""
  try {
    panicsAtTwo(log)
  } catch Bug as e {
    caught = e.message
    log.add("caller caught")
  }
  assertTrue(caught.contains("consumer failed"), "the body's panic reached the caller: '" + caught + "'")
  assertEqual(
    joinStrings(log),
    "consumer 1,consumer 2,gen finally,gen defer,caller caught",
    "cleanup runs before the caller's handler"
  )
}

test "for over a generator: ? propagation runs the pending finally and defer once" {
  val log: List[String] = newList()
  val r = sumUntilRejected(log)
  match r {
    case Ok(v) -> assertTrue(false, "expected Err, got Ok(${v})")
    case Err(e) -> assertEqual(e, "two", "the propagated error")
  }
  assertEqual(joinStrings(log), "consumer 1,gen finally,gen defer", "event order")
}

test "for over a generator: break to an outer loop runs the pending finally and defer once" {
  val log: List[String] = newList()
  val rounds = breakOuter(log)
  assertTrue(rounds == 1, "one round ran")
  assertEqual(joinStrings(log), "round 1 got 1,round 1 got 2,gen finally,gen defer,after outer", "event order")
}

test "for over a generator: continue to an outer loop disposes each round's generator once" {
  val log: List[String] = newList()
  val rounds = continueOuter(log)
  assertTrue(rounds == 2, "both rounds ran")
  assertEqual(
    joinStrings(log),
    "round 1 got 1,gen finally,gen defer,round 2 got 1,gen finally,gen defer",
    "event order"
  )
}

test "for over a generator: a labelled continue inside another generator disposes the inner one" {
  val log: List[String] = newList()
  var got = ""
  for y in genContinuesPastInnerLoop(log) {
    got = got + "${y};"
  }
  assertEqual(got, "11;21;", "the outer generator's values")
  assertEqual(
    joinStrings(log),
    "outer round 1 continues,gen finally,gen defer,outer round 2 continues,gen finally,gen defer,outer end",
    "event order"
  )
}

test "for over a generator: stopping an outer generator suspended in its loop disposes the inner one" {
  val log: List[String] = newList()
  for y in genYieldsFromInnerLoop(log) {
    log.add("consumer ${y}")
    if y == 20 {
      break
    }
  }
  log.add("consumer done")
  assertEqual(
    joinStrings(log),
    "consumer 10,consumer 20,gen finally,gen defer,outer finally,consumer done",
    "inner cleanup, then the outer finally, before the consumer continues"
  )
}

test "for over a generator: return after an await in an async func runs the pending finally and defer once" {
  val log: List[String] = newList()
  val r = await firstAfterAwait(log)
  assertTrue(r == 3, "returned after the second await")
  assertEqual(joinStrings(log), "consumer 2,consumer 3,gen finally,gen defer", "event order")
}

test "for over a generator: a finally that panics on return reaches the caller" {
  val log: List[String] = newList()
  var caught = ""
  try {
    returnsWhileFinallyPanics(log)
  } catch Bug as e {
    caught = e.message
  }
  assertTrue(caught.contains("cleanup failed"), "the finally's panic reached the caller: '" + caught + "'")
  assertEqual(joinStrings(log), "gen finally", "the finally ran once")
}

test "for over a generator: the consumer's panic takes precedence over one from the generator's finally" {
  val log: List[String] = newList()
  var caught = ""
  try {
    for x in genFinallyPanics(log) {
      panic("body failed")
    }
  } catch Bug as e {
    caught = e.message
  }
  assertTrue(caught.contains("body failed"), "the consumer's panic reached the caller: '" + caught + "'")
  assertFalse(caught.contains("cleanup failed"), "not the finally's panic: '" + caught + "'")
  assertEqual(joinStrings(log), "gen finally", "the finally ran once")
}
