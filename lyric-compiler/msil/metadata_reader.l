// msil/metadata_reader.l — pure-Lyric CLI-metadata reader.
//
// Reads a .NET PE assembly's bytes and parses the ECMA-335 metadata container.
// It is the inverse of the metadata *writer* in `pe.l`/`tables.l`/`heaps.l`:
// where the writer lays out the DOS/PE/COFF headers, the CLI header, the
// metadata root (`BSJB`), the stream headers, and the `#~` table-stream
// header, this reader walks the same structures back out of a byte image.
// Resolving external method signatures from reference-assembly metadata this
// way needs no runtime type loading — it is pure byte reading, so it is
// independent of whether the emitting assembly's types can be reflected over.
//
// This module currently covers layers 1–2: the PE container (DOS/PE/COFF/
// optional header, sections, RVA→file-offset, CLI header), the metadata root
// (stream headers), and the `#~` table-stream header (heap-size flags, the
// valid-table bitvector, per-table row counts).  Heap readers, table-row
// readers, the signature-blob decoder, and overload resolution build on top.
//
// All multi-byte integers in the PE/metadata format are little-endian.  Byte
// values are widened to `Int` via mixed Byte*Int arithmetic (the same idiom
// `Std.Encoding` uses for UTF-8 decoding), which keeps this compilable by the
// bootstrap emitter that lacks bitwise operators.  No field read here stores a
// value with the high bit of a 32-bit slot set (offsets, sizes, RVAs, and row
// counts are all well under 2^31), and the 64-bit valid/sorted bitvectors are
// read byte-wise so they never overflow `Int`.
//
// References: ECMA-335 6th edition §II.25.2 (PE file), §II.24.2 (metadata
// physical layout), §II.24.2.6 (`#~` stream).

package Msil.MetadataReader

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char as Ch

// ── Parsed shapes ────────────────────────────────────────────────────────────

// One PE section header (the 40-byte rows after the optional header).  Only
// the fields needed for RVA→file-offset mapping are kept.
pub record SectionHeader {
  virtualAddress: Int
  virtualSize:    Int
  rawDataPtr:     Int
  rawDataSize:    Int
}

// The PE container: enough to locate the CLI header and the metadata root.
pub record PeImage {
  bytes:        slice[Byte]
  peHeaderOff:  Int            // file offset of the "PE\0\0" signature
  numSections:  Int
  optHeaderSize: Int
  isPe32Plus:   Bool
  cliHeaderRva:  Int
  cliHeaderSize: Int
  metadataRva:   Int           // RVA of the BSJB metadata root
  metadataSize:  Int
  metadataOff:   Int           // file offset of the BSJB metadata root
  sections:      List[SectionHeader]
}

// One metadata stream header (`#~`, `#Strings`, `#US`, `#GUID`, `#Blob`).
// `offset` is relative to the metadata root; `fileOff` is absolute.
pub record StreamHeader {
  name:    String
  offset:  Int
  size:    Int
  fileOff: Int
}

// The metadata root (`BSJB`) plus its stream headers.
pub record MetadataRoot {
  versionString: String
  streams:       List[StreamHeader]
}

// The `#~` table-stream header: heap-index widths + which tables are present
// and their row counts.  `rowCounts` is indexed by ECMA table id (0..63);
// absent tables read 0.
pub record TablesHeader {
  heapSizes:      Int          // bit0: #Strings 4-byte, bit1: #GUID, bit2: #Blob
  stringsWide:    Bool
  guidWide:       Bool
  blobWide:       Bool
  presentCount:   Int          // number of tables with a row-count entry
  rowCounts:      List[Int]    // length 64, indexed by table id
}

// ── Little-endian byte readers (Byte→Int widening via mixed arithmetic) ──────

// Read one byte as an unsigned Int (0..255).  `b[o] * 1` is Byte*Int → Int,
// the same widening idiom `Std.Encoding` uses (`(b0 % 32u8) * 64`).
func rdU8(b: in slice[Byte], o: in Int): Int { b[o] * 1 }

func rdU16(b: in slice[Byte], o: in Int): Int {
  rdU8(b, o) + rdU8(b, o + 1) * 256
}

func rdU32(b: in slice[Byte], o: in Int): Int {
  rdU8(b, o) + rdU8(b, o + 1) * 256 + rdU8(b, o + 2) * 65536 + rdU8(b, o + 3) * 16777216
}

