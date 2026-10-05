//! Value-generic records (D169, #8090): a record's `N: Nat` parameter sizes
//! its array fields.  Each length a program uses is a separate type, built,
//! read, written, compared and given to methods like a record with a literal
//! length; its methods are value-generic functions named after it (D173).
//! Run on dotnet, the JVM and native.
@test_module
package Lyric.ValueGenericRecordSelfTest

import Std.Testing

record Ints[N: Nat] {
  var data: array[N, Int]

  func sum(self: in Ints[N]): Int {
    var t = 0
    for x in self.data {
      t = t + x
    }
    t
  }

  func size(self: in Ints[N]): Int = self.data.length

  func lastIndex(self: in Ints[N]): Int = N - 1
}

record FixedVec[T, N: Nat] {
  var data: array[N, T]
  tag: String = "v"
}

record Grid[W: Nat, H: Nat] {
  var cells: array[H, array[W, Int]]
}

record Frozen[N: Nat] {
  items: array[N, Int]
}

record Pair[N: Nat] {
  var left: Ints[N]
  var right: Ints[N]

  func total(self: in Pair[N]): Int = self.left.sum() + self.right.sum() + N
}

record Shaded[N: Nat] {
  var data: array[N, Int]
  size: Int = 7

  func shadowed(self: in Shaded[N]): Int {
    val size = 1
    size + data.length
  }

  func viaField(self: in Shaded[N]): Int = size + N

  func twice(self: in Shaded[N]): Int = viaField() * 2

  func same(self: in Shaded[N]): Self = self
}

val Width = 4

func firstOf[T, N: Nat](v: in FixedVec[T, N]): T = v.data[0]

func totalOf[N: Nat](v: in Ints[N]): Int = v.sum()

func makeInts[N: Nat](): Ints[N] = Ints()

test "a construction binds the length from an array field" {
  val a: array[3, Int] = [1, 2, 3]
  val v = Ints(data = a)
  assertEqualInt(v.sum(), 6, "sum")
  assertEqualInt(v.size(), 3, "size")
  assertEqualInt(v.lastIndex(), 2, "N in a method body")
}

test "two lengths are two instances with their own methods" {
  val a: array[2, Int] = [5, 6]
  val b: array[4, Int] = [1, 1, 1, 1]
  val x = Ints(data = a)
  val y = Ints(data = b)
  assertEqualInt(x.size() + y.size(), 6, "sizes")
  assertEqualInt(x.sum() + y.sum(), 15, "sums")
}

test "a length from the expected type zero fills the array field" {
  val z: Ints[5] = Ints()
  assertEqualInt(z.size(), 5, "length from the type")
  assertEqualInt(z.sum(), 0, "zero filled")
  val w = makeInts[3]()
  assertEqualInt(w.size(), 3, "length from a generic function's argument")
}

test "a field is written through and its array read out as a copy" {
  var v: Ints[3] = Ints()
  v.data[1] = 7
  v.data[2] += 2
  val snapshot = v.data
  v.data[1] = 0
  assertEqualInt(snapshot[1] + snapshot[2], 9, "the read kept its copy")
  assertEqualInt(v.sum(), 2, "the field changed")
}

test "a type and a value parameter together" {
  val names: array[2, String] = ["a", "b"]
  val fv = FixedVec(data = names)
  assertEqual(firstOf(fv), "a", "a generic function over the instance")
  assertEqual(fv.tag, "v", "a defaulted field")
  val nums: array[3, Long] = [9i64, 8i64, 7i64]
  val fl = FixedVec(data = nums, tag = "n")
  assertTrue(firstOf(fl) == 9i64, "a second instance")
}

test "a function generic over the instance length" {
  val a: array[4, Int] = [1, 2, 3, 4]
  assertEqualInt(totalOf(Ints(data = a)), 10, "N bound from the record argument")
}

test "a length given by a constant and nested arrays" {
  var g: Grid[Width, 2] = Grid()
  val row = g.cells[1]
  g.cells[1][3] = 8
  assertEqualInt(g.cells[1][3] + row[3], 8, "a row read out is a copy")
  assertEqualInt(g.cells[0].length, 4, "inner length from the constant")
  assertEqualInt(g.cells.length, 2, "outer length")
}

test "== compares value instances element by element" {
  val a: array[2, Int] = [1, 2]
  val b: array[2, Int] = [1, 2]
  assertTrue(Frozen(items = a) == Frozen(items = b), "equal")
  val c: array[2, Int] = [1, 3]
  assertFalse(Frozen(items = a) == Frozen(items = c), "unequal")
}

test "a field whose type is another instance is specialised with it" {
  val a: array[2, Int] = [1, 2]
  val b: array[2, Int] = [3, 4]
  val p = Pair(left = Ints(data = a), right = Ints(data = b))
  assertEqualInt(p.total(), 12, "both halves and the length")
}

test "a method reads fields and calls methods without self, and names Self" {
  val s: Shaded[3] = Shaded()
  assertEqualInt(s.shadowed(), 4, "a local shadows the field of its name")
  assertEqualInt(s.viaField(), 10, "a bare field read")
  assertEqualInt(s.twice(), 20, "a bare call of another method")
  assertEqualInt(s.same().size, 7, "Self is the instance type")
}
