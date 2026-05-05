// std/math.l - Numeric utilities and BCL System.Math wrappers.
//
// Layered in two tiers per `docs/14-native-stdlib-plan.md` §3:
//
//   1. Native Lyric implementations for integer ops where the body
//      is a one-liner with semantics identical to BCL. These are
//      `@pure` and carry contracts; the prover (Phase 4) reasons
//      about them directly.
//   2. Thin trampolines into `Std.MathHost` (in `_kernel/`) for the
//      Double-shaped surface (transcendentals, rounding,
//      classification). Centralises the `@externTarget` boundary so
//      the audited kernel surface stays in one place per Decision F.

@runtime_checked
package Std.Math

import Std.MathHost as Host

// =====================================================================
// Constants. (Trampoline — IEEE 754 doubles via the kernel boundary.)
// =====================================================================

@stable(since="1.0")
pub func pi():  Double { Host.hostPi() }
@stable(since="1.0")
pub func e():   Double { Host.hostE() }
@stable(since="1.0")
pub func tau(): Double { Host.hostTau() }

// =====================================================================
// Absolute value.
//
// Integer forms native; Double form trampolines to the kernel because
// IEEE 754's `Abs(-0.0) = 0.0` and `Abs(NaN) = NaN` are easy to get
// subtly wrong in a hand-rolled body.
// =====================================================================

// Native: integer abs. Panics on `Int.MinValue` (overflow on negation),
// matching the runtime-bug discipline in §8 of the language reference.
@pure
@stable(since="1.0")
pub func absInt(n: in Int): Int
  ensures: result >= 0
{
  if n < 0 { -n } else { n }
}

// Native: long abs. Same overflow caveat at `Long.MinValue`.
@pure
@stable(since="1.0")
pub func absLong(n: in Long): Long
  ensures: result >= 0i64
{
  if n < 0i64 { -n } else { n }
}

@stable(since="1.0")
pub func absDouble(n: in Double): Double { Host.hostAbsDouble(n) }

// =====================================================================
// Min / Max — pairwise.
//
// Integer forms native; Double form trampolines for IEEE 754 NaN
// propagation (`Math.Min(NaN, x) = NaN`, but `if NaN < x then NaN
// else x = x`).
// =====================================================================

@pure
@stable(since="1.0")
pub func minPairInt(a: in Int, b: in Int): Int
  ensures: result <= a and result <= b
  ensures: result == a or result == b
{
  if a < b { a } else { b }
}

@pure
@stable(since="1.0")
pub func maxPairInt(a: in Int, b: in Int): Int
  ensures: result >= a and result >= b
  ensures: result == a or result == b
{
  if a > b { a } else { b }
}

@pure
@stable(since="1.0")
pub func minPairLong(a: in Long, b: in Long): Long
  ensures: result <= a and result <= b
  ensures: result == a or result == b
{
  if a < b { a } else { b }
}

@pure
@stable(since="1.0")
pub func maxPairLong(a: in Long, b: in Long): Long
  ensures: result >= a and result >= b
  ensures: result == a or result == b
{
  if a > b { a } else { b }
}

@stable(since="1.0")
pub func minPairDouble(a: in Double, b: in Double): Double { Host.hostMinPairDouble(a, b) }
@stable(since="1.0")
pub func maxPairDouble(a: in Double, b: in Double): Double { Host.hostMaxPairDouble(a, b) }

// =====================================================================
// GCD / LCM. Native.
// =====================================================================

// Greatest common divisor via Euclid. `gcd(0, 0) = 0` by convention.
@pure
@stable(since="1.0")
pub func gcd(a: in Int, b: in Int): Int
  requires: a >= 0 and b >= 0
  ensures: result >= 0
{
  var x = a
  var y = b
  while y != 0 {
    val t = y
    y = x % y
    x = t
  }
  x
}

@pure
@stable(since="1.0")
pub func gcdLong(a: in Long, b: in Long): Long
  requires: a >= 0i64 and b >= 0i64
  ensures: result >= 0i64
{
  var x = a
  var y = b
  while y != 0i64 {
    val t = y
    y = x % y
    x = t
  }
  x
}

