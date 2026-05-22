// msil/assembler.l — Single-assembly PE layout engine (Stage M2d / M4).
//
// Takes a populated AssemblerInput (tables, heaps, one or more MethodBodies,
// entry token) and produces a complete, CLR-runnable .NET PE image in a
// ByteWriter.
//
// File layout (FILE_ALIGN = 0x200):
//   0x000–0x07F  DOS stub (128 bytes)
//   0x080–0x1FF  PE/COFF headers + section table, padded to FILE_ALIGN
//   0x200–0x247  CLR IMAGE_COR20_HEADER (72 bytes)
//   0x248–…      Method bodies (each serialized by Msil.Opcodes, in order)
//   <after last body> BSJB metadata root + 5 stream headers + stream data
//   <align>      Zero-padding to FILE_ALIGN
//
// Caller must set MethodDef.rva for each method using methodBodyRvas()
// before calling assemblePe.

package Msil.Assembler

import Msil.Kernel
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Std.Core
import Std.Collections

// RVA at which the first method body begins.
// .text starts at RVA 0x2000; CLR header is 72 bytes.
pub val FIRST_METHOD_RVA: Int = 0x2048

// Input descriptor for the multi-method PE assembler.
pub record AssemblerInput {
  entryPointToken: Int       // e.g. 0x06000001 for MethodDef[1]
  methodBodies:    List[MethodBody]
  tables:          MetadataTables
  strings:         StringHeap
  us:              UsHeap
  blobs:           BlobHeap
  guids:           GuidHeap
}

// ── Internal helpers ──────────────────────────────────────────────────────────

func round4(v: in Int): Int {
  val r = v % 4
  if r == 0 { return v }
  return v + (4 - r)
}

func roundTo(v: in Int, align: in Int): Int {
  val r = v % align
  if r == 0 { return v }
  return v + (align - r)
}

func w2p(w: in ByteWriter, v: in Int): Unit {
  bufU1(w, v % 256)
  bufU1(w, (v / 256) % 256)
}

func w4p(w: in ByteWriter, v: in Int): Unit {
  bufU1(w, v % 256)
  bufU1(w, (v / 256) % 256)
  bufU1(w, (v / 65536) % 256)
  bufU1(w, (v / 16777216) % 256)
}

// ── DOS MZ stub (128 bytes) ───────────────────────────────────────────────────

func writeDos(w: in ByteWriter): Unit {
  bufU1(w, 0x4D)  // 'M'
  bufU1(w, 0x5A)  // 'Z'
  bufZero(w, 58)
  w4p(w, 0x80)    // e_lfanew: PE headers at 0x80
  bufZero(w, 64)
}

// ── PE/COFF headers, padded to file offset 0x200 (384 bytes) ─────────────────

