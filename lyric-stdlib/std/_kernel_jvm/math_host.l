//! std/_kernel_jvm/math_host.l - JVM host boundary for java.lang.Math /
//! java.lang.Double.
//!
//! Mirrors _kernel/math_host.l.  Most operations route directly to
//! java.lang.Math static methods.  Four have no JVM equivalent and are
//! pure-Lyric bodies over the bound externs (the previous version routed
//! them through a phantom `lyric.stdlib.jvm.MathHost` class that never
//! existed at runtime — same elimination as the file/console kernel
//! rewrites, D-progress-555):
//!
//!   tau      — absent from java.lang.Math; 2.0 * hostPi().
//!   log2     — absent from java.lang.Math; hostLn(x) / hostLn(2.0).
//!   truncate — absent from java.lang.Math; x >= 0 ? floor(x) : ceil(x).
//!   sign     — Math.signum returns double (-1.0/0.0/1.0); Lyric declares
//!              Int; a pure comparison chain avoids the double round-trip.
//!              NaN yields 0 (the BCL's Math.Sign throws instead; Std.Math
//!              documents sign() for finite inputs only).
//!
//! isInfinity maps to Java's isInfinite (spelling differs from .NET).
//!
//! Internal: only Std.Math should import this.
@axiom("java.lang.Math and java.lang.Double operations conform to their documented JVM / IEEE 754 contracts")
package Std.MathHost

// =====================================================================
// Constants.  PI and E are static fields on java.lang.Math.
// Tau is absent — pure-Lyric body below.
// =====================================================================
@externTarget("java.lang.Math.PI")
pub func hostPi(): Double = ()

@externTarget("java.lang.Math.E")
pub func hostE(): Double = ()

// java.lang.Math has no Tau field.
pub func hostTau(): Double {
  2.0 * hostPi()
}

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

// java.lang.Math has no log2.
pub func hostLog2(x: in Double): Double {
  hostLn(x) / hostLn(2.0)
}

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
// Truncate (round toward zero) is absent; pure-Lyric body below.
// =====================================================================
@externTarget("java.lang.Math.floor")
pub func hostFloor(x: in Double): Double = ()

// Java spells this "ceil", not "ceiling".
@externTarget("java.lang.Math.ceil")
pub func hostCeiling(x: in Double): Double = ()

// Banker's rounding (round-to-nearest-even), same as .NET Math.Round.
@externTarget("java.lang.Math.rint")
pub func hostRound(x: in Double): Double = ()

// java.lang.Math has no truncate (round toward zero).
pub func hostTruncate(x: in Double): Double {
  if x >= 0.0 {
    hostFloor(x)
  } else {
    hostCeiling(x)
  }
}

// =====================================================================
// Sign / classification (Double).
// =====================================================================
// java.lang.Math.signum returns double; compare directly instead.
pub func hostSignDouble(n: in Double): Int {
  if n > 0.0 {
    1
  } else if n < 0.0 {
    0 - 1
  } else {
    0
  }
}

@externTarget("java.lang.Double.isNaN")
pub func hostIsNaN(x: in Double): Bool = ()

// Java spells this isInfinite, not isInfinity.
@externTarget("java.lang.Double.isInfinite")
pub func hostIsInfinity(x: in Double): Bool = ()

@externTarget("java.lang.Double.isFinite")
pub func hostIsFinite(x: in Double): Bool = ()
