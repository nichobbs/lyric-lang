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
//!
//! Also covers, at the resolution level against the real reference pack, the
//! `ExternParamDefault` kinds the #5605 test above doesn't reach: `EPDZero`
//! (a zeroed-struct default, `JsonDocument.Parse`) and `EPDConst` enum-int /
//! Long numeric constants (`File.OpenHandle`) (#5632).
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

// #5605: trailing-default overload admission and Extends-chain argument
// upcasts, pinned at the RESOLUTION level against the real reference pack —
// the runtime (emission) coverage lives in auto_ffi_self_test.l.  When the
// host has no reference pack there is nothing to resolve against, matching
// the graceful-None handling of the refPackDir() tests above.
test "resolveExtern: trailing-default admission and exact-arity ranking (#5605)" {
  match refPackDir() {
    case None -> assertTrue(true, "no reference pack on this host; nothing to pin")
    case Some(dir) -> {
      val paths = enumRefAssemblies(dir)
      val typeIndex = buildTypeIndex(paths)
      val pathIndex = buildPathIndex(paths)
      // JsonEncodedText.Encode has NO 1-arg overload — a string-only call
      // must admit Encode(String, JavaScriptEncoder = null) and decode the
      // unfilled default as null.
      val args: List[SigType] = newList()
      args.add(mkPrimSig(0x0E))
      match resolveExtern(typeIndex, pathIndex, "System.Text.Json.JsonEncodedText", "Encode", args) {
        case None -> assertTrue(false, "Encode(string) must resolve via the defaulted 2-param overload")
        case Some(re) -> {
          assertEqualInt(re.sig.paramTypes.count, 2, "bound Encode(String, JavaScriptEncoder)")
          match re.sig.paramDefaults[1] {
            case EPDNull -> assertTrue(true, "the unfilled JavaScriptEncoder default decodes to null")
            case _ -> assertTrue(false, "expected EPDNull for the unfilled JavaScriptEncoder default")
          }
        }
      }
      // StreamReader declares BOTH .ctor(Stream) and a defaulted 5-param
      // ctor: with a MemoryStream argument (admitted only through the
      // Extends-chain upcast) the exact-arity candidate must still win —
      // the exact-arity bonus outranks any trailing-default prefix match.
      val ctorArgs: List[SigType] = newList()
      ctorArgs.add(mkNamedSig("System.IO.MemoryStream", false))
      match resolveExtern(typeIndex, pathIndex, "System.IO.StreamReader", ".ctor", ctorArgs) {
        case None -> assertTrue(false, ".ctor(MemoryStream) must resolve via the Extends-chain upcast")
        case Some(ctorRe) -> assertEqualInt(ctorRe.sig.paramTypes.count, 1, "the exact-arity .ctor(Stream) outranks the defaulted 5-param ctor")
      }
    }
  }
}

// #5632: the other `ExternParamDefault` kinds `paramDefaultAt` decodes —
// `EPDZero` (a zeroed struct default) and `EPDConst` numeric/enum constants —
// were only exercised end-to-end via `auto_ffi_self_test.l`'s
// `JsonDoc.Parse`/`File.OpenHandle` cases; neither had a resolution-level
// assertion in this file pinning the Constant-table type-byte branch
// `paramDefaultAt` took to produce them. Same real-reference-pack skeleton as
// the #5605 test above.
test "resolveExtern: JsonDocument.Parse(string) synthesizes an EPDZero struct default (#5632)" {
  match refPackDir() {
    case None -> assertTrue(true, "no reference pack on this host; nothing to pin")
    case Some(dir) -> {
      val paths = enumRefAssemblies(dir)
      val typeIndex = buildTypeIndex(paths)
      val pathIndex = buildPathIndex(paths)
      // JsonDocument.Parse(String, JsonDocumentOptions = default): the
      // unfilled options struct is a zeroed default (typeVal 0x12 with a
      // value-shaped param type), NOT EPDNull — pins the EPDZero branch of
      // `paramDefaultAt` (#5605's own comment: "the shapes a bare
      // type-default guess would get wrong").
      val args: List[SigType] = newList()
      args.add(mkPrimSig(0x0E))
      match resolveExtern(typeIndex, pathIndex, "System.Text.Json.JsonDocument", "Parse", args) {
        case None -> assertTrue(false, "Parse(string) must resolve via the defaulted JsonDocumentOptions overload")
        case Some(re) -> {
          assertEqualInt(re.sig.paramTypes.count, 2, "bound Parse(String, JsonDocumentOptions)")
          match re.sig.paramDefaults[1] {
            case EPDZero -> assertTrue(true, "the unfilled JsonDocumentOptions default is the zeroed-struct kind")
            case _ -> assertTrue(false, "expected EPDZero for the unfilled JsonDocumentOptions default")
          }
        }
      }
    }
  }
}

