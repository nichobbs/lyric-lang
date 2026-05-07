// stdlib/tests/set_tests.l — Tests for Std.Set.
//
// Covers: construction, membership, removal, size, fromSlice, setElements,
// setUnion, setIntersection, setDifference, setIsSubset, setEquals.
// Since sets have unordered iteration, tests rely on setContains and setSize
// rather than positional element checks.
package Std.Set.Tests

import Std.Core
import Std.Set
import Std.CollectionsHost
import Std.Testing

func testEmpty(): Unit {
  val s: Set[Int] = newSet()
  assertTrue(setIsEmpty(s), "empty is empty")
  assertEqualInt(setSize(s), 0, "empty size")
  assertTrue(not setContains(s, 1), "empty contains nothing")
}

func testAddContains(): Unit {
  val s: Set[Int] = newSet()
  setAdd(s, 10)
  setAdd(s, 20)
  setAdd(s, 30)
  assertEqualInt(setSize(s), 3, "size after 3 adds")
  assertTrue(setContains(s, 10), "contains 10")
  assertTrue(setContains(s, 20), "contains 20")
  assertTrue(setContains(s, 30), "contains 30")
  assertTrue(not setContains(s, 99), "does not contain 99")
}

func testAddDuplicate(): Unit {
  val s: Set[Int] = newSet()
  setAdd(s, 42)
  setAdd(s, 42)
  assertEqualInt(setSize(s), 1, "duplicate not added")
}

func testRemove(): Unit {
  val s: Set[Int] = newSet()
  setAdd(s, 1)
  setAdd(s, 2)
  val wasPresent = setRemove(s, 1)
  assertTrue(wasPresent, "remove returns true for present element")
  assertEqualInt(setSize(s), 1, "size after remove")
  assertTrue(not setContains(s, 1), "removed element gone")
  assertTrue(setContains(s, 2), "other element still present")

  val wasAbsent = setRemove(s, 99)
  assertTrue(not wasAbsent, "remove returns false for absent element")
}

func testFromSlice(): Unit {
  val s = setFromSlice([1, 2, 3, 2, 1])
  assertEqualInt(setSize(s), 3, "fromSlice deduplicates")
  assertTrue(setContains(s, 1), "fromSlice contains 1")
  assertTrue(setContains(s, 2), "fromSlice contains 2")
  assertTrue(setContains(s, 3), "fromSlice contains 3")
}

func testElements(): Unit {
  val s = setFromSlice([10, 20, 30])
  val elems = setElements(s)
  assertEqualInt(elems.length, 3, "elements length")
  // Order unspecified; verify all are members.
  assertTrue(setContains(s, elems[0]), "elems[0] is member")
  assertTrue(setContains(s, elems[1]), "elems[1] is member")
  assertTrue(setContains(s, elems[2]), "elems[2] is member")
}

func testUnion(): Unit {
  val a = setFromSlice([1, 2, 3])
  val b = setFromSlice([3, 4, 5])
  val u = setUnion(a, b)
  assertEqualInt(setSize(u), 5, "union size")
  assertTrue(setContains(u, 1), "union contains 1")
  assertTrue(setContains(u, 3), "union contains 3 (shared)")
  assertTrue(setContains(u, 5), "union contains 5")
}

func testIntersection(): Unit {
  val a = setFromSlice([1, 2, 3, 4])
  val b = setFromSlice([3, 4, 5, 6])
  val inter = setIntersection(a, b)
  assertEqualInt(setSize(inter), 2, "intersection size")
  assertTrue(setContains(inter, 3), "intersection contains 3")
  assertTrue(setContains(inter, 4), "intersection contains 4")
  assertTrue(not setContains(inter, 1), "intersection excludes 1")
  assertTrue(not setContains(inter, 5), "intersection excludes 5")
}

func testDifference(): Unit {
  val a = setFromSlice([1, 2, 3, 4])
  val b = setFromSlice([3, 4, 5])
  val diff = setDifference(a, b)
  assertEqualInt(setSize(diff), 2, "difference size")
  assertTrue(setContains(diff, 1), "difference contains 1")
  assertTrue(setContains(diff, 2), "difference contains 2")
  assertTrue(not setContains(diff, 3), "difference excludes 3")
}

func testSubset(): Unit {
  val full = setFromSlice([1, 2, 3, 4, 5])
  val sub  = setFromSlice([2, 4])
  val disjoint = setFromSlice([6, 7])

  assertTrue(setIsSubset(sub, full), "sub is subset of full")
  assertTrue(setIsSubset(full, full), "set is subset of itself")
  assertTrue(not setIsSubset(full, sub), "full is not subset of sub")
  assertTrue(not setIsSubset(disjoint, full), "disjoint is not subset")
}

func testEquals(): Unit {
  val a = setFromSlice([1, 2, 3])
  val b = setFromSlice([3, 1, 2])
  val c = setFromSlice([1, 2])

  assertTrue(setEquals(a, b), "same elements in different order are equal")
  assertTrue(not setEquals(a, c), "different sizes are not equal")
}

func main(): Unit {
  testEmpty()
  testAddContains()
  testAddDuplicate()
  testRemove()
  testFromSlice()
  testElements()
  testUnion()
  testIntersection()
  testDifference()
  testSubset()
  testEquals()
  println("set: ok")
}
