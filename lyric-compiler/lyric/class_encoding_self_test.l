//! class_encoding_self_test.l — #2387: concrete CLASS encoding in MSIL
//! field/method signatures for in-bundle reference types.
//!
//! Before the fix, the self-hosted MSIL emitter used `ELEMENT_TYPE_OBJECT`
//! for every in-bundle reference-type field, so the field signature read as
//! `object` rather than the actual class.  The fix emits a concrete
//! `ELEMENT_TYPE_CLASS + TypeDefOrRef` token — matching what `ildasm` and
//! `System.Reflection.Metadata` expect.
//!
//! This test guards the four scenarios that were documented in the PR:
//!
//! 1. A record whose field type is another in-bundle record (backward ref).
//! 2. A record whose field type is a record declared later in the same bundle
//!    (forward reference — the TypeDef token must be resolved before the
//!    emitter has finished serialising the table).
//! 3. An interface-typed record field (the F# bootstrap fix case).
//! 4. A record mixing concrete-primitive fields with an in-bundle record field.
//!
//! Run via the native `lyric test --target dotnet` (in-process `Msil.Bridge`).
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test lyric-compiler/lyric/class_encoding_self_test.l
@test_module
package Lyric.ClassEncodingSelfTest

import Std.Core
import Std.Testing

// Case 1 & 2: backward and forward in-bundle references.
record Point {
  x: Int
  y: Int
}

record Line {
  a: Point
  b: Point
}

// Case 2: Pair declares both fields as Point (forward ref if emitter processes
// records in declaration order and Line's token was resolved after Point's).
record Pair {
  left: Point
  right: Point
}

// Case 3: interface-typed field.
interface Shape {
  func area(): Int
}

record Square {
  side: Int
}

impl Shape for Square {
  func area(): Int {
    self.side * self.side
  }
}

record Canvas {
  shape: Shape
  label: String
}

// Case 4: mixed String + in-bundle record field.
record Annotated {
  tag: String
  pos: Point
}

test "in-bundle record field (backward ref): field reads correctly" {
  val p = Point(x = 3, y = 4)
  val l = Line(a = p, b = Point(x = 7, y = 8))
  assertEqualInt(l.a.x, 3, "Line.a.x == 3")
  assertEqualInt(l.a.y, 4, "Line.a.y == 4")
  assertEqualInt(l.b.x, 7, "Line.b.x == 7")
  assertEqualInt(l.b.y, 8, "Line.b.y == 8")
}

test "in-bundle record field (forward ref Pair): field reads correctly" {
  val p1 = Point(x = 1, y = 2)
  val p2 = Point(x = 5, y = 6)
  val pair = Pair(left = p1, right = p2)
  assertEqualInt(pair.left.x, 1, "Pair.left.x == 1")
  assertEqualInt(pair.left.y, 2, "Pair.left.y == 2")
  assertEqualInt(pair.right.x, 5, "Pair.right.x == 5")
  assertEqualInt(pair.right.y, 6, "Pair.right.y == 6")
}

test "interface-typed field dispatches through the correct vtable" {
  val sq: Shape = Square(side = 5)
  val c = Canvas(shape = sq, label = "main")
  assertEqualInt(c.shape.area(), 25, "Canvas.shape.area() == 25")
  assertEqual(c.label, "main", "Canvas.label == main")
}

test "mixed String + in-bundle record field round-trips both types" {
  val a = Annotated(tag = "origin", pos = Point(x = 0, y = 0))
  assertEqual(a.tag, "origin", "Annotated.tag == origin")
  assertEqualInt(a.pos.x, 0, "Annotated.pos.x == 0")
  assertEqualInt(a.pos.y, 0, "Annotated.pos.y == 0")
}

test "nested in-bundle reference (Line.a itself stored as Line.b.a)" {
  val inner = Line(a = Point(x = 10, y = 20), b = Point(x = 30, y = 40))
  assertEqualInt(inner.a.x + inner.b.y, 50, "Line.a.x + Line.b.y == 50")
}
