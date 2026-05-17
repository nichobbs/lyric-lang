// stdlib/tests/iter_tests.l — Tests for Std.Iter.
//
// Covers non-allocating helpers (forEach side effects, fold, all, any,
// count, find, sumInt) and allocating helpers (map, filter, take, drop).
package Std.Iter.Tests

import Std.Core
import Std.Iter
import Std.Testing

func testForEach(): Unit {
  // Closures cannot capture outer variables, so we verify forEach
  // by confirming it completes on empty and non-empty slices.
  forEach([], { x: Int -> () })
  forEach([1, 2, 3], { x: Int -> () })
  // Cross-check iteration via fold (which uses the same for-each mechanism).
  val sum = fold([1, 2, 3], 0, { acc: Int, x: Int -> acc + x })
  assertEqualInt(sum, 6, "fold confirms element-by-element traversal")
}

func testFold(): Unit {
  val sum = fold([1, 2, 3, 4], 0, { acc: Int, x: Int -> acc + x })
  assertEqualInt(sum, 10, "fold sum")

  val product = fold([1, 2, 3, 4], 1, { acc: Int, x: Int -> acc * x })
  assertEqualInt(product, 24, "fold product")
}

func testAllAny(): Unit {
  assertTrue(all([2, 4, 6], { x: Int -> x % 2 == 0 }), "all even")
  assertTrue(not all([2, 3, 6], { x: Int -> x % 2 == 0 }), "not all even")
  assertTrue(all([], { x: Int -> false }), "all vacuously true on empty")

  assertTrue(any([1, 3, 4], { x: Int -> x % 2 == 0 }), "any even")
  assertTrue(not any([1, 3, 5], { x: Int -> x % 2 == 0 }), "none even")
  assertTrue(not any([], { x: Int -> true }), "any false on empty")
}

func testCountFind(): Unit {
  assertEqualInt(count([1, 2, 3, 4, 5], { x: Int -> x > 3 }), 2, "count gt 3")
  assertEqualInt(count([1, 2, 3], { x: Int -> x > 100 }), 0, "count none")

  val f = find([10, 20, 30], { x: Int -> x > 15 })
  assertTrue(isSome(f), "find found")
  assertEqualInt(unwrapOr(f, 0), 20, "find value")

  assertTrue(isNone(find([1, 2, 3], { x: Int -> x > 100 })), "find not found")
}

func testSumInt(): Unit {
  assertEqualInt(sumInt([1, 2, 3, 4]), 10, "sumInt")
  assertEqualInt(sumInt([]), 0, "sumInt empty")
}

func testMap(): Unit {
  val doubled = map([1, 2, 3], { x: Int -> x * 2 })
  assertEqualInt(doubled.length, 3, "map length")
  assertEqualInt(doubled[0], 2, "map[0]")
  assertEqualInt(doubled[1], 4, "map[1]")
  assertEqualInt(doubled[2], 6, "map[2]")
}

func testFilter(): Unit {
  val evens = filter([1, 2, 3, 4, 5, 6], { x: Int -> x % 2 == 0 })
  assertEqualInt(evens.length, 3, "filter length")
  assertEqualInt(evens[0], 2, "filter[0]")
  assertEqualInt(evens[2], 6, "filter[2]")
}

func testTakeDrop(): Unit {
  val t = take([1, 2, 3, 4, 5], 3)
  assertEqualInt(t.length, 3, "take length")
  assertEqualInt(t[2], 3, "take[2]")

  val d = drop([1, 2, 3, 4, 5], 2)
  assertEqualInt(d.length, 3, "drop length")
  assertEqualInt(d[0], 3, "drop[0]")

  // boundary: take more than available
  val tAll = take([1, 2], 100)
  assertEqualInt(tAll.length, 2, "take all when n>length")
}

func main(): Unit {
  testForEach()
  testFold()
  testAllAny()
  testCountFind()
  testSumInt()
  testMap()
  testFilter()
  testTakeDrop()
  println("iter: ok")
}
