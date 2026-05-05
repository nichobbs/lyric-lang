// stdlib/tests/math_tests.l — Tests for Std.Math.
//
// Covers native integer functions (abs, min/max, gcd, lcm, sign) and
// the Double trampolines (sqrt, floor, ceiling, round). Floating-point
// comparisons use integer-valued inputs so exact equality is safe.
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
  testDoubleOps()
  println("math: ok")
}
