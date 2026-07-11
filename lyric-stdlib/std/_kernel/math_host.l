//! std/_kernel/math_host.l - host boundary for System.Math / System.Double.
//!
//! Holds every extern declaration that `Std.Math` formerly declared
//! inline.  Kernel function names carry a `host` prefix so they don't
//! collide with the user-facing names in `Std.Math` when the test
//! inliner merges every stdlib file into one user package.
//!
//! Internal: only `Std.Math` should import this; per
//! `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("System.Math and System.Double operations conform to their documented .NET / IEEE 754 contracts")
package Std.MathHost

extern type NetMath = "System.Math"

extern type NetDouble = "System.Double"

extern type NetConvert = "System.Convert"

// =====================================================================
// Constants. (IEEE 754 doubles routed through BCL; literal R8 consts
// are inlined from metadata at compile time.)
// =====================================================================
pub func hostPi(): Double {
  NetMath.PI
}

pub func hostE(): Double {
  NetMath.E
}

pub func hostTau(): Double {
  NetMath.Tau
}

// =====================================================================
// Absolute value (Double).
// =====================================================================
pub func hostAbsDouble(n: in Double): Double {
  NetMath.Abs(n)
}

// =====================================================================
// Min / Max — pairwise (Double).  IEEE 754 NaN-propagating.
// =====================================================================
pub func hostMinPairDouble(a: in Double, b: in Double): Double {
  NetMath.Min(a, b)
}

pub func hostMaxPairDouble(a: in Double, b: in Double): Double {
  NetMath.Max(a, b)
}

// =====================================================================
// Powers / roots / logs.
// =====================================================================
pub func hostPow(base_: in Double, exponent: in Double): Double {
  NetMath.Pow(base_, exponent)
}

pub func hostSqrt(x: in Double): Double {
  NetMath.Sqrt(x)
}

pub func hostCbrt(x: in Double): Double {
  NetMath.Cbrt(x)
}

pub func hostLn(x: in Double): Double {
  NetMath.Log(x)
}

pub func hostLog10(x: in Double): Double {
  NetMath.Log10(x)
}

pub func hostLog2(x: in Double): Double {
  NetMath.Log2(x)
}

pub func hostExp(x: in Double): Double {
  NetMath.Exp(x)
}

// =====================================================================
// Trigonometry. All angles in radians.
// =====================================================================
pub func hostSin(x: in Double): Double {
  NetMath.Sin(x)
}

pub func hostCos(x: in Double): Double {
  NetMath.Cos(x)
}

pub func hostTan(x: in Double): Double {
  NetMath.Tan(x)
}

pub func hostAsin(x: in Double): Double {
  NetMath.Asin(x)
}

pub func hostAcos(x: in Double): Double {
  NetMath.Acos(x)
}

pub func hostAtan(x: in Double): Double {
  NetMath.Atan(x)
}

pub func hostAtan2(y: in Double, x: in Double): Double {
  NetMath.Atan2(y, x)
}

// =====================================================================
// Rounding.  Banker's-rounding via Math.Round; Math.Floor / Math.Ceiling
// behave conventionally.
// =====================================================================
pub func hostFloor(x: in Double): Double {
  NetMath.Floor(x)
}

pub func hostCeiling(x: in Double): Double {
  NetMath.Ceiling(x)
}

pub func hostRound(x: in Double): Double {
  NetMath.Round(x)
}

pub func hostTruncate(x: in Double): Double {
  NetMath.Truncate(x)
}

// =====================================================================
// Sign / classification (Double).
// =====================================================================
pub func hostSignDouble(n: in Double): Int {
  NetMath.Sign(n)
}

pub func hostIsNaN(x: in Double): Bool {
  NetDouble.IsNaN(x)
}

pub func hostIsInfinity(x: in Double): Bool {
  NetDouble.IsInfinity(x)
}

pub func hostIsFinite(x: in Double): Bool {
  NetDouble.IsFinite(x)
}

// =====================================================================
// Integer type widening / narrowing (System.Convert).
//
// Pure-Lyric code cannot implicitly promote Int (32-bit) to Long
// (64-bit) or truncate Long to Int; mixed-width arithmetic silently
// evaluates in the narrower type.  These two externs provide the
// explicit conversions used by numeric algorithms (e.g. zigzag
// encoding in lyric-proto) that need to cross the 32/64-bit boundary
// without overflow.  Overload scoring binds the exact-width overloads
// (ToInt64(int), ToInt32(long)) among Convert's overload set.
// =====================================================================
pub func hostIntToLong(n: in Int): Long {
  NetConvert.ToInt64(n)
}

pub func hostLongToInt(n: in Long): Int {
  NetConvert.ToInt32(n)
}
