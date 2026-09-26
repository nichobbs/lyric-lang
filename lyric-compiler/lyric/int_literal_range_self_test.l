//! Unsuffixed integer literals at and beyond `Int`'s range (#7346).
//!
//! A literal too large for `Int` used to type as `Int` anyway: dotnet wrapped
//! it (`2147483648` printed `-2147483648`) and the JVM failed verification.
//! It now types as `Long`, `Int.MinValue` (`-2147483648`) stays an `Int`, and
//! an operator operand adopts its partner's type only when the value fits.
//! Runs on both targets.
@test_module
package IntLiteralRangeSelfTest

import Std.Core
import Std.Testing

func takesLong(x: in Long): Long = x

func takesInt(x: in Int): Int = x

test "Int boundary literals keep their values" {
  val hi: Int = 2147483647
  val lo: Int = -2147483648
  assertEqual(toString(hi), "2147483647", "Int.MaxValue")
  assertEqual(toString(lo), "-2147483648", "Int.MinValue")
  assertEqual(toString(takesInt(-2147483648)), "-2147483648", "Int.MinValue as an argument")
}

test "a parenthesized Int.MinValue literal folds the same way (#7397)" {
  val lo: Int = -(2147483648)
  assertEqual(toString(lo), "-2147483648", "binding")
  assertEqual(toString(takesInt(-((2147483648)))), "-2147483648", "argument")
}

test "a literal above Int's range is a Long" {
  val big = 3000000000
  val asLong: Long = big
  assertEqual(toString(asLong), "3000000000", "inferred Long keeps its value")
  assertEqual(toString(takesLong(2147483648)), "2147483648", "Long argument")
  val below: Long = -2147483649
  assertEqual(toString(below), "-2147483649", "below Int.MinValue")
}

test "a large literal in arithmetic with an Int widens to Long" {
  val n: Int = 1
  val sum = n + 3000000000
  assertEqual(toString(sum), "3000000001", "Int + Long-valued literal")
}

test "a large literal compared with a Long adopts Long" {
  val x: Long = 5000000000i64
  assertTrue(x == 5000000000, "Long == large literal")
  assertTrue(x > 4999999999, "Long > large literal")
}