// True when bit `bit` (0..7) of the unsigned byte value `byteVal` is set.
func bitSetInByte(byteVal: in Int, bit: in Int): Bool {
  var p = 1
  var k = 0
  while k < bit { p = p * 2  k = k + 1 }
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
      if bitSetInByte(v, bit) { total = total + 1 }
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
  val numSections   = rdU16(bytes, peOff + 6)
  val optHeaderSize = rdU16(bytes, peOff + 20)
  val optBase       = peOff + 24
  if optBase + optHeaderSize > bytes.length {
    return Err(error = "metadata: optional header out of range")
  }
  val magic      = rdU16(bytes, optBase)
  val isPe32Plus = magic == 0x20B
  if magic != 0x10B and magic != 0x20B {
    return Err(error = "metadata: unrecognised optional-header magic 0x" + toString(magic))
  }
  // Data directories start at optBase+96 (PE32) or optBase+112 (PE32+).
  val dataDirStart = if isPe32Plus { optBase + 112 } else { optBase + 96 }
  // CLI header = COM descriptor = data directory index 14.
  val cliDirOff  = dataDirStart + 14 * 8
  if cliDirOff + 8 > bytes.length {
    return Err(error = "metadata: CLI data directory out of range")
  }
  val cliRva  = rdU32(bytes, cliDirOff)
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
    sections.add(SectionHeader(
      virtualAddress = rdU32(bytes, so + 12),
      virtualSize    = rdU32(bytes, so + 8),
      rawDataPtr     = rdU32(bytes, so + 20),
      rawDataSize    = rdU32(bytes, so + 16)))
    si = si + 1
  }
  // Build a partial image so rvaToOffset can be used to resolve the CLI header.
  val partial = PeImage(
    bytes = bytes, peHeaderOff = peOff, numSections = numSections,
    optHeaderSize = optHeaderSize, isPe32Plus = isPe32Plus,
    cliHeaderRva = cliRva, cliHeaderSize = cliSize,
    metadataRva = 0, metadataSize = 0, metadataOff = -1, sections = sections)
  val cliOff = rvaToOffset(partial, cliRva)
  if cliOff < 0 or cliOff + 16 > bytes.length {
    return Err(error = "metadata: CLI header RVA " + toString(cliRva) + " not mapped by any section")
  }
  // CLI header: cb u32, runtime ver u16+u16, then MetaData (RVA u32, Size u32).
  val mdRva  = rdU32(bytes, cliOff + 8)
  val mdSize = rdU32(bytes, cliOff + 12)
  val mdOff  = rvaToOffset(partial, mdRva)
  if mdOff < 0 or mdOff + 16 > bytes.length {
    return Err(error = "metadata: metadata root RVA " + toString(mdRva) + " not mapped by any section")
  }
  Ok(value = PeImage(
    bytes = bytes, peHeaderOff = peOff, numSections = numSections,
    optHeaderSize = optHeaderSize, isPe32Plus = isPe32Plus,
    cliHeaderRva = cliRva, cliHeaderSize = cliSize,
    metadataRva = mdRva, metadataSize = mdSize, metadataOff = mdOff,
    sections = sections))
}

// ── Layer 2a: metadata root + stream headers ─────────────────────────────────

pub func readMetadataRoot(img: in PeImage): Result[MetadataRoot, String] {
  val b   = img.bytes
  val mo  = img.metadataOff
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
  val afterVer  = mo + 16 + verLen
  val numStreams = rdU16(b, afterVer + 2)
  val streams: List[StreamHeader] = newList()
  var p = afterVer + 4
  var k = 0
  while k < numStreams {
    if p + 8 > b.length {
      return Err(error = "metadata: stream header " + toString(k) + " out of range")
    }
    val sOff  = rdU32(b, p)
    val sSize = rdU32(b, p + 4)
    val sName = rdAsciiZ(b, p + 8)
    // Name is null-terminated and padded to the next 4-byte boundary.
    val nameLen = sName.length + 1
    val padded  = ((nameLen + 3) / 4) * 4
    streams.add(StreamHeader(
      name = sName, offset = sOff, size = sSize, fileOff = mo + sOff))
    p = p + 8 + padded
    k = k + 1
  }
  Ok(value = MetadataRoot(versionString = versionString, streams = streams))
}

// Find a stream by name (e.g. "#~", "#Strings").
pub func findStream(root: in MetadataRoot, name: in String): Option[StreamHeader] {
  var i = 0
  while i < root.streams.count {
    if root.streams[i].name == name { return Some(value = root.streams[i]) }
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
    case None -> match findStream(root, "#-") {
      case Some(s2) -> s2
      case None -> return Err(error = "metadata: no '#~' or '#-' table stream")
    }
  }
  val base = sh.fileOff
  if base + 24 > b.length {
    return Err(error = "metadata: '#~' header out of range")
  }
  // +0 Reserved u32, +4 Major u8, +5 Minor u8, +6 HeapSizes u8, +7 Reserved u8,
  // +8 Valid u64, +16 Sorted u64, +24 row counts (u32 × popcount(Valid)).
  val heapSizes = rdU8(b, base + 6)
  val validOff  = base + 8
  val present   = popcount64(b, validOff)
  val rowsOff   = base + 24
  if rowsOff + present * 4 > b.length {
    return Err(error = "metadata: '#~' row counts out of range")
  }
  // Walk table ids 0..63 in order; each present table consumes one u32.
  val rowCounts: List[Int] = newList()
  var t = 0
  while t < 64 { rowCounts.add(0)  t = t + 1 }
  var rc = 0
  var tid = 0
  while tid < 64 {
    val byteIdx = tid / 8
    val bitIdx  = tid % 8
    if bitSetInByte(rdU8(b, validOff + byteIdx), bitIdx) {
      rowCounts[tid] = rdU32(b, rowsOff + rc * 4)
      rc = rc + 1
    }
    tid = tid + 1
  }
  Ok(value = TablesHeader(
    heapSizes    = heapSizes,
    stringsWide  = bitSetInByte(heapSizes, 0),
    guidWide     = bitSetInByte(heapSizes, 1),
    blobWide     = bitSetInByte(heapSizes, 2),
    presentCount = present,
    rowCounts    = rowCounts))
}

// Row count for an ECMA table id (0..63); 0 when the table is absent.
pub func rowCountOf(th: in TablesHeader, tableId: in Int): Int {
  if tableId < 0 or tableId >= th.rowCounts.count { return 0 }
  th.rowCounts[tableId]
}
