//! msil/metadata_reader.l — pure-Lyric CLI-metadata reader.
//!
//! Reads a .NET PE assembly's bytes and parses the ECMA-335 metadata container.
//! It is the inverse of the metadata *writer* in `pe.l`/`tables.l`/`heaps.l`:
//! where the writer lays out the DOS/PE/COFF headers, the CLI header, the
//! metadata root (`BSJB`), the stream headers, and the `#~` table-stream
//! header, this reader walks the same structures back out of a byte image.
//! Resolving external method signatures from reference-assembly metadata this
//! way needs no runtime type loading — it is pure byte reading, so it is
//! independent of whether the emitting assembly's types can be reflected over.
//!
//! This module currently covers layers 1–5 plus reference-assembly discovery:
//! the PE container (DOS/PE/COFF/optional header, sections, RVA→file-offset,
//! CLI header), the metadata root (stream headers), the `#~` table-stream
//! header (heap-size flags, the valid-table bitvector, per-table row counts),
//! the `#Strings`/`#Blob` heap readers, the table layout + TypeDef/MethodDef/
//! Param row readers (with run-length method-list ownership), the MethodDefSig
//! signature-blob decoder, and a reference-pack discovery + type→assembly
//! index.  Overload resolution and the emitter wiring build on top.
//!
//! All multi-byte integers in the PE/metadata format are little-endian.  Byte
//! values are widened to `Int` via mixed Byte*Int arithmetic (the same idiom
//! `Std.Encoding` uses for UTF-8 decoding), which keeps this compilable by the
//! bootstrap emitter that lacks bitwise operators.  No field read here stores a
//! value with the high bit of a 32-bit slot set (offsets, sizes, RVAs, and row
//! counts are all well under 2^31), and the 64-bit valid/sorted bitvectors are
//! read byte-wise so they never overflow `Int`.
//!
//! References: ECMA-335 6th edition §II.25.2 (PE file), §II.24.2 (metadata
//! physical layout), §II.24.2.6 (`#~` stream).
package Msil.MetadataReader

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char as Ch
import Std.Encoding as Enc
import Std.Environment as Environment
import Std.File as File
import Std.Path as Path
import Std.Parse as Parse

// ── Parsed shapes ────────────────────────────────────────────────────────────
// One PE section header (the 40-byte rows after the optional header).  Only
// the fields needed for RVA→file-offset mapping are kept.
pub record SectionHeader {
  virtualAddress: Int
  virtualSize: Int
  rawDataPtr: Int
  rawDataSize: Int
}

// The PE container: enough to locate the CLI header and the metadata root.
pub record PeImage {
  bytes: slice[Byte]
  peHeaderOff: Int            // file offset of the "PE\0\0" signature
  numSections: Int
  optHeaderSize: Int
  isPe32Plus: Bool
  cliHeaderRva: Int
  cliHeaderSize: Int
  metadataRva: Int           // RVA of the BSJB metadata root
  metadataSize: Int
  metadataOff: Int           // file offset of the BSJB metadata root
  resourcesRva: Int          // RVA of the CLI Resources data region (0 = none)
  resourcesSize: Int
  resourcesOff: Int          // file offset of the Resources data region (-1 if none)
  sections: List[SectionHeader]
}

// One metadata stream header (`#~`, `#Strings`, `#US`, `#GUID`, `#Blob`).
// `offset` is relative to the metadata root; `fileOff` is absolute.
pub record StreamHeader {
  name: String
  offset: Int
  size: Int
  fileOff: Int
}

// The metadata root (`BSJB`) plus its stream headers.
pub record MetadataRoot {
  versionString: String
  streams: List[StreamHeader]
}

// The `#~` table-stream header: heap-index widths + which tables are present
// and their row counts.  `rowCounts` is indexed by ECMA table id (0..63);
// absent tables read 0.
pub record TablesHeader {
  heapSizes: Int          // bit0: #Strings 4-byte, bit1: #GUID, bit2: #Blob
  stringsWide: Bool
  guidWide: Bool
  blobWide: Bool
  presentCount: Int          // number of tables with a row-count entry
  rowCounts: List[Int]    // length 64, indexed by table id
  tablesDataOff: Int          // file offset where the table rows begin
}

// ── Little-endian byte readers (Byte→Int widening via mixed arithmetic) ──────
// Read one byte as an unsigned Int (0..255).  `Byte` is unsigned, so `.toInt()`
// zero-extends to the 0..255 range (language reference §541: conversions are
// explicit — no implicit widening).
func rdU8(b: in slice[Byte], o: in Int): Int {
  b[o].toInt()
}

func rdU16(b: in slice[Byte], o: in Int): Int {
  rdU8(b, o) + rdU8(b, o + 1) * 256
}

func rdI16(b: in slice[Byte], o: in Int): Int {
  val lo = rdU8(b, o)
  val hi = rdU8(b, o + 1)
  val result = lo + hi * 256
  if hi >= 128 { result - 65536 } else { result }
}

func rdU32(b: in slice[Byte], o: in Int): Int {
  val h = rdU8(b, o + 3)
  val hTerm = if h >= 128 { (h - 256) * 16777216 } else { h * 16777216 }
  rdU8(b, o) + rdU8(b, o + 1) * 256 + rdU8(b, o + 2) * 65536 + hTerm
}

func rdI32(b: in slice[Byte], o: in Int): Int {
  val h = rdU8(b, o + 3)
  val hTerm = if h >= 128 { (h - 256) * 16777216 } else { h * 16777216 }
  rdU8(b, o) + rdU8(b, o + 1) * 256 + rdU8(b, o + 2) * 65536 + hTerm
}

// True when bit `bit` (0..7) of the unsigned byte value `byteVal` is set.
func bitSetInByte(byteVal: in Int, bit: in Int): Bool {
  var p = 1
  var k = 0
  while k < bit {
    p = p * 2
    k = k + 1
  };
  (byteVal / p) % 2 == 1
}

// Population count of the 8-byte little-endian mask at `b[o..o+8)`.
func popcount64(b: in slice[Byte], o: in Int): Int {
  var total = 0
  var i = 0
  while i < 8 {
    val v = rdU8(b, o + i)
    var bit = 0
    while bit < 8 {
      if bitSetInByte(v, bit) {
        total = total + 1
      }
      bit = bit + 1
    }
    i = i + 1
  }
  total
}

// Read a null-terminated ASCII string starting at `o` (used for stream names).
// Stops at the first NUL or at `b.length`.
func rdAsciiZ(b: in slice[Byte], o: in Int): String {
  var s = ""
  var i = o
  while i < b.length and rdU8(b, i) != 0 {
    s = s + ("" + Ch.fromInt(rdU8(b, i)))
    i = i + 1
  }
  s
}

// ── Layer 1: PE container ────────────────────────────────────────────────────
// Map an RVA to a file offset using the section table.  Returns -1 when no
// section covers the RVA.
pub func rvaToOffset(img: in PeImage, rva: in Int): Int {
  var i = 0
  while i < img.sections.count {
    val s = img.sections[i]
    if rva >= s.virtualAddress and rva < s.virtualAddress + s.virtualSize {
      return s.rawDataPtr + (rva - s.virtualAddress)
    }
    i = i + 1
  }
  -1
}

// Parse the PE container: DOS stub → PE signature → COFF header → optional
// header (PE32/PE32+) → data directory 14 (CLI header) → section table →
// CLI header → metadata root file offset.
pub func readPe(bytes: in slice[Byte]): Result[PeImage, String] {
  if bytes.length < 0x40 {
    return Err(error = "metadata: file too small to be a PE image (" + toString(bytes.length) + " bytes)")
  }
  // DOS header: 'M' 'Z' then e_lfanew at 0x3C.
  if rdU8(bytes, 0) != 0x4D or rdU8(bytes, 1) != 0x5A {
    return Err(error = "metadata: missing 'MZ' DOS signature")
  }
  val peOff = rdU32(bytes, 0x3C)
  if peOff <= 0 or peOff + 24 > bytes.length {
    return Err(error = "metadata: e_lfanew out of range (" + toString(peOff) + ")")
  }
  // PE signature: 'P' 'E' 0 0 → LE u32 0x4550.
  if rdU32(bytes, peOff) != 0x4550 {
    return Err(error = "metadata: missing 'PE\\0\\0' signature at " + toString(peOff))
  }
  val numSections = rdU16(bytes, peOff + 6)
  val optHeaderSize = rdU16(bytes, peOff + 20)
  val optBase = peOff + 24
  if optBase + optHeaderSize > bytes.length {
    return Err(error = "metadata: optional header out of range")
  }
  val magic = rdU16(bytes, optBase)
  val isPe32Plus = magic == 0x20B
  if magic != 0x10B and magic != 0x20B {
    return Err(error = "metadata: unrecognised optional-header magic 0x" + toString(magic))
  }
  // NumberOfRvaAndSizes precedes the data directories (optBase+92 for PE32,
  // optBase+108 for PE32+); the directories themselves start 4 bytes later.
  val numRvaOff = if isPe32Plus { optBase + 108 } else { optBase + 92 }
  val dataDirStart = numRvaOff + 4
  // CLI header = COM descriptor = data directory index 14, so the image must
  // declare at least 15 directory entries and the entry must lie within the
  // optional header (which spans [optBase, optBase+optHeaderSize)).
  val numRvaAndSizes = rdU32(bytes, numRvaOff)
  if numRvaAndSizes < 15 {
    return Err(
      error = "metadata: image has only " + toString(numRvaAndSizes) +
        " data directories; no CLI header (index 14)"
    )
  }
  val cliDirOff = dataDirStart + 14 * 8
  if cliDirOff + 8 > optBase + optHeaderSize {
    return Err(error = "metadata: CLI data directory extends past the optional header")
  }
  if cliDirOff + 8 > bytes.length {
    return Err(error = "metadata: CLI data directory out of range")
  }
  val cliRva = rdU32(bytes, cliDirOff)
  val cliSize = rdU32(bytes, cliDirOff + 4)
  if cliRva == 0 {
    return Err(error = "metadata: not a managed assembly (CLI header RVA is 0)")
  }
  // Section table follows the optional header.
  val secStart = optBase + optHeaderSize
  val sections: List[SectionHeader] = newList()
  var si = 0
  while si < numSections {
    val so = secStart + si * 40
    if so + 40 > bytes.length {
      return Err(error = "metadata: section header " + toString(si) + " out of range")
    }
    sections.add(
      SectionHeader(
        virtualAddress = rdU32(bytes, so + 12),
        virtualSize = rdU32(bytes, so + 8),
        rawDataPtr = rdU32(bytes, so + 20),
        rawDataSize = rdU32(bytes, so + 16)
      )
    )
    si = si + 1
  }
  // Build a partial image so rvaToOffset can be used to resolve the CLI header.
  val partial = PeImage(
    bytes = bytes,
    peHeaderOff = peOff,
    numSections = numSections,
    optHeaderSize = optHeaderSize,
    isPe32Plus = isPe32Plus,
    cliHeaderRva = cliRva,
    cliHeaderSize = cliSize,
    metadataRva = 0,
    metadataSize = 0,
    metadataOff = -1,
    resourcesRva = 0,
    resourcesSize = 0,
    resourcesOff = -1,
    sections = sections
  )
  val cliOff = rvaToOffset(partial, cliRva)
  // Guard every field this function reads out of the CLI header: MetaData
  // (RVA/Size at +8/+12), Flags (+16), EntryPointToken (+20), and Resources
  // (RVA/Size at +24/+28) — the last byte read is at +31, so the header must
  // span at least 32 bytes.  A truncated image in this window must return Err
  // rather than slice-panic, preserving the None-on-bad-input contract.
  if cliOff < 0 or cliOff + 32 > bytes.length {
    return Err(error = "metadata: CLI header RVA " + toString(cliRva) + " not mapped by any section, or header truncated")
  }
  // CLI header: cb u32, runtime ver u16+u16, then MetaData (RVA u32, Size u32)
  // at +8/+12, Flags at +16, EntryPointToken at +20, then Resources (RVA u32,
  // Size u32) at +24/+28 — the data directory of the embedded managed-resource
  // region the emitter (`assembler.l`) lays down as length-prefixed payloads.
  val mdRva = rdU32(bytes, cliOff + 8)
  val mdSize = rdU32(bytes, cliOff + 12)
  val mdOff = rvaToOffset(partial, mdRva)
  if mdOff < 0 or mdOff + 16 > bytes.length {
    return Err(error = "metadata: metadata root RVA " + toString(mdRva) + " not mapped by any section")
  }
  // Resources directory is optional: an RVA of 0 means the assembly carries no
  // embedded managed resources, in which case the file offset stays -1.
  val rsrcRva = rdU32(bytes, cliOff + 24)
  val rsrcSize = rdU32(bytes, cliOff + 28)
  val rsrcOff = if rsrcRva == 0 { -1 } else { rvaToOffset(partial, rsrcRva) }
  Ok(
    value = PeImage(
      bytes = bytes,
      peHeaderOff = peOff,
      numSections = numSections,
      optHeaderSize = optHeaderSize,
      isPe32Plus = isPe32Plus,
      cliHeaderRva = cliRva,
      cliHeaderSize = cliSize,
      metadataRva = mdRva,
      metadataSize = mdSize,
      metadataOff = mdOff,
      resourcesRva = rsrcRva,
      resourcesSize = rsrcSize,
      resourcesOff = rsrcOff,
      sections = sections
    )
  )
}

// ── Layer 2a: metadata root + stream headers ─────────────────────────────────
pub func readMetadataRoot(img: in PeImage): Result[MetadataRoot, String] {
  val b = img.bytes
  val mo = img.metadataOff
  if mo + 20 > b.length {
    return Err(error = "metadata: root header out of range")
  }
  // BSJB signature: 'B' 'S' 'J' 'B' → LE u32 0x424A5342.
  if rdU32(b, mo) != 0x424A5342 {
    return Err(error = "metadata: missing 'BSJB' root signature")
  }
  // +4 Major u16, +6 Minor u16, +8 Reserved u32, +12 VersionLength u32.
  val verLen = rdU32(b, mo + 12)
  if mo + 16 + verLen + 4 > b.length {
    return Err(error = "metadata: version string out of range")
  }
  val versionString = rdAsciiZ(b, mo + 16)
  // After the (4-byte-aligned) version string: Flags u16, Streams u16.
  val afterVer = mo + 16 + verLen
  val numStreams = rdU16(b, afterVer + 2)
  val streams: List[StreamHeader] = newList()
  var p = afterVer + 4
  var k = 0
  while k < numStreams {
    if p + 8 > b.length {
      return Err(error = "metadata: stream header " + toString(k) + " out of range")
    }
    val sOff = rdU32(b, p)
    val sSize = rdU32(b, p + 4)
    val sName = rdAsciiZ(b, p + 8)
    // Name is null-terminated and padded to the next 4-byte boundary.
    val nameLen = sName.length + 1
    val padded = ((nameLen + 3) / 4) * 4
    streams.add(StreamHeader(name = sName, offset = sOff, size = sSize, fileOff = mo + sOff))
    p = p + 8 + padded
    k = k + 1
  }
  Ok(value = MetadataRoot(versionString = versionString, streams = streams))
}

// Find a stream by name (e.g. "#~", "#Strings").
pub func findStream(root: in MetadataRoot, name: in String): Option[StreamHeader] {
  var i = 0
  while i < root.streams.count {
    if root.streams[i].name == name {
      return Some(value = root.streams[i])
    }
    i = i + 1
  }
  None
}

