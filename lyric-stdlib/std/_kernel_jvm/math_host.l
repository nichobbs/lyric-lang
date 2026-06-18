//! std/_kernel_jvm/math_host.l - JVM host boundary for java.lang.Math /
//! java.lang.Double.
//!
//! Mirrors _kernel/math_host.l.  Most operations route directly to
//! java.lang.Math static methods.  Four require lyric.stdlib.jvm.MathHost
//! shims because the JVM API differs:
//!
//!   tau      — absent from java.lang.Math; shim returns 2.0 * Math.PI.
//!   log2     — absent from java.lang.Math; shim returns log(x)/log(2).
//!   truncate — absent from java.lang.Math; shim returns
//!              x >= 0 ? floor(x) : ceil(x).
//!   sign     — Math.signum returns double (-1.0/0.0/1.0); Lyric
//!              declares Int; shim casts to int.
//!
//! isInfinity maps to Java's isInfinite (spelling differs from .NET).
//!
//! Internal: only Std.Math should import this.
@axiom("java.lang.Math and java.lang.Double operations conform to their documented JVM / IEEE 754 contracts")
package Std.MathHost

// =====================================================================
// Constants.  PI and E are static fields on java.lang.Math.
// Tau is absent — routed through MathHost shim.
// =====================================================================
@externTarget("java.lang.Math.PI")
pub func hostPi(): Double = ()

@externTarget("java.lang.Math.E")
pub func hostE(): Double = ()

// java.lang.Math has no Tau field; shim returns 2.0 * Math.PI.
@externTarget("lyric.stdlib.jvm.MathHost.tau")
pub func hostTau(): Double = ()

// =====================================================================
// Absolute value (Double).
// =====================================================================
@externTarget("java.lang.Math.abs")
pub func hostAbsDouble(n: in Double): Double = ()

// =====================================================================
// Min / Max — pairwise (Double).  IEEE 754 NaN-propagating.
// =====================================================================
@externTarget("java.lang.Math.min")
pub func hostMinPairDouble(a: in Double, b: in Double): Double = ()

@externTarget("java.lang.Math.max")
pub func hostMaxPairDouble(a: in Double, b: in Double): Double = ()

// =====================================================================
// Powers / roots / logs.
// =====================================================================
@externTarget("java.lang.Math.pow")
pub func hostPow(base_: in Double, exponent: in Double): Double = ()

@externTarget("java.lang.Math.sqrt")
pub func hostSqrt(x: in Double): Double = ()

@externTarget("java.lang.Math.cbrt")
pub func hostCbrt(x: in Double): Double = ()

// Natural log.
@externTarget("java.lang.Math.log")
pub func hostLn(x: in Double): Double = ()

@externTarget("java.lang.Math.log10")
pub func hostLog10(x: in Double): Double = ()

// java.lang.Math has no log2; shim computes log(x) / log(2).
@externTarget("lyric.stdlib.jvm.MathHost.log2")
pub func hostLog2(x: in Double): Double = ()

@externTarget("java.lang.Math.exp")
pub func hostExp(x: in Double): Double = ()

// =====================================================================
// Trigonometry.  All angles in radians.
// =====================================================================
@externTarget("java.lang.Math.sin")
pub func hostSin(x: in Double): Double = ()

@externTarget("java.lang.Math.cos")
pub func hostCos(x: in Double): Double = ()

@externTarget("java.lang.Math.tan")
pub func hostTan(x: in Double): Double = ()

@externTarget("java.lang.Math.asin")
pub func hostAsin(x: in Double): Double = ()

@externTarget("java.lang.Math.acos")
pub func hostAcos(x: in Double): Double = ()

@externTarget("java.lang.Math.atan")
pub func hostAtan(x: in Double): Double = ()

@externTarget("java.lang.Math.atan2")
pub func hostAtan2(y: in Double, x: in Double): Double = ()

// =====================================================================
// Rounding.  Math.rint uses IEEE 754 round-to-nearest-even (banker's
// rounding), matching .NET Math.Round's default mode.
// Math.ceil maps to Ceiling; Math.floor maps to Floor.
// Truncate (round toward zero) is absent; shim handles it.
// =====================================================================
@externTarget("java.lang.Math.floor")
pub func hostFloor(x: in Double): Double = ()

// Java spells this "ceil", not "ceiling".
@externTarget("java.lang.Math.ceil")
pub func hostCeiling(x: in Double): Double = ()

// Banker's rounding (round-to-nearest-even), same as .NET Math.Round.
@externTarget("java.lang.Math.rint")
pub func hostRound(x: in Double): Double = ()

// java.lang.Math has no truncate; shim: x >= 0 ? floor(x) : ceil(x).
@externTarget("lyric.stdlib.jvm.MathHost.truncate")
pub func hostTruncate(x: in Double): Double = ()

// =====================================================================
// Sign / classification (Double).
// =====================================================================
// java.lang.Math.signum returns double; shim casts to int.
@externTarget("lyric.stdlib.jvm.MathHost.sign")
pub func hostSignDouble(n: in Double): Int = ()

@externTarget("java.lang.Double.isNaN")
pub func hostIsNaN(x: in Double): Bool = ()

// Java spells this isInfinite, not isInfinity.
@externTarget("java.lang.Double.isInfinite")
pub func hostIsInfinity(x: in Double): Bool = ()

@externTarget("java.lang.Double.isFinite")
pub func hostIsFinite(x: in Double): Bool = ()
