//! std/_kernel_native/math_host.l — native-target math boundary (libm).
//!
//! The `--target native` twin of `_kernel/math_host.l`: same
//! `Std.MathHost` package name and `host*` surface, backed by C libm
//! symbols instead of System.Math.  Selected by the native source
//! loader's `_kernel_native/`-over-`_kernel/` basename preference.
//!
//! `.NET`'s Math.Round uses banker's rounding (round-half-to-even);
//! libm's `nearbyint` under the default FE_TONEAREST rounding mode has
//! the same half-to-even behaviour, so `hostRound` binds to it (NOT
//! `round`, which rounds half away from zero and would diverge from the
//! managed targets on *.5 inputs).
@axiom("C99 libm functions conform to their documented contracts")
package Std.MathHost

extern func cSin(x: Double): Double = "sin"

extern func cCos(x: Double): Double = "cos"

extern func cTan(x: Double): Double = "tan"

extern func cAsin(x: Double): Double = "asin"

extern func cAcos(x: Double): Double = "acos"

extern func cAtan(x: Double): Double = "atan"

extern func cAtan2(y: Double, x: Double): Double = "atan2"

extern func cPow(base_: Double, exponent: Double): Double = "pow"

extern func cSqrt(x: Double): Double = "sqrt"

extern func cCbrt(x: Double): Double = "cbrt"

extern func cLog(x: Double): Double = "log"

extern func cLog10(x: Double): Double = "log10"

extern func cLog2(x: Double): Double = "log2"

extern func cExp(x: Double): Double = "exp"

extern func cFabs(x: Double): Double = "fabs"

extern func cFmin(a: Double, b: Double): Double = "fmin"

extern func cFmax(a: Double, b: Double): Double = "fmax"

extern func cFloor(x: Double): Double = "floor"

extern func cCeil(x: Double): Double = "ceil"

extern func cNearbyint(x: Double): Double = "nearbyint"

extern func cTrunc(x: Double): Double = "trunc"

pub func hostPi(): Double {
  3.141592653589793
}

pub func hostE(): Double {
  2.718281828459045
}

pub func hostTau(): Double {
  6.283185307179586
}

pub func hostAbsDouble(n: in Double): Double {
  cFabs(n)
}

pub func hostMinPairDouble(a: in Double, b: in Double): Double {
  cFmin(a, b)
}

pub func hostMaxPairDouble(a: in Double, b: in Double): Double {
  cFmax(a, b)
}

pub func hostPow(base_: in Double, exponent: in Double): Double {
  cPow(base_, exponent)
}

pub func hostSqrt(x: in Double): Double {
  cSqrt(x)
}

pub func hostCbrt(x: in Double): Double {
  cCbrt(x)
}

pub func hostLn(x: in Double): Double {
  cLog(x)
}

pub func hostLog10(x: in Double): Double {
  cLog10(x)
}

pub func hostLog2(x: in Double): Double {
  cLog2(x)
}

pub func hostExp(x: in Double): Double {
  cExp(x)
}

pub func hostSin(x: in Double): Double {
  cSin(x)
}

pub func hostCos(x: in Double): Double {
  cCos(x)
}

pub func hostTan(x: in Double): Double {
  cTan(x)
}

pub func hostAsin(x: in Double): Double {
  cAsin(x)
}

pub func hostAcos(x: in Double): Double {
  cAcos(x)
}

pub func hostAtan(x: in Double): Double {
  cAtan(x)
}

pub func hostAtan2(y: in Double, x: in Double): Double {
  cAtan2(y, x)
}

pub func hostFloor(x: in Double): Double {
  cFloor(x)
}

pub func hostCeiling(x: in Double): Double {
  cCeil(x)
}

pub func hostRound(x: in Double): Double {
  cNearbyint(x)
}

pub func hostTruncate(x: in Double): Double {
  cTrunc(x)
}

pub func hostSignDouble(n: in Double): Int {
  if n > 0.0 {
    return 1
  }
  if n < 0.0 {
    return -1
  }
  0
}

pub func hostIsNaN(x: in Double): Bool {
  x != x
}

pub func hostIsInfinity(x: in Double): Bool {
  x == 1.0 / 0.0 or x == -1.0 / 0.0
}

pub func hostIsFinite(x: in Double): Bool {
  not hostIsNaN(x) and not hostIsInfinity(x)
}

pub func hostIntToLong(n: in Int): Long {
  n.toLong()
}

pub func hostLongToInt(n: in Long): Int {
  n.toInt()
}
