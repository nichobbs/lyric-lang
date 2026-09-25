//! nan_compare_self_test.l — CI gate for NaN-correct Float/Double ordered
//! comparisons on both backends.  IEEE 754 §5.11: every ordered comparison
//! involving NaN is false (`!=` is the one true comparison).
//!
//! JVM (#2772, docs/44 §4): `lowerCmp` / `lowerCmpFail`
//! (jvm/codegen/02_exprs.l) once emitted `fcmpl`/`dcmpl` for all six
//! operators, and pairing the "l" variant (NaN → -1) with `iflt`/`ifle` made
//! NaN less than everything.  The fix selects `fcmpg`/`dcmpg` for `<` and `<=`.
//!
//! MSIL (#7240): `a <= b` lowered as `!(a > b)` via `cgt` and `a >= b` as
//! `!(a < b)` via `clt`, both true for NaN; range patterns (`case 0.0 ..= 1.0`)
//! and `Double range` subtypes admitted NaN the same way.  On doubles the
//! fix uses `cgt.un`/`clt.un` ("or unordered") so the negation is false.
//!
//! Run via the native test runner on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/nan_compare_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/nan_compare_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.  Both
//! lowering paths are exercised: value position (`val r = nan < x`) and
//! condition position (`if nan < x { … }`).
@test_module
package Lyric.NanCompareSelfTest

import Std.Core
import Std.Testing

// Produce a NaN at runtime through a function boundary so the value cannot be
// folded to a non-NaN constant before it reaches the comparison.  `z / z` with
// z == 0 is the canonical 0.0/0.0 → NaN form (IEEE 754 / JVM `fdiv`/`ddiv`).
func nanF(z: in Float): Float {
  z / z
}

func nanD(z: in Double): Double {
  z / z
}

// Condition-position wrappers so the comparison lowers through `lowerCmpFail`
// (the `if`/while branch-on-failure path) rather than the value-materialising
// `lowerCmp` path.  Each returns the boolean result of the ordered compare.
func ltCondF(a: in Float, b: in Float): Bool {
  if a < b {
    true
  } else {
    false
  }
}

func lteCondF(a: in Float, b: in Float): Bool {
  if a <= b {
    true
  } else {
    false
  }
}

func gtCondF(a: in Float, b: in Float): Bool {
  if a > b {
    true
  } else {
    false
  }
}