func writePeHdrs(w: in ByteWriter, textVSize: in Int, textRSize: in Int, imgSize: in Int): Unit {
  // PE signature "PE\0\0"
  bufU1(w, 0x50)  bufU1(w, 0x45)  bufU1(w, 0x00)  bufU1(w, 0x00)

  // COFF header (20 bytes)
  w2p(w, 0x014C)   w2p(w, 1)      // Machine=I386, NumberOfSections=1
  w4p(w, 0)        w4p(w, 0)      // TimeDateStamp, PtrToSymbolTable
  w4p(w, 0)                        // NumberOfSymbols
  w2p(w, 224)      w2p(w, 0x0102) // SizeOfOptionalHeader=224, Characteristics

  // PE32 optional header (96 bytes)
  w2p(w, 0x010B)                   // Magic: PE32
  bufU1(w, 0x30)   bufU1(w, 0x00) // MajorLinkerVersion, MinorLinkerVersion
  w4p(w, textRSize)                // SizeOfCode (file-aligned .text)
  w4p(w, 0)        w4p(w, 0)      // SizeOfInitializedData, SizeOfUninitializedData
  w4p(w, 0)                        // AddressOfEntryPoint (managed; set via CLR header)
  w4p(w, 0x2000)                   // BaseOfCode
  w4p(w, 0)                        // BaseOfData
  w4p(w, 0x400000)                 // ImageBase
  w4p(w, 0x2000)                   // SectionAlignment
  w4p(w, 0x200)                    // FileAlignment
  w2p(w, 4)        w2p(w, 0)      // MajorOSVersion, MinorOSVersion
  w2p(w, 0)        w2p(w, 0)      // MajorImageVersion, MinorImageVersion
  w2p(w, 4)        w2p(w, 0)      // MajorSubsystemVersion, MinorSubsystemVersion
  w4p(w, 0)                        // Win32VersionValue
  w4p(w, imgSize)                  // SizeOfImage
  w4p(w, 0x200)                    // SizeOfHeaders
  w4p(w, 0)                        // CheckSum
  w2p(w, 3)        w2p(w, 0)      // Subsystem=CUI, DllCharacteristics
  w4p(w, 0x100000) w4p(w, 0x1000) // SizeOfStackReserve, SizeOfStackCommit
  w4p(w, 0x100000) w4p(w, 0x1000) // SizeOfHeapReserve, SizeOfHeapCommit
  w4p(w, 0)        w4p(w, 16)     // LoaderFlags, NumberOfRvaAndSizes

  // Data directories (128 bytes: 16 × 8)
  bufZero(w, 112)                  // [0..13]: unused
  w4p(w, 0x2000)   w4p(w, 72)     // [14]: CLR runtime header RVA and size
  bufZero(w, 8)                    // [15]: reserved

  // Section table: .text (40 bytes)
  bufU1(w, 0x2E)  bufU1(w, 0x74)  bufU1(w, 0x65)  bufU1(w, 0x78)
  bufU1(w, 0x74)  bufZero(w, 3)   // ".text\0\0\0"
  w4p(w, textVSize)                // VirtualSize (actual content)
  w4p(w, 0x2000)                   // VirtualAddress
  w4p(w, textRSize)                // SizeOfRawData (file-aligned)
  w4p(w, 0x200)                    // PointerToRawData
  w4p(w, 0)        w4p(w, 0)      // PointerToRelocations, PointerToLinenumbers
  w2p(w, 0)        w2p(w, 0)      // NumberOfRelocations, NumberOfLinenumbers
  w4p(w, 0x60000020)              // Characteristics: code+readable+executable

  // Pad to file offset 0x200
  bufZero(w, 96)
}

// ── CLR IMAGE_COR20_HEADER (72 bytes at file offset 0x200) ───────────────────

func writeClrHdr(w: in ByteWriter, mdRva: in Int, mdSize: in Int, entryToken: in Int): Unit {
  w4p(w, 72)          // cb
  w2p(w, 2)           // MajorRuntimeVersion
  w2p(w, 5)           // MinorRuntimeVersion
  w4p(w, mdRva)       // MetaData.VirtualAddress
  w4p(w, mdSize)      // MetaData.Size
  w4p(w, 1)           // Flags: COMIMAGE_FLAGS_ILONLY
  w4p(w, entryToken)  // EntryPointToken
  bufZero(w, 48)      // Resources/StrongName/CodeManager/VTable/Export/ManagedNative
}

// ── BSJB metadata root + 5 stream headers + stream data ──────────────────────

