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
//!   lyric test --target dotnet lyric-compiler/jvm/pattern_lowering_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/pattern_lowering_self_test.l
//!
//! It also exercises the supporting JVM-backend infrastructure that #2455
//! required to be testable end-to-end: real tuple construction (an
//! `ArrayList` of boxed elements), record/union construction
//! (`new`/`invokespecial`), record field access, and call-site argument
//! coercion of erased (`Object`) tuple elements to a declared parameter
//! type.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
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
