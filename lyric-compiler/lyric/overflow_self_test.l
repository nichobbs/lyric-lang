//! Integer overflow checking (D163): what a debug build computes when nothing
//! overflows, and the explicit wrapping methods.
//!
//! `+`, `-`, `*` and unary `-` on `Int`, `Long`, `UInt`, `ULong` and `Byte`
//! panic on overflow in a debug build (`lyric test` builds debug) and wrap in
//! a release build.  These cases run on every target and stay clear of a
//! panic: results up to each type's limit, every operand and compound target
//! evaluated once, and `.wrappingAdd` / `.wrappingSub` / `.wrappingMul` /
//! `.wrappingNeg`, which wrap in every build.  The panics themselves, and
//! the `UInt` / `ULong` cases (native has no unsigned types yet), are in
//! `overflow_panic_self_test.l` (dotnet and JVM); every target's debug panic
//! and release wrap are pinned by `scripts/ci/overflow-profile-e2e.sh`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/overflow_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/overflow_self_test.l
//!   lyric test --target native lyric-compiler/lyric/overflow_self_test.l
@test_module
package Lyric.OverflowSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func maxInt(): Int = 2147483647

func minInt(): Int = -2147483648

func maxLong(): Long = 9223372036854775807i64

func minLong(): Long = -9223372036854775807i64 - 1i64

record Counter {
  var calls: Int
}

func tick(c: in Counter, v: in Int): Int {
  c.calls = c.calls + 1
  v
}

func slot(c: in Counter): Int {
  c.calls = c.calls + 1
  0
}

test "results up to each type's limit" {
  assertEqualInt(maxInt() - 1 + 1, 2147483647, "Int")
  assertEqualInt(minInt() + 1 - 1, -2147483648, "Int minimum")
  assertEqualInt(46340 * 46340, 2147395600, "Int product")
  assertEqualInt(-46340 * 46340, -2147395600, "negative Int product")
  assertTrue(maxLong() - 1i64 + 1i64 == maxLong(), "Long")
  assertTrue(3037000499i64 * 3037000499i64 == 9223372030926249001i64, "Long product")
  assertTrue(minLong() * 1i64 == minLong(), "Long minimum times one")
  assertTrue(250u8 + 5u8 == 255u8, "Byte")
  assertTrue(15u8 * 17u8 == 255u8, "Byte product")
  assertTrue(5u8 - 5u8 == 0u8, "Byte difference")
  assertEqualInt(-(minInt() + 1), 2147483647, "Int negation")
}

test "mixed widths compute at the wider type" {
  val i: Int = 2147483647
  val l: Long = 1i64
  assertTrue(i + l == 2147483648i64, "Int + Long is a Long and does not overflow")
}

test "the wrapping methods wrap in every build" {
  assertEqualInt(maxInt().wrappingAdd(1), -2147483648, "Int add")
  assertEqualInt(minInt().wrappingSub(1), 2147483647, "Int sub")
  assertEqualInt(65536.wrappingMul(65536), 0, "Int mul")
  assertEqualInt(minInt().wrappingNeg(), -2147483648, "Int neg")
  assertTrue(maxLong().wrappingAdd(1i64) == minLong(), "Long add")
  assertTrue((200u8).wrappingAdd(100u8) == 44u8, "Byte add")
  assertTrue((16u8).wrappingMul(16u8) == 0u8, "Byte mul")
  var h: Int = 17
  h = h.wrappingMul(16777619).wrappingAdd(maxInt())
  assertEqualInt(h, -1862264126, "a hash step")
}

test "operands and compound targets are evaluated once" {
  val c = Counter(calls = 0)
  val s = tick(c, 2) + tick(c, 3)
  assertEqualInt(s, 5, "sum")
  assertEqualInt(c.calls, 2, "each operand once")
  val xs: List[Int] = newList()
  xs.add(10)
  val d = Counter(calls = 0)
  xs[slot(d)] += 5
  assertEqualInt(xs[0], 15, "indexed compound target")
  assertEqualInt(d.calls, 1, "the index is evaluated once")
  var n = 7
  n -= 2
  n *= 3
  assertEqualInt(n, 15, "plain compound targets")
}