test "resolveExtern: File.OpenHandle(string) synthesizes enum and Long numeric EPDConst defaults (#5632)" {
  match refPackDir() {
    case None -> assertTrue(true, "no reference pack on this host; nothing to pin")
    case Some(dir) -> {
      val paths = enumRefAssemblies(dir)
      val typeIndex = buildTypeIndex(paths)
      val pathIndex = buildPathIndex(paths)
      // File.OpenHandle(String, FileMode = Open, FileAccess = Read,
      // FileShare = Read, FileOptions = None, Long preallocationSize = 0):
      // five unfilled defaults — four enum-int constants (two of them
      // non-zero: FileMode.Open = 3, FileAccess.Read = 1, FileShare.Read = 1,
      // FileOptions.None = 0) decoded from the Constant table's int-typed
      // branch, plus an I8 constant — pins both the enum/int `EPDConst`
      // branch and the Long-constant branch of `paramDefaultAt`.
      val args: List[SigType] = newList()
      args.add(mkPrimSig(0x0E))
      match resolveExtern(typeIndex, pathIndex, "System.IO.File", "OpenHandle", args) {
        case None -> assertTrue(false, "OpenHandle(string) must resolve via the five-trailing-default overload")
        case Some(re) -> {
          assertEqualInt(
            re.sig.paramTypes.count,
            6,
            "bound OpenHandle(String, FileMode, FileAccess, FileShare, FileOptions, Int64)"
          )
          match re.sig.paramDefaults[1] {
            case EPDConst(v) -> match v { case ECVInt(iv) -> assertEqualInt(iv, 3, "FileMode default decodes as the enum-int constant Open (3)"); case _ -> assertTrue(false, "expected ECVInt for the FileMode default") }
            case _ -> assertTrue(false, "expected EPDConst for the FileMode default")
          }
          match re.sig.paramDefaults[2] {
            case EPDConst(v) -> match v { case ECVInt(iv) -> assertEqualInt(iv, 1, "FileAccess default decodes as the enum-int constant Read (1)"); case _ -> assertTrue(false, "expected ECVInt for the FileAccess default") }
            case _ -> assertTrue(false, "expected EPDConst for the FileAccess default")
          }
          match re.sig.paramDefaults[3] {
            case EPDConst(v) -> match v { case ECVInt(iv) -> assertEqualInt(iv, 1, "FileShare default decodes as the enum-int constant Read (1)"); case _ -> assertTrue(false, "expected ECVInt for the FileShare default") }
            case _ -> assertTrue(false, "expected EPDConst for the FileShare default")
          }
          match re.sig.paramDefaults[4] {
            case EPDConst(v) -> match v { case ECVInt(iv) -> assertEqualInt(iv, 0, "FileOptions default decodes as the enum-int constant None (0)"); case _ -> assertTrue(false, "expected ECVInt for the FileOptions default") }
            case _ -> assertTrue(false, "expected EPDConst for the FileOptions default")
          }
          match re.sig.paramDefaults[5] {
            case EPDConst(v) -> match v { case ECVLong(lv) -> assertEqualLong(lv, 0i64, "preallocationSize default decodes as the Long numeric constant 0"); case _ -> assertTrue(false, "expected ECVLong for the preallocationSize default") }
            case _ -> assertTrue(false, "expected EPDConst for the preallocationSize default")
          }
        }
      }
    }
  }
}