func gteCondF(a: in Float, b: in Float): Bool {
  if a >= b {
    true
  } else {
    false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Float — value position (lowerCmp).
// ─────────────────────────────────────────────────────────────────────────────
test "Float NaN ordered comparisons are all false (value position)" {
  val nan: Float = nanF(0.0f32)
  val x: Float = 1.0f32
  assertFalse(nan < x, "NaN < x is false")
  assertFalse(nan <= x, "NaN <= x is false")
  assertFalse(nan > x, "NaN > x is false")
  assertFalse(nan >= x, "NaN >= x is false")
  assertFalse(x < nan, "x < NaN is false")
  assertFalse(x <= nan, "x <= NaN is false")
  assertFalse(x > nan, "x > NaN is false")
  assertFalse(x >= nan, "x >= NaN is false")
}

test "Float NaN equality: == is false, != is true" {
  val nan: Float = nanF(0.0f32)
  val x: Float = 1.0f32
  assertFalse(nan == nan, "NaN == NaN is false")
  assertTrue(nan != nan, "NaN != NaN is true")
  assertFalse(nan == x, "NaN == x is false")
  assertTrue(nan != x, "NaN != x is true")
}

// ─────────────────────────────────────────────────────────────────────────────
// Float — condition position (lowerCmpFail).
// ─────────────────────────────────────────────────────────────────────────────
test "Float NaN ordered comparisons are all false (condition position)" {
  val nan: Float = nanF(0.0f32)
  val x: Float = 1.0f32
  assertFalse(ltCondF(nan, x), "if NaN < x is false")
  assertFalse(lteCondF(nan, x), "if NaN <= x is false")
  assertFalse(gtCondF(nan, x), "if NaN > x is false")
  assertFalse(gteCondF(nan, x), "if NaN >= x is false")
}

// ─────────────────────────────────────────────────────────────────────────────
// Double — value and condition positions.
// ─────────────────────────────────────────────────────────────────────────────
test "Double NaN ordered comparisons are all false" {
  val nan: Double = nanD(0.0)
  val x: Double = 1.0
  assertFalse(nan < x, "NaN < x is false (double)")
  assertFalse(nan <= x, "NaN <= x is false (double)")
  assertFalse(nan > x, "NaN > x is false (double)")
  assertFalse(nan >= x, "NaN >= x is false (double)")
  assertFalse(nan == nan, "NaN == NaN is false (double)")
  assertTrue(nan != nan, "NaN != NaN is true (double)")
}

test "Double NaN ordered comparisons are all false (condition position)" {
  val nan: Double = nanD(0.0)
  val x: Double = 1.0
  // Inline if-conditions so the compare lowers through lowerCmpFail.
  val a = if nan < x { true } else { false }
  val b = if nan <= x { true } else { false }
  val c = if nan > x { true } else { false }
  val d = if nan >= x { true } else { false }
  assertFalse(a, "if NaN < x is false (double)")
  assertFalse(b, "if NaN <= x is false (double)")
  assertFalse(c, "if NaN > x is false (double)")
  assertFalse(d, "if NaN >= x is false (double)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-NaN regression: the cmpg/cmpl split must not break ordinary ordering.
// ─────────────────────────────────────────────────────────────────────────────
test "ordinary Float/Double ordering still correct after the cmpg/cmpl split" {
  val one: Float = 1.0f32
  val two: Float = 2.0f32
  assertTrue(one < two, "1.0f < 2.0f")
  assertTrue(one <= two, "1.0f <= 2.0f")
  assertTrue(one <= one, "1.0f <= 1.0f")
  assertFalse(two < one, "2.0f < 1.0f is false")
  assertTrue(two > one, "2.0f > 1.0f")
  assertTrue(two >= two, "2.0f >= 2.0f")
  assertFalse(one > two, "1.0f > 2.0f is false")

  val oneD: Double = 1.0
  val twoD: Double = 2.0
  assertTrue(oneD < twoD, "1.0 < 2.0")
  assertTrue(oneD <= oneD, "1.0 <= 1.0")
  assertTrue(twoD > oneD, "2.0 > 1.0")
  assertTrue(twoD >= twoD, "2.0 >= 2.0")
  assertFalse(twoD < oneD, "2.0 < 1.0 is false")
}

// ─────────────────────────────────────────────────────────────────────────────
// Range patterns and range subtypes admit no NaN (#7240).
// ─────────────────────────────────────────────────────────────────────────────
func unitBucket(x: in Double): String {
  match x {
    case 0.0 ..= 1.0 -> "unit"
    case _ -> "other"
  }
}

func halfOpenBucket(x: in Double): String {
  match x {
    case 0.0 ..< 1.0 -> "unit"
    case _ -> "other"
  }
}

type Fraction = Double range 0.0 ..= 1.0

test "a NaN scrutinee matches no range pattern" {
  assertEqual(unitBucket(0.5), "unit", "0.5 is in 0.0 ..= 1.0")
  assertEqual(unitBucket(1.0), "unit", "the closed bound is included")
  assertEqual(unitBucket(1.5), "other", "1.5 is outside")
  assertEqual(unitBucket(nanD(0.0)), "other", "NaN is in no closed range")
  assertEqual(halfOpenBucket(nanD(0.0)), "other", "NaN is in no half-open range")
}

test "a Double range subtype rejects NaN" {
  match Fraction.tryFrom(0.25) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "0.25 is a Fraction")
  }
  match Fraction.tryFrom(nanD(0.0)) {
    case Ok(_) -> assertTrue(false, "NaN must not be a Fraction")
    case Err(_) -> ()
  }
}