// ── Layer 2b: `#~` table-stream header ───────────────────────────────────────
// Parse the `#~` (or `#-`) table-stream header: heap-size flags, the valid
// bitvector, and the per-table row counts.  Stops at the start of the table
// rows (Phase 2 reads the rows themselves).
pub func readTablesHeader(img: in PeImage, root: in MetadataRoot): Result[TablesHeader, String] {
  val b = img.bytes
  val sh = match findStream(root, "#~") {
    case Some(s) -> s
    case None -> match findStream(root, "#-") { case Some(s2) -> s2; case None -> return Err(error = "metadata: no '#~' or '#-' table stream") }
  }
  val base = sh.fileOff
  if base + 24 > b.length {
    return Err(error = "metadata: '#~' header out of range")
  }
  // +0 Reserved u32, +4 Major u8, +5 Minor u8, +6 HeapSizes u8, +7 Reserved u8,
  // +8 Valid u64, +16 Sorted u64, +24 row counts (u32 × popcount(Valid)).
  val heapSizes = rdU8(b, base + 6)
  val validOff = base + 8
  val present = popcount64(b, validOff)
  val rowsOff = base + 24
  if rowsOff + present * 4 > b.length {
    return Err(error = "metadata: '#~' row counts out of range")
  }
  // Walk table ids 0..63 in order; each present table consumes one u32.
  val rowCounts: List[Int] = newList()
  var t = 0
  while t < 64 {
    rowCounts.add(0)
    t = t + 1
  }
  var rc = 0
  var tid = 0
  while tid < 64 {
    val byteIdx = tid / 8
    val bitIdx = tid % 8
    if bitSetInByte(rdU8(b, validOff + byteIdx), bitIdx) {
      rowCounts[tid] = rdU32(b, rowsOff + rc * 4)
      rc = rc + 1
    }
    tid = tid + 1
  }
  // Table rows begin after the row-count array.  HeapSizes bit 6 (ExtraData,
  // present in `#-` edit-and-continue streams) inserts one extra u32 first.
  var dataOff = rowsOff + present * 4
  if bitSetInByte(heapSizes, 6) {
    dataOff = dataOff + 4
  }
  Ok(
    value = TablesHeader(
      heapSizes = heapSizes,
      stringsWide = bitSetInByte(heapSizes, 0),
      guidWide = bitSetInByte(heapSizes, 1),
      blobWide = bitSetInByte(heapSizes, 2),
      presentCount = present,
      rowCounts = rowCounts,
      tablesDataOff = dataOff
    )
  )
}

// Row count for an ECMA table id (0..63); 0 when the table is absent.
pub func rowCountOf(th: in TablesHeader, tableId: in Int): Int {
  if tableId < 0 or tableId >= th.rowCounts.count {
    return 0
  }
  th.rowCounts[tableId]
}

// ── Layer 3: heaps ───────────────────────────────────────────────────────────
// Read a compressed unsigned integer (ECMA-335 §II.23.2), the inverse of the
// emitter's `writeCompressedUInt`.  Returns (value, bytesConsumed).
pub record CompressedUInt {
  value: Int
  byteWidth: Int
}

// ECMA-335 §II.23.2: the 1-byte form covers lead bytes `0x00`–`0x7F`, the
// 2-byte form `0x80`–`0xBF`, and the 4-byte form `0xC0`–`0xDF`.  The
// `0xE0`–`0xFE` range is reserved and `0xFF` is the null-blob marker —
// neither is a valid compressed integer, so both are rejected with `Err`
// instead of silently decoding to a junk 29-bit value (#1878).  Out-of-range
// and truncated reads are also rejected so a poisoned offset from an earlier
// decode failure degrades to `Err` rather than an out-of-bounds panic.
pub func readCompressedUInt(b: in slice[Byte], o: in Int): Result[CompressedUInt, String] {
  if o < 0 or o >= b.length {
    return Err(
      error = "metadata: compressed integer offset " + toString(o) + " is outside the blob (length " +
        toString(b.length) +
        ")"
    )
  }
  val b0 = rdU8(b, o)
  if b0 < 0x80 {
    Ok(value = CompressedUInt(value = b0, byteWidth = 1))
  } else if b0 < 0xC0 {
    if o + 1 >= b.length {
      return Err(error = "metadata: truncated 2-byte compressed integer at offset " + toString(o))
    }
    Ok(value = CompressedUInt(value = (b0 - 0x80) * 256 + rdU8(b, o + 1), byteWidth = 2))
  } else if b0 < 0xE0 {
    if o + 3 >= b.length {
      return Err(error = "metadata: truncated 4-byte compressed integer at offset " + toString(o))
    }
    Ok(
      value = CompressedUInt(
        value = (b0 - 0xC0) * 16777216 + rdU8(b, o + 1) * 65536 + rdU8(b, o + 2) * 256 + rdU8(b, o + 3),
        byteWidth = 4
      )
    )
  } else {
    Err(error = "metadata: reserved compressed-integer lead byte " + toString(b0) + " at offset " + toString(o))
  }
}

// Read a UTF-8, NUL-terminated string from `b` starting at file offset `off`.
// (`#Strings` heap entries are UTF-8; identifiers are usually ASCII but may
// carry multi-byte code points.)
func readUtf8Z(b: in slice[Byte], off: in Int): String {
  val acc: List[Byte] = newList()
  var i = off
  while i < b.length and rdU8(b, i) != 0 {
    acc.add(b[i])
    i = i + 1
  }
  match Enc.tryDecodeUtf8(acc.toArray()) {
    case Some(s) -> s
    case None -> ""
  }
}

// ── Layer 4: table layout + row readers ──────────────────────────────────────
// Computed physical layout for the metadata tables: heap-index and
// coded-index column widths, plus each table's row size and the file offset
// where its rows begin.  Indexed arrays are length 64 (ECMA table id).
pub record TableLayout {
  stringIdx: Int          // #Strings index width (2 or 4)
  guidIdx: Int
  blobIdx: Int
  typeDefOrRefIdx: Int          // TypeDefOrRef coded-index width
  resolutionScopeIdx: Int       // ResolutionScope coded-index width (TypeRef col 0)
  implementationIdx: Int        // Implementation coded-index width (ManifestResource col 3)
  fieldIdx: Int          // Field simple-index width
  methodIdx: Int          // MethodDef simple-index width
  paramIdx: Int          // Param simple-index width
  typeDefIdx: Int        // TypeDef simple-index width (for NestedClass table)
  rowSize: List[Int]    // length 64
  dataStart: List[Int]    // length 64, file offset of each table's rows
  stringsBase: Int          // file offset of the #Strings heap (-1 if absent)
  blobBase: Int          // file offset of the #Blob heap (-1 if absent)
  // NestedClass table (0x29), pre-indexed by enclosing TypeDef row →  the
  // list of its nested TypeDef rows.  Built once here (a single O(n) scan)
  // so `findTypeDefByFqn`'s nested-type lookups are O(1) instead of
  // rescanning the whole NestedClass table per lookup (#3721) — the BCL
  // reference pack carries thousands of NestedClass rows, and a nested-type
  // extern reference triggers one lookup per compile.
  nestedClassByEnclosing: Map[Int, List[Int]]
}

pub record MdrTypeDefRow {
  flags: Int
  name: String
  namespaceName: String
  extendsToken: Int          // TypeDefOrRef coded index (0 = no base class)
  fieldListStart: Int          // 1-based Field row
  methodListStart: Int          // 1-based MethodDef row
}

pub record MdrMethodDefRow {
  rva: Int
  implFlags: Int
  flags: Int
  name: String
  sigBlob: Int          // #Blob heap index of the MethodDefSig
  paramListStart: Int          // 1-based Param row
}

pub record MdrParamRow {
  flags: Int
  sequence: Int
  name: String
}

// A coded index is 2 bytes when the largest referenced table fits in
// (16 - tagBits) bits, else 4 bytes (ECMA-335 §II.24.2.6).
func codedWidth(maxRows: in Int, tagBits: in Int): Int {
  var limit = 1
  var k = 0
  while k < 16 - tagBits {
    limit = limit * 2
    k = k + 1
  }
  if maxRows < limit {
    2
  } else {
    4
  }
}

// A simple table index is 2 bytes when the table has fewer than 2^16 rows.
func simpleWidth(th: in TablesHeader, tableId: in Int): Int {
  if rowCountOf(th, tableId) < 65536 {
    2
  } else {
    4
  }
}

// Largest row count among a set of table ids (the input to a coded-index
// width decision).  Absent tables read 0.
func maxRowsOf(th: in TablesHeader, ids: in List[Int]): Int {
  var m = 0
  var i = 0
  while i < ids.count {
    val rc = rowCountOf(th, ids[i])
    if rc > m {
      m = rc
    }
    i = i + 1
  }
  m
}

// Coded-index width (2 or 4 bytes) for a tag family: 2 bytes when the largest
// referenced table fits in (16 - tagBits) bits.
func codedWidthFor(th: in TablesHeader, ids: in List[Int], tagBits: in Int): Int {
  codedWidth(maxRowsOf(th, ids), tagBits)
}

// Build a List[Int] of the given table ids — one small constructor per coded
// family so the width computations below read declaratively.
func tableIds(items: in slice[Int]): List[Int] {
  val l: List[Int] = newList()
  var i = 0
  while i < items.length {
    l.add(items[i])
    i = i + 1
  }
  l
}

// Compute the physical column widths, per-table row sizes, and table data
// offsets for every ECMA-335 §II.22 table (ids 0x00..0x2C).  The earlier
// reader modelled only 0x00..0x08 (enough for TypeDef/MethodDef/Param); the
// full schema is needed to locate higher tables such as ManifestResource
// (0x28), whose offset is the cumulative size of every preceding present
// table.  Coded-index widths follow §II.24.2.6; the per-table column layouts
// follow §II.22.  Tables above 0x2C are never present in a regular assembly's
// `#~` stream, so their row sizes stay 0 (and contribute 0 to any offset).
pub func computeLayout(img: in PeImage, root: in MetadataRoot, th: in TablesHeader): Result[TableLayout, String] {
  val stringIdx = if th.stringsWide { 4 } else { 2 }
  val guidIdx = if th.guidWide { 4 } else { 2 }
  val blobIdx = if th.blobWide { 4 } else { 2 }

  // Simple (single-table) index widths.
  val fieldIdx = simpleWidth(th, 0x04)
  val methodIdx = simpleWidth(th, 0x06)
  val paramIdx = simpleWidth(th, 0x08)
  val typeDefIdx = simpleWidth(th, 0x02)
  val eventIdx = simpleWidth(th, 0x14)
  val propertyIdx = simpleWidth(th, 0x17)
  val moduleRefIdx = simpleWidth(th, 0x1A)
  val assemblyRefIdx = simpleWidth(th, 0x23)
  val genericParamIdx = simpleWidth(th, 0x2A)

  // Coded-index widths (ECMA-335 §II.24.2.6).
  val rsIdx = codedWidthFor(th, tableIds([0x00, 0x1A, 0x23, 0x01]), 2)              // ResolutionScope
  val tdrIdx = codedWidthFor(th, tableIds([0x02, 0x01, 0x1B]), 2)                   // TypeDefOrRef
  val hasConstIdx = codedWidthFor(th, tableIds([0x04, 0x08, 0x17]), 2)             // HasConstant
  val hasCAIdx = codedWidthFor(
    th,
    tableIds(
      [
        0x06,
        0x04,
        0x01,
        0x02,
        0x08,
        0x09,
        0x0A,
        0x00,
        0x0E,
        0x17,
        0x14,
        0x11,
        0x1A,
        0x1B,
        0x20,
        0x23,
        0x26,
        0x27,
        0x28,
        0x2A,
        0x2C,
        0x2B
      ]
    ),
    5
  )                                                                                 // HasCustomAttribute
  val hasFMIdx = codedWidthFor(th, tableIds([0x04, 0x08]), 1)                       // HasFieldMarshal
  val hasDeclSecIdx = codedWidthFor(th, tableIds([0x02, 0x06, 0x20]), 2)           // HasDeclSecurity
  val memberRefParentIdx = codedWidthFor(th, tableIds([0x02, 0x01, 0x1A, 0x06, 0x1B]), 3)  // MemberRefParent
  val hasSemanticsIdx = codedWidthFor(th, tableIds([0x14, 0x17]), 1)               // HasSemantics
  val methodDefOrRefIdx = codedWidthFor(th, tableIds([0x06, 0x0A]), 1)             // MethodDefOrRef
  val memberForwardedIdx = codedWidthFor(th, tableIds([0x04, 0x06]), 1)            // MemberForwarded
  val implementationIdx = codedWidthFor(th, tableIds([0x26, 0x23, 0x27]), 2)       // Implementation
  val custAttrTypeIdx = codedWidthFor(th, tableIds([0x06, 0x0A]), 3)               // CustomAttributeType
  val typeOrMethodDefIdx = codedWidthFor(th, tableIds([0x02, 0x06]), 1)            // TypeOrMethodDef

  val rowSize: List[Int] = newList()
  var z = 0
  while z < 64 {
    rowSize.add(0)
    z = z + 1
  }
  rowSize[0x00] = 2 + stringIdx + 3 * guidIdx                              // Module
  rowSize[0x01] = rsIdx + 2 * stringIdx                                    // TypeRef
  rowSize[0x02] = 4 + 2 * stringIdx + tdrIdx + fieldIdx + methodIdx        // TypeDef
  rowSize[0x03] = fieldIdx                                                 // FieldPtr
  rowSize[0x04] = 2 + stringIdx + blobIdx                                  // Field
  rowSize[0x05] = methodIdx                                                // MethodPtr
  rowSize[0x06] = 4 + 2 + 2 + stringIdx + blobIdx + paramIdx               // MethodDef
  rowSize[0x07] = paramIdx                                                 // ParamPtr
  rowSize[0x08] = 2 + 2 + stringIdx                                        // Param
  rowSize[0x09] = typeDefIdx + tdrIdx                                      // InterfaceImpl
  rowSize[0x0A] = memberRefParentIdx + stringIdx + blobIdx                 // MemberRef
  rowSize[0x0B] = 2 + hasConstIdx + blobIdx                                // Constant (Type u1 + pad u1)
  rowSize[0x0C] = hasCAIdx + custAttrTypeIdx + blobIdx                     // CustomAttribute
  rowSize[0x0D] = hasFMIdx + blobIdx                                       // FieldMarshal
  rowSize[0x0E] = 2 + hasDeclSecIdx + blobIdx                              // DeclSecurity
  rowSize[0x0F] = 2 + 4 + typeDefIdx                                       // ClassLayout
  rowSize[0x10] = 4 + fieldIdx                                             // FieldLayout
  rowSize[0x11] = blobIdx                                                  // StandAloneSig
  rowSize[0x12] = typeDefIdx + eventIdx                                    // EventMap
  rowSize[0x13] = eventIdx                                                 // EventPtr
  rowSize[0x14] = 2 + stringIdx + tdrIdx                                   // Event
  rowSize[0x15] = typeDefIdx + propertyIdx                                 // PropertyMap
  rowSize[0x16] = propertyIdx                                              // PropertyPtr
  rowSize[0x17] = 2 + stringIdx + blobIdx                                  // Property
  rowSize[0x18] = 2 + methodIdx + hasSemanticsIdx                          // MethodSemantics
  rowSize[0x19] = typeDefIdx + 2 * methodDefOrRefIdx                       // MethodImpl
  rowSize[0x1A] = stringIdx                                                // ModuleRef
  rowSize[0x1B] = blobIdx                                                  // TypeSpec
  rowSize[0x1C] = 2 + memberForwardedIdx + stringIdx + moduleRefIdx        // ImplMap
  rowSize[0x1D] = 4 + fieldIdx                                             // FieldRVA
  rowSize[0x1E] = 4 + 4                                                    // EncLog
  rowSize[0x1F] = 4                                                        // EncMap
  rowSize[0x20] = 4 + 2 + 2 + 2 + 2 + 4 + blobIdx + 2 * stringIdx          // Assembly
  rowSize[0x21] = 4                                                        // AssemblyProcessor
  rowSize[0x22] = 4 + 4 + 4                                                // AssemblyOS
  rowSize[0x23] = 2 + 2 + 2 + 2 + 4 + blobIdx + 2 * stringIdx + blobIdx    // AssemblyRef
  rowSize[0x24] = 4 + assemblyRefIdx                                       // AssemblyRefProcessor
  rowSize[0x25] = 4 + 4 + 4 + assemblyRefIdx                               // AssemblyRefOS
  rowSize[0x26] = 4 + stringIdx + blobIdx                                  // File
  rowSize[0x27] = 4 + 4 + 2 * stringIdx + implementationIdx                // ExportedType
  rowSize[0x28] = 4 + 4 + stringIdx + implementationIdx                    // ManifestResource
  rowSize[0x29] = 2 * typeDefIdx                                           // NestedClass
  rowSize[0x2A] = 2 + 2 + typeOrMethodDefIdx + stringIdx                   // GenericParam
  rowSize[0x2B] = methodDefOrRefIdx + blobIdx                              // MethodSpec
  rowSize[0x2C] = genericParamIdx + tdrIdx                                 // GenericParamConstraint

  val dataStart: List[Int] = newList()
  var z2 = 0
  while z2 < 64 {
    dataStart.add(0)
    z2 = z2 + 1
  }
  var off = th.tablesDataOff
  var tid = 0
  while tid < 64 {
    dataStart[tid] = off
    off = off + rowCountOf(th, tid) * rowSize[tid]
    tid = tid + 1
  }

  val stringsBase = match findStream(root, "#Strings") { case Some(s) -> s.fileOff; case None -> -1 }
  val blobBase = match findStream(root, "#Blob") { case Some(s) -> s.fileOff; case None -> -1 }

  // Pre-index NestedClass (0x29): enclosing TypeDef row → its nested TypeDef
  // rows.  One O(n) scan here replaces an O(n) rescan on every nested-type
  // lookup in `findTypeDefByFqn` (#3721).
  val nestedClassByEnclosing: Map[Int, List[Int]] = newMap()
  val nestedRowCount = rowCountOf(th, 0x29)
  var ncRow = 0
  while ncRow < nestedRowCount {
    val ncOff = dataStart[0x29] + ncRow * rowSize[0x29]
    val nestedTd = rdIdx(img.bytes, ncOff, typeDefIdx)
    val enclosingTd = rdIdx(img.bytes, ncOff + typeDefIdx, typeDefIdx)
    match mapGet(nestedClassByEnclosing, enclosingTd) {
      case Some(existing) -> existing.add(nestedTd)
      case None -> {
        val fresh: List[Int] = newList()
        fresh.add(nestedTd)
        nestedClassByEnclosing.add(enclosingTd, fresh)
      }
    }
    ncRow = ncRow + 1
  }

  Ok(
    value = TableLayout(
      stringIdx = stringIdx,
      guidIdx = guidIdx,
      blobIdx = blobIdx,
      typeDefOrRefIdx = tdrIdx,
      resolutionScopeIdx = rsIdx,
      implementationIdx = implementationIdx,
      fieldIdx = fieldIdx,
      methodIdx = methodIdx,
      paramIdx = paramIdx,
      typeDefIdx = typeDefIdx,
      rowSize = rowSize,
      dataStart = dataStart,
      stringsBase = stringsBase,
      blobBase = blobBase,
      nestedClassByEnclosing = nestedClassByEnclosing
    )
  )
}

