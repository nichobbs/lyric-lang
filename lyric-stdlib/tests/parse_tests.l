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

// Forms both parsers agree on (#7283: the JVM kernel now rejects malformed
// input by syntax before calling the JDK).
func testParseOptDoubleForms(): Unit {
  assertTrue(unwrapOr[Double](parseOptDouble("-2.5e3"), 0.0) == 0.0 - 2500.0, "-2.5e3")
  assertTrue(unwrapOr[Double](parseOptDouble("+1E-3"), 0.0) == 0.001, "+1E-3")
  assertTrue(unwrapOr[Double](parseOptDouble(".5"), 0.0) == 0.5, ".5")
  assertTrue(unwrapOr[Double](parseOptDouble("5."), 0.0) == 5.0, "5.")
  assertTrue(unwrapOr[Double](parseOptDouble("  42  "), 0.0) == 42.0, "surrounding whitespace")
  assertTrue(isSome[Double](parseOptDouble("Infinity")), "Infinity")
  assertTrue(isSome[Double](parseOptDouble("-Infinity")), "-Infinity")
  assertTrue(isSome[Double](parseOptDouble("NaN")), "NaN")
  assertTrue(isNone[Double](parseOptDouble("")), "empty")
  assertTrue(isNone[Double](parseOptDouble("1.2.3")), "two points")
  assertTrue(isNone[Double](parseOptDouble("e5")), "exponent without mantissa")
  assertTrue(isNone[Double](parseOptDouble("1e")), "exponent without digits")
  assertTrue(isNone[Double](parseOptDouble("1e+")), "signed exponent without digits")
  assertTrue(isNone[Double](parseOptDouble(".")), "lone point")
  assertTrue(isNone[Double](parseOptDouble("-")), "lone sign")
  assertTrue(isNone[Double](parseOptDouble("1 2")), "inner space")
  assertTrue(isNone[Double](parseOptDouble("0x1p3")), "hex float")
  assertTrue(isNone[Double](parseOptDouble("1.5f")), "type suffix")
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
  testParseOptDoubleForms()
  testParseOptBool()
  println("parse: ok")
}
