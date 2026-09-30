//! async_implicit_await_self_test.l — a direct call to an `async func`
//! awaits in place, with or without `await` (docs/01 §7.1, #7838).
//!
//! On `--target dotnet` an `async func` returns its task, and before #7838
//! only an explicit `await` (or `?`) unwrapped it: a direct call in a lambda
//! body, a `val`, a `match` scrutinee, an operand or a call argument left
//! the raw `Task<T>` in place (a cast failure at run time, or T0115 at the
//! first read of a pattern binding).  `Lyric.Propagate` now makes the await
//! explicit.  Each case runs from a synchronous caller and from an `async`
//! one, and the file runs on both targets.
//!
//!   lyric test lyric-compiler/lyric/async_implicit_await_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/async_implicit_await_self_test.l
@test_module
package Lyric.AsyncImplicitAwaitSelfTest

import Std.Core
import Std.Collections
import Std.Testing

async func nextOf(n: in Int): Option[Int] {
  return Some(value = n + 1)
}

async func label(n: in Int): String {
  return "n" + n.toString()
}

async func twice(n: in Int): Int {
  return n * 2
}

async func append(log: in List[String], entry: in String): Unit {
  log.add(entry)
}

func applyTo(g: in (Int) -> Option[Int], n: in Int): Int {
  match g(n) {
    case Some(v) -> v
    case None -> -1
  }
}

func plusOne(n: in Int): Int {
  n + 1
}

func syncCases(): String {
  val viaLambda = applyTo({ x: Int -> nextOf(x) }, 3)
  val bound = nextOf(10)
  val fromVal = match bound { case Some(w) -> w; case None -> -1 }
  val fromScrutinee = match nextOf(20) { case Some(w) -> w; case None -> -1 }
  val operand = "<" + label(5) + ">"
  val argument = plusOne(twice(4))
  viaLambda.toString() + " " + fromVal.toString() + " " + fromScrutinee.toString() + " " + operand + " " +
    argument.toString()
}

async func asyncCases(): String {
  val viaLambda = applyTo({ x: Int -> nextOf(x) }, 3)
  val bound = nextOf(10)
  val fromVal = match bound { case Some(w) -> w; case None -> -1 }
  val fromScrutinee = match nextOf(20) { case Some(w) -> w; case None -> -1 }
  val operand = "<" + label(5) + ">"
  val argument = plusOne(twice(4))
  viaLambda.toString() + " " + fromVal.toString() + " " + fromScrutinee.toString() + " " + operand + " " +
    argument.toString()
}

test "direct async calls await in place in a synchronous caller" {
  assertEqual(syncCases(), "4 11 21 <n5> 9", "lambda body, val, scrutinee, operand and argument")
}

test "direct async calls await in place in an async caller" {
  assertEqual(await asyncCases(), "4 11 21 <n5> 9", "lambda body, val, scrutinee, operand and argument")
}

test "a statement call finishes before the next statement" {
  val log: List[String] = newList()
  append(log, "first")
  log.add("second")
  assertEqualInt(log.count, 2, "both entries")
  assertEqual(log[0], "first", "the async call ran to completion first")
}

test "an explicit await and a spawned call are not awaited twice" {
  assertEqualInt(await twice(6), 12, "explicit await")
  scope {
    val handle = spawn twice(7)
    assertEqualInt(await handle, 14, "spawned call awaited once through its handle")
  }
}
