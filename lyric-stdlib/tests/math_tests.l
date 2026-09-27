//! stdlib/tests/math_tests.l — Tests for Std.Math.
//!
//! Covers native integer functions (abs, min/max, gcd, lcm, sign) and
//! the Double trampolines (sqrt, floor, ceiling, round). Floating-point
//! comparisons use integer-valued inputs so exact equality is safe.
package Std.Math.Tests

import Std.Math
import Std.Testing

func testAbsInt(): Unit {
  assertEqualInt(absInt(5), 5, "absInt positive")
  assertEqualInt(absInt(-5), 5, "absInt negative")
  assertEqualInt(absInt(0), 0, "absInt zero")
}

func testMinMaxInt(): Unit {
  assertEqualInt(minPairInt(3, 7), 3, "minPairInt")
  assertEqualInt(minPairInt(7, 3), 3, "minPairInt reversed")
  assertEqualInt(maxPairInt(3, 7), 7, "maxPairInt")
  assertEqualInt(maxPairInt(7, 3), 7, "maxPairInt reversed")
  assertEqualInt(minPairInt(-1, 1), -1, "minPairInt negative")
  assertEqualInt(maxPairInt(-1, 1), 1, "maxPairInt negative")
}

func testGcd(): Unit {
  assertEqualInt(gcd(12, 8), 4, "gcd(12,8)")
  assertEqualInt(gcd(7, 13), 1, "gcd coprime")
  assertEqualInt(gcd(0, 5), 5, "gcd zero left")
  assertEqualInt(gcd(5, 0), 5, "gcd zero right")
  assertEqualInt(gcd(0, 0), 0, "gcd both zero")
}

func testLcm(): Unit {
  assertEqualInt(lcm(4, 6), 12, "lcm(4,6)")
  assertEqualInt(lcm(7, 13), 91, "lcm coprime")
  assertEqualInt(lcm(0, 5), 0, "lcm zero left")
  assertEqualInt(lcm(5, 0), 0, "lcm zero right")
}

func testSignInt(): Unit {
  assertEqualInt(signInt(10), 1, "signInt positive")
  assertEqualInt(signInt(-10), -1, "signInt negative")
  assertEqualInt(signInt(0), 0, "signInt zero")
}

// #7252: signDouble(NaN) must return 0 rather than throw — NaN has no
// sign, and the JVM/native hosts already returned 0 for it while .NET's
// `Math.Sign(double)` used to throw. Shared code now checks first.
func testSignDoubleNaN(): Unit {
  val nan = 0.0 / 0.0
  assertEqualInt(signDouble(nan), 0, "signDouble(NaN) is 0")
  assertEqualInt(signDouble(5.0), 1, "signDouble positive")
  assertEqualInt(signDouble(-5.0), -1, "signDouble negative")
  assertEqualInt(signDouble(0.0), 0, "signDouble zero")
}

// #7252: longToInt round-trips a value that fits Int, and its own
// `requires:` rejects one that doesn't (matching the panic the BCL/JVM
// hosts already raised for an out-of-range value).
//
// Called qualified (`Math.longToInt`, not bare `longToInt`): both backends
// still lower a BARE `longToInt` to an unchecked truncating conversion that
// never reaches Std.Math's function or its contract (#7465).
func callLongToIntOverflow(): Unit {
  val ignored = Math.longToInt(9223372036854775807i64)
}

func testLongToIntBounds(): Unit {
  assertEqualInt(Math.longToInt(2147483647i64), 2147483647, "longToInt max")
  assertEqualInt(Math.longToInt(-2147483648i64), -2147483648, "longToInt min")
  assertPanics("longToInt rejects a value outside Int range", callLongToIntOverflow)
}

// #7252: absInt/absLong reject Int.MinValue/Long.MinValue, whose negation
// overflows rather than silently returning a negative "absolute value".
func callAbsIntMinValue(): Unit {
  val ignored = absInt(-2147483648)
}

func callAbsLongMinValue(): Unit {
  val ignored = absLong(-9223372036854775808i64)
}

func testAbsRejectsMinValue(): Unit {
  assertPanics("absInt rejects Int.MinValue", callAbsIntMinValue)
  assertPanics("absLong rejects Long.MinValue", callAbsLongMinValue)
}

func testDoubleOps(): Unit {
  // sqrt(4.0) = 2.0 — exact in IEEE 754
  val s = sqrt(4.0)
  assertTrue(s > 1.9 and s < 2.1, "sqrt(4)")

  // floor / ceiling / round on exact integers
  val fl = floor(3.7)
  assertTrue(fl > 2.9 and fl < 3.1, "floor(3.7)")

  val cl = ceiling(3.2)
  assertTrue(cl > 3.9 and cl < 4.1, "ceiling(3.2)")

  val ro = round(2.5)
  assertTrue(ro > 1.9 and ro < 3.1, "round(2.5) is 2 or 3")
}

func main(): Unit {
  testAbsInt()
  testMinMaxInt()
  testGcd()
  testLcm()
  testSignInt()
  testSignDoubleNaN()
  testLongToIntBounds()
  testAbsRejectsMinValue()
  testDoubleOps()
  println("math: ok")
}
