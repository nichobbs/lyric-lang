// list_value_compare_self_test.l — #1779 bug A: comparisons / arithmetic on a
// `List[ValueType]` element-access result.
//
// `List[T]` is represented as `List<object>` with boxed elements.  Before the
// fix, `List[primitive]` was tracked as a bare `MObject`, so `xs[i]` returned
// the boxed `object` while codegen *recorded* it as the element type — a later
// numeric op or comparison (`xs[i] <= 0`, `xs[i] + 1`) then treated the object
// reference as the unboxed value, producing invalid IL or a silently wrong
// result.  The fix tracks `List[ValueType]` as `MListOf(elemTy)` and has
// `EIndex` `unbox.any` the element back to its value type.
//
// Run in CI via native `lyric test --target dotnet` (compiled in-process
// through the self-hosted `Msil.Bridge`).  Imports only `Std.*`.

@test_module
package Lyric.ListValueCompareSelfTest

import Std.Core
import Std.Collections
import Std.Testing

test "Int element: equality and ordering comparisons" {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(-2)
  xs.add(10)
  assertTrue(xs[1] <= 0, "xs[1] (-2) <= 0")
  assertTrue(xs[0] > 0, "xs[0] (1) > 0")
  assertTrue(xs[2] >= 10, "xs[2] (10) >= 10")
  assertTrue(not (xs[0] < 0), "xs[0] (1) not < 0")
  assertTrue(xs[0] == 1, "xs[0] == 1")
  assertTrue(xs[1] != xs[0], "xs[1] != xs[0]")
}

test "Int element: arithmetic" {
  val xs: List[Int] = newList()
  xs.add(3)
  xs.add(4)
  assertEqualInt(xs[0] + xs[1], 7, "3 + 4")
  assertEqualInt(xs[1] * 2, 8, "4 * 2")
  assertEqualInt(xs[1] - xs[0], 1, "4 - 3")
}

test "Int element: comparison inside an if guard" {
  val xs: List[Int] = newList()
  xs.add(5)
  xs.add(-1)
  var hits = 0
  if xs[1] <= 0 { hits = hits + 1 }
  if xs[0] <= 0 { hits = hits + 1 }
  assertEqualInt(hits, 1, "only xs[1] is <= 0")
}

test "Int element: comparison inside a while loop (count negatives)" {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(-2)
  xs.add(3)
  xs.add(-4)
  var neg = 0
  var i = 0
  while i < xs.count {
    if xs[i] < 0 { neg = neg + 1 }
    i = i + 1
  }
  assertEqualInt(neg, 2, "two negative elements")
}

// The exact #1779 origin shape: a value-type list scanned with a `?`-style
// early return on a bad element, in a Result-returning function.
func sumPositives(xs: in List[Int]): Result[Int, String] {
  var total = 0
  var i = 0
  while i < xs.count {
    if xs[i] <= 0 { return Err("non-positive") }
    total = total + xs[i]
    i = i + 1
  }
  Ok(total)
}

func resultValue(r: in Result[Int, String]): Int {
  match r {
    case Ok(v)  -> v
    case Err(_) -> -1
  }
}

func resultLabel(r: in Result[Int, String]): String {
  match r {
    case Ok(_)  -> "ok"
    case Err(e) -> e
  }
}

test "value-type list scan with early-return on a bad element" {
  val good: List[Int] = newList()
  good.add(2)
  good.add(3)
  good.add(5)
  assertEqualInt(resultValue(sumPositives(good)), 10, "2+3+5 = 10")

  val bad: List[Int] = newList()
  bad.add(2)
  bad.add(-3)
  bad.add(5)
  assertEqual(resultLabel(sumPositives(bad)), "non-positive", "negative element -> Err")
}

test "Long element comparison and arithmetic" {
  val xs: List[Long] = newList()
  xs.add(100i64)
  xs.add(-50i64)
  assertTrue(xs[1] < 0i64, "xs[1] (-50) < 0")
  assertTrue(xs[0] >= 100i64, "xs[0] (100) >= 100")
  assertEqualInt(longToInt(xs[0] + xs[1]), 50, "100 + (-50) = 50")
}

test "Double element comparison" {
  val xs: List[Double] = newList()
  xs.add(1.5)
  xs.add(-0.5)
  assertTrue(xs[1] < 0.0, "xs[1] (-0.5) < 0.0")
  assertTrue(xs[0] > 1.0, "xs[0] (1.5) > 1.0")
}

test "Bool element used directly in a condition" {
  val flags: List[Bool] = newList()
  flags.add(true)
  flags.add(false)
  var trues = 0
  var i = 0
  while i < flags.count {
    if flags[i] { trues = trues + 1 }
    i = i + 1
  }
  assertEqualInt(trues, 1, "one true flag")
}

test "Char element comparison" {
  val cs: List[Char] = newList()
  cs.add('a')
  cs.add('z')
  assertTrue(cs[0] == 'a', "cs[0] == 'a'")
  assertTrue(cs[1] != 'a', "cs[1] != 'a'")
}

test "Int element: indexed write then read-back composes correctly" {
  // Confirms the write path (set_Item with auto-box) composes with the
  // read path (get_Item with unbox.any) so that round-trip equality
  // holds.  Guards against future refactors breaking the write→read
  // symmetry the #1779 fix established.
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs[0] = 99
  assertEqualInt(xs[0], 99, "xs[0] after write reads back as 99")
  assertTrue(xs[0] > xs[1], "xs[0] (99) > xs[1] (2) after write")
  assertTrue(xs[0] == 99, "xs[0] == 99 (equality after write)")
}
