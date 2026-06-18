//! stdlib/tests/collections_tests.l — Tests for Std.Collections.
//!
//! Covers: List construction, add, count, index access; Map construction,
//! add, containsKey, mapGet (Some/None), and count.
package Std.Collections.Tests

import Std.Core
import Std.Collections
import Std.Testing

func testListConstruction(): Unit {
  val xs: List[Int] = newList()
  assertTrue(xs.count == 0, "fresh list is empty")
}

func testListAddAndAccess(): Unit {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  assertEqualInt(xs.count, 3, "list count after three adds")
  assertEqualInt(xs[0], 10, "list[0]")
  assertEqualInt(xs[1], 20, "list[1]")
  assertEqualInt(xs[2], 30, "list[2]")
}

func testListStrings(): Unit {
  val xs: List[String] = newList()
  xs.add("alpha")
  xs.add("beta")
  assertEqualInt(xs.count, 2, "string list count")
  assertTrue(xs[0] == "alpha", "xs[0] == alpha")
  assertTrue(xs[1] == "beta", "xs[1] == beta")
}

func testListWithCapacity(): Unit {
  val xs: List[Int] = newListWithCapacity(8)
  assertTrue(xs.count == 0, "capacity-constructed list starts empty")
  xs.add(1)
  assertEqualInt(xs.count, 1, "count after add to capacity list")
}

func testMapConstruction(): Unit {
  val m: Map[String, Int] = newMap()
  assertTrue(m.count == 0, "fresh map is empty")
}

func testMapAddAndContainsKey(): Unit {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  assertEqualInt(m.count, 2, "map count after two adds")
  assertTrue(m.containsKey("a"), "map containsKey a")
  assertTrue(m.containsKey("b"), "map containsKey b")
  assertTrue(not m.containsKey("c"), "map does not containsKey c")
}

func testMapGet(): Unit {
  val m: Map[String, Int] = newMap()
  m.add("x", 42)
  m.add("y", 99)
  match mapGet(m, "x") {
    case Some(v) -> assertEqualInt(v, 42, "mapGet x == 42")
    case None -> assertTrue(false, "mapGet x should be Some")
  }
  match mapGet(m, "z") {
    case Some(_) -> assertTrue(false, "mapGet z should be None")
    case None -> assertTrue(true, "mapGet z is None")
  }
}

func testMapIntKeys(): Unit {
  val m: Map[Int, String] = newMap()
  m.add(1, "one")
  m.add(2, "two")
  match mapGet(m, 1) {
    case Some(s) -> assertTrue(s == "one", "int key 1 -> one")
    case None -> assertTrue(false, "int key 1 missing")
  }
  match mapGet(m, 3) {
    case Some(_) -> assertTrue(false, "int key 3 should be absent")
    case None -> assertTrue(true, "int key 3 absent")
  }
}

func main(): Unit {
  testListConstruction()
  testListAddAndAccess()
  testListStrings()
  testListWithCapacity()
  testMapConstruction()
  testMapAddAndContainsKey()
  testMapGet()
  testMapIntKeys()
  println("collections_tests: ok")
}