// Read a heap or simple/coded index of `width` (2 or 4) bytes.
func rdIdx(b: in slice[Byte], o: in Int, width: in Int): Int {
  if width == 2 {
    rdU16(b, o)
  } else {
    rdU32(b, o)
  }
}

// Resolve a #Strings heap index to its string value ("" for index 0).
pub func stringAt(img: in PeImage, layout: in TableLayout, strIndex: in Int): String {
  if strIndex == 0 or layout.stringsBase < 0 {
    return ""
  }
  readUtf8Z(img.bytes, layout.stringsBase + strIndex)
}

// Resolve a #Blob heap index to its raw bytes (length-prefixed; empty for 0).
pub func blobAt(img: in PeImage, layout: in TableLayout, blobIndex: in Int): slice[Byte] {
  val empty: List[Byte] = newList()
  if blobIndex == 0 or layout.blobBase < 0 {
    return empty.toArray()
  }
  val b = img.bytes
  // A rejected length header (reserved lead byte, truncated read) means the
  // index does not point at a well-formed blob.  This function has no error
  // channel, so surface it as the empty blob — `decodeMethodSig` then rejects
  // the empty blob with a clear `Err` instead of decoding misaligned bytes.
  match readCompressedUInt(b, layout.blobBase + blobIndex) {
    case Err(_) -> empty.toArray()
    case Ok(hdr) -> {
      val start = layout.blobBase + blobIndex + hdr.byteWidth
      val acc: List[Byte] = newList()
      var i = 0
      while i < hdr.value and start + i < b.length {
        acc.add(b[start + i])
        i = i + 1
      }
      acc.toArray()
    }
  }
}

// Read TypeDef row `row` (1-based).  Columns (ECMA §II.22.37):
// Flags(u32), Name(#String), Namespace(#String), Extends(TypeDefOrRef),
// FieldList(Field), MethodList(MethodDef).
pub func readTypeDef(img: in PeImage, layout: in TableLayout, row: in Int): MdrTypeDefRow {
  // Row indices are 1-based per ECMA-335 §II.22; row 0 underflows the table.
  if row < 1 {
    panic("Msil.MetadataReader.readTypeDef: row must be >= 1, got " + toString(row))
  }
  val b = img.bytes
  val o = layout.dataStart[0x02] + (row - 1) * layout.rowSize[0x02]
  val flags = rdU32(b, o)
  var p = o + 4
  val nameI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val nsI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val ext = rdIdx(b, p, layout.typeDefOrRefIdx)
  p = p + layout.typeDefOrRefIdx
  val fieldL = rdIdx(b, p, layout.fieldIdx)
  p = p + layout.fieldIdx
  val methodL = rdIdx(b, p, layout.methodIdx)
  MdrTypeDefRow(
    flags = flags,
    name = stringAt(img, layout, nameI),
    namespaceName = stringAt(img, layout, nsI),
    extendsToken = ext,
    fieldListStart = fieldL,
    methodListStart = methodL
  )
}

// A TypeRef row's name, namespace, and ResolutionScope coded token (ECMA
// §II.22.38).  The ResolutionScope is needed to name a NESTED type: a nested
// TypeRef carries an EMPTY namespace and its ResolutionScope is the enclosing
// TypeRef (tag 3 of the ResolutionScope coded index), so the full name is
// `<enclosing>+<name>`.
pub record MdrTypeRefRow {
  name: String
  namespaceName: String
  resolutionScope: Int
}

// Read TypeRef row `row` (1-based).  Columns: ResolutionScope(coded),
// Name(#String), Namespace(#String).
pub func readTypeRef(img: in PeImage, layout: in TableLayout, row: in Int): MdrTypeRefRow {
  val b = img.bytes
  val o = layout.dataStart[0x01] + (row - 1) * layout.rowSize[0x01]
  val rs = rdIdx(b, o, layout.resolutionScopeIdx)
  var p = o + layout.resolutionScopeIdx
  val nameI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val nsI = rdIdx(b, p, layout.stringIdx)
  MdrTypeRefRow(name = stringAt(img, layout, nameI), namespaceName = stringAt(img, layout, nsI), resolutionScope = rs)
}

// A NestedClass row mapping (ECMA §II.22.32).
pub record NestedClassRow {
  nestedTypeDef: Int          // TypeDef index of the nested type
  enclosingTypeDef: Int       // TypeDef index of the outer type
}

// Read NestedClass row `row` (1-based).  Columns: NestedClass(TypeDef),
// EnclosingClass(TypeDef).  Maps nested types to their declaring outer type.
pub func readNestedClass(img: in PeImage, layout: in TableLayout, row: in Int): NestedClassRow {
  if row < 1 {
    panic("Msil.MetadataReader.readNestedClass: row must be >= 1, got " + toString(row))
  }
  val b = img.bytes
  val o = layout.dataStart[0x29] + (row - 1) * layout.rowSize[0x29]
  val nestedI = rdIdx(b, o, layout.typeDefIdx)
  val enclosingI = rdIdx(b, o + layout.typeDefIdx, layout.typeDefIdx)
  NestedClassRow(nestedTypeDef = nestedI, enclosingTypeDef = enclosingI)
}

// The enclosing TypeDef row of nested TypeDef `row`, or -1 if `row` is not
// nested.  Scans the NestedClass table (ECMA §II.22.32) for the row whose
// NestedClass column equals `row`.
func enclosingTypeDefRow(img: in PeImage, layout: in TableLayout, th: in TablesHeader, row: in Int): Int {
  val n = rowCountOf(th, 0x29)
  var i = 1
  while i <= n {
    val nc = readNestedClass(img, layout, i)
    if nc.nestedTypeDef == row {
      return nc.enclosingTypeDef
    }
    i = i + 1
  }
  -1
}

// Resolve a TypeDefOrRef coded index (the 2-bit-tagged token a CLASS /
// VALUETYPE / GENERICINST signature carries) to the referenced type's
// fully-qualified name.  Tag 0 = TypeDef, 1 = TypeRef, 2 = TypeSpec.
// TypeSpec (generic instantiations etc.) and out-of-range rows return "".
//
// NESTED types are named `<enclosing>+<nested>` (ECMA §II.22.38 / II.14.4): a
// nested type carries an EMPTY namespace, so without the enclosing chain a
// method whose signature mentions a nested type (e.g. `JsonElement.
// EnumerateArray(): JsonElement+ArrayEnumerator`) resolved its return type to a
// bare `ArrayEnumerator` that `resolvedSigToMsil` could not map — which made the
// metadata-direct extern resolver bail and fall back to the static-call guess,
// emitting an instance method as static (MissingMethodException, #3943).  A
// nested TypeDef is detected via the NestedClass table; a nested TypeRef via a
// ResolutionScope whose coded tag is TypeRef (3).
pub func resolveTypeDefOrRefName(
  img: in PeImage, layout: in TableLayout, th: in TablesHeader, codedToken: in Int
): String {
  val tag = codedToken % 4
  val row = codedToken / 4
  if row <= 0 {
    return ""
  }
  if tag == 0 {
    if row > rowCountOf(th, 0x02) {
      return ""
    }
    val td = readTypeDef(img, layout, row)
    if td.namespaceName.length > 0 {
      td.namespaceName + "." + td.name
    } else {
      val encRow = enclosingTypeDefRow(img, layout, th, row)
      if encRow > 0 {
        val encFqn = resolveTypeDefOrRefName(img, layout, th, encRow * 4)
        if encFqn.length > 0 {
          encFqn + "+" + td.name
        } else {
          td.name
        }
      } else {
        td.name
      }
    }
  } else if tag == 1 {
    if row > rowCountOf(th, 0x01) {
      return ""
    }
    val tr = readTypeRef(img, layout, row)
    if tr.namespaceName.length > 0 {
      tr.namespaceName + "." + tr.name
    } else {
      val rsTag = tr.resolutionScope % 4
      val rsRow = tr.resolutionScope / 4
      if rsTag == 3 and rsRow > 0 {
        val encFqn = resolveTypeDefOrRefName(img, layout, th, rsRow * 4 + 1)
        if encFqn.length > 0 {
          encFqn + "+" + tr.name
        } else {
          tr.name
        }
      } else {
        tr.name
      }
    }
  } else {
    ""
  }
}

// Read MethodDef row `row` (1-based).  Columns (ECMA §II.22.26):
// RVA(u32), ImplFlags(u16), Flags(u16), Name(#String), Signature(#Blob),
// ParamList(Param).
pub func readMethodDef(img: in PeImage, layout: in TableLayout, row: in Int): MdrMethodDefRow {
  // Row indices are 1-based per ECMA-335 §II.22; row 0 underflows the table.
  if row < 1 {
    panic("Msil.MetadataReader.readMethodDef: row must be >= 1, got " + toString(row))
  }
  val b = img.bytes
  val o = layout.dataStart[0x06] + (row - 1) * layout.rowSize[0x06]
  val rva = rdU32(b, o)
  val implFlags = rdU16(b, o + 4)
  val flags = rdU16(b, o + 6)
  var p = o + 8
  val nameI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val sigI = rdIdx(b, p, layout.blobIdx)
  p = p + layout.blobIdx
  val paramL = rdIdx(b, p, layout.paramIdx)
  MdrMethodDefRow(
    rva = rva,
    implFlags = implFlags,
    flags = flags,
    name = stringAt(img, layout, nameI),
    sigBlob = sigI,
    paramListStart = paramL
  )
}

// Read Param row `row` (1-based).  Columns (ECMA §II.22.33):
// Flags(u16), Sequence(u16), Name(#String).
pub func readParam(img: in PeImage, layout: in TableLayout, row: in Int): MdrParamRow {
  // Row indices are 1-based per ECMA-335 §II.22; row 0 underflows the table.
  if row < 1 {
    panic("Msil.MetadataReader.readParam: row must be >= 1, got " + toString(row))
  }
  val b = img.bytes
  val o = layout.dataStart[0x08] + (row - 1) * layout.rowSize[0x08]
  val flags = rdU16(b, o)
  val seq = rdU16(b, o + 2)
  val nameI = rdIdx(b, o + 4, layout.stringIdx)
  MdrParamRow(flags = flags, sequence = seq, name = stringAt(img, layout, nameI))
}

// An Assembly row (ECMA-335 §II.22.2).
pub record MdrAssemblyRow {
  hashAlgId: Int
  majorVersion: Int
  minorVersion: Int
  buildNumber: Int
  revisionNumber: Int
  flags: Int
  name: String
  culture: String
}

// Read Assembly row `row` (1-based). Columns:
// HashAlgId(u32), MajorVersion(u16), MinorVersion(u16), BuildNumber(u16),
// RevisionNumber(u16), Flags(u32), PublicKey(#Blob), Name(#String), Culture(#String).
pub func readAssembly(img: in PeImage, layout: in TableLayout, row: in Int): MdrAssemblyRow {
  if row < 1 {
    panic("Msil.MetadataReader.readAssembly: row must be >= 1, got " + toString(row))
  }
  val b = img.bytes
  val o = layout.dataStart[0x20] + (row - 1) * layout.rowSize[0x20]
  val hashAlgId = rdU32(b, o)
  val major = rdU16(b, o + 4)
  val minor = rdU16(b, o + 6)
  val build = rdU16(b, o + 8)
  val revision = rdU16(b, o + 10)
  val flags = rdU32(b, o + 12)
  var p = o + 16
  p = p + layout.blobIdx // skip PublicKey (#Blob index; not needed by MdrAssemblyRow)
  val nameI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val cultureI = rdIdx(b, p, layout.stringIdx)
  MdrAssemblyRow(
    hashAlgId = hashAlgId,
    majorVersion = major,
    minorVersion = minor,
    buildNumber = build,
    revisionNumber = revision,
    flags = flags,
    name = stringAt(img, layout, nameI),
    culture = stringAt(img, layout, cultureI)
  )
}

// Inclusive [start, end] 1-based MethodDef range owned by TypeDef `typeRow`,
// resolved from the run-length method-list ownership (a TypeDef owns the
// MethodDef rows from its MethodList up to the next TypeDef's MethodList, or
// the end of the MethodDef table for the last TypeDef).
pub record RowRange {
  start: Int    // 1-based, inclusive
  endRow: Int    // 1-based, inclusive; < start means empty
}

pub func methodRange(img: in PeImage, layout: in TableLayout, th: in TablesHeader, typeRow: in Int): RowRange {
  val start = readTypeDef(img, layout, typeRow).methodListStart
  val typeCount = rowCountOf(th, 0x02)
  val last = if typeRow < typeCount {
    readTypeDef(img, layout, typeRow + 1).methodListStart - 1
  } else {
    rowCountOf(th, 0x06)
  }
  RowRange(start = start, endRow = last)
}

// Inclusive [start, end] 1-based Field range (table 0x04) owned by TypeDef
// `typeRow` (the rows from this type's `fieldListStart` up to the next type's,
// exclusive).  Mirrors `methodRange`.
pub func fieldRange(img: in PeImage, layout: in TableLayout, th: in TablesHeader, typeRow: in Int): RowRange {
  val start = readTypeDef(img, layout, typeRow).fieldListStart
  val typeCount = rowCountOf(th, 0x02)
  val last = if typeRow < typeCount {
    readTypeDef(img, layout, typeRow + 1).fieldListStart - 1
  } else {
    rowCountOf(th, 0x04)
  }
  RowRange(start = start, endRow = last)
}

// True iff `typeFqn` declares a STATIC field named `fieldName` (FieldAttributes
// Static = 0x0010, ECMA-335 §II.23.1.5).  Used to resolve an `@externTarget`
// that names a static field (e.g. `System.Diagnostics.Stopwatch.Frequency`,
// `System.Guid.Empty`) so the MSIL backend emits `ldsfld` instead of mis-
// emitting a method call.  Reads the Field table directly: flags(u16) +
// name(#String) + sig(#Blob).
pub func isStaticFieldExternIn(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  typeFqn: in String,
  fieldName: in String,
): Bool {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return false
  }
  val fr = fieldRange(img, layout, th, typeRow)
  val b = img.bytes
  var row = fr.start
  while row <= fr.endRow {
    val o = layout.dataStart[0x04] + (row - 1) * layout.rowSize[0x04]
    val flags = rdU16(b, o)
    val nameI = rdIdx(b, o + 2, layout.stringIdx)
    val nm = stringAt(img, layout, nameI)
    if nm == fieldName {
      return (flags / 16) % 2 == 1
    }
    row = row + 1
  }
  false
}

// Read-from-disk wrapper over `isStaticFieldExternIn`.
pub func isStaticFieldExtern(asmPath: in String, typeFqn: in String, fieldName: in String): Bool {
  match File.readBytes(asmPath) {
    case Err(_) -> false
    case Ok(raw) -> match readPe(raw.toArray()) { case Err(_) -> false; case Ok(img) -> match readMetadataRoot(img) { case Err(_) -> false; case Ok(root) -> match readTablesHeader(img, root) { case Err(_) -> false; case Ok(th) -> match computeLayout(img, root, th) { case Err(_) -> false; case Ok(layout) -> isStaticFieldExternIn(img, layout, th, typeFqn, fieldName) } } } }
  }
}

