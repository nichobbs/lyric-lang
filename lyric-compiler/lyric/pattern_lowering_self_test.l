//! pattern_lowering_self_test.l — executable regression test for the five
//! match-arm pattern forms that the self-hosted MSIL and JVM backends
//! previously left unhandled in `lowerPatternTest` / `lowerPatternBind`
//! (issue #2455): `PParen`, `PRange`, `PRecord`, `PTuple`, and `PTypeTest`.
//!
//! Each form was a `T0016` non-exhaustive-match hole under the self-hosted
//! type checker and would have miscompiled (silent no-op for the
//! destructuring forms) on a target that reached it.  This module exercises
//! every form with runtime-value assertions on BOTH targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/pattern_lowering_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/pattern_lowering_self_test.l
//!
//! It also exercises the supporting JVM-backend infrastructure that #2455
//! required to be testable end-to-end: real tuple construction (an
//! `ArrayList` of boxed elements), record/union construction
//! (`new`/`invokespecial`), record field access, and call-site argument
//! coercion of erased (`Object`) tuple elements to a declared parameter
//! type.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! Also covers the literal-pattern kinds that previously fell to the
//! backends' pop-and-match-anything catch-all: triple-quoted and raw string
//! patterns (#1792) plus a Float regression case (#1481).
@test_module
package Lyric.PatternLoweringSelfTest

import Std.Core
import Std.Testing

record Point {
  x: Int
  y: Int
}

union Shape {
  case Circle(radius: Int)
  case Square(side: Int)
}

// Mixed-width match bindings: the SAME name `v` bound across sibling arms at DIFFERENT verifier-slot types (Double/Long/Int) used to share one slot, making the match-join frame unmergeable (VerifyError: Inconsistent stackmap frames).
union Num {
  case AsDouble(v: Double)
  case AsLong(v: Long)
  case AsInt(v: Int)
}

func numToDouble(n: in Num): Double {
  match n {
    case AsDouble(v) -> v
    case AsLong(v) -> v.toDouble()
    case AsInt(v) -> v.toDouble()
  }
}

// Same name `v`, result routed through a Long slot (the other two-slot width).
func numToLong(n: in Num): Long {
  match n {
    case AsDouble(v) -> v.toLong()
    case AsLong(v) -> v
    case AsInt(v) -> v.toLong()
  }
}

// Boundary: int-like binding types (Int / Byte / Char) all frame as VInteger,
// so the same name `v` MUST keep sharing one slot (the fix must not over-split).
union IntLike {
  case FromInt(v: Int)
  case FromByte(v: Byte)
  case FromChar(v: Char)
}

func intLikeToInt(n: in IntLike): Int {
  match n {
    case FromInt(v) -> v
    case FromByte(v) -> v.toInt()
    case FromChar(v) -> v.toInt()
  }
}

// Boundary: distinct REFERENCE classes bound to the same name `w` across arms
// frame as different VObject types (width 1 each), so they must get DISTINCT
// slots — the other half of the verifier-type gate.
record Boxed {
  n: Int
}

union Wrapped {
  case AsStr(w: String)
  case AsBoxed(w: Boxed)
}

func wrappedLen(x: in Wrapped): Int {
  match x {
    case AsStr(w) -> w.length
    case AsBoxed(w) -> w.n
  }
}

// Boundary: Float frames as its own VFloat verifier slot type, distinct from VInteger, so the same name `v` bound in a Float arm and an Int arm must also get DISTINCT slots.
union FloatOrInt {
  case AsFloatV(v: Float)
  case AsIntV(v: Int)
}

func floatOrIntToInt(n: in FloatOrInt): Int {
  match n {
    case AsFloatV(v) -> if v == 2.5f32 { 1 } else { 0 }
    case AsIntV(v) -> v
  }
}

// ── PParen — a single parenthesised pattern binds its inner at the scrutinee
// type, so the bound value stays a usable `Int`.
func parenId(n: Int): Int {
  match n {
    case (z) -> z
  }
}

// ── PRange — inclusive (`..=`) and exclusive (`..`) numeric ranges.
func grade(score: Int): Int {
  match score {
    case 0 ..= 59 -> 1
    case 60 ..= 79 -> 2
    case 80 ..= 100 -> 3
    case _ -> 0
  }
}

func bucket(n: Int): Int {
  match n {
    case 0 .. 10 -> 1
    case 10 .. 20 -> 2
    case _ -> 9
  }
}

