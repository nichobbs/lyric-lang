//! sort_self_test.l — `Std.Sort` bottom-up merge sort (#7281).
//!
//! Covers sizes on both sides of the insertion-sort run width (16) and of
//! each merge width, already-sorted, reversed and duplicate-heavy input, and
//! stability of equal keys.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/sort_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/sort_self_test.l
//! Imports only `Std.*`.
@test_module
package Lyric.SortSelfTest

import Std.Core
import Std.Collections
import Std.Sort
import Std.Testing

record Keyed {
  key: Int
  seq: Int
}

// A deterministic scrambled sequence of `n` values in [0, modulus).
func scrambled(n: in Int, modulus: in Int): slice[Int] {
  val acc: List[Int] = newListWithCapacity(n)
  var x = 12345
  var i = 0
  while i < n {
    x = (x * 1103 + 12345) % 1000003
    acc.add(x % modulus)
    i = i + 1
  }
  acc.toArray()
}

func sumOf(xs: in slice[Int]): Long {
  var s = 0i64
  for x in xs {
    s = s + x.toLong()
  }
  s
}

func checkSortsInts(xs: in slice[Int], label: in String): Unit {
  val sorted = sortInts(xs)
  assertEqualInt(sorted.length, xs.length, label + ": length")
  assertTrue(
    isSorted(sorted, { a: Int, b: Int -> if a < b { -1 } else if a > b { 1 } else { 0 } }),
    label + ": ordered"
  )
  assertEqualLong(sumOf(sorted), sumOf(xs), label + ": same elements")
}

test "sizes around the run and merge widths" {
  val sizes: slice[Int] = [0, 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 1000]
  for n in sizes {
    checkSortsInts(scrambled(n, 1000), "n=" + toString(n))
  }
}

test "sorted, reversed and duplicate-heavy input" {
  val up: List[Int] = newList()
  val down: List[Int] = newList()
  var i = 0
  while i < 200 {
    up.add(i)
    down.add(200 - i)
    i = i + 1
  }
  checkSortsInts(up.toArray(), "ascending")
  checkSortsInts(down.toArray(), "descending")
  checkSortsInts(scrambled(500, 3), "three distinct values")
  val r = sortInts(down.toArray())
  assertEqualInt(r[0], 1, "smallest first")
  assertEqualInt(r[199], 200, "largest last")
}

test "equal keys keep their original order" {
  val keys = scrambled(300, 5)
  val items: List[Keyed] = newList()
  var i = 0
  while i < keys.length {
    items.add(Keyed(key = keys[i], seq = i))
    i = i + 1
  }
  val sorted = sort(items.toArray(), { a: Keyed, b: Keyed -> a.key - b.key })
  var stable = true
  var j = 1
  while j < sorted.length {
    if sorted[j - 1].key == sorted[j].key and sorted[j - 1].seq > sorted[j].seq {
      stable = false
    }
    if sorted[j - 1].key > sorted[j].key {
      stable = false
    }
    j = j + 1
  }
  assertTrue(stable, "ordered by key, ties by original position")
}

test "sortStrings orders ordinally" {
  val r = sortStrings(["pear", "Apple", "apple", "banana", ""])
  assertEqual(r[0], "", "empty first")
  assertEqual(r[1], "Apple", "upper case before lower case")
  assertEqual(r[2], "apple", "then apple")
  assertEqual(r[4], "pear", "pear last")
}