// Retrieves the constant value of an Int32 literal/enum field declared by typeFqn, or None.
pub func getLiteralFieldInt32In(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  typeFqn: in String,
  fieldName: in String,
): Option[Int] {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return None
  }
  val fr = fieldRange(img, layout, th, typeRow)
  val b = img.bytes
  var row = fr.start
  var foundFieldRow = -1
  while row <= fr.endRow {
    val o = layout.dataStart[0x04] + (row - 1) * layout.rowSize[0x04]
    val flags = rdU16(b, o)
    val nameI = rdIdx(b, o + 2, layout.stringIdx)
    val nm = stringAt(img, layout, nameI)
    if nm == fieldName {
      if (flags / 64) % 2 == 1 {
        foundFieldRow = row
      }
      break
    }
    row = row + 1
  }
  if foundFieldRow < 0 {
    return None
  }
  val parentIdx = foundFieldRow * 4 // HasConstant Field tag = 0
  val constCount = rowCountOf(th, 0x0B)
  var crow = 1
  val hasConstIdxWidth = codedWidthFor(th, tableIds([0x04, 0x08, 0x17]), 2)
  while crow <= constCount {
    val o = layout.dataStart[0x0B] + (crow - 1) * layout.rowSize[0x0B]
    val pVal = rdIdx(b, o + 2, hasConstIdxWidth)
    if pVal == parentIdx {
      val typeVal = b[o].toInt()
      if typeVal == 0x02 or typeVal == 0x03 or typeVal == 0x04 or typeVal == 0x05 or typeVal == 0x06 or typeVal == 0x07 or typeVal == 0x08 or typeVal == 0x09 {
        val blobIndex = rdIdx(b, o + 2 + hasConstIdxWidth, layout.blobIdx)
        val blobBytes = blobAt(img, layout, blobIndex)
        if blobBytes.length >= 4 {
          return Some(value = rdI32(blobBytes, 0))
        } else if blobBytes.length == 2 {
          // ELEMENT_TYPE_BOOLEAN (0x02) is unsigned per ECMA-335 §II.23.1.16;
          // I1 (0x04) and I4 (0x08) are signed but never produce a 2-byte blob
          // in conforming metadata (kept here only for defensiveness). I2
          // (0x06) is the only signed type that legitimately reaches this arm.
          val isSigned = typeVal == 0x04 or typeVal == 0x06 or typeVal == 0x08
          return Some(value = if isSigned { rdI16(blobBytes, 0) } else { rdU16(blobBytes, 0) })
        } else if blobBytes.length == 1 {
          return Some(value = blobBytes[0].toInt())
        }
      }
    }
    crow = crow + 1
  }
  None
}

// Read-from-disk wrapper over `getLiteralFieldInt32In`.
pub func getLiteralFieldInt32(asmPath: in String, typeFqn: in String, fieldName: in String): Option[Int] {
  match File.readBytes(asmPath) {
    case Err(_) -> None
    case Ok(raw) -> match readPe(raw.toArray()) {
      case Err(_) -> None
      case Ok(img) -> match readMetadataRoot(img) {
        case Err(_) -> None
        case Ok(root) -> match readTablesHeader(img, root) {
          case Err(_) -> None
          case Ok(th) -> match computeLayout(img, root, th) {
            case Err(_) -> None
            case Ok(layout) -> getLiteralFieldInt32In(img, layout, th, typeFqn, fieldName)
          }
        }
      }
    }
  }
}


// ── Layer 5: signature-blob decoder ──────────────────────────────────────────
//
// Decodes a MethodDefSig / MethodRefSig blob (ECMA-335 §II.23.2.1) into a
// typed shape.  This is the inverse of the emitter's signature writers
// (`buildStaticMethodSig` / `buildInstanceMethodSig` + `bufMsilType`), but it
// handles the *full* element-type grammar so signatures from real reference
// assemblies — value types, by-ref/out parameters, generics, the complete
// primitive set — decode, not just the subset the Lyric writer emits.
// A decoded signature type.  Primitives (VOID, BOOLEAN, CHAR, I1..U8, R4, R8,
// STRING, OBJECT, I, U, TYPEDBYREF) are carried by their element-type byte;
// structured types get their own case.
pub union SigType {
  case STPrim(elemByte: Int)
  case STClass(token: Int)               // ELEMENT_TYPE_CLASS + TypeDefOrRef
  case STValueType(token: Int)           // ELEMENT_TYPE_VALUETYPE + TypeDefOrRef
  case STVar(index: Int)                 // generic type parameter
  case STMVar(index: Int)                // generic method parameter
  case STSzArray(elem: SigType)          // single-dimension zero-based array
  case STArray(elem: SigType, rank: Int) // general (multi-dim) array
  case STByRef(inner: SigType)           // by-ref / out / ref parameter
  case STPtr(inner: SigType)             // unmanaged pointer
  case STGenericInst(valueType: Bool, token: Int, args: List[SigType])
  case STFnPtr                           // function pointer (sig skipped)
  case STUnknown(elemByte: Int)          // unrecognised element type
  // A CLASS / VALUETYPE resolved to its fully-qualified type name.  The decoder
  // never produces this (it can't name a token); `resolveOverloadIn` normalises
  // an `STClass`/`STValueType` token into it so resolved types and the caller's
  // argument types compare by name rather than by cross-assembly token.
  case STNamed(fqn: String, valueType: Bool)
  // A `STGenericInst` whose head token has been resolved to a fully-qualified
  // name and whose args have been recursively normalised.  Produced by
  // `resolveSigTypeFqn` (the existing call site that already collapses
  // `STClass`/`STValueType` into `STNamed`) so the iface MemberRef shape
  // can be compared across assemblies without tokens.  D105 §A's structural
  // validation consumes this form for nested generic iface methods like
  // `IEnumerable<T>.GetEnumerator(): IEnumerator<T>`.
  case STNamedGenericInst(fqn: String, valueType: Bool, args: List[SigType])
}

pub record DecodedMethodSig {
  hasThis: Bool
  isGeneric: Bool
  genParamCount: Int
  returnType: SigType
  paramTypes: List[SigType]
}

// Element-type bytes that decode to a leaf primitive `STPrim`.
func isPrimByte(et: in Int): Bool {
  (et >= 0x01 and et <= 0x0E) or et == 0x16 or et == 0x18 or et == 0x19 or et == 0x1C
}

// Result of decoding one type: the type plus the offset just past it.
pub record DecodedType {
  ty: SigType
  next: Int
}

// Poison result for an undecodable type: `STUnknown` never matches an
// overload, and `next = b.length` halts every enclosing decode loop.  A
// rejected compressed integer (reserved lead byte, truncated read, #1878)
// thus degrades to "no resolution" instead of a silently misaligned decode.
func undecodableType(b: in slice[Byte], elemByte: in Int): DecodedType {
  DecodedType(ty = STUnknown(elemByte = elemByte), next = b.length)
}

// Decode one Type at offset `o`, skipping any leading custom modifiers
// (CMOD_OPT / CMOD_REQD).
pub func decodeType(b: in slice[Byte], o: in Int): DecodedType {
  var p = o
  // Skip custom modifiers: (CMOD_OPT 0x20 | CMOD_REQD 0x1F) + TypeDefOrRef.
  while p < b.length and (rdU8(b, p) == 0x1F or rdU8(b, p) == 0x20) {
    val cmByte = rdU8(b, p)
    p = p + 1
    match readCompressedUInt(b, p) {
      case Err(_) -> return undecodableType(b, cmByte)
      case Ok(cm) -> {
        p = p + cm.byteWidth
      }
    }
  }
  // A truncated blob (or a poisoned offset from a failed inner decode) can
  // land exactly on the end; degrade rather than read out of bounds.
  if p < 0 or p >= b.length {
    return undecodableType(b, 0)
  }
  val et = rdU8(b, p)
  p = p + 1
  if et == 0x11 or et == 0x12 {
    match readCompressedUInt(b, p) {
      case Err(_) -> undecodableType(b, et)
      case Ok(tok) -> {
        val ty = if et == 0x11 { STValueType(token = tok.value) } else { STClass(token = tok.value) }
        DecodedType(ty = ty, next = p + tok.byteWidth)
      }
    }
  } else if et == 0x13 or et == 0x1E {
    match readCompressedUInt(b, p) {
      case Err(_) -> undecodableType(b, et)
      case Ok(n) -> {
        val ty = if et == 0x13 { STVar(index = n.value) } else { STMVar(index = n.value) }
        DecodedType(ty = ty, next = p + n.byteWidth)
      }
    }
  } else if et == 0x1D {
    val inner = decodeType(b, p)
    DecodedType(ty = STSzArray(elem = inner.ty), next = inner.next)
  } else if et == 0x10 {
    val inner = decodeType(b, p)
    DecodedType(ty = STByRef(inner = inner.ty), next = inner.next)
  } else if et == 0x0F {
    val inner = decodeType(b, p)
    DecodedType(ty = STPtr(inner = inner.ty), next = inner.next)
  } else if et == 0x15 {
    // GENERICINST (CLASS|VALUETYPE) TypeDefOrRef GenArgCount Type*
    val kind = rdU8(b, p)
    var cur = p + 1
    var tokValue = 0
    match readCompressedUInt(b, cur) {
      case Err(_) -> return undecodableType(b, et)
      case Ok(tok) -> {
        tokValue = tok.value
        cur = cur + tok.byteWidth
      }
    }
    var argCount = 0
    match readCompressedUInt(b, cur) {
      case Err(_) -> return undecodableType(b, et)
      case Ok(cnt) -> {
        argCount = cnt.value
        cur = cur + cnt.byteWidth
      }
    }
    val args: List[SigType] = newList()
    var i = 0
    while i < argCount and cur < b.length {
      val a = decodeType(b, cur)
      args.add(a.ty)
      cur = a.next
      i = i + 1
    }
    DecodedType(ty = STGenericInst(valueType = kind == 0x11, token = tokValue, args = args), next = cur)
  } else if et == 0x14 {
    // ARRAY Type ArrayShape(rank numSizes size* numLoBounds loBound*)
    val inner = decodeType(b, p)
    var cur = inner.next
    var rankValue = 0
    match readCompressedUInt(b, cur) {
      case Err(_) -> return undecodableType(b, et)
      case Ok(rank) -> {
        rankValue = rank.value
        cur = cur + rank.byteWidth
      }
    }
    var sizeCount = 0
    match readCompressedUInt(b, cur) {
      case Err(_) -> return undecodableType(b, et)
      case Ok(numSizes) -> {
        sizeCount = numSizes.value
        cur = cur + numSizes.byteWidth
      }
    }
    var i = 0
    while i < sizeCount {
      match readCompressedUInt(b, cur) {
        case Err(_) -> return undecodableType(b, et)
        case Ok(s) -> {
          cur = cur + s.byteWidth
        }
      }
      i = i + 1
    }
    var loCount = 0
    match readCompressedUInt(b, cur) {
      case Err(_) -> return undecodableType(b, et)
      case Ok(numLo) -> {
        loCount = numLo.value
        cur = cur + numLo.byteWidth
      }
    }
    var j = 0
    while j < loCount {
      match readCompressedUInt(b, cur) {
        case Err(_) -> return undecodableType(b, et)
        case Ok(s2) -> {
          cur = cur + s2.byteWidth
        }
      }
      j = j + 1
    }
    DecodedType(ty = STArray(elem = inner.ty, rank = rankValue), next = cur)
  } else if et == 0x1B {
    // FNPTR + MethodDefSig — decode the nested sig to advance past it.
    match decodeMethodSigAt(b, p) {
      case Err(_) -> undecodableType(b, et)
      case Ok(nested) -> DecodedType(ty = STFnPtr, next = nested.next)
    }
  } else if isPrimByte(et) {
    DecodedType(ty = STPrim(elemByte = et), next = p)
  } else {
    DecodedType(ty = STUnknown(elemByte = et), next = p)
  }
}

// Result of decoding a method signature: the signature plus the offset past it.
pub record DecodedMethodSigAt {
  sig: DecodedMethodSig
  next: Int
}

// Decode a MethodDefSig at offset `o` (used both at the blob root and for
// nested FNPTR signatures).  Returns `Err` when the signature header carries
// a malformed compressed integer (#1878) or starts past the end of the blob.
pub func decodeMethodSigAt(b: in slice[Byte], o: in Int): Result[DecodedMethodSigAt, String] {
  if o < 0 or o >= b.length {
    return Err(
      error = "metadata: method signature offset " + toString(o) + " is outside the blob (length " +
        toString(b.length) +
        ")"
    )
  }
  val cc = rdU8(b, o)
  var p = o + 1
  val hasThis = (cc / 32) % 2 == 1   // HASTHIS  (0x20)
  val isGeneric = (cc / 16) % 2 == 1   // GENERIC  (0x10)
  var genCount = 0
  if isGeneric {
    match readCompressedUInt(b, p) {
      case Err(e) -> return Err(error = e)
      case Ok(g) -> {
        genCount = g.value
        p = p + g.byteWidth
      }
    }
  }
  var paramCount = 0
  match readCompressedUInt(b, p) {
    case Err(e) -> return Err(error = e)
    case Ok(pc) -> {
      paramCount = pc.value
      p = p + pc.byteWidth
    }
  }
  val ret = decodeType(b, p)
  p = ret.next
  val params: List[SigType] = newList()
  var i = 0
  while i < paramCount and p < b.length {
    if rdU8(b, p) == 0x41 {
      // SENTINEL marks the start of vararg arguments; it sits between
      // parameters and does not itself consume a parameter slot.
      p = p + 1
    } else {
      val a = decodeType(b, p)
      params.add(a.ty)
      p = a.next
      i = i + 1
    }
  }
  Ok(
    value = DecodedMethodSigAt(
      sig = DecodedMethodSig(
        hasThis = hasThis,
        isGeneric = isGeneric,
        genParamCount = genCount,
        returnType = ret.ty,
        paramTypes = params
      ),
      next = p
    )
  )
}

// Decode a complete MethodDefSig blob.  Returns an error for an empty or
// malformed blob.
pub func decodeMethodSig(blob: in slice[Byte]): Result[DecodedMethodSig, String] {
  if blob.length == 0 {
    return Err(error = "metadata: empty method signature blob")
  }
  match decodeMethodSigAt(blob, 0) {
    case Err(e) -> Err(error = e)
    case Ok(d) -> Ok(value = d.sig)
  }
}

// Construct a primitive `SigType` from its ECMA element-type byte.  Exposed so
// callers in other packages (which cannot pattern-match or construct an
// imported union case directly) can build argument types for resolution.
pub func mkPrimSig(elemByte: in Int): SigType {
  STPrim(elemByte = elemByte)
}

// The primitive element-type byte of a `SigType`, or -1 for any non-primitive
// shape.  The cross-package accessor companion to `mkPrimSig`.
pub func sigPrimByte(t: in SigType): Int {
  match t {
    case STPrim(b) -> b
    case _ -> -1
  }
}

// The TypeDefOrRef token of a CLASS / VALUETYPE `SigType`, or -1 otherwise.
// Cross-package accessor (the bootstrap parser rejects package-qualified
// union-case patterns, so codegen can't match `case Mdr.STClass(t)` directly).
pub func sigClassToken(t: in SigType): Int {
  match t {
    case STClass(tok) -> tok
    case STValueType(tok) -> tok
    case _ -> -1
  }
}

// True when the `SigType` is a value type (VALUETYPE), false otherwise.
pub func sigIsValueType(t: in SigType): Bool {
  match t {
    case STValueType(_) -> true
    case _ -> false
  }
}

// Construct an `STNamed` (a class/value type identified by FQN).  The caller
// (codegen) uses this to describe a non-primitive argument by name.
pub func mkNamedSig(fqn: in String, valueType: in Bool): SigType {
  STNamed(fqn = fqn, valueType = valueType)
}

// The FQN of an `STNamed`, or "" for any other shape.  Cross-package accessor.
pub func sigNamedFqn(t: in SigType): String {
  match t {
    case STNamed(fqn, _) -> fqn
    case _ -> ""
  }
}

// The 0-based generic-type-parameter index when `t` is `STVar(i)`, else `None`.
// Used by D105 §A to map iface-method `STVar` shapes onto `MTypeVar` so the
// MemberRef signature substitutes correctly through the TypeSpec.
pub func sigVarIndex(t: in SigType): Option[Int] {
  match t {
    case STVar(idx) -> Some(value = idx)
    case _ -> None
  }
}