// ── PRange over a Long scrutinee that is *erased* to `object` (a tuple element).
// The range bound type (`i64`) must drive the unbox/compare width — unboxing to
// `int` would truncate the 64-bit value and mis-discriminate.
func longRangeInTuple(p: (Long, Int)): Int {
  match p {
    case (1i64 .. 6i64, _) -> 1
    case (_, _) -> 2
  }
}

// ── PTuple — literal sub-patterns drive arm selection (the test path must
// unbox each element and compare).
func classifyPair(p: (Int, Int)): Int {
  match p {
    case (0, 0) -> 100
    case (0, _) -> 200
    case (_, 0) -> 300
    case (_, _) -> 400
  }
}

// ── PRecord — named-field destructuring; bound fields carry their declared
// types, so arithmetic on them is well-typed.
func recordSum(pt: Point): Int {
  match pt {
    case Point { x = a, y = b } -> a + b
  }
}

// ── PRecord short field form `Point{x}` binds local `x` to field `x`.
func recordDiff(pt: Point): Int {
  match pt {
    case Point { x, y } -> x - y
  }
}

// ── PConstructor on a constructed union value (construction is the supporting
// infrastructure #2455 needed on the JVM target).
func shapeMetric(sh: Shape): Int {
  match sh {
    case Circle(r) -> r
    case Square(s) -> s * s
  }
}

// ── PLiteral string variants (#1792) — triple-quoted and raw string literal
// patterns must compare the payload like a plain string literal.  Both
// previously fell to the backend's literal catch-all, which popped the
// scrutinee with no comparison so the FIRST arm always won — each function
// below must select a non-first arm to prove the comparison is emitted.
func tripleStringArm(s: String): Int {
  match s {
    case """alpha""" -> 1
    case """beta""" -> 2
    case _ -> 0
  }
}

func rawStringArm(s: String): Int {
  match s {
    case r"one\n" -> 1
    case r"two\n" -> 2
    case _ -> 0
  }
}

// ── PLiteral Float regression — the LFloat arm shipped earlier (#1481); keep a
// non-first-arm selection so the same defect class cannot silently return.
func floatBand(x: Double): Int {
  match x {
    case 1.5 -> 1
    case 2.5 -> 2
    case _ -> 0
  }
}

// ── PTypeTest — `pattern is Type` narrows the scrutinee to `Type` and binds the
// inner pattern at that type, so the bound value's field is read at the narrowed
// type.  (A record type-test keeps the class resolution direct on both targets.)
func typeTestPointX(pt: Point): Int {
  match pt {
    case p is Point -> p.x
    case _ -> -1
  }
}

test "PParen binds inner at scrutinee type" {
  assertEqualInt(parenId(42), 42, "paren binds 42")
  assertEqualInt(parenId(-7), -7, "paren binds -7")
}

test "PRange inclusive bounds" {
  assertEqualInt(grade(0), 1, "0 -> band 1")
  assertEqualInt(grade(59), 1, "59 -> band 1 (inclusive hi)")
  assertEqualInt(grade(60), 2, "60 -> band 2 (inclusive lo)")
  assertEqualInt(grade(79), 2, "79 -> band 2")
  assertEqualInt(grade(80), 3, "80 -> band 3")
  assertEqualInt(grade(100), 3, "100 -> band 3 (inclusive hi)")
  assertEqualInt(grade(120), 0, "120 -> out of range")
}

test "PRange exclusive upper bound" {
  assertEqualInt(bucket(0), 1, "0 -> bucket 1")
  assertEqualInt(bucket(9), 1, "9 -> bucket 1")
  assertEqualInt(bucket(10), 2, "10 -> bucket 2 (excl boundary)")
  assertEqualInt(bucket(19), 2, "19 -> bucket 2")
  assertEqualInt(bucket(20), 9, "20 -> out (excl hi)")
}

test "PRange on an erased Long tuple element compares at 64-bit width" {
  assertEqualInt(longRangeInTuple((3i64, 0)), 1, "3L in 1..6")
  assertEqualInt(longRangeInTuple((9i64, 0)), 2, "9L out of 1..6")
  // 2^32 + 1: its low 32 bits are 1 (in range), but the full Long is not — a
  // truncating unbox-to-int would wrongly select arm 1.
  assertEqualInt(longRangeInTuple((4294967297i64, 0)), 2, "2^32+1 not in 1..6 (no truncation)")
}

