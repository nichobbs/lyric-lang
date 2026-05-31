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
// This module currently covers layers 1–5 plus reference-assembly discovery:
// the PE container (DOS/PE/COFF/optional header, sections, RVA→file-offset,
// CLI header), the metadata root (stream headers), the `#~` table-stream
// header (heap-size flags, the valid-table bitvector, per-table row counts),
// the `#Strings`/`#Blob` heap readers, the table layout + TypeDef/MethodDef/
// Param row readers (with run-length method-list ownership), the MethodDefSig
// signature-blob decoder, and a reference-pack discovery + type→assembly
// index.  Overload resolution and the emitter wiring build on top.
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
  tablesDataOff:  Int          // file offset where the table rows begin
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
  // NumberOfRvaAndSizes precedes the data directories (optBase+92 for PE32,
  // optBase+108 for PE32+); the directories themselves start 4 bytes later.
  val numRvaOff   = if isPe32Plus { optBase + 108 } else { optBase + 92 }
  val dataDirStart = numRvaOff + 4
  // CLI header = COM descriptor = data directory index 14, so the image must
  // declare at least 15 directory entries and the entry must lie within the
  // optional header (which spans [optBase, optBase+optHeaderSize)).
  val numRvaAndSizes = rdU32(bytes, numRvaOff)
  if numRvaAndSizes < 15 {
    return Err(error = "metadata: image has only " + toString(numRvaAndSizes)
      + " data directories; no CLI header (index 14)")
  }
  val cliDirOff  = dataDirStart + 14 * 8
  if cliDirOff + 8 > optBase + optHeaderSize {
    return Err(error = "metadata: CLI data directory extends past the optional header")
  }
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
  // Table rows begin after the row-count array.  HeapSizes bit 6 (ExtraData,
  // present in `#-` edit-and-continue streams) inserts one extra u32 first.
  var dataOff = rowsOff + present * 4
  if bitSetInByte(heapSizes, 6) { dataOff = dataOff + 4 }
  Ok(value = TablesHeader(
    heapSizes     = heapSizes,
    stringsWide   = bitSetInByte(heapSizes, 0),
    guidWide      = bitSetInByte(heapSizes, 1),
    blobWide      = bitSetInByte(heapSizes, 2),
    presentCount  = present,
    rowCounts     = rowCounts,
    tablesDataOff = dataOff))
}

// Row count for an ECMA table id (0..63); 0 when the table is absent.
pub func rowCountOf(th: in TablesHeader, tableId: in Int): Int {
  if tableId < 0 or tableId >= th.rowCounts.count { return 0 }
  th.rowCounts[tableId]
}

// ── Layer 3: heaps ───────────────────────────────────────────────────────────

// Read a compressed unsigned integer (ECMA-335 §II.23.2), the inverse of the
// emitter's `writeCompressedUInt`.  Returns (value, bytesConsumed).
pub record CompressedUInt {
  value:     Int
  byteWidth: Int
}

pub func readCompressedUInt(b: in slice[Byte], o: in Int): CompressedUInt {
  val b0 = rdU8(b, o)
  if b0 < 0x80 {
    CompressedUInt(value = b0, byteWidth = 1)
  } else if b0 < 0xC0 {
    CompressedUInt(value = (b0 - 0x80) * 256 + rdU8(b, o + 1), byteWidth = 2)
  } else {
    CompressedUInt(value =
      (b0 - 0xC0) * 16777216 + rdU8(b, o + 1) * 65536
        + rdU8(b, o + 2) * 256 + rdU8(b, o + 3),
      byteWidth = 4)
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
    case None    -> ""
  }
}

// ── Layer 4: table layout + row readers ──────────────────────────────────────

// Computed physical layout for the metadata tables: heap-index and
// coded-index column widths, plus each table's row size and the file offset
// where its rows begin.  Indexed arrays are length 64 (ECMA table id).
pub record TableLayout {
  stringIdx:       Int          // #Strings index width (2 or 4)
  guidIdx:         Int
  blobIdx:         Int
  typeDefOrRefIdx: Int          // TypeDefOrRef coded-index width
  fieldIdx:        Int          // Field simple-index width
  methodIdx:       Int          // MethodDef simple-index width
  paramIdx:        Int          // Param simple-index width
  rowSize:         List[Int]    // length 64
  dataStart:       List[Int]    // length 64, file offset of each table's rows
  stringsBase:     Int          // file offset of the #Strings heap (-1 if absent)
  blobBase:        Int          // file offset of the #Blob heap (-1 if absent)
}