// Construct an `STSzArray(elem)`.  Cross-package accessor used by D105 §A's
// shape-lifting validation pass so callers can wrap a substituted element
// type without touching the union internals.
pub func mkSzArraySig(elem: in SigType): SigType {
  STSzArray(elem = elem)
}

// Element type of `t` when it is `STSzArray(elem)`, else `None`.
pub func sigSzArrayElem(t: in SigType): Option[SigType] {
  match t {
    case STSzArray(elem) -> Some(value = elem)
    case _ -> None
  }
}

// Construct an `STByRef(inner)`.  Cross-package accessor.
pub func mkByRefSig(inner: in SigType): SigType {
  STByRef(inner = inner)
}

// Inner type of `t` when it is `STByRef(inner)`, else `None`.
pub func sigByRefInner(t: in SigType): Option[SigType] {
  match t {
    case STByRef(inner) -> Some(value = inner)
    case _ -> None
  }
}

// Resolved generic instantiation parts: the closed type's head FQN, whether
// the head is a value type, and the per-position type arguments.  Bundled
// into a record so the cross-package accessor returns a single value that
// the codegen-side comparison can destructure without re-walking the union.
pub record NamedGenericInstParts {
  fqn: String
  valueType: Bool
  args: List[SigType]
}

// Construct an `STNamedGenericInst(fqn, valueType, args)`.
pub func mkNamedGenericInstSig(fqn: in String, valueType: in Bool, args: in List[SigType]): SigType {
  STNamedGenericInst(fqn = fqn, valueType = valueType, args = args)
}

// FQN/valueType/args of `t` when it is `STNamedGenericInst`, else `None`.
pub func sigNamedGenericInstParts(t: in SigType): Option[NamedGenericInstParts] {
  match t {
    case STNamedGenericInst(fqn, vt, args) -> Some(value = NamedGenericInstParts(fqn = fqn, valueType = vt, args = args))
    case _ -> None
  }
}

// Substitute every `STVar(i)` occurrence in `s` with `typeArgs[i]`.  Used by
// D105 §A's F0022/F0023 validation pass to compare an iface method's
// signature (which carries `STVar` for each iface generic param) against
// the impl method's concrete signature.  Out-of-range `STVar(i)` (i.e.
// `i >= typeArgs.count`) is left unchanged — defensive default for
// malformed metadata that the upstream consumer treats as a "can't verify"
// case.  `STMVar`, `STPtr`, `STFnPtr`, and `STUnknown` are passed through;
// the v1 F0022/F0023 cut bails on those upstream via `sigHasGenericOrByRefMsil`.
pub func substituteVarsInSigType(s: in SigType, typeArgs: in List[SigType]): SigType {
  match s {
    case STVar(idx) -> {
      if idx >= 0 and idx < typeArgs.count {
        typeArgs[idx]
      } else {
        s
      }
    }
    case STSzArray(elem) -> STSzArray(elem = substituteVarsInSigType(elem, typeArgs))
    case STArray(elem, rank) -> STArray(elem = substituteVarsInSigType(elem, typeArgs), rank = rank)
    case STByRef(inner) -> STByRef(inner = substituteVarsInSigType(inner, typeArgs))
    case STGenericInst(vt, tok, args) -> {
      val substArgs: List[SigType] = newList()
      var i = 0
      while i < args.count {
        substArgs.add(substituteVarsInSigType(args[i], typeArgs))
        i = i + 1
      }
      STGenericInst(valueType = vt, token = tok, args = substArgs)
    }
    case STNamedGenericInst(fqn, vt, args) -> {
      val substArgs: List[SigType] = newList()
      var i = 0
      while i < args.count {
        substArgs.add(substituteVarsInSigType(args[i], typeArgs))
        i = i + 1
      }
      STNamedGenericInst(fqn = fqn, valueType = vt, args = substArgs)
    }
    case _ -> s
  }
}

// True when the `SigType` is an `STNamed` value type.  Cross-package accessor.
pub func sigNamedIsValueType(t: in SigType): Bool {
  match t {
    case STNamed(_, vt) -> vt
    case _ -> false
  }
}

// ── Phase 3a: reference-assembly discovery + type→assembly index ──────────────
//
// To resolve an extern method's MemberRef the emitter must know which assembly
// hosts the CLR type.  Rather than a hardcoded prefix table, this derives the
// mapping from the on-disk reference assemblies: each ref assembly's TypeDef
// table is read and every public type's fully-qualified name is mapped to that
// assembly's simple name.  In the .NET reference pack the BCL types are real
// TypeDefs in their facade assembly (e.g. `System.Math` in `System.Runtime`,
// `System.Console` in `System.Console`), so a TypeDef-derived index is
// sufficient — no ExportedType/type-forward chasing is required.
// Index of the last path separator (`/` or `\`), or -1 when there is none.
func lastSepIndex(path: in String): Int {
  val a = match Str.lastIndexOf(path, "/") { case None -> -1; case Some(i) -> i }
  val b = match Str.lastIndexOf(path, "\\") { case None -> -1; case Some(i) -> i }
  if a > b {
    a
  } else {
    b
  }
}

// Strip a directory (either separator) + ".dll" extension to the assembly's
// simple name.
func assemblySimpleName(path: in String): String {
  val cut = lastSepIndex(path)
  val base = if cut < 0 { path } else { Str.substring(path, cut + 1, path.length - cut - 1) }
  if Str.endsWith(base, ".dll") {
    Str.substring(base, 0, base.length - 4)
  } else {
    base
  }
}

// True when `s` is non-empty and all ASCII/Unicode digits.
func isAllDigits(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    if not Ch.isDigit(s[i]) {
      return false
    }
    i = i + 1
  }
  true
}

// Strip a leading run of non-digit characters from `s` (e.g. "net10" → "10").
// Used by `dirVersionGreater` so TFM monikers compare numerically (#1813).
func stripLeadingAlpha(s: in String): String {
  var i = 0
  while i < s.length and not Ch.isDigit(s[i]) {
    i = i + 1
  }
  if i == 0 {
    s
  } else {
    Str.substring(s, i, s.length - i)
  }
}

// Natural-order "greater than": compare dot-separated components numerically
// after stripping any leading alpha prefix (so "net10" > "net9" — fixes #1813),
// falling back to code-point order when neither stripped form is all-digits.
func dirVersionGreater(a: in String, b: in String): Bool {
  val pa = Str.split(a, ".")
  val pb = Str.split(b, ".")
  var i = 0
  while i < pa.length and i < pb.length {
    val x = pa[i]
    val y = pb[i]
    if x != y {
      val xs = stripLeadingAlpha(x)
      val ys = stripLeadingAlpha(y)
      if isAllDigits(xs) and isAllDigits(ys) {
        return Parse.parseInt(xs) > Parse.parseInt(ys)
      } else {
        return x > y
      }
    }
    i = i + 1
  }
  pa.length > pb.length
}

// Pick the highest-versioned immediate subdirectory of `dir` (used to select
// the reference-pack version and target-framework folders, of which there is
// normally exactly one).
func pickHighestDir(dir: in String): Option[String] {
  match File.listDirs(dir) {
    case Err(_) -> None
    case Ok(names) -> {
      if names.count == 0 {
        return None
      }
      var best = names[0]
      var i = 1
      while i < names.count {
        if dirVersionGreater(names[i], best) {
          best = names[i]
        }
        i = i + 1
      }
      Some(value = best)
    }
  }
}

// Candidate .NET install roots, in priority order.
// KNOWN LIMITATION: the fallback set after `DOTNET_ROOT` is Unix-only (uses `$HOME`,
// not `%USERPROFILE%`; hardcodes `/usr/{share,lib}/dotnet`).  Windows support without
// `DOTNET_ROOT` set is tracked separately — set `DOTNET_ROOT` explicitly on Windows.
func candidateDotnetRoots(): List[String] {
  val roots: List[String] = newList()
  val dr = Environment.getVarOrDefault("DOTNET_ROOT", "")
  if dr.length > 0 {
    roots.add(dr)
  }
  val home = Environment.getVarOrDefault("HOME", "")
  if home.length > 0 {
    roots.add(Path.join(home, ".dotnet"))
  }
  roots.add("/usr/share/dotnet")
  roots.add("/usr/lib/dotnet")
  roots.add("/usr/local/share/dotnet")
  roots.add("/opt/homebrew/opt/dotnet/libexec")
  roots
}

// Locate the reference-assembly directory
// (`<root>/packs/Microsoft.NETCore.App.Ref/<version>/ref/<tfm>/`).
pub func refPackDir(): Option[String] {
  val roots = candidateDotnetRoots()
  var i = 0
  while i < roots.count {
    val packs = Path.join(roots[i], "packs/Microsoft.NETCore.App.Ref")
    if File.dirExists(packs) {
      match pickHighestDir(packs) {
        case Some(ver) -> {
          val refDir = Path.join(Path.join(packs, ver), "ref")
          if File.dirExists(refDir) {
            match pickHighestDir(refDir) {
              case Some(tfm) -> return Some(value = Path.join(refDir, tfm))
              case None -> {
              }
            }
          }
        }
        case None -> {
        }
      }
    }
    i = i + 1
  }
  None
}

// Human-readable trace of what `refPackDir()` tried, for the W0007 diagnostic
// in `Msil.Codegen.ensureMetadataIndex`.  Mirrors `refPackDir()`'s walk over
// `candidateDotnetRoots()` exactly but never returns early — it records the
// outcome at every root so a `None` result (reference pack not found on this
// machine) is actionable instead of a silent "everything falls back to
// System.Runtime" (#4698: this fallback is wrong for types like
// System.Console that live in their own dedicated facade, not forwarded via
// System.Runtime — and the silent failure mode is exactly what turned a
// single missing reference pack into an unreproducible-looking macOS-only
// TypeLoadException in Std.ConsoleHost).
pub func refPackDirDebugInfo(): String {
  val roots = candidateDotnetRoots()
  if roots.count == 0 {
    return "no candidate roots (DOTNET_ROOT and HOME both unset)"
  }
  var acc = ""
  var i = 0
  while i < roots.count {
    val root = roots[i]
    val packs = Path.join(root, "packs/Microsoft.NETCore.App.Ref")
    var line = root + " -> "
    if not File.dirExists(packs) {
      line = line + "no packs/Microsoft.NETCore.App.Ref"
    } else {
      match pickHighestDir(packs) {
        case None -> {
          line = line + "packs/Microsoft.NETCore.App.Ref exists but is empty"
        }
        case Some(ver) -> {
          val refDir = Path.join(Path.join(packs, ver), "ref")
          if not File.dirExists(refDir) {
            line = line + "version " + ver + " has no ref/ subdir"
          } else {
            match pickHighestDir(refDir) {
              case None -> {
                line = line + "version " + ver + "'s ref/ subdir is empty (no TFM)"
              }
              case Some(tfm) -> {
                line = line + "found " + Path.join(refDir, tfm)
              }
            }
          }
        }
      }
    }
    acc = if i == 0 { line } else { acc + "; " + line }
    i = i + 1
  }
  acc
}

// Full paths of every `*.dll` reference assembly directly inside `refDir`.
pub func enumRefAssemblies(refDir: in String): List[String] {
  val acc: List[String] = newList()
  match File.listFiles(refDir) {
    case Err(_) -> acc
    case Ok(names) -> {
      var i = 0
      while i < names.count {
        if Str.endsWith(names[i], ".dll") {
          acc.add(Path.join(refDir, names[i]))
        }
        i = i + 1
      }
      acc
    }
  }
}

// Record every public top-level TypeDef of the parsed image in `index`,
// mapping the type's fully-qualified name to `asmName`.  First writer wins
// (duplicates across facades are ignored).
func scanPublicTypes(ri: in ResourceImage, asmName: in String, index: in Map[String, String]): Unit {
  val n = rowCountOf(ri.th, 0x02)
  var i = 1
  while i <= n {
    val td = readTypeDef(ri.img, ri.layout, i)
    // Index only Public top-level types (TypeAttributes visibility
    // mask 0x07 == Public); this excludes `<Module>`, nested, and
    // non-public types, which are never extern-resolution targets.
    if (td.flags % 8) == 1 {
      val fqn = if td.namespaceName.length > 0 { td.namespaceName + "." + td.name } else { td.name }
      match mapGet(index, fqn) {
        case Some(_) -> {
        }
        case None -> index.add(fqn, asmName)
      }
    }
    i = i + 1
  }
}

// Record every public top-level value type (any type whose Extends field
// resolves to "System.ValueType" or "System.Enum") of the parsed image in
// `vtypeSet` (FQN → true).  First writer wins.  Also indexes public NESTED
// value types under their "Enclosing+Nested" FQN (see scanNestedValueTypes).
func scanValueTypes(ri: in ResourceImage, vtypeSet: in Map[String, Bool]): Unit {
  val n = rowCountOf(ri.th, 0x02)
  var i = 1
  while i <= n {
    val td = readTypeDef(ri.img, ri.layout, i)
    // Only public top-level types can be extern targets.
    if (td.flags % 8) == 1 and td.extendsToken > 0 {
      val extName = resolveTypeDefOrRefName(ri.img, ri.layout, ri.th, td.extendsToken)
      if extName == "System.ValueType" or extName == "System.Enum" {
        val fqn = if td.namespaceName.length > 0 { td.namespaceName + "." + td.name } else { td.name }
        match mapGet(vtypeSet, fqn) {
          case Some(_) -> {
          }
          case None -> vtypeSet.add(fqn, true)
        }
      }
    }
    i = i + 1
  }
  scanNestedValueTypes(ri, vtypeSet)
}

// Build a map from a nested TypeDef row → its enclosing TypeDef row by scanning
// the NestedClass table (0x29, ECMA-335 §II.22.32).  Used to form the
// "Enclosing+Nested" FQN of nested types.
func buildNestedClassMap(ri: in ResourceImage): Map[Int, Int] {
  val m: Map[Int, Int] = newMap()
  val n = rowCountOf(ri.th, 0x29)
  var i = 1
  while i <= n {
    val nc = readNestedClass(ri.img, ri.layout, i)
    if not m.containsKey(nc.nestedTypeDef) {
      m.add(nc.nestedTypeDef, nc.enclosingTypeDef)
    }
    i = i + 1
  }
  m
}

// Record every public NESTED value type of the parsed image in `vtypeSet`,
// keyed by its "Enclosing+Nested" CLR FQN (e.g.
// "System.Text.Json.JsonElement+ObjectEnumerator").  `scanValueTypes` is
// otherwise top-level only; nested value-typed externs (the JSON
// `ArrayEnumerator`/`ObjectEnumerator` structs) need this so the self-hosted
// emitter encodes them as ELEMENT_TYPE_VALUETYPE rather than CLASS in
// cross-package signatures (a CLASS-vs-VALUETYPE mismatch faults at run time
// with `Method not found`).  Single-level nesting (the only shape the stdlib
// `_kernel/` externs use today); deeper nesting would need a recursive
// enclosing-FQN walk.
func scanNestedValueTypes(ri: in ResourceImage, vtypeSet: in Map[String, Bool]): Unit {
  val nestedMap = buildNestedClassMap(ri)
  if nestedMap.count == 0 {
    return
  }
  val n = rowCountOf(ri.th, 0x02)
  var i = 1
  while i <= n {
    val td = readTypeDef(ri.img, ri.layout, i)
    // Nested visibility mask 0x07 == NestedPublic (2); only NestedPublic
    // types are reachable extern targets.
    if (td.flags % 8) == 2 and td.extendsToken > 0 {
      match mapGet(nestedMap, i) {
        case None -> {
        }
        case Some(enclosingRow) -> {
          val extName = resolveTypeDefOrRefName(ri.img, ri.layout, ri.th, td.extendsToken)
          if extName == "System.ValueType" or extName == "System.Enum" {
            val enc = readTypeDef(ri.img, ri.layout, enclosingRow)
            val encFqn = if enc.namespaceName.length > 0 { enc.namespaceName + "." + enc.name } else { enc.name }
            val fqn = encFqn + "+" + td.name
            if not vtypeSet.containsKey(fqn) {
              vtypeSet.add(fqn, true)
            }
          }
        }
      }
    }
    i = i + 1
  }
}

