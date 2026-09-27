//! stdlib/tests/collections_tests.l — Tests for Std.Collections.
//!
//! Covers: List construction, add, count, index access, listContains;
//! Map construction, add, containsKey, mapGet (Some/None), and count.
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

func testListContains(): Unit {
  val xs: List[String] = newList()
  assertTrue(not listContains(xs, "a"), "empty list contains nothing")
  xs.add("alpha")
  xs.add("beta")
  xs.add("gamma")
  assertTrue(listContains(xs, "alpha"), "contains first element")
  assertTrue(listContains(xs, "beta"), "contains middle element")
  assertTrue(listContains(xs, "gamma"), "contains last element")
  assertTrue(not listContains(xs, "delta"), "does not contain absent element")
  assertTrue(not listContains(xs, "alph"), "no prefix match")
  assertTrue(not listContains(xs, ""), "empty string absent")
  xs.add("")
  assertTrue(listContains(xs, ""), "empty string present after add")
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

// mapForEach and mapEntries pair every key with its own value, with no
// lookup per key (#7282): the kernel walks entries directly.
func testMapForEachPairsKeysWithValues(): Unit {
  val m: Map[String, Int] = newMap()
  var i = 0
  while i < 500 {
    m["k" + toString(i)] = i * 3
    i = i + 1
  }
  // Captured lists (not reassigned vars) so the test also runs on native,
  // whose closures capture by value.
  val seen: List[Int] = newList()
  val mismatched: List[String] = newList()
  mapForEach(m, { k: String, v: Int -> seen.add(v); if "k" + toString(v / 3) != k { mismatched.add(k) } })
  assertEqualInt(seen.count, 500, "mapForEach visits every entry once")
  assertEqualInt(mismatched.count, 0, "mapForEach pairs each key with its own value")
  var total = 0
  var si = 0
  while si < seen.count {
    total = total + seen[si]
    si = si + 1
  }
  assertEqualInt(total, 3 * (499 * 500 / 2), "mapForEach sees every value")
  val empty: Map[String, Int] = newMap()
  val none: List[Int] = newList()
  mapForEach(empty, { k: String, v: Int -> none.add(v) })
  assertEqualInt(none.count, 0, "mapForEach on an empty map calls nothing")
}

func testMapEntriesPairsKeysWithValues(): Unit {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < 300 {
    m[i] = "v" + toString(i)
    i = i + 1
  }
  val es = mapEntries(m)
  assertEqualInt(es.count, 300, "mapEntries returns every entry")
  var mismatched = 0
  var j = 0
  while j < es.count {
    if es[j].value != "v" + toString(es[j].key) {
      mismatched = mismatched + 1
    }
    j = j + 1
  }
  assertEqualInt(mismatched, 0, "mapEntries pairs each key with its own value")
}

func main(): Unit {
  testListConstruction()
  testListAddAndAccess()
  testListStrings()
  testListWithCapacity()
  testListContains()
  testMapConstruction()
  testMapAddAndContainsKey()
  testMapGet()
  testMapIntKeys()
  testMapForEachPairsKeysWithValues()
  testMapEntriesPairsKeysWithValues()
  println("collections_tests: ok")
}
