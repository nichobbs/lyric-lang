//! stdlib/tests/parse_tests.l — Tests for Std.Parse.
//!
//! Covers the pure-Lyric parseOptInt / parseOptLong implementations and
//! verifies edge cases: leading whitespace, signs, overflow boundaries,
//! non-numeric characters, and the panicking convenience wrappers.
package Std.Parse.Tests

import Std.Core
import Std.Parse
import Std.Testing

func testParseOptIntBasic(): Unit {
  assertTrue(isSome[Int](parseOptInt("0")), "0 parses")
  assertTrue(isSome[Int](parseOptInt("42")), "42 parses")
  assertTrue(isSome[Int](parseOptInt("-1")), "-1 parses")
  assertTrue(isSome[Int](parseOptInt("+7")), "+7 parses")

  assertEqualInt(unwrapOr[Int](parseOptInt("0"), -1), 0, "0 = 0")
  assertEqualInt(unwrapOr[Int](parseOptInt("42"), -1), 42, "42 = 42")
  assertEqualInt(unwrapOr[Int](parseOptInt("-1"), 0), -1, "-1 = -1")
  assertEqualInt(unwrapOr[Int](parseOptInt("+7"), -1), 7, "+7 = 7")
}

func testParseOptIntWhitespace(): Unit {
  assertEqualInt(unwrapOr[Int](parseOptInt("  42"), -1), 42, "leading spaces")
  assertEqualInt(unwrapOr[Int](parseOptInt("\t10"), -1), 10, "leading tab")
  assertEqualInt(unwrapOr[Int](parseOptInt("\n-5"), 0), -5, "leading newline")
}

func testParseOptIntBoundary(): Unit {
  // Int32 range: -2147483648 to 2147483647
  assertEqualInt(unwrapOr[Int](parseOptInt("2147483647"), 0), 2147483647, "Int32.MaxValue")
  assertTrue(isSome[Int](parseOptInt("-2147483648")), "Int32.MinValue is Some")
  // Can't compare -2147483648 directly with assertEqualInt without overflow, so
  // verify sign only.
  assertTrue(unwrapOr[Int](parseOptInt("-2147483648"), 0) < 0, "Int32.MinValue is negative")
  assertTrue(isNone[Int](parseOptInt("2147483648")), "MaxValue+1 is None")
  assertTrue(isNone[Int](parseOptInt("-2147483649")), "MinValue-1 is None")
}

func testParseOptIntInvalid(): Unit {
  assertTrue(isNone[Int](parseOptInt("")), "empty is None")
  assertTrue(isNone[Int](parseOptInt("abc")), "letters are None")
  assertTrue(isNone[Int](parseOptInt("1.5")), "decimal is None")
  assertTrue(isNone[Int](parseOptInt("1e5")), "exponent is None")
  assertTrue(isNone[Int](parseOptInt("  ")), "only whitespace is None")
  assertTrue(isNone[Int](parseOptInt("-")), "bare minus is None")
  assertTrue(isNone[Int](parseOptInt("+")), "bare plus is None")
  assertTrue(isNone[Int](parseOptInt("1 2")), "embedded space is None")
}

func testParseIntPanic(): Unit {
  assertEqualInt(parseInt("99"), 99, "parseInt 99")
}

func testParseOptLongBasic(): Unit {
  assertTrue(isSome[Long](parseOptLong("0")), "long 0 parses")
  assertTrue(isSome[Long](parseOptLong("-1")), "long -1 parses")

  assertEqualLong(unwrapOr[Long](parseOptLong("0"), -1i64), 0i64, "long 0 = 0")
}

func testParseOptLongBoundary(): Unit {
  // Int64 boundaries
  assertTrue(isSome[Long](parseOptLong("9223372036854775807")), "Int64.MaxValue is Some")
  assertTrue(isSome[Long](parseOptLong("-9223372036854775808")), "Int64.MinValue is Some")
  assertTrue(isNone[Long](parseOptLong("9223372036854775808")), "MaxValue+1 is None")
  assertTrue(isNone[Long](parseOptLong("-9223372036854775809")), "MinValue-1 is None")
}

func testParseOptDouble(): Unit {
  // Double and Bool still go through the host — basic smoke test.
  assertTrue(isSome[Double](parseOptDouble("3.14")), "3.14 parses")
  assertTrue(isNone[Double](parseOptDouble("xyz")), "xyz double is None")
}

func testParseOptBool(): Unit {
  assertTrue(isSome[Bool](parseOptBool("true")), "true parses")
  assertTrue(isSome[Bool](parseOptBool("false")), "false parses")
  assertTrue(isNone[Bool](parseOptBool("yes")), "yes is None")
}

func main(): Unit {
  testParseOptIntBasic()
  testParseOptIntWhitespace()
  testParseOptIntBoundary()
  testParseOptIntInvalid()
  testParseIntPanic()
  testParseOptLongBasic()
  testParseOptLongBoundary()
  testParseOptDouble()
  testParseOptBool()
  println("parse: ok")
}