// Add every public top-level TypeDef in the assembly at `asmPath` to `index`,
// mapping the type's fully-qualified name to the assembly's simple name.
// Malformed or unreadable assemblies (read failure, bad PE/metadata) are
// skipped silently — a single broken DLL must not abort building the index.
pub func addAssemblyTypes(index: in Map[String, String], asmPath: in String): Unit {
  match File.readBytes(asmPath) {
    case Err(_) -> {
    }
    case Ok(raw) -> match parseAssemblyImage(raw.toArray()) { case None -> {  }; case Some(ri) -> scanPublicTypes(ri, assemblySimpleName(asmPath), index) }
  }
}

// Build a type-FQN → assembly-simple-name index over the given assemblies.
pub func buildTypeIndex(asmPaths: in List[String]): Map[String, String] {
  val index: Map[String, String] = newMap()
  var i = 0
  while i < asmPaths.count {
    addAssemblyTypes(index, asmPaths[i])
    i = i + 1
  }
  index
}

// Populate both a type→assembly-name index and an assembly-name→path index from
// one assembly, reading the DLL once.  First writer wins for each name.  Lets a
// caller (e.g. the emitter's lazy index build) fill both maps in a single pass.
pub func addAssemblyToIndexes(
  typeIndex: in Map[String, String], pathIndex: in Map[String, String], asmPath: in String
): Unit {
  val nm = assemblySimpleName(asmPath)
  match mapGet(pathIndex, nm) {
    case Some(_) -> {
    }
    case None -> pathIndex.add(nm, asmPath)
  }
  addAssemblyTypes(typeIndex, asmPath)
}

// Populate the type→assembly-name, assembly-name→path, and value-type indexes
// from one assembly with a single disk read and a single metadata parse — the
// merged form of `addAssemblyToIndexes` + `addAssemblyValueTypes` (#2147).
// First writer wins for every name; a malformed assembly is skipped (a single
// broken DLL must not abort building the index), but the skip is logged
// (W0006) rather than silent: every type the skipped assembly would have
// contributed silently falls back to the wrong owning assembly in
// `assemblyForTypeMsil` (e.g. the CoreLib-forwarding default "System.Runtime",
// which is wrong for a dedicated facade like System.Console), producing a
// TypeRef that compiles cleanly but throws `TypeLoadException` at first use —
// a failure mode with no build-time signal until this warning (#4698).
pub func addAssemblyToIndexesAndValueTypes(
  typeIndex: in Map[String, String],
  pathIndex: in Map[String, String],
  vtypeSet: in Map[String, Bool],
  asmPath: in String,
): Unit {
  val nm = assemblySimpleName(asmPath)
  match mapGet(pathIndex, nm) {
    case Some(_) -> {
    }
    case None -> pathIndex.add(nm, asmPath)
  }
  match File.readBytes(asmPath) {
    case Err(e) -> {
      val reason = match e {
        case InvalidPath(p, r) -> "invalid path: " + p + " (" + r + ")"
        case FileNotFound(p) -> "file not found: " + p
        case DirectoryNotFound(p) -> "directory not found: " + p
        case AlreadyExists(p) -> "already exists: " + p
        case PermissionDenied(p) -> "permission denied: " + p
        case IoError(p, msg) -> "I/O error for " + p + ": " + msg
        case EndOfInput(src) -> "end of input: " + src
        case KeyNotFound(k) -> "key not found: " + k
      }
      println(
        "W0006: addAssemblyToIndexesAndValueTypes: failed to read '" + asmPath + "' (" + reason +
          ") — its types will fall back to the default assembly in auto-FFI resolution"
      )
    }
    case Ok(raw) -> match parseAssemblyImage(raw.toArray()) {
      case None -> {
        println(
          "W0006: addAssemblyToIndexesAndValueTypes: failed to parse '" + asmPath +
            "' as a .NET assembly — its types will fall back to the default assembly in auto-FFI resolution"
        )
      }
      case Some(ri) -> { scanPublicTypes(ri, nm, typeIndex); scanValueTypes(ri, vtypeSet) }
    }
  }
}

// Resolve a CLR type's fully-qualified name to its owning assembly's simple
// name, or None when no indexed assembly defines it.
pub func assemblyForType(index: in Map[String, String], typeFqn: in String): Option[String] {
  match mapGet(index, typeFqn) {
    case Some(asmName) -> Some(asmName)
    case None -> {
      var lastSpecialIdx = -1
      var idx = 0
      while idx < typeFqn.length {
        val charStr = typeFqn.substring(idx, 1)
        if charStr == "+" or charStr == "." {
          lastSpecialIdx = idx
        }
        idx = idx + 1
      }
      if lastSpecialIdx >= 0 {
        assemblyForType(index, typeFqn.substring(0, lastSpecialIdx))
      } else {
        None
      }
    }
  }
}

// Scan the public TypeDef rows of `asmPath` and record each value type (any
// type whose Extends field resolves to "System.ValueType" or "System.Enum")
// in `vtypeSet` (FQN → true).  First writer wins.  Standalone variant of the
// value-type half of `addAssemblyToIndexesAndValueTypes`, which callers
// filling all three indexes should prefer (it reads the DLL once).
pub func addAssemblyValueTypes(vtypeSet: in Map[String, Bool], asmPath: in String): Unit {
  match File.readBytes(asmPath) {
    case Err(_) -> {
    }
    case Ok(raw) -> match parseAssemblyImage(raw.toArray()) { case None -> {  }; case Some(ri) -> scanValueTypes(ri, vtypeSet) }
  }
}

// True when `typeFqn` is a value type (struct or enum) according to the
// metadata-derived vtypeSet built by addAssemblyValueTypes.
pub func isValueTypeFqn(vtypeSet: in Map[String, Bool], typeFqn: in String): Bool {
  match mapGet(vtypeSet, typeFqn) {
    case None -> false
    case Some(_) -> true
  }
}

// ── Phase 3b: overload resolution ────────────────────────────────────────────
//
// Given a CLR type, a method name, and the call's argument types, select the
// best-matching MethodDef overload from metadata.  Argument and parameter
// types are compared in `SigType` space (the caller maps its lowered argument
// types to `SigType`s); the scoring replicates the bootstrap emitter's
// coercion rules: an exact match beats a widening numeric conversion
// (`Int`→`Long`, etc.), and an `object` parameter accepts any argument.
// A resolved method: its calling shape and decoded signature.
pub record ResolvedMethod {
  name: String
  isStatic: Bool
  isVirtual: Bool
  // True iff the MethodAttributes.Abstract bit (0x0400) is set — i.e. the
  // method has no body and an implementer must supply one.  Used by the
  // D105 interface-impl conformance pass to distinguish required methods
  // from C# 8 default interface methods.  Older callers leave this False.
  isAbstract: Bool
  returnType: SigType
  paramTypes: List[SigType]
}

// Widening rank for the numeric primitive element types (-1 for non-numeric).
// A narrower type implicitly converts to a wider one: I1<U1<I2<U2<Char<I4<U4
// <I8<U8<R4<R8 (unsigned ranked alongside their signed width).
func numericRank(elemByte: in Int): Int {
  if elemByte == 0x04 {
    1
  } else if elemByte == 0x05 {
    // I1
    1
  } else if elemByte == 0x06 {
    // U1
    2
  } else if elemByte == 0x07 {
    // I2
    2
  } else if elemByte == 0x03 {
    // U2
    3
  } else if elemByte == 0x08 {
    // CHAR
    4
  } else if elemByte == 0x09 {
    // I4
    4
  } else if elemByte == 0x0A {
    // U4
    5
  } else if elemByte == 0x0B {
    // I8
    5
  } else if elemByte == 0x0C {
    // U8
    6
  } else if elemByte == 0x0D {
    // R4
    7
  } else {
    // R8
    -1
  }
}

// Score one argument against one parameter: 2 = exact, 1 = widening / boxes to
// object, -1 = incompatible.
pub func scoreSigType(arg: in SigType, param: in SigType): Int {
  match param {
    case STPrim(pb) -> match arg {
      case STPrim(ab) -> {
        if ab == pb {
          2
        } else if pb == 0x1C {
          1
        } else {
          // object accepts anything
          val ra = numericRank(ab)
          val rp = numericRank(pb)
          if ra >= 0 and rp >= 0 and ra <= rp {
            1
          } else {
            -1
          }
        }
      }
      case _ -> if pb == 0x1C { 1 } else { -1 }          // object accepts references
    }
    case STClass(pt) -> match arg { case STClass(at) -> if at == pt { 2 } else { -1 }; case _ -> -1 }
    case STValueType(pt) -> match arg { case STValueType(at) -> if at == pt { 2 } else { -1 }; case _ -> -1 }
    case STNamed(pfqn, pvt) -> match arg { case STNamed(afqn, avt) -> if afqn == pfqn and avt == pvt { 2 } else { -1 }; case _ -> -1 }
    case STSzArray(pe) -> match arg {
      // CLR arrays with value-type elements are invariant — `int[]` cannot be
      // passed where `long[]` is expected.  Only accept an exact element match
      // (score 2); a 1 (widening) on the element kind would mis-bind at the JIT.
      case STSzArray(ae) -> if scoreSigType(ae, pe) == 2 { 2 } else { -1 }
      case _ -> -1
    }
    // A by-ref / `out` / `ref` parameter matches a by-ref argument of the same
    // pointee.  Required so the metadata-direct resolver can score an instance
    // method that carries an `out`/`ref` parameter (e.g. `JsonElement.
    // TryGetProperty(string, out JsonElement)`) and thus detect `hasThis`
    // instead of falling back to the static-call guess (#3943).
    case STByRef(pi) -> match arg { case STByRef(ai) -> scoreSigType(ai, pi); case _ -> -1 }
    case _ -> -1
  }
}

// Normalise a decoded `SigType` so its non-primitive types are named by FQN
// (resolving the TypeDefOrRef token to a fully-qualified name) — making them
// comparable to a caller's by-name argument types and directly mappable by the
// emitter.  Primitive and other shapes pass through unchanged.
pub func resolveSigTypeFqn(img: in PeImage, layout: in TableLayout, th: in TablesHeader, t: in SigType): SigType {
  match t {
    case STGenericInst(vt, tok, args) -> {
      val fqn = resolveTypeDefOrRefName(img, layout, th, tok)
      if fqn.length == 0 {
        // Token didn't resolve (unusual): fall through with original args
        // recursively normalised so an STClass inside still becomes STNamed.
        val normArgs: List[SigType] = newList()
        var i = 0
        while i < args.count {
          normArgs.add(resolveSigTypeFqn(img, layout, th, args[i]))
          i = i + 1
        }
        STGenericInst(valueType = vt, token = tok, args = normArgs)
      } else {
        val normArgs: List[SigType] = newList()
        var i = 0
        while i < args.count {
          normArgs.add(resolveSigTypeFqn(img, layout, th, args[i]))
          i = i + 1
        }
        STNamedGenericInst(fqn = fqn, valueType = vt, args = normArgs)
      }
    }
    case STSzArray(elem) -> STSzArray(elem = resolveSigTypeFqn(img, layout, th, elem))
    case STByRef(inner) -> STByRef(inner = resolveSigTypeFqn(img, layout, th, inner))
    case _ -> {
      val tok = sigClassToken(t)
      if tok < 0 {
        t
      } else {
        val fqn = resolveTypeDefOrRefName(img, layout, th, tok)
        if fqn.length == 0 {
          t
        } else {
          STNamed(fqn = fqn, valueType = sigIsValueType(t))
        }
      }
    }
  }
}

// Score a candidate's (already FQN-normalised) parameter list against the
// caller's argument types: the sum of per-parameter scores, or -1 on arity
// mismatch or any incompatible parameter.
pub func scoreParams(argTypes: in List[SigType], params: in List[SigType]): Int {
  if params.count != argTypes.count {
    return -1
  }
  var total = 0
  var i = 0
  while i < argTypes.count {
    val s = scoreSigType(argTypes[i], params[i])
    if s < 0 {
      return -1
    }
    total = total + s
    i = i + 1
  }
  total
}

// Score a whole candidate against the argument list: the sum of per-parameter
// scores, or -1 on arity mismatch or any incompatible parameter.
//
// CALLER NOTE: this entry point does NOT normalize `sig.paramTypes` from raw
// `STClass`/`STValueType` tokens to `STNamed`.  `resolveOverloadIn` does that
// pre-normalization before delegating to the internal `scoreParams`; direct
// callers supplying `STNamed` args must pre-normalize too, or go through
// `resolveOverloadIn` / `resolveExtern`.
pub func scoreOverload(argTypes: in List[SigType], sig: in DecodedMethodSig): Int {
  if sig.paramTypes.count != argTypes.count {
    return -1
  }
  var total = 0
  var i = 0
  while i < argTypes.count {
    val s = scoreSigType(argTypes[i], sig.paramTypes[i])
    if s < 0 {
      return -1
    }
    total = total + s
    i = i + 1
  }
  total
}

// The nested TypeDef row directly under `enclosingRow` named `nestedName`, or
// -1 when absent.  O(1) average case via `layout.nestedClassByEnclosing`
// (#3721) instead of a linear NestedClass table scan.
func findNestedTypeDef(img: in PeImage, layout: in TableLayout, enclosingRow: in Int, nestedName: in String): Int {
  match mapGet(layout.nestedClassByEnclosing, enclosingRow) {
    case None -> -1
    case Some(candidates) -> {
      var ci = 0
      while ci < candidates.count {
        val nestedTd = readTypeDef(img, layout, candidates[ci])
        if nestedTd.name == nestedName {
          return candidates[ci]
        }
        ci = ci + 1
      }
      -1
    }
  }
}

// Find the TypeDef row (1-based) whose fully-qualified name is `typeFqn`, or
// -1 when absent.
pub func findTypeDefByFqn(img: in PeImage, layout: in TableLayout, th: in TablesHeader, typeFqn: in String): Int {
  // Handle nested types: if typeFqn contains a `+`, split into outer and nested parts.
  // E.g., "System.Text.Json.JsonElement+ObjectEnumerator" → outer="System.Text.Json.JsonElement", nested="ObjectEnumerator"
  var plusIdx: Int = -1
  var idx: Int = 0
  while idx < typeFqn.length {
    if typeFqn.substring(idx, 1) == "+" {
      plusIdx = idx
    }
    idx = idx + 1
  }

  if plusIdx >= 0 {
    // This is a nested type. Look up the outer type first.
    val outerFqn = typeFqn.substring(0, plusIdx)
    val nestedName = typeFqn.substring(plusIdx + 1, typeFqn.length - plusIdx - 1)
    val outerTypeDefIdx = findTypeDefByFqn(img, layout, th, outerFqn)
    if outerTypeDefIdx < 0 {
      return -1
    }
    return findNestedTypeDef(img, layout, outerTypeDefIdx, nestedName)
  }

  // No nested type: regular top-level type lookup.
  val n = rowCountOf(th, 0x02)
  var i = 1
  while i <= n {
    val td = readTypeDef(img, layout, i)
    val fqn = if td.namespaceName.length > 0 { td.namespaceName + "." + td.name } else { td.name }
    if fqn == typeFqn {
      return i
    }
    i = i + 1
  }

  // Fallback: handle dotted nested types (e.g. "System.Text.Json.JsonElement.ObjectEnumerator")
  var dotIdx: Int = -1
  var dIdx: Int = 0
  while dIdx < typeFqn.length {
    if typeFqn.substring(dIdx, 1) == "." {
      dotIdx = dIdx
    }
    dIdx = dIdx + 1
  }

  if dotIdx >= 0 {
    val outerFqn = typeFqn.substring(0, dotIdx)
    val nestedName = typeFqn.substring(dotIdx + 1, typeFqn.length - dotIdx - 1)
    val outerTypeDefIdx = findTypeDefByFqn(img, layout, th, outerFqn)
    if outerTypeDefIdx >= 0 {
      return findNestedTypeDef(img, layout, outerTypeDefIdx, nestedName)
    }
  }

  return -1
}

// MethodAttributes: Virtual = 0x0040.  Static (0x0010) is read off the
// `hasThis` bit of the method signature instead, so no helper here.
func methodIsVirtual(flags: in Int): Bool {
  (flags / 64) % 2 == 1
}

// MethodAttributes: Abstract = 0x0400.  Interface methods that *must* be
// implemented carry this bit; C# 8+ default interface methods carry only
// Virtual and are optional.
pub func methodIsAbstract(flags: in Int): Bool {
  (flags / 1024) % 2 == 1
}

