//! async_match_suspend_self_test.l — dual-target runtime regression test for
//! `match` arms whose guard or body really suspends inside an `async func`
//! (#7816), and for a compound assignment whose value awaits.
//!
//! On `--target dotnet` an `async func` is an `IAsyncStateMachine` whose
//! `MoveNext` is re-entered after every real suspension, and every IL local
//! reverts to its default on re-entry.  A `match` arm's pattern bindings were
//! IL locals, so `case Some(v) -> { await delay(5); v * 2 }` returned 0 after
//! the resume instead of `v * 2` (a silent miscompile), and a nested `@`
//! binding re-matched against a lost value fell through every arm.  An arm
//! whose guard or body can suspend now keeps its bindings in state-machine
//! fields, and the scrutinee is kept too when a guard can suspend (a later
//! arm's pattern test reads it after the guard resumed).  An `await` in a
//! guard now also makes the function suspend at all: it used to block the
//! thread when the guard held the function's only `await`.  `t += await f()`
//! left `t` on the evaluation stack across the suspension (invalid IL); the
//! value is now evaluated first, like a field or index target's.  An `await`
//! that completes synchronously never exercised any of this, so every case
//! suspends for real through `Std.Task.delay`.
//!
//! `--target jvm` lowers `async func` synchronously (an `await` blocks the
//! calling virtual thread), so match state lives in ordinary locals there;
//! the same cases pin that parity.
//!
//! The record declared after every `async func` reads back correctly only if
//! each state machine's Pass-1 field-count prediction held.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/async_match_suspend_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/async_match_suspend_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.AsyncMatchSuspendSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

async func pause(): Unit {
  await Std.Task.delay(5);
  ()
}

async func asyncThree(): Int {
  await Std.Task.delay(5)
  3
}

async func isBig(n: in Int): Bool {
  await Std.Task.delay(5)
  n > 10
}

record MatchPoint {
  x: Int
  y: Int
}

union MatchShape {
  case Circle(r: Int)
  case Rect(w: Int, h: Int)
}

async func doubleSome(o: in Option[Int]): Int {
  match o {
    case Some(v) -> {
      await Std.Task.delay(5)
      v * 2
    }
    case None -> 0
  }
}

async func unionCases(s: in MatchShape): Int {
  match s {
    case Circle(r) -> {
      await pause()
      r * 3
    }
    case Rect(w, h) -> {
      await pause()
      w * h
    }
  }
}

async func tuplePattern(a: in Int, b: in String): String {
  match (a, b) {
    case (n, s) -> {
      await pause()
      s + toString(n)
    }
  }
}

async func recordPattern(p: in MatchPoint): Int {
  match p {
    case MatchPoint { x, y } -> {
      await pause()
      x * 10 + y
    }
  }
}

async func nestedPattern(o: in Option[(Int, String)]): String {
  match o {
    case Some((n, s)) -> {
      await pause()
      s + toString(n)
    }
    case None -> "none"
  }
}

async func atPattern(o: in Option[Int]): String {
  match o {
    case whole @ Some(v) -> {
      await pause()
      match whole {
        case Some(w) -> toString(v) + "/" + toString(w)
        case None -> "lost"
      }
    }
    case None -> "none"
  }
}

async func orPattern(s: in MatchShape): Int {
  match s {
    case Rect(n, _) | Circle(n) -> {
      await pause()
      n + 100
    }
  }
}

// The guard suspends; when it fails, the next arm's test reads the scrutinee.
async func awaitingGuard(o: in Option[Int]): String {
  match o {
    case Some(v) if await isBig(v) -> {
      await pause()
      "big " + toString(v)
    }
    case Some(v) -> "small " + toString(v)
    case None -> "none"
  }
}

// The guard holds the function's only `await`.
async func guardOnlyAwait(o: in Option[Int]): Int {
  match o {
    case Some(v) if await isBig(v) -> v
    case Some(v) -> 0 - v
    case None -> 0
  }
}

async func plainGuardSuspendingBody(o: in Option[Int]): Int {
  match o {
    case Some(v) if v > 3 -> {
      await pause()
      v + 1
    }
    case Some(v) -> v
    case None -> 0
  }
}

async func statementMatch(o: in Option[String], log: in List[String]): Unit {
  match o {
    case Some(s) -> {
      await pause()
      log.add(s)
    }
    case None -> log.add("none")
  }
}

async func twoAwaitsInArm(o: in Option[Int]): Int {
  match o {
    case Some(v) -> {
      await pause()
      val a = v + 1
      await pause()
      a + v
    }
    case None -> 0
  }
}

// Two arms bind `v` at different types; each keeps its own field.
async func sameNameDifferentTypes(r: in Result[Int, String]): String {
  match r {
    case Ok(v) -> {
      await pause()
      "ok " + toString(v * 2)
    }
    case Err(v) -> {
      await pause()
      "err " + v
    }
  }
}