test "PTuple literal sub-patterns select the arm" {
  assertEqualInt(classifyPair((0, 0)), 100, "(0,0)")
  assertEqualInt(classifyPair((0, 7)), 200, "(0,_)")
  assertEqualInt(classifyPair((7, 0)), 300, "(_,0)")
  assertEqualInt(classifyPair((3, 4)), 400, "(_,_)")
}

test "PTuple binds each element" {
  match (3, 4) {
    case (a, b) -> {
      assertEqualInt(a, 3, "tuple elem a")
      assertEqualInt(b, 4, "tuple elem b")
    }
  }
}

test "PRecord destructures named fields" {
  assertEqualInt(recordSum(Point(x = 2, y = 5)), 7, "x + y")
  assertEqualInt(recordDiff(Point(x = 9, y = 4)), 5, "x - y (short form)")
}

test "PConstructor on a constructed union" {
  assertEqualInt(shapeMetric(Circle(radius = 6)), 6, "circle metric")
  assertEqualInt(shapeMetric(Square(side = 4)), 16, "square metric")
}

test "PTypeTest narrows and binds" {
  assertEqualInt(typeTestPointX(Point(x = 11, y = 2)), 11, "is Point -> x")
}

test "PLiteral triple-quoted string pattern selects the matching arm" {
  assertEqualInt(tripleStringArm("alpha"), 1, "triple-string arm 1")
  assertEqualInt(tripleStringArm("beta"), 2, "triple-string arm 2 (non-first)")
  assertEqualInt(tripleStringArm("gamma"), 0, "triple-string wildcard")
}

test "PLiteral raw string pattern selects the matching arm" {
  // Raw strings keep the backslash literal: the scrutinee must spell it as
  // an escaped backslash in a plain string to be equal.
  assertEqualInt(rawStringArm("one\\n"), 1, "raw-string arm 1")
  assertEqualInt(rawStringArm("two\\n"), 2, "raw-string arm 2 (non-first)")
  assertEqualInt(rawStringArm("two\n"), 0, "real newline does not equal raw \\n")
}

test "PLiteral Float pattern selects the matching arm" {
  assertEqualInt(floatBand(1.5), 1, "float arm 1")
  assertEqualInt(floatBand(2.5), 2, "float arm 2 (non-first)")
  assertEqualInt(floatBand(3.5), 0, "float wildcard")
}

test "mixed-width match bindings: same name across Double/Long/Int arms" {
  assertTrue(numToDouble(AsDouble(v = 2.5)) == 2.5, "Double arm binds v: Double")
  assertTrue(numToDouble(AsLong(v = 100i64)) == 100.0, "Long arm binds v: Long, widened")
  assertTrue(numToDouble(AsInt(v = 7)) == 7.0, "Int arm binds v: Int, widened")
}

test "mixed-width match bindings: result routed through a Long slot" {
  assertEqualLong(numToLong(AsDouble(v = 4.0)), 4i64, "Double arm truncated to Long")
  assertEqualLong(numToLong(AsLong(v = 42i64)), 42i64, "Long arm binds v: Long")
  assertEqualLong(numToLong(AsInt(v = 9)), 9i64, "Int arm binds v: Int, widened to Long")
}

test "mixed-width bindings: int-like arms keep sharing one slot" {
  assertEqualInt(intLikeToInt(FromInt(v = 65)), 65, "Int arm binds v: Int")
  // Value < 128 so signed/unsigned agree — the unsigned-Byte→Int widening
  // above 127 is a separate JVM-backend concern (#4855), not the slot gate.
  assertEqualInt(intLikeToInt(FromByte(v = 100.toByte())), 100, "Byte arm binds v: Byte")
  assertEqualInt(intLikeToInt(FromChar(v = 'A')), 65, "Char arm binds v: Char")
}

test "mixed-width bindings: distinct ref classes get distinct slots" {
  assertEqualInt(wrappedLen(AsStr(w = "hello")), 5, "String arm binds w: String")
  assertEqualInt(wrappedLen(AsBoxed(w = Boxed(n = 42))), 42, "record arm binds w: Boxed")
}

test "mixed-width bindings: Float and Int arms get distinct verifier slots" {
  assertEqualInt(floatOrIntToInt(AsFloatV(v = 2.5f32)), 1, "Float arm binds v: Float")
  assertEqualInt(floatOrIntToInt(AsIntV(v = 7)), 7, "Int arm binds v: Int")
}
