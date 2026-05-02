// std/math.l - Numeric utilities and BCL System.Math wrappers.
//
// Each routine forwards to a `System.Math` static method via
// `@externTarget`.  Lyric users see ordinary functions on
// primitive types; the BCL handles the heavy lifting.

@runtime_checked
package Std.Math

// =====================================================================
// Constants.
// =====================================================================

@externTarget("System.Math.PI")
pub func pi(): Double = ()

@externTarget("System.Math.E")
pub func e(): Double = ()

@externTarget("System.Math.Tau")
pub func tau(): Double = ()

// =====================================================================
// Absolute value.
// =====================================================================

@externTarget("System.Math.Abs")
pub func absInt(n: in Int): Int = ()

@externTarget("System.Math.Abs")
pub func absLong(n: in Long): Long = ()

@externTarget("System.Math.Abs")
pub func absDouble(n: in Double): Double = ()

// =====================================================================
// Min / Max — pairwise.
// =====================================================================

@externTarget("System.Math.Min")
pub func minPairInt(a: in Int, b: in Int): Int = ()

@externTarget("System.Math.Max")
pub func maxPairInt(a: in Int, b: in Int): Int = ()

@externTarget("System.Math.Min")
pub func minPairLong(a: in Long, b: in Long): Long = ()

@externTarget("System.Math.Max")
pub func maxPairLong(a: in Long, b: in Long): Long = ()

@externTarget("System.Math.Min")
pub func minPairDouble(a: in Double, b: in Double): Double = ()

@externTarget("System.Math.Max")
pub func maxPairDouble(a: in Double, b: in Double): Double = ()

// =====================================================================
// Powers / roots / logs.
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
// Trigonometry.  All angles in radians.
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
// Rounding.
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
// =====================================================================

@externTarget("System.Math.Sign")
pub func signInt(n: in Int): Int = ()

@externTarget("System.Math.Sign")
pub func signLong(n: in Long): Int = ()

@externTarget("System.Math.Sign")
pub func signDouble(n: in Double): Int = ()

@externTarget("System.Double.IsNaN")
pub func isNaN(x: in Double): Bool = ()

@externTarget("System.Double.IsInfinity")
pub func isInfinity(x: in Double): Bool = ()

@externTarget("System.Double.IsFinite")
pub func isFinite(x: in Double): Bool = ()
