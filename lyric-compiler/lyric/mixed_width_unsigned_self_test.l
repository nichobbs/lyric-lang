//! `UInt op ULong` widening zero-extends the `UInt` (#7350).
//!
//! The dotnet and JVM counterpart of `mixed_width_arith_self_test.l`'s
//! signed cases: a `UInt` with its top bit set must widen with `conv.u8` /
//! `Integer.toUnsignedLong`, not a sign extension.  Native has no unsigned
//! integer types yet, so this runs on dotnet and JVM.
@test_module
package MixedWidthUnsignedSelfTest

import Std.Core
import Std.Testing

test "UInt op ULong zero-extends the UInt" {
  val u: UInt = 4000000000u32
  val ul: ULong = 1u64
  assertEqual(toString(u + ul), "4000000001", "UInt with the top bit set + ULong")
  assertEqual(toString(ul + u), "4000000001", "ULong + UInt")
}

test "UInt op ULong covers every arithmetic operator" {
  val u: UInt = 4000000000u32
  val ul: ULong = 3u64
  assertEqual(toString(u - ul), "3999999997", "UInt - ULong")
  assertEqual(toString(u * ul), "12000000000", "UInt * ULong")
  assertEqual(toString(u / ul), "1333333333", "UInt / ULong")
  assertEqual(toString(u % ul), "1", "UInt % ULong")
}

test "UInt and ULong compare after zero-extending the UInt (#7382)" {
  val u: UInt = 4000000000u32
  val ul: ULong = 1u64
  val big: ULong = 5000000000u64
  assertTrue(u > ul, "UInt with the top bit set > ULong")
  assertTrue(ul < u, "ULong < UInt with the top bit set")
  assertTrue(u >= ul and ul <= u, ">= and <=")
  assertTrue(u < big, "UInt < a larger ULong")
  assertTrue(big > u, "larger ULong > UInt")
}