pub record TypeDefRow {
  flags:           Int
  name:            String
  namespaceName:   String
  fieldListStart:  Int          // 1-based Field row
  methodListStart: Int          // 1-based MethodDef row
}

pub record MethodDefRow {
  rva:            Int
  implFlags:      Int
  flags:          Int
  name:           String
  sigBlob:        Int          // #Blob heap index of the MethodDefSig
  paramListStart: Int          // 1-based Param row
}

pub record ParamRow {
  flags:    Int
  sequence: Int
  name:     String
}

// A coded index is 2 bytes when the largest referenced table fits in
// (16 - tagBits) bits, else 4 bytes (ECMA-335 §II.24.2.6).
func codedWidth(maxRows: in Int, tagBits: in Int): Int {
  var limit = 1
  var k = 0
  while k < 16 - tagBits { limit = limit * 2  k = k + 1 }
  if maxRows < limit { 2 } else { 4 }
}

// A simple table index is 2 bytes when the table has fewer than 2^16 rows.
func simpleWidth(th: in TablesHeader, tableId: in Int): Int {
  if rowCountOf(th, tableId) < 65536 { 2 } else { 4 }
}

func maxOf4(a: in Int, b: in Int, c: in Int, d: in Int): Int {
  var m = a
  if b > m { m = b }
  if c > m { m = c }
  if d > m { m = d }
  m
}

// Compute the physical column widths, per-table row sizes, and table data
// offsets.  Only tables 0x00..0x08 (Module..Param) are schema-modelled —
// enough to locate and read TypeDef/MethodDef/Param, which is all the metadata
// reader needs.  Rows of higher tables follow these and never shift their
// offsets, so their sizes are not required here.
pub func computeLayout(img: in PeImage, root: in MetadataRoot,
                       th: in TablesHeader): Result[TableLayout, String] {
  val stringIdx = if th.stringsWide { 4 } else { 2 }
  val guidIdx   = if th.guidWide    { 4 } else { 2 }
  val blobIdx   = if th.blobWide    { 4 } else { 2 }
  val fieldIdx  = simpleWidth(th, 0x04)
  val methodIdx = simpleWidth(th, 0x06)
  val paramIdx  = simpleWidth(th, 0x08)
  // ResolutionScope: Module(0x00), ModuleRef(0x1A), AssemblyRef(0x23), TypeRef(0x01).
  val rsIdx = codedWidth(maxOf4(rowCountOf(th, 0x00), rowCountOf(th, 0x1A),
                                rowCountOf(th, 0x23), rowCountOf(th, 0x01)), 2)
  // TypeDefOrRef: TypeDef(0x02), TypeRef(0x01), TypeSpec(0x1B).
  val tdrIdx = codedWidth(maxOf4(rowCountOf(th, 0x02), rowCountOf(th, 0x01),
                                 rowCountOf(th, 0x1B), 0), 2)

  val rowSize: List[Int] = newList()
  var z = 0
  while z < 64 { rowSize.add(0)  z = z + 1 }
  rowSize[0x00] = 2 + stringIdx + 3 * guidIdx                              // Module
  rowSize[0x01] = rsIdx + 2 * stringIdx                                    // TypeRef
  rowSize[0x02] = 4 + 2 * stringIdx + tdrIdx + fieldIdx + methodIdx        // TypeDef
  rowSize[0x03] = fieldIdx                                                 // FieldPtr
  rowSize[0x04] = 2 + stringIdx + blobIdx                                  // Field
  rowSize[0x05] = methodIdx                                                // MethodPtr
  rowSize[0x06] = 4 + 2 + 2 + stringIdx + blobIdx + paramIdx               // MethodDef
  rowSize[0x07] = paramIdx                                                 // ParamPtr
  rowSize[0x08] = 2 + 2 + stringIdx                                        // Param

  val dataStart: List[Int] = newList()
  var z2 = 0
  while z2 < 64 { dataStart.add(0)  z2 = z2 + 1 }
  var off = th.tablesDataOff
  var tid = 0
  while tid <= 0x08 {
    dataStart[tid] = off
    off = off + rowCountOf(th, tid) * rowSize[tid]
    tid = tid + 1
  }

  val stringsBase = match findStream(root, "#Strings") {
    case Some(s) -> s.fileOff
    case None    -> -1
  }
  val blobBase = match findStream(root, "#Blob") {
    case Some(s) -> s.fileOff
    case None    -> -1
  }
  Ok(value = TableLayout(
    stringIdx = stringIdx, guidIdx = guidIdx, blobIdx = blobIdx,
    typeDefOrRefIdx = tdrIdx, fieldIdx = fieldIdx, methodIdx = methodIdx,
    paramIdx = paramIdx, rowSize = rowSize, dataStart = dataStart,
    stringsBase = stringsBase, blobBase = blobBase))
}

