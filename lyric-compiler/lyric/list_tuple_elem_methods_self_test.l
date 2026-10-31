//! list_tuple_elem_methods_self_test.l - `indexOf`, `lastIndexOf` and `remove` on a `List` of
//! tuples find the element on every target (#8668).
//!
//! On `--target dotnet` a `List` of tuples is the erased `List<object>`, so the receiver's lowered
//! type was `object`: `indexOf` bound to `String.IndexOf` (an access violation) and `remove` to the
//! pop-only fallback (always `false`).  The type checker now records the stdlib `List` receiver and
//! the backend lowers those methods through `List.IndexOf`/`LastIndexOf`/`Remove`.
@test_module
package Lyric.ListTupleElemMethodsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func pairs(): List[(Int, Int)] {
  val c: List[(Int, Int)] = newList()
  c.add((1, 2))
  c.add((5, 6))
  c.add((3, 4))
  c.add((5, 6))
  c
}

test "indexOf finds a tuple by value" {
  val c = pairs()
  assertEqualInt(c.indexOf((5, 6)), 1, "indexOf")
  assertEqualInt(c.indexOf((9, 9)), -1, "indexOf absent")
}

test "indexOf finds the identical tuple" {
  val c: List[(Int, Int)] = newList()
  val t = (5, 6)
  c.add(t)
  assertEqualInt(c.indexOf(t), 0, "indexOf same value")
}

test "lastIndexOf finds the last equal tuple" {
  val c = pairs()
  assertEqualInt(c.lastIndexOf((5, 6)), 3, "lastIndexOf")
  assertEqualInt(c.lastIndexOf((9, 9)), -1, "lastIndexOf absent")
}

test "remove removes the first equal tuple" {
  val c = pairs()
  assertTrue(c.remove((5, 6)), "removed")
  assertEqualInt(c.count, 3, "count after remove")
  assertEqualInt(c.indexOf((5, 6)), 2, "second copy remains")
  assertFalse(c.remove((9, 9)), "absent not removed")
  assertEqualInt(c.count, 3, "count after absent remove")
}

test "contains agrees with indexOf" {
  val c = pairs()
  assertTrue(c.contains((3, 4)), "contains")
  assertFalse(c.contains((4, 3)), "not contains")
}
