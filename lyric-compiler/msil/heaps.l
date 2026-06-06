//! msil/heaps.l — ECMA-335 metadata heap builders (Stage M2a).
//!
//! Implements the four heaps used by the CLR metadata system:
//!   #Strings — null-terminated UTF-8 strings; indices are byte offsets.
//!   #Blob    — compressed-length-prefixed byte blobs; indices are byte offsets.
//!   #US      — user string literals in UTF-16LE; indices are byte offsets.
//!   #GUID    — 16-byte GUIDs; indices are 1-based.
//!
//! All four heap types expose the same lifecycle:
//!   1. Construct with `new*Heap()`.
//!   2. Intern or append entries; get back the heap index/offset.
//!   3. Serialize with `serialize*(h, w)` to a ByteWriter at layout time.
//!
//! Duplicate detection:
//!   StringHeap, BlobHeap, and UsHeap deduplicate entries by a string key
//!   so the same logical entry always maps to the same heap index.
//!   GuidHeap uses a sequential counter (no dedup) since each assembly
//!   typically has at most one GUID (the module Mvid).
//!
//! References: ECMA-335 6th edition §II.24.2.
package Msil.Heaps

import Msil.Kernel
import Std.Core
import Std.Collections
import Std.Char
import Std.Encoding as Enc

// ── Compressed unsigned integer (ECMA-335 §II.23.2) ──────────────────────────
// Encodes an unsigned integer into 1, 2, or 4 bytes for blob/US length prefixes.
func writeCompressedUInt(w: in ByteWriter, v: in Int): Unit {
  if v <= 0x7F {
    bufU1(w, v)
  } else if v <= 0x3FFF {
    // 2-byte form: high byte has bit 7 set.
    // (v / 256) is at most 0x3F (6 bits), so + 0x80 is safe (no overlap).
    bufU1(w, (v / 256) + 0x80)
    bufU1(w, v % 256)
  } else {
    // 4-byte form: first byte has bits 7 and 6 set.
    // (v / 16777216) is at most 0x1F (5 bits), so + 0xC0 is safe.
    bufU1(w, (v / 16777216) + 0xC0)
    bufU1(w, (v / 65536) % 256)
    bufU1(w, (v / 256) % 256)
    bufU1(w, v % 256)
  }
}

// ── #Strings heap (ECMA-335 §II.24.2.3) ──────────────────────────────────────
// Null-terminated UTF-8 strings.  Heap offset 0 is the empty string (a single
// 0x00 byte).  Duplicate strings share one heap entry.
pub record StringHeap {
  buf: ByteWriter
  entries: Map[String, Int]
}

pub func newStringHeap(): StringHeap {
  val buf = bufNew()
  bufU1(buf, 0)
  StringHeap(buf = buf, entries = newMap())
}

// Returns the byte offset of `s` in the heap (the start of the UTF-8 bytes,
// before the null terminator).
pub func internString(h: in StringHeap, s: in String): Int {
  match mapGet(h.entries, s) {
    case Some(off) -> off
    case None -> {
      val off = bufLen(h.buf)
      h.entries.add(s, off)
      bufBytes(h.buf, Enc.encodeUtf8(s))
      bufU1(h.buf, 0)
      off
    }
  }
}

pub func stringHeapSize(h: in StringHeap): Int {
  bufLen(h.buf)
}

pub func serializeStrings(h: in StringHeap, w: in ByteWriter): Unit {
  bufAppend(w, h.buf)
}

// ── #Blob heap (ECMA-335 §II.24.2.4) ─────────────────────────────────────────
// Compressed-length-prefixed blobs.  Heap offset 0 is the empty blob (0x00).
// `key` is a caller-supplied dedup identifier (typically the signature text).
pub record BlobHeap {
  buf: ByteWriter
  entries: Map[String, Int]
}

pub func newBlobHeap(): BlobHeap {
  val buf = bufNew()
  bufU1(buf, 0)
  BlobHeap(buf = buf, entries = newMap())
}

// Returns the byte offset of the blob's length-prefix byte.
// `key` is the dedup key; `data` is the raw blob content.
pub func internBlob(h: in BlobHeap, key: in String, data: in List[Byte]): Int {
  match mapGet(h.entries, key) {
    case Some(off) -> off
    case None -> {
      val off = bufLen(h.buf)
      h.entries.add(key, off)
      writeCompressedUInt(h.buf, data.count)
      bufByteList(h.buf, data)
      off
    }
  }
}

pub func blobHeapSize(h: in BlobHeap): Int {
  bufLen(h.buf)
}

pub func serializeBlobs(h: in BlobHeap, w: in ByteWriter): Unit {
  bufAppend(w, h.buf)
}

// ── #US heap (ECMA-335 §II.24.2.4) ───────────────────────────────────────────
// User-string literals encoded as UTF-16LE with a compressed-length prefix.
// Heap offset 0 is the empty entry (0x00).  Duplicate strings share one entry.
//
// Each blob contains: n×2 UTF-16LE bytes + 1 flag byte.
// Flag byte: 0 if all code units are < 0x80; 1 if any code unit is ≥ 0x80.
pub record UsHeap {
  buf: ByteWriter
  entries: Map[String, Int]
}

pub func newUsHeap(): UsHeap {
  val buf = bufNew()
  bufU1(buf, 0)
  UsHeap(buf = buf, entries = newMap())
}

// Returns the byte offset of the blob-length prefix for `s`.
pub func internUs(h: in UsHeap, s: in String): Int {
  match mapGet(h.entries, s) {
    case Some(off) -> off
    case None -> {
      val off = bufLen(h.buf)
      h.entries.add(s, off)
      val n = s.length
      writeCompressedUInt(h.buf, n * 2 + 1)
      var hasHigh = false
      var i = 0
      while i < n {
        val cu = toInt(s[i])
        bufU1(h.buf, cu % 256)
        bufU1(h.buf, cu / 256)
        if cu >= 128 {
          hasHigh = true
        }
        i = i + 1
      }
      if hasHigh {
        bufU1(h.buf, 1)
      } else {
        bufU1(h.buf, 0)
      }
      off
    }
  }
}

pub func usHeapSize(h: in UsHeap): Int {
  bufLen(h.buf)
}

pub func serializeUs(h: in UsHeap, w: in ByteWriter): Unit {
  bufAppend(w, h.buf)
}

// ── #GUID heap (ECMA-335 §II.24.2.5) ─────────────────────────────────────────
// Sequence of 16-byte GUIDs.  Index 0 means "no GUID".  The first GUID added
// has index 1, the second has index 2, and so on.
pub record GuidHeap {
  buf: ByteWriter
  count: Int
}

pub func newGuidHeap(): GuidHeap {
  GuidHeap(buf = bufNew(), count = 0)
}

// Appends `guid` (must be a List[Byte] of length 16) and returns its 1-based
// index.
pub func appendGuid(h: in GuidHeap, guid: in List[Byte]): Int {
  h.count = h.count + 1
  bufByteList(h.buf, guid)
  h.count
}

pub func guidHeapSize(h: in GuidHeap): Int {
  bufLen(h.buf)
}

pub func serializeGuids(h: in GuidHeap, w: in ByteWriter): Unit {
  bufAppend(w, h.buf)
}