// Read a heap or simple/coded index of `width` (2 or 4) bytes.
func rdIdx(b: in slice[Byte], o: in Int, width: in Int): Int {
  if width == 2 { rdU16(b, o) } else { rdU32(b, o) }
}

// Resolve a #Strings heap index to its string value ("" for index 0).
pub func stringAt(img: in PeImage, layout: in TableLayout, strIndex: in Int): String {
  if strIndex == 0 or layout.stringsBase < 0 { return "" }
  readUtf8Z(img.bytes, layout.stringsBase + strIndex)
}

// Resolve a #Blob heap index to its raw bytes (length-prefixed; empty for 0).
pub func blobAt(img: in PeImage, layout: in TableLayout, blobIndex: in Int): slice[Byte] {
  val empty: List[Byte] = newList()
  if blobIndex == 0 or layout.blobBase < 0 { return empty.toArray() }
  val b = img.bytes
  val hdr = readCompressedUInt(b, layout.blobBase + blobIndex)
  val start = layout.blobBase + blobIndex + hdr.byteWidth
  val acc: List[Byte] = newList()
  var i = 0
  while i < hdr.value and start + i < b.length {
    acc.add(b[start + i])
    i = i + 1
  }
  acc.toArray()
}

// Read TypeDef row `row` (1-based).  Columns (ECMA §II.22.37):
// Flags(u32), Name(#String), Namespace(#String), Extends(TypeDefOrRef),
// FieldList(Field), MethodList(MethodDef).
pub func readTypeDef(img: in PeImage, layout: in TableLayout,
                     row: in Int): TypeDefRow {
  val b = img.bytes
  val o = layout.dataStart[0x02] + (row - 1) * layout.rowSize[0x02]
  val flags = rdU32(b, o)
  var p = o + 4
  val nameI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  val nsI = rdIdx(b, p, layout.stringIdx)
  p = p + layout.stringIdx
  p = p + layout.typeDefOrRefIdx             // skip Extends
  val fieldL = rdIdx(b, p, layout.fieldIdx)
  p = p + layout.fieldIdx
  val methodL = rdIdx(b, p, layout.methodIdx)
  TypeDefRow(
    flags = flags, name = stringAt(img, layout, nameI),
    namespaceName = stringAt(img, layout, nsI),
    fieldListStart = fieldL, methodListStart = methodL)
}

// Read MethodDef row `row` (1-based).  Columns (ECMA §II.22.26):
// RVA(u32), ImplFlags(u16), Flags(u16), Name(#String), Signature(#Blob),
// ParamList(Param).
pub func readMethodDef(img: in PeImage, layout: in TableLayout,
                       row: in Int): MethodDefRow {
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
  MethodDefRow(
    rva = rva, implFlags = implFlags, flags = flags,
    name = stringAt(img, layout, nameI), sigBlob = sigI, paramListStart = paramL)
}

