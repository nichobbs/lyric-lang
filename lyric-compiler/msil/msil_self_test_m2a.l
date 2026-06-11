//! msil_self_test_m2a.l — Stage M2a self-test for parameterized heap builders.
//!
//! Exercises all four heap types (StringHeap, BlobHeap, UsHeap, GuidHeap) and
//! verifies the structural invariants expected by the ECMA-335 layout engine.
//!
//! Run in CI via native `lyric test` (D-progress-474 / #66), linking the
//! already-compiled compiler DLLs as restored deps:
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_self_test_m2a.l
//!
//! Regression coverage for #3085: `Msil.Kernel.ByteWriter` shares its short
//! name with the transitively-loaded `Std.Stream.ByteWriter`; the consumer
//! codegen must bind the explicitly-imported package's type (scope-tier
//! resolution in `Msil.Codegen.resolveTypeFqn`), or every `bufNew()` call
//! site faults at runtime with a mismatched MemberRef return type.
@test_module
package Msil.SelfTestM2a

import Msil.Heaps
import Msil.Kernel
import Std.Core
import Std.Collections
import Std.Testing

test "StringHeap interning and serialization" {
  val sh = newStringHeap()
  // New heap starts at size 1 (the null byte at offset 0).
  assertEqualInt(stringHeapSize(sh), 1, "strings_start")

  // First intern returns offset 1; dedup returns the same offset.
  val off1 = internString(sh, "Hello")
  assertEqualInt(off1, 1, "string_intern first offset")
  assertEqualInt(internString(sh, "Hello"), 1, "string_intern dedup")

  // "Hello\0" = 6 bytes so the next entry starts at offset 7.
  val off2 = internString(sh, "Main")
  assertEqualInt(off2, 7, "string second offset")
  assertEqualInt(stringHeapSize(sh), 12, "string heap size")

  // Serialize and spot-check: byte[0]=0 (empty), byte[1..5]='H','e','l','l','o',
  // byte[6]=0 (null terminator).
  val shW = bufNew()
  serializeStrings(sh, shW)
  val shBytes = bufToList(shW)
  assertTrue(shBytes[0] == 0, "strings byte 0")
  assertTrue(shBytes[1] == 72, "strings byte 'H'")
  assertTrue(shBytes[2] == 101, "strings byte 'e'")
  assertTrue(shBytes[3] == 108, "strings byte 'l'")
  assertTrue(shBytes[4] == 108, "strings byte 'l'")
  assertTrue(shBytes[5] == 111, "strings byte 'o'")
  assertTrue(shBytes[6] == 0, "strings null terminator")
}

test "BlobHeap interning" {
  val bh = newBlobHeap()
  // New blob heap starts at size 1.
  assertEqualInt(blobHeapSize(bh), 1, "blob_start")

  val bdataW = bufNew()
  bufU1(bdataW, 0x00)
  bufU1(bdataW, 0x00)
  bufU1(bdataW, 0x01)
  val bdata = bufToList(bdataW)
  val boff1 = internBlob(bh, "sig.void", bdata)
  assertEqualInt(boff1, 1, "blob_intern first offset")
  assertEqualInt(internBlob(bh, "sig.void", bdata), 1, "blob_intern dedup")
  // Offset 0 = null byte, offset 1 = compressed-length(3) = 0x03, offsets 2-4 = data.
  assertEqualInt(blobHeapSize(bh), 5, "blob heap size")
}

test "UsHeap interning and serialization" {
  val uh = newUsHeap()
  // New US heap starts at size 1.
  assertEqualInt(usHeapSize(uh), 1, "us_start")

  val uoff1 = internUs(uh, "Hi")
  assertEqualInt(uoff1, 1, "us_intern first offset")
  assertEqualInt(internUs(uh, "Hi"), 1, "us_intern dedup")
  // "Hi" = 2 chars so blobLen = 2*2+1 = 5; compressed(5) = 0x05 (1 byte);
  // stored as: 0x05, 'H'(0x48), 0x00, 'i'(0x69), 0x00, flag(0x00) = 6 bytes;
  // total after offset 0: 1 + 6 = 7.
  assertEqualInt(usHeapSize(uh), 7, "us heap size")

  val uhW = bufNew()
  serializeUs(uh, uhW)
  val uhBytes = bufToList(uhW)
  assertTrue(uhBytes[1] == 5, "us compressed length")
  assertTrue(uhBytes[2] == 72, "us byte 'H'")
  assertTrue(uhBytes[3] == 0, "us UTF-16 high byte")
}

test "GuidHeap appending" {
  val gh = newGuidHeap()
  // New GUID heap starts at size 0.
  assertEqualInt(guidHeapSize(gh), 0, "guid_start")

  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val zeroGuid = bufToList(guidW)

  // appendGuid returns the 1-based index; one GUID occupies 16 bytes.
  val gidx = appendGuid(gh, zeroGuid)
  assertEqualInt(gidx, 1, "guid index")
  assertEqualInt(guidHeapSize(gh), 16, "guid heap size")
}