async func matchInLoop(xs: in List[Option[Int]]): Int {
  var t = 0
  for o in xs {
    match o {
      case Some(v) -> {
        await pause()
        t = t + v
      }
      case None -> ()
    }
  }
  t
}

async func valueOfMatch(o: in Option[Int]): Int {
  val got = match o { case Some(v) -> { await pause(); v * 3 }; case None -> -1 }
  got + 1
}

async func destructuringVal(p: in (Int, String)): String {
  val (a, b) = p
  await pause()
  b + toString(a)
}

async func compoundAssign(): Int {
  var t = 10
  t += await asyncThree()
  t *= await asyncThree()
  t
}

async func compoundAssignString(): String {
  var s = "a"
  s += "b"
  s += toString(await asyncThree())
  s
}

record AfterAsyncMatchRecord {
  a: Int
  b: String
}

func optionsOneNoneThree(): List[Option[Int]] {
  val xs: List[Option[Int]] = newList()
  xs.add(Some(1))
  xs.add(None)
  xs.add(Some(3))
  xs
}

test "a union constructor pattern's binding survives a real suspension (#7816)" {
  assertEqualInt(await doubleSome(Some(21)), 42, "Some(21) doubles after the await")
  assertEqualInt(await doubleSome(None), 0, "None arm")
}

test "every case of a user union keeps its bindings" {
  assertEqualInt(await unionCases(Rect(w = 3, h = 5)), 15, "Rect(3, 5)")
  assertEqualInt(await unionCases(Circle(r = 7)), 21, "Circle(7)")
}

test "a tuple pattern's bindings survive a real suspension" {
  assertEqual(await tuplePattern(4, "t"), "t4", "both elements after the await")
}

test "a record pattern's bindings survive a real suspension" {
  assertEqualInt(await recordPattern(MatchPoint(x = 3, y = 4)), 34, "x and y after the await")
}

test "a nested pattern's bindings survive a real suspension" {
  assertEqual(await nestedPattern(Some((5, "n"))), "n5", "Some((5, n))")
  assertEqual(await nestedPattern(None), "none", "None arm")
}

test "an @ binding and its inner binding survive a real suspension" {
  assertEqual(await atPattern(Some(6)), "6/6", "whole and v after the await")
}

test "an or-pattern's binding survives a real suspension" {
  assertEqualInt(await orPattern(Rect(w = 4, h = 9)), 104, "Rect alternative")
  assertEqualInt(await orPattern(Circle(r = 6)), 106, "Circle alternative")
}

test "a guard that suspends keeps the bindings and the scrutinee" {
  assertEqual(await awaitingGuard(Some(20)), "big 20", "guard holds")
  assertEqual(await awaitingGuard(Some(2)), "small 2", "guard fails, the next arm re-tests the scrutinee")
  assertEqual(await awaitingGuard(None), "none", "guard skipped")
}

test "a guard holding the function's only await" {
  assertEqualInt(await guardOnlyAwait(Some(30)), 30, "guard holds")
  assertEqualInt(await guardOnlyAwait(Some(3)), -3, "guard fails")
}

test "a plain guard with a suspending body" {
  assertEqualInt(await plainGuardSuspendingBody(Some(9)), 10, "guarded arm")
  assertEqualInt(await plainGuardSuspendingBody(Some(2)), 2, "fallback arm")
}

test "a statement-position match keeps its binding" {
  val log: List[String] = newList()
  await statementMatch(Some("hi"), log)
  await statementMatch(None, log)
  assertEqualInt(log.count, 2, "one entry per call")
  assertEqual(log[0], "hi", "the Some arm's binding after the await")
  assertEqual(log[1], "none", "the None arm")
}

test "a binding read after two suspensions in one arm" {
  assertEqualInt(await twoAwaitsInArm(Some(5)), 11, "(5 + 1) + 5")
}

test "two arms binding the same name at different types keep separate fields" {
  assertEqual(await sameNameDifferentTypes(Ok(4)), "ok 8", "Int binding")
  assertEqual(await sameNameDifferentTypes(Err("x")), "err x", "String binding")
}

test "a match inside a for loop body keeps both the loop's and the arm's state" {
  assertEqualInt(await matchInLoop(optionsOneNoneThree()), 4, "1 + 3")
}

test "a value-producing match whose arm suspends" {
  assertEqualInt(await valueOfMatch(Some(4)), 13, "4 * 3 + 1")
  assertEqualInt(await valueOfMatch(None), 0, "-1 + 1")
}

test "a destructuring val survives a real suspension" {
  assertEqual(await destructuringVal((4, "q")), "q4", "both names after the await")
}

test "a compound assignment whose value suspends" {
  assertEqualInt(await compoundAssign(), 39, "(10 + 3) * 3")
  assertEqual(await compoundAssignString(), "ab3", "String +=")
}

test "a record declared after every async func keeps its field tokens" {
  val r = AfterAsyncMatchRecord(a = 7, b = "ok")
  assertEqualInt(r.a, 7, "first field")
  assertEqual(r.b, "ok", "second field")
}
