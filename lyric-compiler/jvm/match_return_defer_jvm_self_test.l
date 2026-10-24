//! match_return_defer_jvm_self_test.l — JVM regression test for #7541.
//!
//! A `val x = match … { case Ok(v) -> v; case Err(e) -> return Err(e) }`
//! inside a function that also holds a pending `defer` must produce a
//! verifiable class.
@test_module
package Jvm.MatchReturnDeferSelfTest

import Std.Core
import Std.Testing

protected type Counter {
  var count: Int
  entry increment() {
    count = count + 1
  }
  entry get(): Int {
    return count
  }
}

func parsePart(s: in String): Result[Int, String] {
  if s == "" {
    Err("empty")
  } else {
    Ok(s.length)
  }
}

func sumParts(c: in Counter, a: in String, b: in String): Result[Int, String] {
  defer {
    c.increment()
  }
  val x = match parsePart(a) { case Ok(v) -> v; case Err(e) -> return Err(e) }
  val y = match parsePart(b) { case Ok(v) -> v; case Err(e) -> return Err(e) }
  return Ok(x + y)
}

test "match-with-return arms under a pending defer" {
  val c = Counter(count = 0)
  assertEqualInt(match sumParts(c, "ab", "cde") { case Ok(n) -> n; case Err(_) -> -1 }, 5, "ok path")
  assertEqual(match sumParts(c, "", "cde") { case Ok(_) -> "ok"; case Err(e) -> e }, "empty", "first err")
  assertEqual(match sumParts(c, "a", "") { case Ok(_) -> "ok"; case Err(e) -> e }, "empty", "second err")
  assertEqualInt(c.get(), 3, "defer ran on every path")
}

func mkSlice(n: Int): slice[Int] {
  val acc: List[Int] = newList()
  acc.add(n)
  acc.toArray()
}

func pick(o: in Option[Int]): slice[Int] {
  val xs = match o { case None -> []; case Some(v) -> mkSlice(v) }
  return xs
}

func pickIf(b: in Bool, n: in Int): slice[Int] {
  val xs = if b { [] } else { mkSlice(n) }
  return xs
}

test "empty list literal arm joins with a slice-typed arm" {
  assertEqualInt(pickIf(true, 1).length, 0, "if-then literal")
  assertEqualInt(pickIf(false, 1).length, 1, "if-else slice")
  assertEqualInt(pick(None).length, 0, "none -> empty")
  assertEqualInt(pick(Some(4)).length, 1, "some -> one")
}
