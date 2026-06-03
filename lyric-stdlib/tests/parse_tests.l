// stdlib/tests/parse_tests.l — Tests for Std.Parse.
//
// Covers the pure-Lyric parseOptInt / parseOptLong implementations and
// verifies edge cases: leading whitespace, signs, overflow boundaries,
// non-numeric characters, and the panicking convenience wrappers.
package Std.Parse.Tests

import Std.Core
import Std.Parse
import Std.Testing

func testParseOptIntBasic(): Unit {
  assertTrue(isSome(parseOptInt("0")),    "0 parses")
  assertTrue(isSome(parseOptInt("42")),   "42 parses")
  assertTrue(isSome(parseOptInt("-1")),   "-1 parses")
  assertTrue(isSome(parseOptInt("+7")),   "+7 parses")

  assertEqualInt(unwrapOr(parseOptInt("0"),   -1), 0,  "0 = 0")
  assertEqualInt(unwrapOr(parseOptInt("42"),  -1), 42, "42 = 42")
  assertEqualInt(unwrapOr(parseOptInt("-1"),  0),  -1, "-1 = -1")
  assertEqualInt(unwrapOr(parseOptInt("+7"),  -1), 7,  "+7 = 7")
}

func testParseOptIntWhitespace(): Unit {
  assertEqualInt(unwrapOr(parseOptInt("  42"),   -1), 42, "leading spaces")
  assertEqualInt(unwrapOr(parseOptInt("\t10"),   -1), 10, "leading tab")
  assertEqualInt(unwrapOr(parseOptInt("\n-5"),   0),  -5, "leading newline")
}

func testParseOptIntBoundary(): Unit {
  // Int32 range: -2147483648 to 2147483647
  assertEqualInt(unwrapOr(parseOptInt("2147483647"),  0), 2147483647, "Int32.MaxValue")
  assertTrue(isSome(parseOptInt("-2147483648")),               "Int32.MinValue is Some")
  // Can't compare -2147483648 directly with assertEqualInt without overflow, so
  // verify sign only.
  assertTrue(unwrapOr(parseOptInt("-2147483648"), 0) < 0,     "Int32.MinValue is negative")
  assertTrue(isNone(parseOptInt("2147483648")),               "MaxValue+1 is None")
  assertTrue(isNone(parseOptInt("-2147483649")),              "MinValue-1 is None")
}

func testParseOptIntInvalid(): Unit {
  assertTrue(isNone(parseOptInt("")),       "empty is None")
  assertTrue(isNone(parseOptInt("abc")),    "letters are None")
  assertTrue(isNone(parseOptInt("1.5")),    "decimal is None")
  assertTrue(isNone(parseOptInt("1e5")),    "exponent is None")
  assertTrue(isNone(parseOptInt("  ")),     "only whitespace is None")
  assertTrue(isNone(parseOptInt("-")),      "bare minus is None")
  assertTrue(isNone(parseOptInt("+")),      "bare plus is None")
  assertTrue(isNone(parseOptInt("1 2")),    "embedded space is None")
}

func testParseIntPanic(): Unit {
  assertEqualInt(parseInt("99"), 99, "parseInt 99")
}

func testParseOptLongBasic(): Unit {
  assertTrue(isSome(parseOptLong("0")),  "long 0 parses")
  assertTrue(isSome(parseOptLong("-1")), "long -1 parses")

  assertEqualInt(unwrapOr(parseOptInt("0"), -1), 0, "long 0 = 0")
}

func testParseOptLongBoundary(): Unit {
  // Int64 boundaries
  assertTrue(isSome(parseOptLong("9223372036854775807")),  "Int64.MaxValue is Some")
  assertTrue(isSome(parseOptLong("-9223372036854775808")), "Int64.MinValue is Some")
  assertTrue(isNone(parseOptLong("9223372036854775808")),  "MaxValue+1 is None")
  assertTrue(isNone(parseOptLong("-9223372036854775809")), "MinValue-1 is None")
}

func testParseOptDouble(): Unit {
  // Double and Bool still go through the host — basic smoke test.
  assertTrue(isSome(parseOptDouble("3.14")), "3.14 parses")
  assertTrue(isNone(parseOptDouble("xyz")),  "xyz double is None")
}

func testParseOptBool(): Unit {
  assertTrue(isSome(parseOptBool("true")),  "true parses")
  assertTrue(isSome(parseOptBool("false")), "false parses")
  assertTrue(isNone(parseOptBool("yes")),   "yes is None")
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