// Least common multiple. Uses `(a / gcd) * b` to defer the multiply
// until after the divide, reducing overflow surface vs. `a * b / gcd`.
// Returns 0 when either argument is 0 (the conventional definition;
// avoids div-by-zero through `gcd(0, 0) = 0`).
@pure
@stable(since="1.0")
pub func lcm(a: in Int, b: in Int): Int
  requires: a >= 0 and b >= 0
  ensures: result >= 0
{
  if a == 0 or b == 0 {
    0
  } else {
    (a / gcd(a, b)) * b
  }
}

@pure
@stable(since="1.0")
pub func lcmLong(a: in Long, b: in Long): Long
  requires: a >= 0i64 and b >= 0i64
  ensures: result >= 0i64
{
  if a == 0i64 or b == 0i64 {
    0i64
  } else {
    (a / gcdLong(a, b)) * b
  }
}

// =====================================================================
// Powers / roots / logs. (Trampoline — hardware-tuned IEEE 754 transcendentals.)
// =====================================================================

@stable(since="1.0")
pub func pow(base_: in Double, exponent: in Double): Double { Host.hostPow(base_, exponent) }
@stable(since="1.0")
pub func sqrt(x: in Double): Double  { Host.hostSqrt(x) }
@stable(since="1.0")
pub func cbrt(x: in Double): Double  { Host.hostCbrt(x) }
@stable(since="1.0")
pub func ln(x: in Double): Double    { Host.hostLn(x) }
@stable(since="1.0")
pub func log10(x: in Double): Double { Host.hostLog10(x) }
@stable(since="1.0")
pub func log2(x: in Double): Double  { Host.hostLog2(x) }
@stable(since="1.0")
pub func exp(x: in Double): Double   { Host.hostExp(x) }

// =====================================================================
// Trigonometry. All angles in radians. (Trampoline.)
// =====================================================================

@stable(since="1.0")
pub func sin(x: in Double): Double  { Host.hostSin(x) }
@stable(since="1.0")
pub func cos(x: in Double): Double  { Host.hostCos(x) }
@stable(since="1.0")
pub func tan(x: in Double): Double  { Host.hostTan(x) }
@stable(since="1.0")
pub func asin(x: in Double): Double { Host.hostAsin(x) }
@stable(since="1.0")
pub func acos(x: in Double): Double { Host.hostAcos(x) }
@stable(since="1.0")
pub func atan(x: in Double): Double { Host.hostAtan(x) }
@stable(since="1.0")
pub func atan2(y: in Double, x: in Double): Double { Host.hostAtan2(y, x) }

// =====================================================================
// Rounding. (Trampoline — banker's-rounding semantics via Math.Round.)
// =====================================================================

@stable(since="1.0")
pub func floor(x: in Double): Double    { Host.hostFloor(x) }
@stable(since="1.0")
pub func ceiling(x: in Double): Double  { Host.hostCeiling(x) }
@stable(since="1.0")
pub func round(x: in Double): Double    { Host.hostRound(x) }
@stable(since="1.0")
pub func truncate(x: in Double): Double { Host.hostTruncate(x) }

// =====================================================================
// Sign / classification.
//
// Integer signs native; Double sign + classification trampoline
// (BCL's `Math.Sign(double)` throws on NaN, and IEEE 754 inspection
// is bit-pattern work better left to the BCL).
// =====================================================================

@pure
@stable(since="1.0")
pub func signInt(n: in Int): Int
  ensures: result == -1 or result == 0 or result == 1
{
  if n > 0 {
    1
  } else if n < 0 {
    -1
  } else {
    0
  }
}

@pure
@stable(since="1.0")
pub func signLong(n: in Long): Int
  ensures: result == -1 or result == 0 or result == 1
{
  if n > 0i64 {
    1
  } else if n < 0i64 {
    -1
  } else {
    0
  }
}

@stable(since="1.0")
pub func signDouble(n: in Double): Int    { Host.hostSignDouble(n) }
@stable(since="1.0")
pub func isNaN(x: in Double): Bool        { Host.hostIsNaN(x) }
@stable(since="1.0")
pub func isInfinity(x: in Double): Bool   { Host.hostIsInfinity(x) }
@stable(since="1.0")
pub func isFinite(x: in Double): Bool     { Host.hostIsFinite(x) }
