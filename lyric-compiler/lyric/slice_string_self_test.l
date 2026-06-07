//! slice_string_self_test.l — regression test for two self-hosted MSIL
//! codegen fixes from #2539:
//!
//!   1. `String` relational operators (`<` / `>` / `<=` / `>=`).  The
//!      relational arms used to emit a raw integer `clt` / `cgt`, which
//!      compares the two string *references* as integers rather than
//!      lexicographically.  They now route through
//!      `String.CompareOrdinal`, so `"a" < "b"` is `true`.
//!
//!   2. `slice.length`.  Slice values are `List`-backed at runtime
//!      (slice literals and `List.toArray()` both yield a `List`), but
//!      `.length` codegen used to assume a real array (`ldlen`) or a
//!      `String` (`String.get_Length`), reading garbage / faulting.
//!      `.length` now routes through the collection-count path
//!      (`ICollection.get_Count`) for every `List`-backed receiver, and
//!      slice indexing (`xs[i]`) routes through `IList.get_Item`, so both
//!      work whether the value is a genuine CLI array or a `List`.
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: those
//! `_tests.l` files are compiled and run by the **F# stage-0** emitter,
//! which does not exercise the self-hosted codegen these fixes live in.
//! `lyric test` compiles this `@test_module` IN-PROCESS through the
//! self-hosted `Msil.Bridge`, then runs it.  Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.  Run via:
//!
//!   lyric test lyric-compiler/lyric/slice_string_self_test.l
//!
//! Note: `Std.Sort.sortInts` / `sortStrings` are intentionally NOT
//! exercised here — they route through a *generic* `sort[T]` whose
//! `slice[T]` parameter is emitted as a true CLR `!0[]` array while the
//! argument is `List`-backed; correcting that cross-package generic-slice
//! ABI is tracked separately from this `.length` / string-comparison fix.
@test_module
package Lyric.SliceStringSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// String relational operators — lexicographic, not pointer comparison.
// ─────────────────────────────────────────────────────────────────────────────
test "String < is lexicographic" {
  assertTrue("a" < "b", "a < b")
  assertTrue(not ("b" < "a"), "not b < a")
  assertTrue("apple" < "banana", "apple < banana")
  assertTrue("ab" < "abc", "prefix is less")
  assertTrue(not ("a" < "a"), "not a < a (equal)")
}

test "String > is lexicographic" {
  assertTrue("b" > "a", "b > a")
  assertTrue(not ("a" > "b"), "not a > b")
  assertTrue("banana" > "apple", "banana > apple")
  assertTrue(not ("a" > "a"), "not a > a (equal)")
}

test "String <= and >= include equality" {
  assertTrue("a" <= "a", "a <= a")
  assertTrue("a" <= "b", "a <= b")
  assertTrue(not ("b" <= "a"), "not b <= a")
  assertTrue("a" >= "a", "a >= a")
  assertTrue("b" >= "a", "b >= a")
  assertTrue(not ("a" >= "b"), "not a >= b")
}

test "String < on List-read values picks the minimum" {
  val xs: List[String] = newList()
  xs.add("charlie")
  xs.add("alpha")
  xs.add("bravo")
  var bestIdx = 0
  var k = 1
  while k < xs.count {
    if xs[k] < xs[bestIdx] {
      bestIdx = k
    }
    k = k + 1
  }
  assertEqual(xs[bestIdx], "alpha", "min of charlie/alpha/bravo")
}

// ─────────────────────────────────────────────────────────────────────────────
// slice.length — element count for every List-backed slice representation.
// ─────────────────────────────────────────────────────────────────────────────
test "slice literal .length" {
  val xs: slice[Int] = [3, 1, 2]
  assertEqualInt(xs.length, 3, "int literal length")
  val empty: slice[Int] = []
  assertEqualInt(empty.length, 0, "empty literal length")
  val strs: slice[String] = ["a", "b"]
  assertEqualInt(strs.length, 2, "string literal length")
}

test "slice literal indexing" {
  val xs: slice[Int] = [10, 20, 30]
  assertEqualInt(xs[0], 10, "index 0")
  assertEqualInt(xs[2], 30, "index 2")
  val strs: slice[String] = ["x", "y"]
  assertEqual(strs[1], "y", "string index 1")
}

test "List.toArray().length" {
  val l: List[Int] = newList()
  l.add(3)
  l.add(1)
  l.add(2)
  assertEqualInt(l.toArray().length, 3, "toArray length")
}

// ─────────────────────────────────────────────────────────────────────────────
// slice parameters — `.length` / indexing inside a non-generic callee that
// declares a `slice[T]` parameter (whose CLR signature is `T[]` but whose
// argument is List-backed).
// ─────────────────────────────────────────────────────────────────────────────
func sliceLen(xs: in slice[Int]): Int {
  xs.length
}

func sliceFirst(xs: in slice[Int]): Int {
  xs[0]
}

func sliceSum(xs: in slice[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.length {
    total = total + xs[i]
    i = i + 1
  }
  total
}

test "slice param .length / index / iterate" {
  assertEqualInt(sliceLen([5, 6, 7, 8]), 4, "param length")
  assertEqualInt(sliceFirst([5, 6, 7, 8]), 5, "param first")
  assertEqualInt(sliceSum([1, 2, 3, 4]), 10, "param sum via length+index")
}

// ─────────────────────────────────────────────────────────────────────────────
// Genuine CLI-array slices (a `String.split` result) — `.length`, indexing,
// and `for` iteration must all agree on the element count.
// ─────────────────────────────────────────────────────────────────────────────
test "split result .length / index / for" {
  val parts = Str.split("a,b,c", ",")
  assertEqualInt(parts.length, 3, "split length")
  assertEqual(parts[0], "a", "split index 0")
  assertEqual(parts[2], "c", "split index 2")
  var n = 0
  for p in parts {
    n = n + 1
  }
  assertEqualInt(n, 3, "split for count")
}
