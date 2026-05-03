// std/_kernel/math_host.l - host boundary for System.Math / System.Double.
//
// Holds every `@externTarget` declaration that `Std.Math` formerly
// declared inline.  Kernel function names carry a `host` prefix so
// they don't collide with the user-facing names in `Std.Math` when
// the test inliner merges every stdlib file into one user package.
//
// Internal: only `Std.Math` should import this; per
// `compiler/lyric/std/_kernel/README.md` the kernel is the audited
// extern boundary, not a general-purpose API.

@axiom("System.Math and System.Double operations conform to their documented .NET / IEEE 754 contracts")
package Std.MathHost

// =====================================================================
// Constants. (IEEE 754 doubles routed through BCL.)
// =====================================================================

@externTarget("System.Math.PI")
pub func hostPi(): Double = ()

@externTarget("System.Math.E")
pub func hostE(): Double = ()

@externTarget("System.Math.Tau")
pub func hostTau(): Double = ()

// =====================================================================
// Absolute value (Double).
// =====================================================================

@externTarget("System.Math.Abs")
pub func hostAbsDouble(n: in Double): Double = ()

// =====================================================================
// Min / Max — pairwise (Double).  IEEE 754 NaN-propagating.
// =====================================================================

@externTarget("System.Math.Min")
pub func hostMinPairDouble(a: in Double, b: in Double): Double = ()

@externTarget("System.Math.Max")
pub func hostMaxPairDouble(a: in Double, b: in Double): Double = ()

// =====================================================================
// Powers / roots / logs.
// =====================================================================

@externTarget("System.Math.Pow")
pub func hostPow(base_: in Double, exponent: in Double): Double = ()

@externTarget("System.Math.Sqrt")
pub func hostSqrt(x: in Double): Double = ()

@externTarget("System.Math.Cbrt")
pub func hostCbrt(x: in Double): Double = ()

@externTarget("System.Math.Log")
pub func hostLn(x: in Double): Double = ()

@externTarget("System.Math.Log10")
pub func hostLog10(x: in Double): Double = ()

@externTarget("System.Math.Log2")
pub func hostLog2(x: in Double): Double = ()

@externTarget("System.Math.Exp")
pub func hostExp(x: in Double): Double = ()

// =====================================================================
// Trigonometry. All angles in radians.
// =====================================================================

@externTarget("System.Math.Sin")
pub func hostSin(x: in Double): Double = ()

@externTarget("System.Math.Cos")
pub func hostCos(x: in Double): Double = ()

@externTarget("System.Math.Tan")
pub func hostTan(x: in Double): Double = ()

@externTarget("System.Math.Asin")
pub func hostAsin(x: in Double): Double = ()

@externTarget("System.Math.Acos")
pub func hostAcos(x: in Double): Double = ()

@externTarget("System.Math.Atan")
pub func hostAtan(x: in Double): Double = ()

@externTarget("System.Math.Atan2")
pub func hostAtan2(y: in Double, x: in Double): Double = ()

// =====================================================================
// Rounding.  Banker's-rounding via Math.Round; Math.Floor / Math.Ceiling
// behave conventionally.
// =====================================================================

@externTarget("System.Math.Floor")
pub func hostFloor(x: in Double): Double = ()

@externTarget("System.Math.Ceiling")
pub func hostCeiling(x: in Double): Double = ()

@externTarget("System.Math.Round")
pub func hostRound(x: in Double): Double = ()

@externTarget("System.Math.Truncate")
pub func hostTruncate(x: in Double): Double = ()

// =====================================================================
// Sign / classification (Double).
// =====================================================================

@externTarget("System.Math.Sign")
pub func hostSignDouble(n: in Double): Int = ()

@externTarget("System.Double.IsNaN")
pub func hostIsNaN(x: in Double): Bool = ()

@externTarget("System.Double.IsInfinity")
pub func hostIsInfinity(x: in Double): Bool = ()

@externTarget("System.Double.IsFinite")
pub func hostIsFinite(x: in Double): Bool = ()
