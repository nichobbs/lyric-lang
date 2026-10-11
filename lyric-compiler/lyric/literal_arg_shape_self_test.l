//! literal_arg_shape_self_test.l — a bracket literal passed where a `List` is
//! expected is built as that `List`, and the literals inside it as the shape
//! the `List`'s element type gives them, on every target (#8191, #8192,
//! #8193).
//!
//! docs/01 §2.7: a bracket literal used directly where a `List[T]` is
//! expected types and is built as `List[T]` there.  A generic callee's
//! parameter is instantiated from the other arguments, so `size([1, 2, 3])`
//! binds `T` in `size[T](xs: List[T])` to `Int` (M0002 before, #8193) and a
//! literal beside a `List` at a bare `T` is that `List` (#8191).  A literal
//! inside a `List[slice[Int]]` is a slice: the JVM built it as an
//! `ArrayList` and read it as an array (ClassCastException, #8192).  The
//! cases cover a call argument, a binding, a record and a union case field, a
//! return, a slice and an array of slices (as a binding, a field and an
//! argument), a method's argument, a generic callee, a generic record and
//! union case, and a generic callee called from a generic function.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/literal_arg_shape_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/literal_arg_shape_self_test.l
//!   lyric test --target native lyric-compiler/lyric/literal_arg_shape_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.LiteralArgShapeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Grid {
  rows: List[slice[Int]]
}

union Shape {
  case Rows(rows: List[slice[Int]])
  case Blank
}

record GBox[T] {
  items: List[T]
}

union Bag[T] {
  case Full(items: List[T])
  case Empty
}

record Table {
  cells: slice[slice[Int]]
}

record Pt {
  xs: List[Int]

  func plus(self: in Pt, ys: in List[Int]): Int {
    self.xs.count + ys[1]
  }
}

func Pt.addAll(self: in Pt, ys: in List[Int]): Int {
  self.xs.count * 10 + ys.count
}

func Pt.sizeOf[T](self: in Pt, ys: in List[T]): Int {
  ys.count
}

// The construction is the function's value, so it is checked against the
// return type and its field literal is a `List[T]` of the caller's `T`.
func boxOf[T](x: in T): GBox[T] {
  GBox(items = [x, x])
}

func bagLen[T](b: in Bag[T]): Int {
  match b {
    case Full(items) -> items.count
    case Empty -> 0
  }
}

func cellWidth(cells: in slice[slice[Int]]): Int {
  cells[1].length
}

func countSome[T](xs: in List[Option[T]]): Int {
  xs.count
}

func optionsOf[T](x: in T): Int {
  countSome([Some(value = x), None])
}

func count(xs: in List[slice[Int]]): Int {
  xs.count * 10 + xs[1].length
}

func sumRows(xs: in List[slice[Int]]): Int {
  var acc = 0
  for row in xs {
    for v in row {
      acc = acc + v
    }
  }
  acc
}

func joinWords(xs: in List[slice[String]]): String {
  var acc = ""
  for row in xs {
    for w in row {
      acc = acc + w
    }
  }
  acc
}

func rows(): List[slice[Int]] {
  [[4], [5, 6, 7]]
}

func rowsReturned(): List[slice[Int]] {
  return [[4], [5, 6, 7, 8]]
}

func shapeLen(s: in Shape): Int {
  match s {
    case Rows(rs) -> rs[1].length
    case Blank -> 0
  }
}

func size[T](xs: in List[T]): Int {
  xs.count
}

func lastOf[T](xs: in List[T]): T {
  xs[xs.count - 1]
}

func second[T](a: in T, b: in T): T {
  b
}

func first[T](a: in T, b: in T): T {
  a
}

func pairSize[T](a: in T, b: in T): Int {
  size([a, b])
}

func sumLongs(xs: in List[Long]): Long {
  var acc = 0i64
  for x in xs {
    acc = acc + x
  }
  acc
}

test "a List[slice[Int]] call argument, the issue's repro (#8192)" {
  assertEqualInt(count([[1], [5, 6]]), 22, "count")
  assertEqualInt(sumRows([[1], [5, 6]]), 12, "iterated")
  assertEqual(joinWords([["a"], ["b", "c"]]), "abc", "slice[String] elements")
}

test "a List of slices bound, stored in a field and returned (#8192)" {
  val xs: List[slice[Int]] = [[1], [5, 6]]
  assertEqualInt(xs[1].length, 2, "binding")
  val g = Grid(rows = [[1], [5, 6, 7]])
  assertEqualInt(g.rows[1].length, 3, "record field")
  assertEqualInt(shapeLen(Rows(rows = [[1], [5, 6]])), 2, "union case field")
  assertEqualInt(rows()[1].length, 3, "trailing value")
  assertEqualInt(rowsReturned()[1].length, 4, "return")
}

test "a slice and an array of slices (#8192)" {
  val s: slice[slice[Int]] = [[1], [5, 6]]
  assertEqualInt(s[1].length, 2, "slice of slices")
  val a: array[2, slice[Int]] = [[1], [5, 6, 9]]
  assertEqualInt(a[1].length, 3, "array of slices")
  val ls: List[slice[Long]] = [[1], [5, 6]]
  assertTrue(ls[1][1] == 6i64, "widened element")
  assertEqualInt(Table(cells = [[1], [5, 6, 7]]).cells[1].length, 3, "slice of slices field")
  assertEqualInt(cellWidth([[1], [5, 6]]), 2, "slice of slices argument")
}

test "a method's List parameter takes a literal as that List" {
  val p = Pt(xs = [1])
  assertEqualInt(p.addAll([1, 2]), 12, "dot-named method")
  assertEqualInt(p.plus([1, 2]), 3, "method in the record")
  assertEqualInt(p.sizeOf(["a", "b", "c"]), 3, "generic method")
}

test "a literal for a generic List[T] parameter (#8193)" {
  assertEqualInt(size([1, 2, 3]), 3, "Int")
  assertEqual(lastOf(["a", "b"]), "b", "String")
  assertEqualInt(pairSize("a", "b"), 2, "inside a generic function")
  assertEqualInt(GBox(items = [1, 2, 3]).items.count, 3, "generic record field")
  val b: GBox[Int] = GBox(items = [1, 2])
  assertEqualInt(b.items[1], 2, "generic record field, annotated")
  assertEqualInt(bagLen(Full(items = [1, 2, 3, 4])), 4, "generic union case field")
  assertEqualInt(boxOf(5).items[1], 5, "generic function's record, value T")
  assertEqual(boxOf("a").items[1], "a", "generic function's record, reference T")
  assertEqualInt(boxOf([1, 2, 3]).items[0].length, 3, "generic function's record, slice T")
  assertEqualInt(optionsOf(5), 2, "List[Option[T]] inside a generic function")
}

test "a literal beside a List at a bare T is that List (#8191)" {
  val base: List[Int] = newList()
  base.add(9)
  val r = second(base, [1, 2])
  assertEqualInt(r.count * 10 + r[1], 22, "after the List")
  val r2 = first([1, 2, 3], base)
  assertEqualInt(r2.count * 10 + r2[2], 33, "before the List")
  val longs: List[Long] = newList()
  val r3 = first([1, 2], longs)
  assertTrue(sumLongs(r3) == 3i64, "elements widen to the List's")
  val r4 = second([7], [1, 2])
  assertEqualInt(r4.length, 2, "two literals stay slices")
}
