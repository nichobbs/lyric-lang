//! metadata_reader_self_test.l — regression coverage for the reference-pack
//! probe walk (#4741, #4747).
//!
//! `probeRefPackRoot` / `RefPackProbe` are intentionally not `pub` (#4746) —
//! `refPackDir()` and `refPackDirDebugInfo()` are the only public surface,
//! and both are built on top of the same per-root probe (#4741: before that
//! refactor the two walks could silently drift apart).  This test exercises
//! that shared-source-of-truth property from outside the package: whatever
//! `refPackDir()` finds (or doesn't) on the host running this test,
//! `refPackDirDebugInfo()`'s trace must agree with it.
//!
//! Converted from a plain `func main` program to `@test_module` (#4751).
//! `Msil.MetadataReader` resolves under native `lyric test` the same way
//! `Msil.Kernel`/`Msil.Heaps` do for the sibling `msil_self_test_m2a.l`-
//! `m2d.l`/`m88.l` `@test_module` files: the self-hosted compiler DLLs are
//! staged as restored deps (see the "MSIL backend self-tests M2a-M2d
//! (native lyric test)" CI step), so no `LYRIC_LOAD_COMPILER=1` recompile
//! is needed here either. This file is wired into that step's file list in
//! `.github/workflows/ci.yml` (#4786).
//!
//! Also covers `rdI16` sign-extension and `decodeInt32ConstantBlob`'s
//! signed/unsigned classification (#4331). Both were made `pub` in
//! `Msil.MetadataReader` (mirroring the existing `mkPrimSig`/`sigPrimByte`
//! cross-package test-accessor pattern) specifically so this package can
//! construct byte blobs directly, without a real DLL fixture carrying a
//! negative I2 literal/enum field.
@test_module
package Msil.MetadataReaderSelfTest

import Msil.MetadataReader
import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing

test "refPackDirDebugInfo() returns a non-empty trace" {
  val debugInfo = refPackDirDebugInfo()
  assertTrue(debugInfo.length > 0, "debugInfo_nonEmpty")
}

test "refPackDir() and refPackDirDebugInfo() agree on what was found" {
  val debugInfo = refPackDirDebugInfo()
  match refPackDir() {
    case Some(dir) -> {
      assertTrue(Str.contains(debugInfo, "found " + dir), "debugInfo_mentionsFoundDir")
    }
    case None -> {
      assertTrue(not Str.contains(debugInfo, "found "), "debugInfo_hasNoFoundMarker")
    }
  }
}

// rdI16 (little-endian signed 16-bit reader) and its sign-extension edge
// cases (#4331). `rdI16` is `pub` specifically so this cross-package test can
// reach it directly with constructed byte buffers, without a real DLL fixture.
test "rdI16: 0x0000 decodes to 0" {
  val bytes: List[Byte] = newList()
  bytes.add(0x00u8)
  bytes.add(0x00u8)
  assertEqualInt(rdI16(bytes.toArray(), 0), 0, "rdI16_zero")
}

test "rdI16: 0x7FFF decodes to 32767 (max positive)" {
  val bytes: List[Byte] = newList()
  bytes.add(0xFFu8)
  bytes.add(0x7Fu8)
  assertEqualInt(rdI16(bytes.toArray(), 0), 32767, "rdI16_maxPositive")
}

test "rdI16: 0x8000 decodes to -32768 (min negative)" {
  val bytes: List[Byte] = newList()
  bytes.add(0x00u8)
  bytes.add(0x80u8)
  assertEqualInt(rdI16(bytes.toArray(), 0), -32768, "rdI16_minNegative")
}

test "rdI16: 0xFFFF decodes to -1" {
  val bytes: List[Byte] = newList()
  bytes.add(0xFFu8)
  bytes.add(0xFFu8)
  assertEqualInt(rdI16(bytes.toArray(), 0), -1, "rdI16_negativeOne")
}

test "rdI16: reads at a non-zero offset, ignoring surrounding bytes" {
  val bytes: List[Byte] = newList()
  bytes.add(0xAAu8) // padding, must be ignored
  bytes.add(0xFFu8)
  bytes.add(0x7Fu8) // 0x7FFF at offset 1
  bytes.add(0xBBu8) // padding, must be ignored
  assertEqualInt(rdI16(bytes.toArray(), 1), 32767, "rdI16_offset")
}

// decodeInt32ConstantBlob: the ElementType-aware blob decode that backs
// getLiteralFieldInt32In's Constant-table decoding (#4331). Exercised
// directly with constructed 2-byte blobs since a full PE/metadata fixture
// with a real negative I2 literal/enum field isn't available in this
// sandbox.
test "decodeInt32ConstantBlob: I2 (0x06) 2-byte blob is sign-extended" {
  val bytes: List[Byte] = newList()
  bytes.add(0xFFu8)
  bytes.add(0xFFu8) // 0xFFFF as I2 == -1
  match decodeInt32ConstantBlob(0x06, bytes.toArray()) {
    case Some(v) -> assertEqualInt(v, -1, "decode_i2_negative")
    case None -> assertTrue(false, "decode_i2_negative_expectedSome")
  }
}