func writeMeta(w: in ByteWriter,
               tildeBuf: in ByteWriter,
               strBuf:   in ByteWriter,
               usBuf:    in ByteWriter,
               blBuf:    in ByteWriter,
               guBuf:    in ByteWriter): Unit {
  // Capture raw sizes before appending
  val tRaw = bufLen(tildeBuf)
  val sRaw = bufLen(strBuf)
  val uRaw = bufLen(usBuf)
  val bRaw = bufLen(blBuf)
  val gRaw = bufLen(guBuf)

  // Padded stream sizes (streams must be 4-byte-aligned per ECMA-335 §II.24.2.2)
  val tSize = round4(tRaw)
  val sSize = round4(sRaw)
  val uSize = round4(uRaw)
  val bSize = round4(bRaw)
  val gSize = round4(gRaw)

  // Stream offsets from BSJB root start.
  // BSJB header = 32 bytes; stream headers = 12+20+12+16+16 = 76 bytes; total = 108.
  val tOff = 108
  val sOff = tOff + tSize
  val uOff = sOff + sSize
  val bOff = uOff + uSize
  val gOff = bOff + bSize

  // BSJB root header (32 bytes)
  bufU1(w, 0x42)  bufU1(w, 0x53)  bufU1(w, 0x4A)  bufU1(w, 0x42)  // "BSJB"
  w2p(w, 1)       w2p(w, 1)       // MajorVersion=1, MinorVersion=1
  w4p(w, 0)                        // Reserved
  w4p(w, 12)                       // VersionLength=12
  // "v4.0.30319\0\0" (12 bytes)
  bufU1(w, 0x76)  bufU1(w, 0x34)  bufU1(w, 0x2E)  bufU1(w, 0x30)  bufU1(w, 0x2E)
  bufU1(w, 0x33)  bufU1(w, 0x30)  bufU1(w, 0x33)  bufU1(w, 0x31)  bufU1(w, 0x39)
  bufU1(w, 0x00)  bufU1(w, 0x00)
  w2p(w, 0)                        // Flags
  w2p(w, 5)                        // NumberOfStreams

  // Stream header 1: "#~\0\0" (12 bytes)
  w4p(w, tOff)    w4p(w, tSize)
  bufU1(w, 0x23)  bufU1(w, 0x7E)  bufU1(w, 0x00)  bufU1(w, 0x00)

  // Stream header 2: "#Strings\0\0\0\0" (20 bytes)
  w4p(w, sOff)    w4p(w, sSize)
  bufU1(w, 0x23)  bufU1(w, 0x53)  bufU1(w, 0x74)  bufU1(w, 0x72)
  bufU1(w, 0x69)  bufU1(w, 0x6E)  bufU1(w, 0x67)  bufU1(w, 0x73)
  bufU1(w, 0x00)  bufU1(w, 0x00)  bufU1(w, 0x00)  bufU1(w, 0x00)

  // Stream header 3: "#US\0" (12 bytes)
  w4p(w, uOff)    w4p(w, uSize)
  bufU1(w, 0x23)  bufU1(w, 0x55)  bufU1(w, 0x53)  bufU1(w, 0x00)

  // Stream header 4: "#Blob\0\0\0" (16 bytes)
  w4p(w, bOff)    w4p(w, bSize)
  bufU1(w, 0x23)  bufU1(w, 0x42)  bufU1(w, 0x6C)  bufU1(w, 0x6F)
  bufU1(w, 0x62)  bufU1(w, 0x00)  bufU1(w, 0x00)  bufU1(w, 0x00)

  // Stream header 5: "#GUID\0\0\0" (16 bytes)
  w4p(w, gOff)    w4p(w, gSize)
  bufU1(w, 0x23)  bufU1(w, 0x47)  bufU1(w, 0x55)  bufU1(w, 0x49)
  bufU1(w, 0x44)  bufU1(w, 0x00)  bufU1(w, 0x00)  bufU1(w, 0x00)

  // Stream data: append each buffer then zero-pad to its declared size
  bufAppend(w, tildeBuf)   bufZero(w, tSize - tRaw)
  bufAppend(w, strBuf)     bufZero(w, sSize - sRaw)
  bufAppend(w, usBuf)      bufZero(w, uSize - uRaw)
  bufAppend(w, blBuf)      bufZero(w, bSize - bRaw)
  bufAppend(w, guBuf)      bufZero(w, gSize - gRaw)
}

// ── Public helpers ────────────────────────────────────────────────────────────