// Resolve the best-matching overload of `member` on `typeFqn` for `argTypes`,
// reading from already-parsed metadata.  Returns None when the type is absent
// or no overload is compatible.
pub func resolveOverloadIn(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  typeFqn: in String,
  member: in String,
  argTypes: in List[SigType],
): Option[ResolvedMethod] {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return None
  }
  val mr = methodRange(img, layout, th, typeRow)
  var best: Option[ResolvedMethod] = None
  var bestScore = -1
  var mi = mr.start
  while mi <= mr.endRow {
    val md = readMethodDef(img, layout, mi)
    if md.name == member {
      match decodeMethodSig(blobAt(img, layout, md.sigBlob)) {
        case Err(_) -> {
        }
        case Ok(sig) -> {
          // Normalise non-primitive parameter / return types to FQN names so
          // matching and emission don't depend on this assembly's tokens.
          val normParams: List[SigType] = newList()
          var pj = 0
          while pj < sig.paramTypes.count {
            normParams.add(resolveSigTypeFqn(img, layout, th, sig.paramTypes[pj]))
            pj = pj + 1
          }
          val score = scoreParams(argTypes, normParams)
          if score >= 0 and score > bestScore {
            bestScore = score
            best = Some(
              value = ResolvedMethod(
                name = md.name,
                isStatic = not sig.hasThis,
                isVirtual = methodIsVirtual(md.flags),
                isAbstract = methodIsAbstract(md.flags),
                returnType = resolveSigTypeFqn(img, layout, th, sig.returnType),
                paramTypes = normParams
              )
            )
          }
        }
      }
    }
    mi = mi + 1
  }
  best
}

// Resolve an overload by reading the assembly at `asmPath`.  A convenience
// wrapper over `resolveOverloadIn`; callers compiling many references should
// parse each assembly once and call `resolveOverloadIn` directly.
pub func resolveOverload(
  asmPath: in String, typeFqn: in String, member: in String, argTypes: in List[SigType]
): Option[ResolvedMethod] {
  match File.readBytes(asmPath) {
    case Err(_) -> None
    case Ok(raw) -> match readPe(raw.toArray()) { case Err(_) -> None; case Ok(img) -> match readMetadataRoot(img) { case Err(_) -> None; case Ok(root) -> match readTablesHeader(img, root) { case Err(_) -> None; case Ok(th) -> match computeLayout(img, root, th) { case Err(_) -> None; case Ok(layout) -> resolveOverloadIn(img, layout, th, typeFqn, member, argTypes) } } } }
  }
}

// Decode the raw signature of a method on a (possibly generic) declaring type,
// selecting by member name + arity rather than scoring against concrete
// argument types.  Unlike `resolveOverloadIn`, the returned `paramTypes`
// preserve `STVar`/`STMVar` (generic type/method parameters) and `STByRef`
// wrappers — `scoreSigType` cannot match those, so the scoring path is unusable
// for a member like `ConcurrentDictionary`2::TryGetValue(!0, !1&)`.  `declArity`
// is the Lyric wrapper's full parameter count (receiver included for instance
// methods); the instance overload (`declArity - 1` BCL params) is preferred,
// falling back to the static/ctor overload (`declArity` BCL params).  Non-VAR
// class/value-type tokens are normalised to `STNamed` (FQN) so the caller can
// map them without this assembly's tokens; `hasThis` distinguishes instance
// from static.
pub func decodeExternMethodSigIn(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  typeFqn: in String,
  member: in String,
  declArity: in Int,
): Option[DecodedMethodSig] {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return None
  }
  val mr = methodRange(img, layout, th, typeRow)
  var instanceMatch: Option[DecodedMethodSig] = None
  var staticMatch: Option[DecodedMethodSig] = None
  var mi = mr.start
  while mi <= mr.endRow {
    val md = readMethodDef(img, layout, mi)
    if md.name == member {
      match decodeMethodSig(blobAt(img, layout, md.sigBlob)) {
        case Err(_) -> {
        }
        case Ok(sig) -> {
          val normParams: List[SigType] = newList()
          var pj = 0
          while pj < sig.paramTypes.count {
            normParams.add(resolveSigTypeFqn(img, layout, th, sig.paramTypes[pj]))
            pj = pj + 1
          }
          val normSig = DecodedMethodSig(
            hasThis = sig.hasThis,
            isGeneric = sig.isGeneric,
            genParamCount = sig.genParamCount,
            returnType = resolveSigTypeFqn(img, layout, th, sig.returnType),
            paramTypes = normParams
          )
          // Instance overload: the receiver is the implicit `this`, so the BCL
          // method has one fewer parameter than the Lyric wrapper.
          if normParams.count == declArity - 1 {
            match instanceMatch {
              case None -> {
                instanceMatch = Some(value = normSig)
              }
              case Some(_) -> ()
            }
          } else if normParams.count == declArity {
            match staticMatch {
              case None -> {
                staticMatch = Some(value = normSig)
              }
              case Some(_) -> ()
            }
          }
        }
      }
    }
    mi = mi + 1
  }
  match instanceMatch {
    case Some(s) -> Some(value = s)
    case None -> staticMatch
  }
}

// Read-from-disk convenience wrapper over `decodeExternMethodSigIn`.
pub func decodeExternMethodSig(
  asmPath: in String, typeFqn: in String, member: in String, declArity: in Int
): Option[DecodedMethodSig] {
  match File.readBytes(asmPath) {
    case Err(_) -> None
    case Ok(raw) -> match readPe(raw.toArray()) { case Err(_) -> None; case Ok(img) -> match readMetadataRoot(img) { case Err(_) -> None; case Ok(root) -> match readTablesHeader(img, root) { case Err(_) -> None; case Ok(th) -> match computeLayout(img, root, th) { case Err(_) -> None; case Ok(layout) -> decodeExternMethodSigIn(img, layout, th, typeFqn, member, declArity) } } } }
  }
}

// Like `scoreSigType`, but additionally accepts:
//  - a NAMED reference argument into a NAMED reference parameter of a different
//    type (implicit upcast, e.g. CultureInfo → IFormatProvider), scored 1;
//  - an erased extern-type argument (MObject → STPrim(0x1C)) into any
//    non-value-type NAMED parameter, scored 1.
// Both are below an exact match's 2, so an exact overload always wins.
// Value-type and primitive mismatches remain -1.
pub func scoreSigTypeLenient(arg: in SigType, param: in SigType): Int {
  val s = scoreSigType(arg, param)
  if s >= 0 {
    s
  } else {
    val paramIsRefNamed = match param { case STNamed(_, vt) -> not vt; case _ -> false }
    if paramIsRefNamed {
      // Any reference-typed arg (named or erased-object) flows into a named
      // reference parameter as an implicit upcast.
      val argIsObject = match arg { case STPrim(b) -> b == 0x1C; case _ -> false }
      val argIsRefNamed = match arg { case STNamed(_, vt) -> not vt; case _ -> false }
      if argIsObject or argIsRefNamed { 1 } else { 0 - 1 }
    } else {
      0 - 1
    }
  }
}

// Sum of per-parameter lenient scores, or -1 on arity mismatch / any
// incompatible parameter.  The lenient counterpart of `scoreParams`.
pub func scoreParamsLenient(argTypes: in List[SigType], params: in List[SigType]): Int {
  if params.count != argTypes.count {
    return 0 - 1
  }
  var total = 0
  var i = 0
  while i < argTypes.count {
    val s = scoreSigTypeLenient(argTypes[i], params[i])
    if s < 0 {
      return 0 - 1
    }
    total = total + s
    i = i + 1
  }
  total
}

// Score `argTypes` against the leading `argTypes.count` of `params` (which may be
// longer).  Used for prefix matches where the caller supplies fewer arguments
// than the BCL method declares and the trailing params are optional.  Returns -1
// when any leading param is incompatible.
func scoreParamsPrefix(argTypes: in List[SigType], params: in List[SigType]): Int {
  if params.count < argTypes.count {
    return 0 - 1
  }
  var total = 0
  var i = 0
  while i < argTypes.count {
    val s = scoreSigTypeLenient(argTypes[i], params[i])
    if s < 0 {
      return 0 - 1
    }
    total = total + s
    i = i + 1
  }
  total
}

// True iff the param with 1-based `seq` on the method whose Param rows span
// [pstart, pend) carries the `Optional` flag (ECMA-335 §II.23.1.13, 0x0010).
// A trailing param with no Param row at all is NOT optional (returns false), so
// a prefix match is only attempted when every unfilled position is provably
// optional.
func paramSeqOptional(img: in PeImage, layout: in TableLayout, pstart: in Int, pend: in Int, seq: in Int): Bool {
  var pr = pstart
  while pr < pend {
    val prow = readParam(img, layout, pr)
    if prow.sequence == seq {
      // Param.Optional flag = 0x0010 (bit 4); test it arithmetically (the
      // bitwise `.and` method is keyword-named and won't parse on a field
      // receiver), matching this file's other flag tests.
      return (prow.flags / 16) % 2 == 1
    }
    pr = pr + 1
  }
  false
}

// Count of contiguous trailing optional params on MethodDef `methodRow` (which
// declares `totalParams` params).  BCL optional params are always trailing and
// contiguous, so a caller supplying `totalParams - N` arguments may omit the
// last N iff `N <= methodTrailingOptionalCount(...)`.
func methodTrailingOptionalCount(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  methodRow: in Int,
  totalParams: in Int,
): Int {
  if totalParams <= 0 {
    return 0
  }
  val md = readMethodDef(img, layout, methodRow)
  val pstart = md.paramListStart
  val totalMethods = rowCountOf(th, 0x06)
  val pend = if methodRow < totalMethods {
    readMethodDef(img, layout, methodRow + 1).paramListStart
  } else {
    rowCountOf(th, 0x08) + 1
  }
  var cnt = 0
  var s = totalParams
  while s >= 1 and paramSeqOptional(img, layout, pstart, pend, s) {
    cnt = cnt + 1
    s = s - 1
  }
  cnt
}

// named-reference upcasts).  `fullArgTypes` is the Lyric wrapper's complete
// argument list (the receiver is arg 0 for instance methods); an instance
// candidate (`hasThis`, BCL param count == fullArgTypes.count - 1) is scored
// against the receiver-excluded tail, a static candidate (BCL param count ==
// fullArgTypes.count) against the whole list.  Instance candidates win ties so
// the convention matches reflection's bias.  Returns the normalised
// `DecodedMethodSig` (`hasThis` + FQN-named param/return types) so the emitter
// can encode the BCL method's real signature — fixing both the
// instance-vs-static guess and Lyric-vs-BCL parameter-type mismatches.  None
// when the type is absent or no overload is compatible.
pub func resolveExternMethodScoredIn(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  typeFqn: in String,
  member: in String,
  fullArgTypes: in List[SigType],
): Option[DecodedMethodSig] {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return None
  }
  val declArity = fullArgTypes.count
  val tail: List[SigType] = newList()
  var ti = 1
  while ti < fullArgTypes.count {
    tail.add(fullArgTypes[ti])
    ti = ti + 1
  }
  val mr = methodRange(img, layout, th, typeRow)
  var best: Option[DecodedMethodSig] = None
  var bestScore = 0 - 1
  var bestIsInstance = false
  var mi = mr.start
  while mi <= mr.endRow {
    val md = readMethodDef(img, layout, mi)
    if md.name == member {
      match decodeMethodSig(blobAt(img, layout, md.sigBlob)) {
        case Err(_) -> {
        }
        case Ok(sig) -> {
          val normParams: List[SigType] = newList()
          var pj = 0
          while pj < sig.paramTypes.count {
            normParams.add(resolveSigTypeFqn(img, layout, th, sig.paramTypes[pj]))
            pj = pj + 1
          }
          val isInstance = sig.hasThis
          // Exact-arity matches earn a large bonus so they always beat a
          // shorter-supplied prefix match against a longer overload whose
          // trailing params are optional (e.g. `JsonEncodedText.Encode(string)`
          // resolving to `Encode(string, JavaScriptEncoder = null)`).  Prefix
          // matches keep their raw (non-negative) score so they are still
          // selectable when no exact overload exists; the emitter fills the
          // unsupplied trailing optionals with their type defaults.
          val exactBonus = 1000000
          val nReal = normParams.count
          // Constructors: hasThis is set in the CLR sig convention even though the
          // receiver is implicitly allocated by newobj and is NOT listed as an
          // explicit parameter.  Score against fullArgTypes directly (no head-drop)
          // with nReal == declArity, before the generic instance branch which would
          // compute nReal == declArity - 1 and always miss.
          val score = if member == ".ctor" and nReal == declArity {
            val sc = scoreParamsLenient(fullArgTypes, normParams)
            if sc < 0 {
              sc
            } else {
              sc + exactBonus
            }
          } else if member == ".ctor" and nReal > declArity and nReal - declArity <= methodTrailingOptionalCount(img, layout, th, mi, nReal) {
            scoreParamsPrefix(fullArgTypes, normParams)
          } else if isInstance and nReal == declArity - 1 {
            val sc = scoreParamsLenient(tail, normParams)
            if sc < 0 {
              sc
            } else {
              sc + exactBonus
            }
          } else if not isInstance and nReal == declArity {
            val sc = scoreParamsLenient(fullArgTypes, normParams)
            if sc < 0 {
              sc
            } else {
              sc + exactBonus
            }
          } else if isInstance and nReal > declArity - 1 and nReal - (declArity - 1) <= methodTrailingOptionalCount(img, layout, th, mi, nReal) {
            scoreParamsPrefix(tail, normParams)
          } else if not isInstance and nReal > declArity and nReal - declArity <= methodTrailingOptionalCount(img, layout, th, mi, nReal) {
            scoreParamsPrefix(fullArgTypes, normParams)
          } else {
            0 - 1
          }
          val better = if score < 0 {
            false
          } else if score > bestScore {
            true
          } else if score == bestScore and isInstance and not bestIsInstance {
            true
          } else {
            false
          }
          if better {
            bestScore = score
            bestIsInstance = isInstance
            best = Some(
              value = DecodedMethodSig(
                hasThis = sig.hasThis,
                isGeneric = sig.isGeneric,
                genParamCount = sig.genParamCount,
                returnType = resolveSigTypeFqn(img, layout, th, sig.returnType),
                paramTypes = normParams
              )
            )
          }
        }
      }
    }
    mi = mi + 1
  }
  best
}

// Read-from-disk convenience wrapper over `resolveExternMethodScoredIn`.
pub func resolveExternMethodScored(
  asmPath: in String,
  typeFqn: in String,
  member: in String,
  fullArgTypes: in List[SigType],
): Option[DecodedMethodSig] {
  match File.readBytes(asmPath) {
    case Err(_) -> None
    case Ok(raw) -> match readPe(raw.toArray()) { case Err(_) -> None; case Ok(img) -> match readMetadataRoot(img) { case Err(_) -> None; case Ok(root) -> match readTablesHeader(img, root) { case Err(_) -> None; case Ok(th) -> match computeLayout(img, root, th) { case Err(_) -> None; case Ok(layout) -> resolveExternMethodScoredIn(img, layout, th, typeFqn, member, fullArgTypes) } } } }
  }
}

// ── Layer 5b: interface-impl conformance support (D105 Phase 2) ──────────────
//
// `TypeAttributes.ClassSemanticsMask` is the two-bit field at 0x20:
//   0x00 = Class, 0x20 = Interface, 0x40 = reserved.
// True iff this TypeDef row flags an interface (ECMA-335 §II.23.1.15).
pub func isInterfaceTypeDef(flags: in Int): Bool {
  (flags / 32) % 2 == 1
}

// All methods declared on the TypeDef at `typeFqn`, with their parameter and
// return types normalised to `STNamed`-keyed FQNs (matching `resolveOverloadIn`).
// `None` when the type is absent from the assembly.  Used by the MSIL backend's
// interface-impl validation pass to enumerate the methods a Lyric `impl` block
// must structurally satisfy.  The result preserves declaration order and
// includes every method on the type — interfaces in the reference pack carry
// only their abstract slots (their methods are flagged `Abstract` + `Virtual`),
// but the caller does the filtering downstream so we don't have to expose every
// MethodAttributes bit here.
pub func allMethodSigsOn(
  img: in PeImage, layout: in TableLayout, th: in TablesHeader, typeFqn: in String
): Option[List[ResolvedMethod]] {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return None
  }
  val mr = methodRange(img, layout, th, typeRow)
  val methods: List[ResolvedMethod] = newList()
  var mi = mr.start
  while mi <= mr.endRow {
    val md = readMethodDef(img, layout, mi)
    match decodeMethodSig(blobAt(img, layout, md.sigBlob)) {
      case Err(_) -> {
      }
      case Ok(sig) -> {
        val normParams: List[SigType] = newList()
        var pj = 0
        while pj < sig.paramTypes.count {
          normParams.add(resolveSigTypeFqn(img, layout, th, sig.paramTypes[pj]))
          pj = pj + 1
        }
        methods.add(
          ResolvedMethod(
            name = md.name,
            isStatic = not sig.hasThis,
            isVirtual = methodIsVirtual(md.flags),
            isAbstract = methodIsAbstract(md.flags),
            returnType = resolveSigTypeFqn(img, layout, th, sig.returnType),
            paramTypes = normParams
          )
        )
      }
    }
    mi = mi + 1
  }
  Some(value = methods)
}

