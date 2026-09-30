//! `u64` literals from 2^63 to 2^64-1 and `u32` literals up to 2^32-1
//! are writable and load their unsigned value (#7839).
//!
//! The lexer used to range-check every integer literal against the signed
//! 64-bit range, so `18446744073709551615u64` was L0010 and a `ULong` above
//! Long.MaxValue had to be computed at run time.  A `u64` literal now takes
//! the full unsigned range and is carried as its 64-bit two's-complement
//! pattern, which both backends load unchanged (`ldc.i8` / `ldc2_w`).  Each
//! case below compares, orders, divides or prints a value whose top bit is
//! set, so a signed reading changes the result.  Native has no unsigned
//! integer types yet, so this runs on dotnet and JVM.
@test_module
package UnsignedLiteralMaxSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val modMax: ULong = 18446744073709551615u64

val modHalf: ULong = 0x8000_0000_0000_0000u64

type HighHalf = ULong range 9223372036854775808u64 ..= 18446744073709551615u64

record Holder {
  v: ULong
}

func maxULong(): ULong {
  18446744073709551615u64
}

func passU(x: in ULong): ULong {
  x
}

func classify(x: in ULong): String {
  match x {
    case 18446744073709551615u64 -> "max"
    case 9223372036854775808u64 -> "half"
    case 0u64 -> "zero"
    case _ -> "other"
  }
}

test "decimal u64 literals above Long max print unsigned" {
  val max: ULong = 18446744073709551615u64
  val half: ULong = 9223372036854775808u64
  val belowHalf: ULong = 9223372036854775807u64
  val zero: ULong = 0u64
  assertEqual(toString(max), "18446744073709551615", "2^64-1")
  assertEqual(toString(half), "9223372036854775808", "2^63")
  assertEqual(toString(belowHalf), "9223372036854775807", "2^63-1")
  assertEqual(toString(zero), "0", "0")
}

test "hex octal binary and underscored u64 literals" {
  val hex: ULong = 0xFFFF_FFFF_FFFF_FFFFu64
  val oct: ULong = 0o1777777777777777777777u64
  val bin: ULong = 0b1000000000000000000000000000000000000000000000000000000000000001u64
  val underscored: ULong = 18_446_744_073_709_551_614u64
  assertTrue(hex == 18446744073709551615u64, "hex equals decimal 2^64-1")
  assertTrue(oct == 18446744073709551615u64, "octal equals decimal 2^64-1")
  assertTrue(bin == 9223372036854775809u64, "binary 2^63+1")
  assertEqual(toString(underscored), "18446744073709551614", "underscored 2^64-2")
}

test "u64 literals above Long max order unsigned" {
  val max: ULong = 18446744073709551615u64
  val half: ULong = 9223372036854775808u64
  val belowHalf: ULong = 9223372036854775807u64
  val one: ULong = 1u64
  assertTrue(half > belowHalf, "2^63 > 2^63-1")
  assertTrue(max > half, "2^64-1 > 2^63")
  assertTrue(max > one, "2^64-1 > 1")
  assertTrue(one < max, "1 < 2^64-1")
  assertTrue(belowHalf < half, "2^63-1 < 2^63")
  assertTrue(max >= max, "2^64-1 >= itself")
  assertTrue(half <= max, "2^63 <= 2^64-1")
  assertTrue(max != half, "2^64-1 != 2^63")
}

test "u64 literals above Long max divide unsigned" {
  val max: ULong = 18446744073709551615u64
  val half: ULong = 9223372036854775808u64
  val two: ULong = 2u64
  val ten: ULong = 10u64
  val q = max / two
  assertEqual(toString(q), "9223372036854775807", "(2^64-1) / 2")
  val r = max % ten
  assertEqual(toString(r), "5", "(2^64-1) % 10")
  val h = half / two
  assertEqual(toString(h), "4611686018427387904", "2^63 / 2")
  val m = max / half
  assertEqual(toString(m), "1", "(2^64-1) / 2^63")
}

test "u64 max arithmetic wraps like the ULong it stands for" {
  val max: ULong = 18446744073709551615u64
  val back = max - 18446744073709551614u64
  assertTrue(back == 1u64, "(2^64-1) - (2^64-2) == 1")
  val near = 9223372036854775807u64 + 1u64
  assertTrue(near == 9223372036854775808u64, "2^63-1 + 1 == 2^63")
}

test "u64 literals above Long max flow through calls fields and module values" {
  assertTrue(maxULong() == 18446744073709551615u64, "function result")
  assertTrue(passU(18446744073709551615u64) == 18446744073709551615u64, "argument")
  val h = Holder(v = 18446744073709551615u64)
  assertTrue(h.v == 18446744073709551615u64, "record field")
  assertTrue(modMax == 18446744073709551615u64, "module val (decimal)")
  assertTrue(modHalf == 9223372036854775808u64, "module val (hex)")
  val local: ULong = modMax
  assertTrue(local > modHalf, "module vals order unsigned")
}

test "u64 literal patterns above Long max" {
  assertEqual(classify(18446744073709551615u64), "max", "2^64-1 arm")
  assertEqual(classify(9223372036854775808u64), "half", "2^63 arm")
  assertEqual(classify(0u64), "zero", "0 arm")
  assertEqual(classify(7u64), "other", "wildcard arm")
}

func highHalfIsOk(r: in Result[HighHalf, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

func highHalfError(r: in Result[HighHalf, String]): String {
  match r {
    case Ok(_) -> ""
    case Err(e) -> e
  }
}

test "ULong range subtype with bounds above Long max" {
  assertTrue(highHalfIsOk(HighHalf.tryFrom(18446744073709551615u64)), "upper bound inclusive")
  assertTrue(highHalfIsOk(HighHalf.tryFrom(9223372036854775808u64)), "lower bound inclusive")
  assertTrue(highHalfIsOk(HighHalf.tryFrom(12345678901234567890u64)), "a value inside the range")
  assertFalse(highHalfIsOk(HighHalf.tryFrom(9223372036854775807u64)), "2^63-1 below the range")
  assertFalse(highHalfIsOk(HighHalf.tryFrom(0u64)), "0 below the range")
  assertEqualLong(HighHalf.from(18446744073709551615u64).toLong(), -1i64, "from(2^64-1) keeps the 64-bit pattern")
  assertEqual(
    highHalfError(HighHalf.tryFrom(5u64)),
    "HighHalf.tryFrom: value out of range [9223372036854775808, 18446744073709551615]",
    "the range message prints the bounds unsigned"
  )
}

test "u32 literals up to 2^32-1" {
  val max: UInt = 4294967295u32
  val hex: UInt = 0xFFFF_FFFFu32
  val half: UInt = 2147483648u32
  assertEqual(toString(max), "4294967295", "2^32-1")
  assertTrue(hex == max, "hex 2^32-1")
  assertTrue(max > half, "2^32-1 > 2^31")
  assertEqual(toString(max / 2u32), "2147483647", "(2^32-1) / 2")
}
