//! conversion_name_resolution_self_test.l — a bare call to a conversion
//! function name resolves like any other name (#7465).
//!
//! Both backends used to lower the bare names `longToInt`, `intToLong`,
//! `charToInt` and `intToDouble` to unchecked conversion opcodes before name
//! resolution ran, so a bare `longToInt(x)` never reached the range-checked
//! `Std.Math.longToInt` and silently truncated, and a package's own function
//! with one of those names was never called.  The explicit truncating
//! conversion is the `.toInt()` / `.toLong()` / `.toDouble()` method family.
@test_module
package Lyric.ConversionNameResolutionSelfTest

import Std.Core
import Std.Math
import Std.Testing

// Declared here so a bare call must reach this body, not a conversion opcode.
func charToInt(c: in Char): Int {
  -7
}

func intToDouble(n: in Int): Double {
  0.25
}

func bareLongToIntAboveRange(): Unit {
  val ignored = longToInt(3000000000i64)
}

func bareLongToIntBelowRange(): Unit {
  val ignored = longToInt(-2147483649i64)
}

func qualifiedLongToIntAboveRange(): Unit {
  val ignored = Std.Math.longToInt(3000000000i64)
}

func aliasedLongToIntAboveRange(): Unit {
  val ignored = Math.longToInt(3000000000i64)
}

test "bare longToInt converts an in-range value" {
  assertEqualInt(longToInt(42i64), 42, "longToInt(42)")
  assertEqualInt(longToInt(2147483647i64), 2147483647, "longToInt(Int max)")
  assertEqualInt(longToInt(-2147483648i64), -2147483648, "longToInt(Int min)")
}

test "bare longToInt rejects a value outside Int" {
  assertPanics("bare longToInt(3_000_000_000)", bareLongToIntAboveRange)
  assertPanics("bare longToInt(Int min - 1)", bareLongToIntBelowRange)
}

test "qualified longToInt behaves like the bare call" {
  assertEqualInt(Std.Math.longToInt(2147483647i64), 2147483647, "Std.Math.longToInt(Int max)")
  assertEqualInt(Math.longToInt(-5i64), -5, "Math.longToInt(-5)")
  assertPanics("Std.Math.longToInt(3_000_000_000)", qualifiedLongToIntAboveRange)
  assertPanics("Math.longToInt(3_000_000_000)", aliasedLongToIntAboveRange)
}

test "bare intToLong resolves to Std.Math" {
  val widened: Long = intToLong(2000000000)
  assertTrue(widened + widened == 4000000000i64, "intToLong widens before the addition")
}

test "toInt is the explicit truncating conversion" {
  assertEqualInt(3000000000i64.toInt(), -1294967296, "3_000_000_000.toInt() wraps")
  assertEqualInt(2147483647i64.toInt(), 2147483647, "Int max round-trips")
}

test "a package's own conversion-named function is called" {
  assertEqualInt(charToInt('A'), -7, "local charToInt")
  assertTrue(intToDouble(3) == 0.25, "local intToDouble")
}
