//! jvm/zip_reader.l — ZIP archive reader for JDK .jmod files.
//!
//! Enumerates entries via the ZIP central directory (PKWARE Application Note
//! §4.3.12), not by walking local file headers: JDK JMOD entries are written
//! with streaming data descriptors (general-purpose flag bit 3), so their local
//! headers carry zero sizes and sequential scanning cannot recover them.  The
//! central directory holds authoritative sizes plus each entry's local-header
//! offset; the compressed-data offset is then read from that local header.
//! STORED and DEFLATE entries are both supported; DEFLATE is decompressed via
//! Jvm.Deflate.inflate.
//!
//! A JMOD prefixes the embedded ZIP with a 4-byte magic header ("JM" + version);
//! the resulting offset shift is recovered from the EOCD position rather than
//! hard-coded, so plain ZIPs and JMODs are both handled.
//!
//! Bitwise operations are expressed as arithmetic so this file compiles cleanly
//! under both the self-hosted compiler and the F# stage-0 bootstrap emitter
//! (which lacks support for the .and/.or/.shl/.shr method forms on Int).
package Jvm.ZipReader

import Std.Core
import Std.Collections
import Std.Char
import Jvm.Deflate

// ── Little-endian readers ─────────────────────────────────────────────────────
// Convert a raw byte (possibly signed) to unsigned 0-255.
func rdU8(b: in slice[Byte], o: in Int): Int {
  val v = b[o].toInt()
  if v < 0 {
    v + 256
  } else {
    v
  }
}

func rdU16Le(b: in slice[Byte], o: in Int): Int {
  rdU8(b, o) + rdU8(b, o + 1) * 256
}

func rdU32Le(b: in slice[Byte], o: in Int): Int {
  rdU8(b, o) + rdU8(b, o + 1) * 256 + rdU8(b, o + 2) * 65536 + rdU8(b, o + 3) * 16777216
}

// ── ZIP entry descriptor ──────────────────────────────────────────────────────
pub record ZipEntry {
  name: String
  method: Int    // 0 = STORED, 8 = DEFLATE
  compressedSize: Int
  uncompressedSize: Int
  dataOffset: Int    // absolute offset of file data within the archive
  hasDataDescriptor: Bool  // true when flags bit 3 is set (sizes in LFH may be 0)
  crc32: Int
}

// ── Entry enumeration ─────────────────────────────────────────────────────────
// Convert a sub-range of raw bytes to a String.
// JDK JMOD entry paths are pure ASCII; non-ASCII bytes are skipped.
func bytesToString(data: in slice[Byte], offset: in Int, len: in Int): String {
  if len <= 0 {
    return ""
  }
  var s = ""
  var i = 0
  while i < len {
    val b = rdU8(data, offset + i)
    if b > 0 and b < 128 {
      s = s + ("" + fromInt(b))
    }
    i = i + 1
  }
  s
}