// Read Param row `row` (1-based).  Columns (ECMA §II.22.33):
// Flags(u16), Sequence(u16), Name(#String).
pub func readParam(img: in PeImage, layout: in TableLayout,
                   row: in Int): ParamRow {
  val b = img.bytes
  val o = layout.dataStart[0x08] + (row - 1) * layout.rowSize[0x08]
  val flags = rdU16(b, o)
  val seq   = rdU16(b, o + 2)
  val nameI = rdIdx(b, o + 4, layout.stringIdx)
  ParamRow(flags = flags, sequence = seq, name = stringAt(img, layout, nameI))
}

// Inclusive [start, end] 1-based MethodDef range owned by TypeDef `typeRow`,
// resolved from the run-length method-list ownership (a TypeDef owns the
// MethodDef rows from its MethodList up to the next TypeDef's MethodList, or
// the end of the MethodDef table for the last TypeDef).
pub record RowRange {
  start:  Int    // 1-based, inclusive
  endRow: Int    // 1-based, inclusive; < start means empty
}

pub func methodRange(img: in PeImage, layout: in TableLayout, th: in TablesHeader,
                     typeRow: in Int): RowRange {
  val start = readTypeDef(img, layout, typeRow).methodListStart
  val typeCount = rowCountOf(th, 0x02)
  val last = if typeRow < typeCount {
    readTypeDef(img, layout, typeRow + 1).methodListStart - 1
  } else {
    rowCountOf(th, 0x06)
  }
  RowRange(start = start, endRow = last)
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
}

pub record DecodedMethodSig {
  hasThis:       Bool
  isGeneric:     Bool
  genParamCount: Int
  returnType:    SigType
  paramTypes:    List[SigType]
}

// Element-type bytes that decode to a leaf primitive `STPrim`.
func isPrimByte(et: in Int): Bool {
  (et >= 0x01 and et <= 0x0E) or et == 0x16 or et == 0x18 or et == 0x19 or et == 0x1C
}

// Result of decoding one type: the type plus the offset just past it.
pub record DecodedType {
  ty:   SigType
  next: Int
}

// Decode one Type at offset `o`, skipping any leading custom modifiers
// (CMOD_OPT / CMOD_REQD).
pub func decodeType(b: in slice[Byte], o: in Int): DecodedType {
  var p = o
  // Skip custom modifiers: (CMOD_OPT 0x20 | CMOD_REQD 0x1F) + TypeDefOrRef.
  while p < b.length and (rdU8(b, p) == 0x1F or rdU8(b, p) == 0x20) {
    p = p + 1
    val cm = readCompressedUInt(b, p)
    p = p + cm.byteWidth
  }
  val et = rdU8(b, p)
  p = p + 1
  if et == 0x11 or et == 0x12 {
    val tok = readCompressedUInt(b, p)
    val ty = if et == 0x11 { STValueType(token = tok.value) } else { STClass(token = tok.value) }
    DecodedType(ty = ty, next = p + tok.byteWidth)
  } else if et == 0x13 or et == 0x1E {
    val n = readCompressedUInt(b, p)
    val ty = if et == 0x13 { STVar(index = n.value) } else { STMVar(index = n.value) }
    DecodedType(ty = ty, next = p + n.byteWidth)
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
    val tok = readCompressedUInt(b, cur)
    cur = cur + tok.byteWidth
    val cnt = readCompressedUInt(b, cur)
    cur = cur + cnt.byteWidth
    val args: List[SigType] = newList()
    var i = 0
    while i < cnt.value {
      val a = decodeType(b, cur)
      args.add(a.ty)
      cur = a.next
      i = i + 1
    }
    DecodedType(ty = STGenericInst(valueType = kind == 0x11, token = tok.value, args = args), next = cur)
  } else if et == 0x14 {
    // ARRAY Type ArrayShape(rank numSizes size* numLoBounds loBound*)
    val inner = decodeType(b, p)
    var cur = inner.next
    val rank = readCompressedUInt(b, cur)
    cur = cur + rank.byteWidth
    val numSizes = readCompressedUInt(b, cur)
    cur = cur + numSizes.byteWidth
    var i = 0
    while i < numSizes.value {
      val s = readCompressedUInt(b, cur)
      cur = cur + s.byteWidth
      i = i + 1
    }
    val numLo = readCompressedUInt(b, cur)
    cur = cur + numLo.byteWidth
    var j = 0
    while j < numLo.value {
      val s2 = readCompressedUInt(b, cur)
      cur = cur + s2.byteWidth
      j = j + 1
    }
    DecodedType(ty = STArray(elem = inner.ty, rank = rank.value), next = cur)
  } else if et == 0x1B {
    // FNPTR + MethodDefSig — decode the nested sig to advance past it.
    val nested = decodeMethodSigAt(b, p)
    DecodedType(ty = STFnPtr, next = nested.next)
  } else if isPrimByte(et) {
    DecodedType(ty = STPrim(elemByte = et), next = p)
  } else {
    DecodedType(ty = STUnknown(elemByte = et), next = p)
  }
}