test "decodeInt32ConstantBlob: I2 (0x06) 2-byte blob decodes a large negative value" {
  val bytes: List[Byte] = newList()
  bytes.add(0x00u8)
  bytes.add(0x80u8) // 0x8000 as I2 == -32768
  match decodeInt32ConstantBlob(0x06, bytes.toArray()) {
    case Some(v) -> assertEqualInt(v, -32768, "decode_i2_minNegative")
    case None -> assertTrue(false, "decode_i2_minNegative_expectedSome")
  }
}

test "decodeInt32ConstantBlob: U2 (0x07) 2-byte blob stays unsigned (uses rdU16)" {
  val bytes: List[Byte] = newList()
  bytes.add(0xFFu8)
  bytes.add(0xFFu8) // 0xFFFF as U2 == 65535, NOT -1
  match decodeInt32ConstantBlob(0x07, bytes.toArray()) {
    case Some(v) -> assertEqualInt(v, 65535, "decode_u2_maxUnsigned")
    case None -> assertTrue(false, "decode_u2_maxUnsigned_expectedSome")
  }
}

test "decodeInt32ConstantBlob: CHAR (0x03) 2-byte blob also stays unsigned" {
  // isSigned only covers typeVal 0x04/0x06/0x08 (I1/I2/I4); CHAR (0x03) must
  // fall through to the unsigned (rdU16) branch even though it never
  // legitimately produces a value with the high bit set in practice.
  val bytes: List[Byte] = newList()
  bytes.add(0x00u8)
  bytes.add(0x80u8) // 0x8000 read as unsigned == 32768
  match decodeInt32ConstantBlob(0x03, bytes.toArray()) {
    case Some(v) -> assertEqualInt(v, 32768, "decode_char_unsigned")
    case None -> assertTrue(false, "decode_char_unsigned_expectedSome")
  }
}

// rdI64 (little-endian signed 64-bit reader): the Constant-table decode for
// I8/U8 and R8 literal fields is built on it (`getLiteralFieldConstIn`).
// Constructed byte buffers again — no DLL fixture with a 64-bit literal is
// needed to pin the two's-complement composition (unsigned low half plus
// signed high half scaled by 2^32).
test "rdI64: zero decodes to 0" {
  val bytes: List[Byte] = newList()
  var i = 0
  while i < 8 {
    bytes.add(0x00u8)
    i = i + 1
  }
  assertEqualLong(rdI64(bytes.toArray(), 0), 0i64, "rdI64_zero")
}

test "rdI64: all-FF decodes to -1" {
  val bytes: List[Byte] = newList()
  var i = 0
  while i < 8 {
    bytes.add(0xFFu8)
    i = i + 1
  }
  assertEqualLong(rdI64(bytes.toArray(), 0), -1i64, "rdI64_minusOne")
}

test "rdI64: max positive (0x7FFFFFFFFFFFFFFF) decodes to Long.MaxValue" {
  val bytes: List[Byte] = newList()
  var i = 0
  while i < 7 {
    bytes.add(0xFFu8)
    i = i + 1
  }
  bytes.add(0x7Fu8)
  assertEqualLong(rdI64(bytes.toArray(), 0), 9223372036854775807i64, "rdI64_maxPositive")
}

test "rdI64: min negative (0x8000000000000000) decodes to Long.MinValue" {
  val bytes: List[Byte] = newList()
  var i = 0
  while i < 7 {
    bytes.add(0x00u8)
    i = i + 1
  }
  bytes.add(0x80u8)
  assertEqualLong(rdI64(bytes.toArray(), 0), -9223372036854775807i64 - 1i64, "rdI64_minNegative")
}

test "rdI64: the IEEE 754 bit pattern of Math.PI decodes intact" {
  // 0x400921FB54442D18 little-endian — the R8 Constant blob of System.Math.PI.
  val bytes: List[Byte] = newList()
  bytes.add(0x18u8)
  bytes.add(0x2Du8)
  bytes.add(0x44u8)
  bytes.add(0x54u8)
  bytes.add(0xFBu8)
  bytes.add(0x21u8)
  bytes.add(0x09u8)
  bytes.add(0x40u8)
  assertEqualLong(rdI64(bytes.toArray(), 0), 4614256656552045848i64, "rdI64_piBits")
}

test "rdI64: reads at a non-zero offset, ignoring surrounding bytes" {
  val bytes: List[Byte] = newList()
  bytes.add(0xAAu8)
  bytes.add(0x2Au8) // 42
  var i = 0
  while i < 7 {
    bytes.add(0x00u8)
    i = i + 1
  }
  bytes.add(0xAAu8)
  assertEqualLong(rdI64(bytes.toArray(), 1), 42i64, "rdI64_offset")
}
