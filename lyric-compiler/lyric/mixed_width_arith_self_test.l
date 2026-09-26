//! Mixed-width arithmetic the type checker widens (#7350).
//!
//! `widenArithmetic` types `Int op Long` as `Long` (and `UInt op ULong` as
//! `ULong`, `Float op Double` as `Double`), but the backends picked the
//! opcode from the left operand alone: dotnet combined an i4 with an i8 as
//! int32 and silently truncated, and the JVM failed verification.  Every
//! operator is covered in both operand orders.  Runs on dotnet, JVM and
//! native; the `UInt`/`ULong` case (native has no unsigned types yet) is in
//! `mixed_width_unsigned_self_test.l`.
@test_module
package MixedWidthArithSelfTest

import Std.Core
import Std.Testing

func big(): Long = 3000000000i64

func one(): Int = 1

test "Int op Long widens to Long in both operand orders" {
  val i: Int = 7
  val l: Long = big()
  assertEqual(toString(i + l), "3000000007", "Int + Long")
  assertEqual(toString(l + i), "3000000007", "Long + Int")
  assertEqual(toString(i - l), "-2999999993", "Int - Long")
  assertEqual(toString(l - i), "2999999993", "Long - Int")
  assertEqual(toString(i * l), "21000000000", "Int * Long")
  assertEqual(toString(l * i), "21000000000", "Long * Int")
  assertEqual(toString(l / i), "428571428", "Long / Int")
  assertEqual(toString(i / l), "0", "Int / Long")
  assertEqual(toString(l % i), "4", "Long % Int")
  assertEqual(toString(i % l), "7", "Int % Long")
}

test "a call result on either side widens too" {
  assertEqual(toString(one() + big()), "3000000001", "Int call + Long call")
  assertEqual(toString(big() - one()), "2999999999", "Long call - Int call")
}

test "a negative Int sign-extends" {
  val i: Int = -5
  val l: Long = big()
  assertEqual(toString(i + l), "2999999995", "negative Int + Long")
}

test "Float op Double widens to Double" {
  val f: Float = 1.5f32
  val d: Double = 2.25
  assertTrue(f + d == 3.75, "Float + Double")
  assertTrue(d - f == 0.75, "Double - Float")
  assertTrue(f * d == 3.375, "Float * Double")
}

test "a compound assignment widens its Int operand" {
  var l: Long = big()
  val i: Int = 5
  l += i
  assertEqual(toString(l), "3000000005", "Long += Int")
  l -= i
  assertEqual(toString(l), "3000000000", "Long -= Int")
}

test "Int and Long compare after widening in both operand orders (#7382)" {
  val i: Int = 7
  val l: Long = big()
  val neg: Int = -5
  val small: Long = 7i64
  assertTrue(i < l, "Int < Long")
  assertTrue(l > i, "Long > Int")
  assertTrue(i <= l, "Int <= Long")
  assertTrue(l >= i, "Long >= Int")
  assertTrue(not (i > l), "not Int > Long")
  assertTrue(not (l < i), "not Long < Int")
  assertTrue(i >= small and i <= small, "Int equal to Long is both <= and >=")
  assertTrue(neg < small, "negative Int sign-extends before <")
  assertTrue(one() < big(), "call results compare too")
}

test "Float and Double compare after widening (#7382)" {
  val f: Float = 1.5f32
  val d: Double = 2.25
  assertTrue(f < d, "Float < Double")
  assertTrue(d >= f, "Double >= Float")
  assertTrue(not (f > d), "not Float > Double")
}
