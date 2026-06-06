//! msil_self_test_m2a.l — Stage M2a self-test for parameterized heap builders.
//!
//! Exercises all four heap types (StringHeap, BlobHeap, UsHeap, GuidHeap) and
//! verifies the structural invariants expected by the ECMA-335 layout engine.
//!
//! Checks emitted (one per line, key=value):
//!   strings_start_ok    — new heap starts at size 1 (the null byte at offset 0)
//!   string_intern_ok    — first intern returns offset 1; dedup returns same offset
//!   string_size_ok      — size after two distinct strings is correct
//!   string_bytes_ok     — serialized bytes match expected UTF-8 + null layout
//!   blob_start_ok       — new blob heap starts at size 1
//!   blob_intern_ok      — internBlob returns correct offset; dedup works
//!   blob_size_ok        — size after one 3-byte blob is correct (1+1+3 = 5)
//!   us_start_ok         — new US heap starts at size 1
//!   us_intern_ok        — internUs returns correct offset; dedup works
//!   us_size_ok          — size after interning "Hi" is correct (1 + 1 + 4 + 1 = 7)
//!   us_bytes_ok         — first byte after offset 0 is the compressed length (5)
//!   guid_start_ok       — new GUID heap starts at size 0
//!   guid_intern_ok      — appendGuid returns 1-based index 1
//!   guid_size_ok        — size after one GUID is 16
package Msil.SelfTestM2a

import Msil.Heaps
import Msil.Kernel
import Std.Core
import Std.Collections

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=false")
  }
}

func main(): Unit {
  // ── StringHeap ─────────────────────────────────────────────────────────────
  val sh = newStringHeap()
  check("strings_start_ok", stringHeapSize(sh) == 1)

  val off1 = internString(sh, "Hello")
  check("string_intern_ok", off1 == 1 and internString(sh, "Hello") == 1)

  val off2 = internString(sh, "Main")
  // "Hello\0" = 6 bytes → next entry starts at offset 7
  check("string_size_ok", off2 == 7 and stringHeapSize(sh) == 12)

  // Serialize and spot-check: byte[0]=0 (empty), byte[1..5]='H','e','l','l','o', byte[6]=0
  val shW = bufNew()
  serializeStrings(sh, shW)
  val shBytes = bufToList(shW)
  check(
    "string_bytes_ok",
    shBytes[0] == 0 and shBytes[1] == 72 and
      // 'H'
      shBytes[2] == 101 and
      // 'e'
      shBytes[3] == 108 and
      // 'l'
      shBytes[4] == 108 and
      // 'l'
      shBytes[5] == 111 and
      // 'o'
      shBytes[6] == 0
  )       // null terminator

  // ── BlobHeap ───────────────────────────────────────────────────────────────
  val bh = newBlobHeap()
  check("blob_start_ok", blobHeapSize(bh) == 1)

  val bdataW = bufNew()
  bufU1(bdataW, 0x00)
  bufU1(bdataW, 0x00)
  bufU1(bdataW, 0x01)
  val bdata = bufToList(bdataW)
  val boff1 = internBlob(bh, "sig.void", bdata)
  check("blob_intern_ok", boff1 == 1 and internBlob(bh, "sig.void", bdata) == 1)
  // offset 0 = null byte, offset 1 = compressed-length(3) = 0x03, offsets 2-4 = data
  check("blob_size_ok", blobHeapSize(bh) == 5)

  // ── UsHeap ─────────────────────────────────────────────────────────────────
  val uh = newUsHeap()
  check("us_start_ok", usHeapSize(uh) == 1)

  val uoff1 = internUs(uh, "Hi")
  check("us_intern_ok", uoff1 == 1 and internUs(uh, "Hi") == 1)
  // "Hi" = 2 chars → blobLen = 2*2+1 = 5; compressed(5) = 0x05 (1 byte)
  // stored as: 0x05, 'H'(0x48), 0x00, 'i'(0x69), 0x00, flag(0x00) = 6 bytes
  // total after offset 0: 1 + 6 = 7
  check("us_size_ok", usHeapSize(uh) == 7)

  val uhW = bufNew()
  serializeUs(uh, uhW)
  val uhBytes = bufToList(uhW)
  check("us_bytes_ok", uhBytes[1] == 5 and uhBytes[2] == 72 and uhBytes[3] == 0)

  // ── GuidHeap ───────────────────────────────────────────────────────────────
  val gh = newGuidHeap()
  check("guid_start_ok", guidHeapSize(gh) == 0)

  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val zeroGuid = bufToList(guidW)

  val gidx = appendGuid(gh, zeroGuid)
  check("guid_intern_ok", gidx == 1)
  check("guid_size_ok", guidHeapSize(gh) == 16)
}
