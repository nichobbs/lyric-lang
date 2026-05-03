// std/math.l - Numeric utilities and BCL System.Math wrappers.
//
// Layered in two tiers per `docs/14-native-stdlib-plan.md` §3:
//
//   1. Native Lyric implementations for integer ops where the body
//      is a one-liner with semantics identical to BCL. These are
//      `@pure` and carry contracts; the prover (Phase 4) reasons
//      about them directly.
//   2. `@externTarget` to `System.Math` / `System.Double` for floats
//      and transcendentals (kernel surface; behaviours like IEEE 754
//      NaN propagation, banker's rounding, hardware-tuned sin/cos
//      we deliberately do not reimplement — see plan §3 "what stays
//      kernel forever").

@runtime_checked
package Std.Math

// =====================================================================
// Constants. (Kernel — IEEE 754 doubles routed through BCL.)
// =====================================================================

@externTarget("System.Math.PI")
pub func pi(): Double = ()

@externTarget("System.Math.E")
pub func e(): Double = ()

@externTarget("System.Math.Tau")
pub func tau(): Double = ()

// =====================================================================
// Absolute value.
//
// Integer forms native; Double form stays kernel because IEEE 754's
// `Abs(-0.0) = 0.0` and `Abs(NaN) = NaN` are easy to get subtly wrong
// in a hand-rolled body.
// =====================================================================

// Native: integer abs. Panics on `Int.MinValue` (overflow on negation),
// matching the runtime-bug discipline in §8 of the language reference.
@pure
pub func absInt(n: in Int): Int
  ensures: result >= 0
{
  if n < 0 { -n } else { n }
}

// Native: long abs. Same overflow caveat at `Long.MinValue`.
@pure
pub func absLong(n: in Long): Long
  ensures: result >= 0i64
{
  if n < 0i64 { -n } else { n }
}

@externTarget("System.Math.Abs")
pub func absDouble(n: in Double): Double = ()

// =====================================================================
// Min / Max — pairwise.
//
// Integer forms native; Double form stays kernel for IEEE 754 NaN
// propagation (`Math.Min(NaN, x) = NaN`, but `if NaN < x then NaN
// else x = x`).
// =====================================================================

@pure
pub func minPairInt(a: in Int, b: in Int): Int
  ensures: result <= a and result <= b
  ensures: result == a or result == b
{
  if a < b { a } else { b }
}

@pure
pub func maxPairInt(a: in Int, b: in Int): Int
  ensures: result >= a and result >= b
  ensures: result == a or result == b
{
  if a > b { a } else { b }
}

@pure
pub func minPairLong(a: in Long, b: in Long): Long
  ensures: result <= a and result <= b
  ensures: result == a or result == b
{
  if a < b { a } else { b }
}

@pure
pub func maxPairLong(a: in Long, b: in Long): Long
  ensures: result >= a and result >= b
  ensures: result == a or result == b
{
  if a > b { a } else { b }
}

@externTarget("System.Math.Min")
pub func minPairDouble(a: in Double, b: in Double): Double = ()

@externTarget("System.Math.Max")
pub func maxPairDouble(a: in Double, b: in Double): Double = ()

// =====================================================================
// GCD / LCM. Native additions; not previously exposed.
// =====================================================================

// Greatest common divisor via Euclid. `gcd(0, 0) = 0` by convention.
@pure
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
// Powers / roots / logs. (Kernel — hardware-tuned IEEE 754 transcendentals.)
// =====================================================================

@externTarget("System.Math.Pow")
pub func pow(base_: in Double, exponent: in Double): Double = ()

@externTarget("System.Math.Sqrt")
pub func sqrt(x: in Double): Double = ()

@externTarget("System.Math.Cbrt")
pub func cbrt(x: in Double): Double = ()

@externTarget("System.Math.Log")
pub func ln(x: in Double): Double = ()

@externTarget("System.Math.Log10")
pub func log10(x: in Double): Double = ()

@externTarget("System.Math.Log2")
pub func log2(x: in Double): Double = ()

@externTarget("System.Math.Exp")
pub func exp(x: in Double): Double = ()

// =====================================================================
// Trigonometry. All angles in radians. (Kernel.)
// =====================================================================

@externTarget("System.Math.Sin")
pub func sin(x: in Double): Double = ()

@externTarget("System.Math.Cos")
pub func cos(x: in Double): Double = ()

@externTarget("System.Math.Tan")
pub func tan(x: in Double): Double = ()

@externTarget("System.Math.Asin")
pub func asin(x: in Double): Double = ()

@externTarget("System.Math.Acos")
pub func acos(x: in Double): Double = ()

@externTarget("System.Math.Atan")
pub func atan(x: in Double): Double = ()

@externTarget("System.Math.Atan2")
pub func atan2(y: in Double, x: in Double): Double = ()

// =====================================================================
// Rounding. (Kernel — banker's-rounding semantics.)
// =====================================================================

@externTarget("System.Math.Floor")
pub func floor(x: in Double): Double = ()

@externTarget("System.Math.Ceiling")
pub func ceiling(x: in Double): Double = ()

@externTarget("System.Math.Round")
pub func round(x: in Double): Double = ()

@externTarget("System.Math.Truncate")
pub func truncate(x: in Double): Double = ()

// =====================================================================
// Sign / classification.
//
// Integer signs native; Double sign + classification stay kernel
// (BCL's `Math.Sign(double)` throws on NaN, and IEEE 754 inspection
// is bit-pattern work better left to the BCL).
// =====================================================================

@pure
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

@externTarget("System.Math.Sign")
pub func signDouble(n: in Double): Int = ()

@externTarget("System.Double.IsNaN")
pub func isNaN(x: in Double): Bool = ()

@externTarget("System.Double.IsInfinity")
pub func isInfinity(x: in Double): Bool = ()

@externTarget("System.Double.IsFinite")
pub func isFinite(x: in Double): Bool = ()
