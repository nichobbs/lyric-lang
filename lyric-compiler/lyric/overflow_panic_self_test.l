//! Integer overflow checking (D163): the panics a debug build raises, and the
//! `UInt` / `ULong` cases.
//!
//! `lyric test` builds debug, so `+`, `-`, `*` and unary `-` that leave
//! `Int`, `Long`, `UInt`, `ULong` or `Byte` panic with
//! `arithmetic overflow: <type> <operation>`.  `assertPanicsWith` catches the
//! panic, which the native target cannot (no unwinding, D-N-003), and native
//! has no `UInt` / `ULong` yet, so this file runs on dotnet and the JVM;
//! `scripts/ci/overflow-profile-e2e.sh` checks the native panic, and the
//! release wrap on every target, by running a program.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/overflow_panic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/overflow_panic_self_test.l
@test_module
package Lyric.OverflowPanicSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func maxInt(): Int = 2147483647

func minInt(): Int = -2147483648

func maxLong(): Long = 9223372036854775807i64

func minLong(): Long = -9223372036854775807i64 - 1i64

func maxUInt(): UInt = 4294967295u32

func maxULong(): ULong = 18446744073709551615u64

func byteOf(v: in Byte): Byte = v

test "Int and Long overflow panics" {
  assertPanicsWith("Int add", "arithmetic overflow: Int addition", { -> val _ = maxInt() + 1 })
  assertPanicsWith("Int sub", "arithmetic overflow: Int subtraction", { -> val _ = minInt() - 1 })
  assertPanicsWith("Int mul", "arithmetic overflow: Int multiplication", { -> val _ = 65536 * maxInt() })
  assertPanicsWith("Int mul by -1", "arithmetic overflow: Int multiplication", { -> val _ = minInt() * -1 })
  assertPanicsWith("Int neg", "arithmetic overflow: Int negation", { -> val _ = -minInt() })
  assertPanicsWith("Long add", "arithmetic overflow: Long addition", { -> val _ = maxLong() + 1i64 })
  assertPanicsWith("Long sub", "arithmetic overflow: Long subtraction", { -> val _ = minLong() - 1i64 })
  assertPanicsWith("Long mul", "arithmetic overflow: Long multiplication", { -> val _ = maxLong() * 2i64 })
  assertPanicsWith("Long mul by -1", "arithmetic overflow: Long multiplication", { -> val _ = minLong() * -1i64 })
  assertPanicsWith("Long neg", "arithmetic overflow: Long negation", { -> val _ = -minLong() })
}

test "unsigned and Byte overflow panics" {
  assertPanicsWith("UInt add", "arithmetic overflow: UInt addition", { -> val _ = maxUInt() + 1u32 })
  assertPanicsWith("UInt sub", "arithmetic overflow: UInt subtraction", { -> val _ = 0u32 - maxUInt() })
  assertPanicsWith("UInt mul", "arithmetic overflow: UInt multiplication", { -> val _ = maxUInt() * 2u32 })
  assertPanicsWith("ULong add", "arithmetic overflow: ULong addition", { -> val _ = maxULong() + 1u64 })
  assertPanicsWith("ULong sub", "arithmetic overflow: ULong subtraction", { -> val _ = 1u64 - 2u64 })
  assertPanicsWith("ULong mul", "arithmetic overflow: ULong multiplication", { -> val _ = maxULong() * 2u64 })
  assertPanicsWith("Byte add", "arithmetic overflow: Byte addition", { -> val _ = byteOf(200u8) + 100u8 })
  assertPanicsWith("Byte sub", "arithmetic overflow: Byte subtraction", { -> val _ = byteOf(1u8) - 2u8 })
  assertPanicsWith("Byte mul", "arithmetic overflow: Byte multiplication", { -> val _ = byteOf(16u8) * 16u8 })
}

test "compound assignment overflow panics" {
  assertPanicsWith("+=", "arithmetic overflow: Int addition", { -> var n = maxInt(); n += 1 })
  assertPanicsWith(
    "indexed *=",
    "arithmetic overflow: Long multiplication",
    { -> val xs: List[Long] = newList(); xs.add(maxLong()); xs[0] *= 2i64 }
  )
}

test "unsigned results up to each type's limit" {
  assertTrue(maxUInt() - 1u32 + 1u32 == maxUInt(), "UInt")
  assertTrue(65535u32 * 65537u32 == maxUInt(), "UInt product")
  assertTrue(maxULong() - 1u64 + 1u64 == maxULong(), "ULong")
  assertTrue(4294967295u64 * 4294967297u64 == maxULong(), "ULong product")
  assertTrue(maxUInt().wrappingAdd(1u32) == 0u32, "UInt wrappingAdd")
  assertTrue(0u32.wrappingSub(1u32) == maxUInt(), "UInt wrappingSub")
  assertTrue(maxULong().wrappingAdd(1u64) == 0u64, "ULong wrappingAdd")
  assertTrue(maxULong().wrappingMul(2u64) == maxULong() - 1u64, "ULong wrappingMul")
}