/// Read every ZIP entry from `data` by parsing the central directory.
///
/// JDK JMOD entries are written with streaming data descriptors (general-purpose
/// flag bit 3 set), so their local file headers carry zero compressed /
/// uncompressed sizes — sequential local-header scanning cannot recover them.
/// The central directory at the end of the archive holds the authoritative
/// sizes and each entry's local-header offset, so it is the only reliable
/// enumeration path.  The exact data offset is then resolved from the entry's
/// local file header (whose name / extra lengths can differ from the central
/// directory record's).
///
/// A JMOD prefixes the embedded ZIP with a 4-byte magic header ("JM" + version),
/// which shifts every ZIP-relative offset.  The shift is recovered from the
/// known EOCD position (`cdStart - cdOffsetInEocd`) rather than hard-coding it,
/// so a plain ZIP (shift 0) and a JMOD (shift 4) are both handled.
pub func readZipEntries(data: in slice[Byte]): List[ZipEntry] {
  val entries: List[ZipEntry] = newList()
  val n = data.length
  if n < 22 {
    return entries
  }

  // Locate the End Of Central Directory record (sig 0x06054B50) by scanning
  // backward from the end (the trailing comment is empty for JDK JMODs).
  val eocdSig = 0x06054B50
  var eocd = -1
  var p = n - 22
  while p >= 0 and eocd < 0 {
    if rdU32Le(data, p) == eocdSig {
      eocd = p
    }
    p = p - 1
  }
  if eocd < 0 {
    return entries
  }

  val totalEntries = rdU16Le(data, eocd + 10)
  val cdSize = rdU32Le(data, eocd + 12)
  val cdOffsetZip = rdU32Le(data, eocd + 16)
  val cdStart = eocd - cdSize           // central directory file offset
  val baseShift = cdStart - cdOffsetZip   // file offset of ZIP "offset 0"

  val cdEntrySig = 0x02014B50
  val lfhSig = 0x04034B50
  var cp = cdStart
  var count = 0
  while count < totalEntries and cp + 46 <= n {
    if rdU32Le(data, cp) != cdEntrySig {
      return entries
    }
    val method = rdU16Le(data, cp + 10)
    // The CRC32 field (cp+16) is a full unsigned 32-bit value that routinely
    // exceeds Int32.MaxValue; reading it via `rdU32Le` would overflow Lyric's
    // checked Int arithmetic.  It is never consumed downstream, so it is left
    // at 0 rather than read.
    val crc = 0
    val compSize = rdU32Le(data, cp + 20)
    val uncompSize = rdU32Le(data, cp + 24)
    val nameLen = rdU16Le(data, cp + 28)
    val extraLen = rdU16Le(data, cp + 30)
    val commentLen = rdU16Le(data, cp + 32)
    val lhOffset = rdU32Le(data, cp + 42)
    val name = bytesToString(data, cp + 46, nameLen)

    // Resolve the compressed-data offset from the local file header.
    val lhFile = baseShift + lhOffset
    var dataOffset = lhFile + 30
    if lhFile + 30 <= n and rdU32Le(data, lhFile) == lfhSig {
      val lhNameLen = rdU16Le(data, lhFile + 26)
      val lhExtraLen = rdU16Le(data, lhFile + 28)
      dataOffset = lhFile + 30 + lhNameLen + lhExtraLen
    }

    entries.add(
      ZipEntry(
        name = name,
        method = method,
        compressedSize = compSize,
        uncompressedSize = uncompSize,
        dataOffset = dataOffset,
        hasDataDescriptor = false,
        crc32 = crc
      )
    )

    cp = cp + 46 + nameLen + extraLen + commentLen
    count = count + 1
  }
  entries
}

// ── Entry extraction ──────────────────────────────────────────────────────────
/// Decompress or copy the data for `entry` from `data`.
/// Returns the uncompressed bytes as a List[Int] (values 0-255).
/// Returns an empty list if the entry uses an unsupported compression method
/// or has a data descriptor with unknown sizes.
pub func extractEntry(data: in slice[Byte], ent: in ZipEntry): List[Int] {
  if ent.hasDataDescriptor and ent.compressedSize == 0 {
    return newList()
  }

  if ent.method == 0 {
    // STORED: copy bytes directly.
    val buf: List[Int] = newList()
    var i = 0
    while i < ent.uncompressedSize {
      buf.add(rdU8(data, ent.dataOffset + i))
      i = i + 1
    }
    buf
  } else if ent.method == 8 {
    // DEFLATE.
    inflate(data, ent.dataOffset, ent.compressedSize)
  } else {
    newList()   // unsupported method
  }
}

/// Find the first entry with the given name and extract it.
/// Returns None if no matching entry exists.
pub func extractByName(data: in slice[Byte], entries: in List[ZipEntry], name: in String): Option[List[Int]] {
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.name == name {
      return Some(value = extractEntry(data, e))
    }
    i = i + 1
  }
  None
}
