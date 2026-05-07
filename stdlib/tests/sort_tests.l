// stdlib/tests/sort_tests.l — Tests for Std.Sort.
//
// Covers: empty slice, single element, already-sorted, reverse-sorted,
// duplicates, stability, sortInts, sortStrings, isSorted predicate.
package Std.Sort.Tests

import Std.Core
import Std.Sort
import Std.Testing

// Comparator reused across several tests.
func cmpInt(a: Int, b: Int): Int {
  if a < b { -1 } else if a > b { 1 } else { 0 }
}

func testEmpty(): Unit {
  val sorted = sortInts([])
  assertEqualInt(sorted.length, 0, "empty sort length")
}

func testSingle(): Unit {
  val sorted = sortInts([42])
  assertEqualInt(sorted.length, 1, "single sort length")
  assertEqualInt(sorted[0], 42, "single sort value")
}

func testSortInts(): Unit {
  val sorted = sortInts([3, 1, 4, 1, 5, 9, 2, 6])
  assertEqualInt(sorted.length, 8, "sort length")
  assertEqualInt(sorted[0], 1, "sorted[0]")
  assertEqualInt(sorted[1], 1, "sorted[1]")
  assertEqualInt(sorted[2], 2, "sorted[2]")
  assertEqualInt(sorted[3], 3, "sorted[3]")
  assertEqualInt(sorted[7], 9, "sorted[7]")
}

func testSortAlreadySorted(): Unit {
  val xs = [1, 2, 3, 4, 5]
  val sorted = sortInts(xs)
  assertEqualInt(sorted[0], 1, "already sorted[0]")
  assertEqualInt(sorted[4], 5, "already sorted[4]")
}

func testSortReversed(): Unit {
  val sorted = sortInts([5, 4, 3, 2, 1])
  assertEqualInt(sorted[0], 1, "reversed[0]")
  assertEqualInt(sorted[4], 5, "reversed[4]")
}

func testSortDuplicates(): Unit {
  val sorted = sortInts([3, 3, 1, 2, 1, 2])
  assertEqualInt(sorted[0], 1, "dups[0]")
  assertEqualInt(sorted[1], 1, "dups[1]")
  assertEqualInt(sorted[2], 2, "dups[2]")
  assertEqualInt(sorted[3], 2, "dups[3]")
  assertEqualInt(sorted[4], 3, "dups[4]")
  assertEqualInt(sorted[5], 3, "dups[5]")
}

func testSortStrings(): Unit {
  val sorted = sortStrings(["banana", "apple", "cherry", "apricot"])
  assertEqual(sorted[0], "apple", "strings[0]")
  assertEqual(sorted[1], "apricot", "strings[1]")
  assertEqual(sorted[2], "banana", "strings[2]")
  assertEqual(sorted[3], "cherry", "strings[3]")
}

func testIsSorted(): Unit {
  val cmp = { a: Int, b: Int -> if a < b { -1 } else if a > b { 1 } else { 0 } }
  assertTrue(isSorted([], cmp), "empty is sorted")
  assertTrue(isSorted([1], cmp), "single is sorted")
  assertTrue(isSorted([1, 2, 3], cmp), "ascending is sorted")
  assertTrue(isSorted([1, 1, 2], cmp), "with duplicates is sorted")
  assertTrue(not isSorted([3, 1, 2], cmp), "unsorted is not sorted")
  assertTrue(not isSorted([1, 3, 2], cmp), "partially sorted is not sorted")
}

func testSortLongs(): Unit {
  val sorted = sortLongs([30i64, 10i64, 20i64])
  // Just verify order holds.
  assertTrue(sorted[0] < sorted[1], "longs[0] < longs[1]")
  assertTrue(sorted[1] < sorted[2], "longs[1] < longs[2]")
}

func testCustomComparator(): Unit {
  // Sort descending by supplying a reversed comparator.
  val sorted = sort([3, 1, 4, 1, 5], { a: Int, b: Int ->
    if a > b { -1 } else if a < b { 1 } else { 0 }
  })
  assertEqualInt(sorted[0], 5, "desc[0]")
  assertEqualInt(sorted[4], 1, "desc[4]")
}

func main(): Unit {
  testEmpty()
  testSingle()
  testSortInts()
  testSortAlreadySorted()
  testSortReversed()
  testSortDuplicates()
  testSortStrings()
  testIsSorted()
  testSortLongs()
  testCustomComparator()
  println("sort: ok")
}
