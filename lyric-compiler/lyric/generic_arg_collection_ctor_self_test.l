//! generic_arg_collection_ctor_self_test.l - `newList()` / `newMap()`
//! without type arguments, passed to a generic function's parameter.
//!
//! On --target native a collection constructor takes its element types from
//! the type its position expects. A generic function's argument was lowered
//! with no expected type, so `unwrapOr(o, newList())` failed with "'newList'
//! needs its element types". The argument is now lowered against the
//! parameter type under the type arguments the other arguments bind, as a
//! lambda argument already was. Runs on every target.
@test_module
package Lyric.GenericArgCollectionCtorSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func firstOr[T](xs: in List[T], fallback: in T): T {
  if xs.count > 0 {
    xs[0]
  } else {
    fallback
  }
}

func sizeOf[K, V](m: in Map[K, V], label: in String): String {
  label + "=" + m.count.toString()
}

func pick[T](useFirst: in Bool, a: in T, b: in T): T {
  if useFirst {
    a
  } else {
    b
  }
}

test "newList() after the argument that binds T" {
  val none: Option[List[String]] = None
  val xs = unwrapOr(none, newList())
  assertEqualInt(xs.count, 0, "the default is an empty list")
  xs.add("a")
  assertEqual(xs[0], "a", "the list holds Strings")
  val some: Option[List[String]] = Some(value = ["b", "c"])
  assertEqualInt(unwrapOr(some, newList()).count, 2, "the Some value wins")
}

test "newList() before the argument that binds T" {
  val ys: List[Int] = [7, 8]
  val zs = pick(false, newList(), ys)
  assertEqualInt(zs.count, 2, "the second argument")
  val ws = pick(true, newList(), ys)
  assertEqualInt(ws.count, 0, "the empty first argument")
  ws.add(3)
  assertEqualInt(ws[0], 3, "the list holds Ints")
}

test "newListWithCapacity() and a nested element type" {
  val outer: List[List[Int]] = newList()
  val inner = firstOr(outer, newListWithCapacity(4))
  inner.add(5)
  assertEqualInt(inner[0], 5, "the fallback list holds Ints")
}

test "newMap() whose key and value types the other argument binds" {
  val m: Option[Map[String, Int]] = None
  val dflt = unwrapOr(m, newMap())
  dflt.add("k", 1)
  assertEqual(sizeOf(dflt, "m"), "m=1", "the map holds String keys and Int values")
}

test "a match arm that passes newList() to a generic function" {
  val o: Option[Option[List[String]]] = Some(value = None)
  val keys: List[String] = match o { case Some(inner) -> unwrapOr(inner, newList()); case None -> newList() }
  assertEqualInt(keys.count, 0, "an empty list")
}
