//! equality_self_test.l — #1480: `==` / `!=` dispatch to the `@derive(Equals)`
//! structural-equality method for records and distinct types.
//!
//! Before this wiring, `==` on a record lowered to a static `Object.Equals`
//! call — reference equality for ref types — so two field-equal records
//! compared unequal.  `BEq`/`BNeq` now call the synthesised
//! `<Type>.equals(self, other)` (emitted by `Lyric.Derives`; it reaches codegen
//! only after #1796 stopped mono dropping it), so `==` is structural.
//!
//! Run in CI via native `lyric test --target dotnet` (compiled in-process
//! through the self-hosted `Msil.Bridge`).  Imports only `Std.*`.  MSIL target
//! only (epic #1470 defers JVM).
@test_module
package Lyric.EqualitySelfTest

import Std.Core
import Std.Testing

@derive(Equals)
record Point {
  x: Int
  y: Int
}

@derive(Equals)
record Named {
  id: Int
  name: String
}

@derive(Equals)
record Line {
  a: Point
  b: Point
}

@derive(Equals)
record Empty {
  // Distinct types also receive a synthesised `equals` from `Lyric.Derives`
  // (it compares the `value` field on both operands directly).
}

@derive(Equals)
type Score = Int

@derive(Equals)
type Tag = String

test "field-equal records compare == true" {
  val p1 = Point(x = 1, y = 2)
  val p2 = Point(x = 1, y = 2)
  assertTrue(p1 == p2, "(1,2) == (1,2)")
}

test "field-different records compare == false and != true" {
  val p1 = Point(x = 1, y = 2)
  val p3 = Point(x = 1, y = 9)
  val p4 = Point(x = 7, y = 2)
  assertTrue(not (p1 == p3), "(1,2) != (1,9) on y")
  assertTrue(p1 != p3, "!= true on y")
  assertTrue(p1 != p4, "!= true on x")
}

test "records with a String field compare structurally" {
  val a = Named(id = 1, name = "alice")
  val b = Named(id = 1, name = "alice")
  val c = Named(id = 1, name = "bob")
  assertTrue(a == b, "same id+name")
  assertTrue(a != c, "different name")
}

test "nested records compare structurally (recursive ==)" {
  val l1 = Line(a = Point(x = 1, y = 2), b = Point(x = 3, y = 4))
  val l2 = Line(a = Point(x = 1, y = 2), b = Point(x = 3, y = 4))
  val l3 = Line(a = Point(x = 1, y = 2), b = Point(x = 3, y = 5))
  assertTrue(l1 == l2, "equal nested lines")
  assertTrue(l1 != l3, "different nested b.y")
}

test "empty record is always == itself" {
  val e1 = Empty()
  val e2 = Empty()
  assertTrue(e1 == e2, "empty == empty")
}

// `==` participates in ordinary boolean expressions.
func samePoint(p: in Point, q: in Point): Bool {
  p == q
}

test "structural == composes in a boolean-returning function" {
  assertTrue(samePoint(Point(x = 5, y = 6), Point(x = 5, y = 6)), "func == true")
  assertTrue(not samePoint(Point(x = 5, y = 6), Point(x = 5, y = 7)), "func == false")
}

test "distinct types over Int compare structurally via @derive(Equals)" {
  val a = Score(42)
  val b = Score(42)
  val c = Score(99)
  assertTrue(a == b, "Score(42) == Score(42)")
  assertTrue(a != c, "Score(42) != Score(99)")
}

test "distinct types over String compare structurally" {
  val a = Tag("alpha")
  val b = Tag("alpha")
  val c = Tag("beta")
  assertTrue(a == b, "Tag(\"alpha\") == Tag(\"alpha\")")
  assertTrue(a != c, "Tag(\"alpha\") != Tag(\"beta\")")
}