// Result of decoding a method signature: the signature plus the offset past it.
pub record DecodedMethodSigAt {
  sig:  DecodedMethodSig
  next: Int
}

// Decode a MethodDefSig at offset `o` (used both at the blob root and for
// nested FNPTR signatures).
pub func decodeMethodSigAt(b: in slice[Byte], o: in Int): DecodedMethodSigAt {
  val cc = rdU8(b, o)
  var p = o + 1
  val hasThis   = (cc / 32) % 2 == 1   // HASTHIS  (0x20)
  val isGeneric = (cc / 16) % 2 == 1   // GENERIC  (0x10)
  var genCount = 0
  if isGeneric {
    val g = readCompressedUInt(b, p)
    genCount = g.value
    p = p + g.byteWidth
  }
  val pc = readCompressedUInt(b, p)
  p = p + pc.byteWidth
  val ret = decodeType(b, p)
  p = ret.next
  val params: List[SigType] = newList()
  var i = 0
  while i < pc.value and p < b.length {
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
  DecodedMethodSigAt(
    sig = DecodedMethodSig(
      hasThis = hasThis, isGeneric = isGeneric, genParamCount = genCount,
      returnType = ret.ty, paramTypes = params),
    next = p)
}

// Decode a complete MethodDefSig blob.  Returns an error for an empty blob.
pub func decodeMethodSig(blob: in slice[Byte]): Result[DecodedMethodSig, String] {
  if blob.length == 0 {
    return Err(error = "metadata: empty method signature blob")
  }
  Ok(value = decodeMethodSigAt(blob, 0).sig)
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
  val a = match Str.lastIndexOf(path, "/")  { case None -> -1  case Some(i) -> i }
  val b = match Str.lastIndexOf(path, "\\") { case None -> -1  case Some(i) -> i }
  if a > b { a } else { b }
}

// Strip a directory (either separator) + ".dll" extension to the assembly's
// simple name.
func assemblySimpleName(path: in String): String {
  val cut = lastSepIndex(path)
  val base = if cut < 0 { path } else { Str.substring(path, cut + 1, path.length - cut - 1) }
  if Str.endsWith(base, ".dll") { Str.substring(base, 0, base.length - 4) } else { base }
}

// True when `s` is non-empty and all ASCII/Unicode digits.
func isAllDigits(s: in String): Bool {
  if s.length == 0 { return false }
  var i = 0
  while i < s.length {
    if not Ch.isDigit(s[i]) { return false }
    i = i + 1
  }
  true
}

// Natural-order "greater than": compare dot-separated components, numerically
// when both are all-digits (so `10.0.10` > `10.0.9`, which a plain
// lexicographic compare gets wrong), otherwise by code point.
func dirVersionGreater(a: in String, b: in String): Bool {
  val pa = Str.split(a, ".")
  val pb = Str.split(b, ".")
  var i = 0
  while i < pa.length and i < pb.length {
    val x = pa[i]
    val y = pb[i]
    if x != y {
      if isAllDigits(x) and isAllDigits(y) {
        return Parse.parseInt(x) > Parse.parseInt(y)
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
      if names.count == 0 { return None }
      var best = names[0]
      var i = 1
      while i < names.count {
        if dirVersionGreater(names[i], best) { best = names[i] }
        i = i + 1
      }
      Some(value = best)
    }
  }
}

// Candidate .NET install roots, in priority order.
func candidateDotnetRoots(): List[String] {
  val roots: List[String] = newList()
  val dr = Environment.getVarOrDefault("DOTNET_ROOT", "")
  if dr.length > 0 { roots.add(dr) }
  val home = Environment.getVarOrDefault("HOME", "")
  if home.length > 0 { roots.add(Path.join(home, ".dotnet")) }
  roots.add("/usr/share/dotnet")
  roots.add("/usr/lib/dotnet")
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
              case None -> {}
            }
          }
        }
        case None -> {}
      }
    }
    i = i + 1
  }
  None
}

