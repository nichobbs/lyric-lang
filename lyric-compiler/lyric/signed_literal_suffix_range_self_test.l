//! Each signed integer suffix spans exactly its signed range, and its
//! minimum is written as a unary minus applied to the magnitude one past
//! the maximum (#7847).
//!
//! The lexer used to bound every signed-suffixed literal by the 64-bit
//! range only, so `3000000000i32` compiled and wrapped to -1294967296 and
//! `300i8` compiled as 300.  It now reports L0010 outside the suffix's
//! range; `-128i8`, `-32768i16`, `-2147483648i32` and
//! `-9223372036854775808i64` stay legal, in every base.  `i8` is an `Int`
//! literal (`Byte` is unsigned and cannot hold -128), as `i16` always was.
//! Each case below moves a minimum or maximum through a binding, a call, a
//! record field, a module value, a list literal, a match pattern or a range
//! subtype, where a backend that sized the negation by its operand would
//! push a `long` into an `int` slot or wrap the value.
@test_module
package SignedLiteralSuffixRangeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val modMinI32: Int = -2147483648i32

val modMinI8: Int = -128i8

val modMinI64: Long = -9223372036854775808i64

type SmallSigned = Int range -128i8 ..= 127i8

record IntHolder {
  v: Int
}

func passInt(x: in Int): Int {
  x
}

func minI32(): Int {
  -2147483648i32
}

func smallIsOk(r: in Result[SmallSigned, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

func smallValue(r: in Result[SmallSigned, String]): Int {
  match r {
    case Ok(s) -> s.toInt()
    case Err(_) -> 0
  }
}

func classify(x: in Int): String {
  match x {
    case -2147483648i32 -> "i32 min"
    case 2147483647i32 -> "i32 max"
    case -32768i16 -> "i16 min"
    case -128i8 -> "i8 min"
    case 127i8 -> "i8 max"
    case _ -> "other"
  }
}

test "signed suffix minimums and maximums in decimal" {
  val i8Min: Int = -128i8
  val i8Max: Int = 127i8
  val i16Min: Int = -32768i16
  val i16Max: Int = 32767i16
  val i32Min: Int = -2147483648i32
  val i32Max: Int = 2147483647i32
  val i64Min: Long = -9223372036854775808i64
  val i64Max: Long = 9223372036854775807i64
  assertEqual(toString(i8Min), "-128", "i8 min")
  assertEqual(toString(i8Max), "127", "i8 max")
  assertEqual(toString(i16Min), "-32768", "i16 min")
  assertEqual(toString(i16Max), "32767", "i16 max")
  assertEqual(toString(i32Min), "-2147483648", "i32 min")
  assertEqual(toString(i32Max), "2147483647", "i32 max")
  assertEqual(toString(i64Min), "-9223372036854775808", "i64 min")
  assertEqual(toString(i64Max), "9223372036854775807", "i64 max")
}

test "signed suffix minimums in hex binary and octal" {
  val i8Hex: Int = -0x80i8
  val i8Bin: Int = -0b1000_0000i8
  val i8Oct: Int = -0o200i8
  val i16Hex: Int = -0x8000i16
  val i32Hex: Int = -0x8000_0000i32
  val i32Bin: Int = -0b1000_0000_0000_0000_0000_0000_0000_0000i32
  val i64Hex: Long = -0x8000_0000_0000_0000i64
  assertEqual(toString(i8Hex), "-128", "-0x80i8")
  assertEqual(toString(i8Bin), "-128", "-0b10000000i8")
  assertEqual(toString(i8Oct), "-128", "-0o200i8")
  assertEqual(toString(i16Hex), "-32768", "-0x8000i16")
  assertEqual(toString(i32Hex), "-2147483648", "-0x80000000i32")
  assertEqual(toString(i32Bin), "-2147483648", "binary i32 min")
  assertEqual(toString(i64Hex), "-9223372036854775808", "-0x8000000000000000i64")
  val i8HexMax: Int = 0x7Fi8
  val i32HexMax: Int = 0x7FFF_FFFFi32
  assertEqual(toString(i8HexMax), "127", "0x7Fi8")
  assertEqual(toString(i32HexMax), "2147483647", "0x7FFFFFFFi32")
}

test "signed minimums are Int and Long values" {
  assertTrue(-2147483648i32 < 2147483647i32, "i32 min < max")
  assertTrue(-128i8 < 127i8, "i8 min < max")
  assertTrue(-9223372036854775808i64 < 0i64, "i64 min < 0")
  assertEqualInt(-128i8 + 128, 0, "i8 min + 128")
  assertEqualInt(-2147483648i32 + 1, -2147483647, "i32 min + 1")
  assertTrue(-9223372036854775808i64 + 1i64 == -9223372036854775807i64, "i64 min + 1")
  assertEqualInt(-(127i8 - 1i8), -126, "negated i8 expression")
}

test "signed minimums through calls fields and module values" {
  assertEqualInt(passInt(-2147483648i32), -2147483648, "i32 min as an Int argument")
  assertEqualInt(passInt(-128i8), -128, "i8 min as an Int argument")
  assertEqualInt(minI32(), -2147483648, "i32 min returned")
  val h = IntHolder(v = -2147483648i32)
  assertEqualInt(h.v, -2147483648, "i32 min in an Int field")
  assertEqualInt(modMinI32, -2147483648, "i32 min module value")
  assertEqualInt(modMinI8, -128, "i8 min module value")
  assertEqual(toString(modMinI64), "-9223372036854775808", "i64 min module value")
}

test "signed minimums in list literals" {
  val xs = [-128i8, 127i8, 0i8]
  assertEqualInt(xs[0], -128, "i8 list: min")
  assertEqualInt(xs[1], 127, "i8 list: max")
  val ys = [-2147483648i32, 2147483647i32]
  assertEqualInt(ys[0], -2147483648, "i32 list: min")
  assertEqualInt(ys[1], 2147483647, "i32 list: max")
}

test "signed minimums as match patterns" {
  assertEqual(classify(-2147483648), "i32 min", "i32 min pattern")
  assertEqual(classify(2147483647), "i32 max", "i32 max pattern")
  assertEqual(classify(-32768), "i16 min", "i16 min pattern")
  assertEqual(classify(-128), "i8 min", "i8 min pattern")
  assertEqual(classify(127), "i8 max", "i8 max pattern")
  assertEqual(classify(128), "other", "one past i8 max")
}

test "range subtype bounded by i8 literals" {
  assertEqualInt(smallValue(SmallSigned.tryFrom(-128)), -128, "i8 range: min accepted")
  assertEqualInt(smallValue(SmallSigned.tryFrom(127)), 127, "i8 range: max accepted")
  assertFalse(smallIsOk(SmallSigned.tryFrom(-129)), "i8 range: below min rejected")
  assertFalse(smallIsOk(SmallSigned.tryFrom(128)), "i8 range: above max rejected")
}