/// Compute the RVA for each method body in `bodies`.
///
/// Returns a list of the same length: `result[i]` is the RVA the caller
/// must assign to `MethodDef[i+1].rva` before calling `assemblePe`.
/// Method bodies are laid out consecutively starting at `FIRST_METHOD_RVA`,
/// with zero-byte padding inserted before any fat-header body so the body's
/// RVA is 4-byte aligned (ECMA-335 II.25.4.5).  Without this padding the
/// JIT rejects the assembly with `InvalidProgramException` whenever a
/// tiny-header method precedes a fat-header method (e.g. when `main` uses
/// any local — see issue #962).
pub func methodBodyRvas(bodies: in List[MethodBody]): List[Int] {
  val rvas: List[Int] = newList()
  var rva = FIRST_METHOD_RVA
  var i = 0
  val count = bodies.count
  while i < count {
    if methodBodyIsFatHeader(bodies[i]) {
      val rem = rva % 4
      if rem != 0 { rva = rva + (4 - rem) }
    }
    rvas.add(rva)
    val buf = bufNew()
    serializeMethodBody(bodies[i], buf)
    rva = rva + bufLen(buf)
    i = i + 1
  }
  return rvas
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Assemble a complete, CLR-runnable PE image.
///
/// Caller must populate `inp.tables` with MethodDef.rva values obtained
/// from `methodBodyRvas(inp.methodBodies)` before calling this function.
pub func assemblePe(inp: in AssemblerInput): ByteWriter {
  // Serialize all method bodies and compute pre-body fat-header alignment
  // padding so the totals match what `methodBodyRvas` produced.  Fat
  // headers must start on a 4-byte boundary (ECMA-335 II.25.4.5); without
  // that, the JIT throws InvalidProgramException whenever a tiny-header
  // method precedes a fat-header method (issue #962).
  val mbBufs: List[ByteWriter] = newList()
  val mbPads: List[Int] = newList()  // bytes of padding to write *before* mbBufs[i]
  var i = 0
  val mbCount = inp.methodBodies.count
  var mbCursor = FIRST_METHOD_RVA
  var mbTotalRaw = 0
  while i < mbCount {
    var pad = 0
    if methodBodyIsFatHeader(inp.methodBodies[i]) {
      val rem = mbCursor % 4
      if rem != 0 { pad = 4 - rem }
    }
    mbPads.add(pad)
    mbCursor = mbCursor + pad
    val buf = bufNew()
    serializeMethodBody(inp.methodBodies[i], buf)
    mbBufs.add(buf)
    mbCursor = mbCursor + bufLen(buf)
    mbTotalRaw = mbTotalRaw + pad + bufLen(buf)
    i = i + 1
  }

  // Serialize heap data
  val strBuf = bufNew()
  serializeStrings(inp.strings, strBuf)

  val usBuf = bufNew()
  serializeUs(inp.us, usBuf)

  val blBuf = bufNew()
  serializeBlobs(inp.blobs, blBuf)

  val guBuf = bufNew()
  serializeGuids(inp.guids, guBuf)

  // Serialize #~ metadata tables stream
  val tildeBuf = bufNew()
  serializeTablesStream(inp.tables, 0, tildeBuf)

  // Compute padded stream sizes
  val tSize = round4(bufLen(tildeBuf))
  val sSize = round4(bufLen(strBuf))
  val uSize = round4(bufLen(usBuf))
  val bSize = round4(bufLen(blBuf))
  val gSize = round4(bufLen(guBuf))

  // metaSize = BSJB header(32) + stream headers(76) + padded stream data
  val metaSize = 108 + tSize + sSize + uSize + bSize + gSize

  // PE layout
  val clrHdrSz  = 72
  val mdRva     = 0x2000 + clrHdrSz + mbTotalRaw   // metadata RVA in .text section
  val textVSize = clrHdrSz + mbTotalRaw + metaSize  // actual content bytes in .text
  val textRSize = roundTo(textVSize, 0x200)          // file-aligned .text size
  val imgSize   = 0x2000 + roundTo(textVSize, 0x2000)  // SizeOfImage

  // Write PE image
  val w = bufNew()
  writeDos(w)                                              // 0x000–0x07F
  writePeHdrs(w, textVSize, textRSize, imgSize)            // 0x080–0x1FF
  writeClrHdr(w, mdRva, metaSize, inp.entryPointToken)     // 0x200–0x247

  // Method bodies (with fat-header alignment padding interleaved)
  var j = 0
  while j < mbCount {
    if mbPads[j] > 0 { bufZero(w, mbPads[j]) }
    bufAppend(w, mbBufs[j])
    j = j + 1
  }

  writeMeta(w, tildeBuf, strBuf, usBuf, blBuf, guBuf)      // metadata
  bufZero(w, textRSize - textVSize)                        // section padding
  return w
}