// Full paths of every `*.dll` reference assembly directly inside `refDir`.
pub func enumRefAssemblies(refDir: in String): List[String] {
  val acc: List[String] = newList()
  match File.listFiles(refDir) {
    case Err(_) -> acc
    case Ok(names) -> {
      var i = 0
      while i < names.count {
        if Str.endsWith(names[i], ".dll") { acc.add(Path.join(refDir, names[i])) }
        i = i + 1
      }
      acc
    }
  }
}

// Add every public top-level TypeDef in the assembly at `asmPath` to `index`,
// mapping the type's fully-qualified name to the assembly's simple name.  The
// first assembly to claim a name wins (duplicates across facades are ignored).
// Malformed or unreadable assemblies (read failure, bad PE/metadata) are
// skipped silently — a single broken DLL must not abort building the index.
pub func addAssemblyTypes(index: in Map[String, String], asmPath: in String): Unit {
  match File.readBytes(asmPath) {
    case Err(_) -> {}
    case Ok(raw) -> match readPe(raw.toArray()) {
      case Err(_) -> {}
      case Ok(img) -> match readMetadataRoot(img) {
        case Err(_) -> {}
        case Ok(root) -> match readTablesHeader(img, root) {
          case Err(_) -> {}
          case Ok(th) -> match computeLayout(img, root, th) {
            case Err(_) -> {}
            case Ok(layout) -> {
              val asmName = assemblySimpleName(asmPath)
              val n = rowCountOf(th, 0x02)
              var i = 1
              while i <= n {
                val td = readTypeDef(img, layout, i)
                // Index only Public top-level types (TypeAttributes visibility
                // mask 0x07 == Public); this excludes `<Module>`, nested, and
                // non-public types, which are never extern-resolution targets.
                if (td.flags % 8) == 1 {
                  val fqn = if td.namespaceName.length > 0 {
                    td.namespaceName + "." + td.name
                  } else { td.name }
                  match mapGet(index, fqn) {
                    case Some(_) -> {}
                    case None    -> index.add(fqn, asmName)
                  }
                }
                i = i + 1
              }
            }
          }
        }
      }
    }
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

// Resolve a CLR type's fully-qualified name to its owning assembly's simple
// name, or None when no indexed assembly defines it.
pub func assemblyForType(index: in Map[String, String], typeFqn: in String): Option[String] {
  mapGet(index, typeFqn)
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
  name:       String
  isStatic:   Bool
  isVirtual:  Bool
  returnType: SigType
  paramTypes: List[SigType]
}

// Widening rank for the numeric primitive element types (-1 for non-numeric).
// A narrower type implicitly converts to a wider one: I1<U1<I2<U2<Char<I4<U4
// <I8<U8<R4<R8 (unsigned ranked alongside their signed width).
func numericRank(elemByte: in Int): Int {
  if elemByte == 0x04 { 1 }       // I1
  else if elemByte == 0x05 { 1 }  // U1
  else if elemByte == 0x06 { 2 }  // I2
  else if elemByte == 0x07 { 2 }  // U2
  else if elemByte == 0x03 { 3 }  // CHAR
  else if elemByte == 0x08 { 4 }  // I4
  else if elemByte == 0x09 { 4 }  // U4
  else if elemByte == 0x0A { 5 }  // I8
  else if elemByte == 0x0B { 5 }  // U8
  else if elemByte == 0x0C { 6 }  // R4
  else if elemByte == 0x0D { 7 }  // R8
  else { -1 }
}

// Score one argument against one parameter: 2 = exact, 1 = widening / boxes to
// object, -1 = incompatible.
pub func scoreSigType(arg: in SigType, param: in SigType): Int {
  match param {
    case STPrim(pb) -> match arg {
      case STPrim(ab) -> {
        if ab == pb { 2 }
        else if pb == 0x1C { 1 }                       // object accepts anything
        else {
          val ra = numericRank(ab)
          val rp = numericRank(pb)
          if ra >= 0 and rp >= 0 and ra <= rp { 1 } else { -1 }
        }
      }
      case _ -> if pb == 0x1C { 1 } else { -1 }          // object accepts references
    }
    case STClass(pt) -> match arg {
      case STClass(at) -> if at == pt { 2 } else { -1 }
      case _ -> -1
    }
    case STValueType(pt) -> match arg {
      case STValueType(at) -> if at == pt { 2 } else { -1 }
      case _ -> -1
    }
    case STSzArray(pe) -> match arg {
      case STSzArray(ae) -> scoreSigType(ae, pe)
      case _ -> -1
    }
    case _ -> -1
  }
}

// Score a whole candidate against the argument list: the sum of per-parameter
// scores, or -1 on arity mismatch or any incompatible parameter.
pub func scoreOverload(argTypes: in List[SigType], sig: in DecodedMethodSig): Int {
  if sig.paramTypes.count != argTypes.count { return -1 }
  var total = 0
  var i = 0
  while i < argTypes.count {
    val s = scoreSigType(argTypes[i], sig.paramTypes[i])
    if s < 0 { return -1 }
    total = total + s
    i = i + 1
  }
  total
}

// Find the TypeDef row (1-based) whose fully-qualified name is `typeFqn`, or
// -1 when absent.
pub func findTypeDefByFqn(img: in PeImage, layout: in TableLayout, th: in TablesHeader,
                          typeFqn: in String): Int {
  val n = rowCountOf(th, 0x02)
  var i = 1
  while i <= n {
    val td = readTypeDef(img, layout, i)
    val fqn = if td.namespaceName.length > 0 {
      td.namespaceName + "." + td.name
    } else { td.name }
    if fqn == typeFqn { return i }
    i = i + 1
  }
  -1
}

// MethodAttributes: Static = 0x0010, Virtual = 0x0040.
func methodIsStatic(flags: in Int): Bool { (flags / 16) % 2 == 1 }
func methodIsVirtual(flags: in Int): Bool { (flags / 64) % 2 == 1 }

// Resolve the best-matching overload of `member` on `typeFqn` for `argTypes`,
// reading from already-parsed metadata.  Returns None when the type is absent
// or no overload is compatible.
pub func resolveOverloadIn(img: in PeImage, layout: in TableLayout, th: in TablesHeader,
                           typeFqn: in String, member: in String,
                           argTypes: in List[SigType]): Option[ResolvedMethod] {
  val typeRow = findTypeDefByFqn(img, layout, th, typeFqn)
  if typeRow < 0 { return None }
  val mr = methodRange(img, layout, th, typeRow)
  var best: Option[ResolvedMethod] = None
  var bestScore = -1
  var mi = mr.start
  while mi <= mr.endRow {
    val md = readMethodDef(img, layout, mi)
    if md.name == member {
      match decodeMethodSig(blobAt(img, layout, md.sigBlob)) {
        case Err(_) -> {}
        case Ok(sig) -> {
          val score = scoreOverload(argTypes, sig)
          if score >= 0 and score > bestScore {
            bestScore = score
            best = Some(value = ResolvedMethod(
              name = md.name,
              isStatic = not sig.hasThis,
              isVirtual = methodIsVirtual(md.flags),
              returnType = sig.returnType,
              paramTypes = sig.paramTypes))
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
pub func resolveOverload(asmPath: in String, typeFqn: in String, member: in String,
                         argTypes: in List[SigType]): Option[ResolvedMethod] {
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
            case Ok(layout) -> resolveOverloadIn(img, layout, th, typeFqn, member, argTypes)
          }
        }
      }
    }
  }
}
