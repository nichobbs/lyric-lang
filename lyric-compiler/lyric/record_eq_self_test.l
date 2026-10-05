//! Structural `==` on records (D164).
//!
//! `==` and `!=` on a record with no `var` field, or on one that derives
//! `Equals`, compare the two records field by field: a field that is itself
//! such a record is compared by its fields, a distinct type by its
//! underlying value, and every other field with that type's own `==`.  A
//! record with a `var` field that does not derive `Equals` keeps identity.
//! The checker records each such operator and
//! `Lyric.ContractElaborator.lowerRecordEq` rewrites it before any backend
//! runs, so these cases pin the same behaviour on every target.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/record_eq_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/record_eq_self_test.l
//!   lyric test --target native lyric-compiler/lyric/record_eq_self_test.l
@test_module
package Lyric.RecordEqSelfTest

import Std.Core
import Std.Testing

record Point {
  x: Int
  y: Int
}

record Segment {
  a: Point
  b: Point
  label: String
}

type Meters = Double

record Leg {
  length: Meters
  name: String
}

record Box[T] {
  value: T
}

record Empty {
}

record Sample {
  v: Double
}

union Shape {
  case Dot(at: Point)
  case Nothing
}

record Tagged {
  shape: Shape
}

record Cell {
  var n: Int
}

@derive(Equals)
record Account {
  var balance: Long
  owner: String
}

record Counter {
  var calls: Int
}

func pt(c: in Counter, x: in Int): Point {
  c.calls = c.calls + 1
  Point(x = x, y = c.calls)
}

test "a value record compares field by field" {
  assertTrue(Point(x = 1, y = 2) == Point(x = 1, y = 2), "equal fields")
  assertFalse(Point(x = 1, y = 2) == Point(x = 1, y = 3), "a different field")
  assertTrue(Point(x = 1, y = 2) != Point(x = 2, y = 2), "!=")
  assertFalse(Point(x = 1, y = 2) != Point(x = 1, y = 2), "!= on equal records")
}

test "nested records, strings and distinct fields" {
  val s1 = Segment(a = Point(x = 0, y = 0), b = Point(x = 3, y = 4), label = "ab")
  val s2 = Segment(a = Point(x = 0, y = 0), b = Point(x = 3, y = 4), label = "a" + "b")
  assertTrue(s1 == s2, "nested and String fields")
  assertFalse(s1 == s2.copy(b = Point(x = 3, y = 5)), "a nested field differs")
  assertTrue(Leg(length = Meters.from(2.5), name = "x") == Leg(length = Meters.from(2.5), name = "x"), "distinct field")
  assertFalse(
    Leg(length = Meters.from(2.5), name = "x") == Leg(length = Meters.from(2.0), name = "x"),
    "distinct differs"
  )
}

test "generic, empty and union-holding records" {
  assertTrue(Box(value = 7) == Box(value = 7), "Box[Int]")
  assertTrue(Box(value = Box(value = 7)) == Box(value = Box(value = 7)), "Box[Box[Int]] compares both levels")
  assertFalse(Box(value = Box(value = 7)) == Box(value = Box(value = 8)), "Box[Box[Int]] inner differs")
  assertFalse(Box(value = "a") == Box(value = "b"), "Box[String]")
  assertTrue(Empty() == Empty(), "no fields")
  assertTrue(Tagged(shape = Shape.Nothing) == Tagged(shape = Shape.Nothing), "a nullary union field")
}

test "a floating-point field is equal when == holds or both are NaN (D172)" {
  val nan = 0.0 / 0.0
  assertTrue(Sample(v = nan) == Sample(v = nan), "a NaN field equals a NaN field")
  assertFalse(Sample(v = nan) == Sample(v = 1.0), "NaN against a number")
  assertTrue(Sample(v = 0.0) == Sample(v = -0.0), "zero equals negative zero")
  assertFalse(nan == nan, "a bare NaN is still not equal to itself")
}

test "a mutable record keeps identity unless it derives Equals" {
  val c1 = Cell(n = 1)
  val c2 = Cell(n = 1)
  val c3 = c1
  assertFalse(c1 == c2, "two equal mutable records are distinct")
  assertTrue(c1 == c3, "the same instance")
  val a1 = Account(balance = 10i64, owner = "ann")
  val a2 = Account(balance = 10i64, owner = "ann")
  assertTrue(a1 == a2, "derives Equals")
  a2.balance = 11i64
  assertTrue(a1 != a2, "after a write")
}

test "each operand is evaluated once, left to right" {
  val c = Counter(calls = 0)
  assertTrue(pt(c, 5) != pt(c, 5), "the second call sees the first")
  assertEqualInt(c.calls, 2, "two calls")
}

union Tree {
  case Leaf(label: String)
  case Node(left: Tree, right: Tree)
}

test "unions compare structurally on every target" {
  val t1 = Tree.Node(left = Tree.Leaf(label = "a"), right = Tree.Leaf(label = "b"))
  val t2 = Tree.Node(left = Tree.Leaf(label = "a"), right = Tree.Leaf(label = "b"))
  assertTrue(t1 == t2, "nested payloads")
  assertTrue(t1 != Tree.Node(left = Tree.Leaf(label = "a"), right = Tree.Leaf(label = "c")), "a differing leaf")
  assertTrue(Shape.Nothing == Shape.Nothing, "nullary cases")
  assertFalse(Shape.Dot(at = Point(x = 1, y = 2)) == Shape.Nothing, "different cases")
  val some1: Option[Int] = Some(value = 3)
  val some2: Option[Int] = Some(value = 3)
  assertTrue(some1 == some2, "Option[Int]")
}