// True iff `typeFqn` resolves to an interface in this assembly.  Returns false
// when the type is absent — callers (e.g. the F0020 check) treat absence
// separately because it usually means the reference pack does not carry the
// declaring assembly, not that the type is mis-declared.
pub func typeIsInterface(img: in PeImage, layout: in TableLayout, th: in TablesHeader, typeFqn: in String): Bool {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 {
    return false
  }
  isInterfaceTypeDef(readTypeDef(img, layout, typeRow).flags)
}

// Inspection result for an external type used as an `impl` target: whether the
// .NET type carries the `Interface` ClassSemantics bit, and the resolved
// signatures of every method declared on it.  Lifecycle / disk-read errors
// (missing file, malformed PE / metadata, type absent from the assembly)
// collapse to `None`, mirroring `resolveOverload` — the caller treats that as
// "can't verify" and falls back to runtime checks.
pub record InterfaceInspection {
  isInterface: Bool
  methods: List[ResolvedMethod]
}

// Read-from-disk convenience wrapper that loads `asmPath` and inspects
// `typeFqn` for an interface-impl validation pass.  Used by the MSIL
// backend's `validateExternImplConformanceMsil`; co-located here so the
// File / PE / metadata layering stays self-contained.
pub func inspectInterfaceTarget(asmPath: in String, typeFqn: in String): Option[InterfaceInspection] {
  match File.readBytes(asmPath) {
    case Err(_) -> None
    case Ok(raw) -> match readPe(raw.toArray()) { case Err(_) -> None; case Ok(img) -> match readMetadataRoot(img) { case Err(_) -> None; case Ok(root) -> match readTablesHeader(img, root) { case Err(_) -> None; case Ok(th) -> match computeLayout(img, root, th) { case Err(_) -> None; case Ok(layout) -> match allMethodSigsOn(img, layout, th, typeFqn) { case None -> None; case Some(ms) -> Some(value = InterfaceInspection(isInterface = typeIsInterface(img, layout, th, typeFqn), methods = ms)) } } } } }
  }
}

// ── resolveExtern: discovery + resolution composed ───────────────────────────
//
// The single entry point the emitter calls to resolve an extern method.  It
// looks the owning assembly up in a prebuilt type→assembly-name index, maps
// that name to its on-disk path via a companion name→path index, then resolves
// the best overload from that assembly.  Callers build both indexes once (over
// `enumRefAssemblies(refPackDir())` plus any restored-dependency DLLs) and
// reuse them across call sites.
pub record ResolvedExtern {
  assemblyName: String        // owning assembly's simple name (for the AssemblyRef)
  sig: ResolvedMethod
}

// Build an assembly-simple-name → full-DLL-path index over the given
// assemblies (the path companion to `buildTypeIndex`).  Because the path is
// recorded per assembly rather than reconstructed from a single directory, an
// assembly that lives outside the reference-pack directory — e.g. a restored
// NuGet dependency in the package cache — still resolves to its real file.
// First writer wins, matching `buildTypeIndex`.
pub func buildPathIndex(asmPaths: in List[String]): Map[String, String] {
  val index: Map[String, String] = newMap()
  var i = 0
  while i < asmPaths.count {
    val name = assemblySimpleName(asmPaths[i])
    match mapGet(index, name) {
      case Some(_) -> {
      }
      case None -> index.add(name, asmPaths[i])
    }
    i = i + 1
  }
  index
}

// Resolve an extern method call: look the owning assembly up in `typeIndex`
// (FQN → simple name), map it to its on-disk path via `pathIndex` (simple name
// → full path), then resolve the best overload from that assembly.  Both
// indexes are built once by the caller (over the reference pack plus any
// restored-dependency DLLs) and reused across call sites.  Carrying explicit
// paths means assemblies outside the reference-pack directory still resolve.
// Full path of `<asmName>.dll` inside the reference directory `refDir`,
// joined platform-portably (the caller's `refDir` may use either separator).
pub func refAssemblyPath(refDir: in String, asmName: in String): String {
  Path.join(refDir, asmName + ".dll")
}

pub func resolveExtern(
  typeIndex: in Map[String, String],
  pathIndex: in Map[String, String],
  typeFqn: in String,
  member: in String,
  argTypes: in List[SigType],
): Option[ResolvedExtern] {
  match assemblyForType(typeIndex, typeFqn) {
    case None -> None
    case Some(asmName) -> match mapGet(pathIndex, asmName) { case None -> None; case Some(asmPath) -> match resolveOverload(asmPath, typeFqn, member, argTypes) { case None -> None; case Some(m) -> Some(value = ResolvedExtern(assemblyName = asmName, sig = m)) } }
  }
}

// ── Layer 6: embedded managed resources ──────────────────────────────────────
//
// Read a named entry out of the ManifestResource table (0x28) and extract its
// payload bytes from the CLI Resources data region.  This is the metadata-
// direct inverse of the emitter's resource writer (`assembler.l`): the writer
// concatenates each resource as a 4-byte little-endian length prefix followed
// by the payload into the Resources region, and records the per-resource byte
// offset into that region in each ManifestResource row.  Reading the same
// structures back needs no runtime assembly load — it is pure byte reading, so
// it works under Native AOT where `System.Reflection.Assembly.Load(byte[])` is
// unsupported.  ECMA-335 §II.22.24 (ManifestResource), §II.25.3.3.3 (Resources).
// One ManifestResource row (table 0x28).  `implementation` is the coded
// Implementation index: 0 means the resource is embedded in this assembly (the
// only kind a Lyric-emitted DLL carries); non-zero points into the File /
// AssemblyRef tables for a linked external resource.
pub record ManifestResourceEntry {
  resourceOffset: Int    // byte offset of the payload into the Resources region
  flags: Int             // ManifestResourceAttributes (1 = Public, 2 = Private)
  name: String           // resource name (from #Strings)
  implementation: Int    // coded Implementation (0 = embedded in this assembly)
}

// Read ManifestResource row `row` (1-based).  Columns (ECMA §II.22.24):
// Offset(u4), Flags(u4), Name(#String), Implementation(coded Implementation).
pub func readManifestResource(
  img: in PeImage, layout: in TableLayout, th: in TablesHeader, row: in Int
): ManifestResourceEntry {
  if row < 1 {
    panic("Msil.MetadataReader.readManifestResource: row must be >= 1, got " + toString(row))
  }
  val maxRow = rowCountOf(th, 0x28)
  if row > maxRow {
    panic(
      "Msil.MetadataReader.readManifestResource: row " + toString(row) + " exceeds the ManifestResource row count " +
        toString(maxRow)
    )
  }
  val b = img.bytes
  val o = layout.dataStart[0x28] + (row - 1) * layout.rowSize[0x28]
  val resOff = rdU32(b, o)
  val flags = rdU32(b, o + 4)
  var p = o + 8
  val nameI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val implIdx = rdIdx(b, p, layout.implementationIdx)
  ManifestResourceEntry(
    resourceOffset = resOff,
    flags = flags,
    name = stringAt(img, layout, nameI),
    implementation = implIdx
  )
}

// Extract the payload bytes of an embedded resource whose `resOffset` is the
// byte offset into the Resources region.  Reads the 4-byte length prefix at
// `resourcesOff + resOffset`, then that many payload bytes.  Returns an empty
// slice when the image declares no Resources region (offset -1) or the read
// would run past the image.
pub func extractResourceBytes(img: in PeImage, resOffset: in Int): slice[Byte] {
  val empty: List[Byte] = newList()
  if img.resourcesOff < 0 {
    return empty.toArray()
  }
  // A malformed or hostile ManifestResource row can carry an Offset outside
  // the Resources region; reject it instead of reading bytes from an adjacent
  // section (code, metadata tables, ...) (#3224).  A zero-size region rejects
  // every offset — a row pointing into a declared-empty region is malformed
  // (#3251).
  if resOffset < 0 or resOffset >= img.resourcesSize {
    return empty.toArray()
  }
  val b = img.bytes
  val base = img.resourcesOff + resOffset
  if base + 4 > b.length {
    return empty.toArray()
  }
  val len = rdU32(b, base)
  // Clamp the payload read to the end of the Resources region (as well as the
  // image) so a corrupt length prefix cannot spill into the next section.
  var limit = b.length
  if img.resourcesSize > 0 and img.resourcesOff + img.resourcesSize < limit {
    limit = img.resourcesOff + img.resourcesSize
  }
  val acc: List[Byte] = newList()
  var i = 0
  while i < len and base + 4 + i < limit {
    acc.add(b[base + 4 + i])
    i = i + 1
  }
  acc.toArray()
}

// A parsed assembly image: the PE container plus the computed table layout
// and `#~` header.  Built once per DLL — by `openResourceImage` for
// embedded-resource reads (then queried by `resourceNamesIn` /
// `tryReadResourceIn`) and by the type-index builders' shared
// `parseAssemblyImage` step.
pub record ResourceImage {
  img: PeImage
  layout: TableLayout
  th: TablesHeader
}

// Parse raw assembly bytes through every metadata layer (PE container,
// metadata root, `#~` header, table layout).  Returns `None` when any layer
// rejects the bytes — the shared graceful-failure policy for callers that
// treat a malformed or non-managed DLL as "nothing to read".
func parseAssemblyImage(raw: in slice[Byte]): Option[ResourceImage] {
  val img = match readPe(raw) { case Ok(v) -> v; case Err(_) -> return None }
  val root = match readMetadataRoot(img) { case Ok(v) -> v; case Err(_) -> return None }
  val th = match readTablesHeader(img, root) { case Ok(v) -> v; case Err(_) -> return None }
  val layout = match computeLayout(img, root, th) { case Ok(v) -> v; case Err(_) -> return None }
  Some(value = ResourceImage(img = img, layout = layout, th = th))
}

// Open `path` as a .NET assembly and prepare it for embedded-resource reads.
// Returns `None` when the file is unreadable or not a well-formed managed PE
// image (the caller treats a non-Lyric / unreadable DLL as "no contract
// resources", matching the previous loader-based behaviour).  Pure byte
// reading — no runtime assembly load, so it is Native-AOT-safe.
pub func openResourceImage(path: in String): Option[ResourceImage] {
  match File.readBytes(path) {
    case Err(_) -> None
    case Ok(raw) -> parseAssemblyImage(raw.toArray())
  }
}

// Every embedded-resource name in the assembly (resources whose Implementation
// is 0 — i.e. carried in this assembly, not linked from another file).  Order
// matches the ManifestResource table row order, which the emitter writes in
// declaration order (deterministic per build).
pub func resourceNamesIn(ri: in ResourceImage): List[String] {
  val names: List[String] = newList()
  val n = rowCountOf(ri.th, 0x28)
  var i = 1
  while i <= n {
    val r = readManifestResource(ri.img, ri.layout, ri.th, i)
    if r.implementation == 0 {
      names.add(r.name)
    }
    i = i + 1
  }
  names
}

// Read the payload bytes of the embedded resource named `name`, or `None` when
// no embedded resource has that name.  Scans the ManifestResource table for a
// name match, then extracts the length-prefixed payload from the Resources
// region.
pub func tryReadResourceIn(ri: in ResourceImage, name: in String): Option[slice[Byte]] {
  val n = rowCountOf(ri.th, 0x28)
  var i = 1
  while i <= n {
    val r = readManifestResource(ri.img, ri.layout, ri.th, i)
    if r.implementation == 0 and r.name == name {
      return Some(value = extractResourceBytes(ri.img, r.resourceOffset))
    }
    i = i + 1
  }
  None
}

// Information about nullary union case Instance singleton fields in a DLL.
// `hasInstances` is true when the DLL contains at least one static field named
// "Instance" on a TypeDef whose name contains "_" (the naming convention for
// union case classes).  `isClassTyped` is true when that field's FieldSig uses
// ELEMENT_TYPE_CLASS (0x12) rather than ELEMENT_TYPE_OBJECT (0x1c): CLASS-typed
// Instance fields come from DLLs emitted by the F#-era bootstrap compiler;
// DLLs emitted by the current self-hosted compiler use ELEMENT_TYPE_OBJECT.
// This distinction matters for MemberRef resolution: the CLR rejects a MemberRef
// whose field signature differs from the FieldDef's field signature, so
// `registerRestoredUnionCase` must create MemberRefs with the same element type
// that the target DLL actually declares.
//
// Background: an earlier approach used the arity-suffix proxy
// (`coreDllHasAritySuffixTypeDef`), but that is WRONG for self-hosted DLLs
// that define no generic type — `Lyric.Lexer` carries ~70 keyword union cases
// each with an `Instance` singleton yet has no backtick TypeDef, so the proxy
// returned false and the restored path fell back to `newobj`, producing fresh
// instances that never `Object.Equals` the lexer's keyword tokens (#3920).
pub record InstanceFieldKind {
  hasInstances: Bool
  isClassTyped: Bool
}

// Helper: scan a parsed CLI image for nullary-case Instance fields and return
// their element-type convention.  Extracted from `dllNullaryInstanceInfo` so
// the multi-line loop body stays readable — `lyric fmt` collapses a nested-match
// `Ok(raw) ->` arm onto a single line regardless of length.
func imageNullaryInstanceInfo(bytes: in slice[Byte]): InstanceFieldKind {
  match parseAssemblyImage(bytes) {
    case None -> InstanceFieldKind(hasInstances = false, isClassTyped = false)
    case Some(ri) -> {
      val b = ri.img.bytes
      val typeDefCount = rowCountOf(ri.th, 0x02)
      var row = 1
      var found = false
      var classTyped = false
      while row <= typeDefCount and not found {
        val td = readTypeDef(ri.img, ri.layout, row)
        if Str.contains(td.name, "_") {
          val fr = fieldRange(ri.img, ri.layout, ri.th, row)
          var frow = fr.start
          while frow <= fr.endRow and not found {
            val o = ri.layout.dataStart[0x04] + (frow - 1) * ri.layout.rowSize[0x04]
            val flags = rdU16(b, o)
            val nameI = rdIdx(b, o + 2, ri.layout.stringIdx)
            val nm = stringAt(ri.img, ri.layout, nameI)
            // Bit 4 of FieldAttributes is Static (0x0010); (flags / 16) % 2 == 1 tests it.
            if nm == "Instance" and (flags / 16) % 2 == 1 {
              found = true
              val sigI = rdIdx(b, o + 2 + ri.layout.stringIdx, ri.layout.blobIdx)
              val sig = blobAt(ri.img, ri.layout, sigI)
              // Byte 1 of the FieldSig blob is the element type:
              // 0x12 = ELEMENT_TYPE_CLASS (F#-era); 0x1c = ELEMENT_TYPE_OBJECT (self-hosted).
              classTyped = sig.length >= 2 and rdU8(sig, 1) == 0x12
            }
            frow = frow + 1
          }
        }
        row = row + 1
      }
      InstanceFieldKind(hasInstances = found, isClassTyped = classTyped)
    }
  }
}

// Scan `dllPath` once and return how its nullary-case Instance fields are typed.
// Returns `InstanceFieldKind(false, false)` when the file is missing, unreadable,
// or contains no Instance field on a "_"-named TypeDef — safe default (no
// MemberRefs emitted, no resolution error).
pub func dllNullaryInstanceInfo(dllPath: in String): InstanceFieldKind {
  match File.readBytes(dllPath) {
    case Err(_) -> InstanceFieldKind(hasInstances = false, isClassTyped = false)
    case Ok(raw) -> imageNullaryInstanceInfo(raw.toArray())
  }
}

// A simple container for Assembly version components.
pub record AssemblyVersion {
  major: Int
  minor: Int
  build: Int
  revision: Int
}

// Read the assembly version from the given .NET assembly file path.
// Returns Some(AssemblyVersion(major, minor, build, revision)) if found, or None.
pub func readAssemblyVersion(asmPath: in String): Option[AssemblyVersion] {
  match openResourceImage(asmPath) {
    case None -> None
    case Some(ri) -> {
      if ri.th.rowCounts[0x20] > 0 {
        val row = readAssembly(ri.img, ri.layout, 1)
        Some(value = AssemblyVersion(
          major = row.majorVersion,
          minor = row.minorVersion,
          build = row.buildNumber,
          revision = row.revisionNumber
        ))
      } else {
        None
      }
    }
  }
}
