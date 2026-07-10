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
// Zero-extend a raw byte to unsigned 0-255.  Lyric `Byte` is unsigned and
// `.toInt()` zero-extends, so `v` is always in [0, 255] — no sign-correction
// branch is needed (#2343).
func rdU8(b: in slice[Byte], o: in Int): Int {
  b[o].toInt()
}

func rdU16Le(b: in slice[Byte], o: in Int): Int {
  rdU8(b, o) + rdU8(b, o + 1) * 256
}

func rdU32Le(b: in slice[Byte], o: in Int): Int {
  val b3 = rdU8(b, o + 3)
  val low = rdU8(b, o) + rdU8(b, o + 1) * 256 + rdU8(b, o + 2) * 65536
  // A full unsigned u32 with the top byte >= 128 exceeds Int32.MaxValue and
  // would overflow the checked multiply (panic on a malformed archive).
  // Saturate to Int.maxValue: any such size/offset is far beyond a real
  // archive, so callers' `<= n` bounds checks reject it.
  if b3 >= 128 {
    2147483647
  } else {
    low + b3 * 16777216
  }
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
  // A malformed EOCD (cdSize larger than the file) yields a negative or
  // out-of-range central-directory start; bail BEFORE any further offset
  // arithmetic.  `cdOffsetZip`/`lhOffset` are untrusted u32 fields saturated
  // to Int.maxValue by rdU32Le, so combining them with `cdStart` before this
  // check could overflow Lyric's checked Int and panic (issue #5486).
  if cdStart < 0 or cdStart > n {
    return entries
  }
  // file offset of ZIP "offset 0"; kept in Long so the untrusted-field subtract
  // never overflows.  Only ever narrowed to Int after a per-use bounds check.
  val baseShift: Long = cdStart.toLong() - cdOffsetZip.toLong()
  val nL = n.toLong()

  val cdEntrySig = 0x02014B50
  val lfhSig = 0x04034B50
  var cp = cdStart
  var count = 0
  // `cp <= n - 46` rather than `cp + 46 <= n`: the latter can overflow Int for
  // a `cp` near 2^31 on a crafted ~2GB archive.
  while count < totalEntries and cp >= 0 and cp <= n - 46 {
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
    // Reject a name field that runs past the end of the buffer (Long math: cp
    // and nameLen are both bounded but their sum can exceed Int near n=2^31).
    if cp.toLong() + 46i64 + nameLen.toLong() > nL {
      return entries
    }
    val name = bytesToString(data, cp + 46, nameLen)

    // Resolve the compressed-data offset from the local file header.  Everything
    // is computed in Long and only narrowed to Int once proven in [0, n];
    // dataOffset stays -1 (rejected by extractEntry) when the header is out of
    // range, so a crafted lhOffset cannot drive an overflow or OOB read.
    val lhFileL: Long = baseShift + lhOffset.toLong()
    var dataOffset = -1
    if lhFileL >= 0i64 and lhFileL + 30i64 <= nL {
      val lhFile = lhFileL.toInt()
      if rdU32Le(data, lhFile) == lfhSig {
        val lhNameLen = rdU16Le(data, lhFile + 26)
        val lhExtraLen = rdU16Le(data, lhFile + 28)
        val doL: Long = lhFileL + 30i64 + lhNameLen.toLong() + lhExtraLen.toLong()
        dataOffset = if doL >= 0i64 and doL <= nL { doL.toInt() } else { -1 }
      } else {
        dataOffset = lhFile + 30
      }
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

    // Advance in Long; a crafted length triple could otherwise overflow the
    // Int add.  A next position past the end ends the walk via the loop guard.
    val nextCpL: Long = cp.toLong() + 46i64 + nameLen.toLong() + extraLen.toLong() + commentLen.toLong()
    cp = if nextCpL >= 0i64 and nextCpL <= nL { nextCpL.toInt() } else { -1 }
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
    // STORED: copy bytes directly.  Bound the copy against the actual buffer
    // length — `uncompressedSize` and `dataOffset` come from the untrusted
    // archive and a malformed pair would otherwise index out of bounds.
    val buf: List[Int] = newList()
    var i = 0
    while i < ent.uncompressedSize and ent.dataOffset >= 0 and ent.dataOffset + i < data.length {
      buf.add(rdU8(data, ent.dataOffset + i))
      i = i + 1
    }
    buf
  } else if ent.method == 8 {
    // DEFLATE.  `dataOffset` is untrusted; bail on an out-of-range start (the
    // bit reader also clamps its window against `data.length`, so an oversized
    // `compressedSize` cannot read past the buffer either).
    if ent.dataOffset < 0 or ent.dataOffset > data.length {
      newList()
    } else {
      inflate(data, ent.dataOffset, ent.compressedSize)
    }
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
