package Msil.Pe

import Msil.Kernel
import Std.Core
import Std.Collections

// ---------------------------------------------------------------------------
// Stage M1: fixed-layout PE/COFF + CLR metadata for a minimal "Hello" assembly.
//
// File layout (1024 bytes total):
//   0x000–0x07F  DOS stub          (128 bytes)
//   0x080–0x1FF  PE/COFF headers   (384 bytes, padded to file-align 0x200)
//   0x200–0x247  CLR header        ( 72 bytes, IMAGE_COR20_HEADER)
//   0x248–0x253  Method body       ( 12 bytes, tiny-format MSIL for Main)
//   0x254–0x3EB  Metadata          (408 bytes, BSJB root + 5 streams)
//   0x3EC–0x3FF  Padding           ( 20 bytes, section raw-data alignment)
//
// RVA base for .text section: 0x2000.
// All multi-byte values are little-endian.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// DOS stub (128 bytes, offsets 0x000–0x07F)
// ---------------------------------------------------------------------------
func writeDosStub(w: in ByteWriter): Unit {
  bufU1(w, 0x4D)  // MZ
  bufU1(w, 0x5A)
  bufZero(w, 58)  // unused DOS header fields 0x02–0x3B
  bufU4(w, 0x80)  // e_lfanew: PE headers at file offset 0x80
  bufZero(w, 64)  // unused stub code 0x40–0x7F
}

// ---------------------------------------------------------------------------
// PE/COFF headers + section table, padded to file offset 0x200 (384 bytes)
// ---------------------------------------------------------------------------
func writePeHeaders(w: in ByteWriter): Unit {
  // PE signature "PE\0\0"
  bufU1(w, 0x50)
  bufU1(w, 0x45)
  bufU1(w, 0x00)
  bufU1(w, 0x00)

  // COFF header (20 bytes)
  bufU2(w, 0x014C)  // Machine: I386
  bufU2(w, 1)       // NumberOfSections
  bufU4(w, 0)       // TimeDateStamp
  bufU4(w, 0)       // PointerToSymbolTable
  bufU4(w, 0)       // NumberOfSymbols
  bufU2(w, 224)     // SizeOfOptionalHeader
  bufU2(w, 0x0102)  // Characteristics: executable + 32-bit

  // PE32 optional header — fixed fields (96 bytes)
  bufU2(w, 0x010B)    // Magic: PE32
  bufU1(w, 0x30)      // MajorLinkerVersion
  bufU1(w, 0x00)      // MinorLinkerVersion
  bufU4(w, 0x200)     // SizeOfCode
  bufU4(w, 0)         // SizeOfInitializedData
  bufU4(w, 0)         // SizeOfUninitializedData
  bufU4(w, 0)         // AddressOfEntryPoint (managed entry via CLR header)
  bufU4(w, 0x2000)    // BaseOfCode
  bufU4(w, 0)         // BaseOfData
  bufU4(w, 0x400000)  // ImageBase
  bufU4(w, 0x2000)    // SectionAlignment
  bufU4(w, 0x200)     // FileAlignment
  bufU2(w, 4)         // MajorOSVersion
  bufU2(w, 0)         // MinorOSVersion
  bufU2(w, 0)         // MajorImageVersion
  bufU2(w, 0)         // MinorImageVersion
  bufU2(w, 4)         // MajorSubsystemVersion
  bufU2(w, 0)         // MinorSubsystemVersion
  bufU4(w, 0)         // Win32VersionValue
  bufU4(w, 0x4000)    // SizeOfImage  (2 sections × 0x2000 alignment)
  bufU4(w, 0x200)     // SizeOfHeaders
  bufU4(w, 0)         // CheckSum
  bufU2(w, 3)         // Subsystem: CUI
  bufU2(w, 0)         // DllCharacteristics
  bufU4(w, 0x100000)  // SizeOfStackReserve
  bufU4(w, 0x1000)    // SizeOfStackCommit
  bufU4(w, 0x100000)  // SizeOfHeapReserve
  bufU4(w, 0x1000)    // SizeOfHeapCommit
  bufU4(w, 0)         // LoaderFlags
  bufU4(w, 16)        // NumberOfRvaAndSizes

  // Data directories (128 bytes, 16 × 8)
  bufZero(w, 112)     // [0..13]: all unused
  bufU4(w, 0x2000)    // [14] CLR runtime header RVA
  bufU4(w, 72)        // [14] CLR runtime header size
  bufZero(w, 8)       // [15]: reserved

  // Section table: .text only (40 bytes)
  bufU1(w, 0x2E)  // '.'
  bufU1(w, 0x74)  // 't'
  bufU1(w, 0x65)  // 'e'
  bufU1(w, 0x78)  // 'x'
  bufU1(w, 0x74)  // 't'
  bufZero(w, 3)   // name zero-padding to 8 bytes
  bufU4(w, 0x1EC)       // VirtualSize: 492 bytes of actual content
  bufU4(w, 0x2000)      // VirtualAddress
  bufU4(w, 0x200)       // SizeOfRawData (file-aligned)
  bufU4(w, 0x200)       // PointerToRawData
  bufU4(w, 0)           // PointerToRelocations
  bufU4(w, 0)           // PointerToLinenumbers
  bufU2(w, 0)           // NumberOfRelocations
  bufU2(w, 0)           // NumberOfLinenumbers
  bufU4(w, 0x60000020)  // Characteristics: code + readable + executable

  // Pad headers to file offset 0x200
  bufZero(w, 96)
}

// ---------------------------------------------------------------------------
// CLR header IMAGE_COR20_HEADER (72 bytes, at file offset 0x200, RVA 0x2000)
// ---------------------------------------------------------------------------
func writeClrHeader(w: in ByteWriter): Unit {
  bufU4(w, 72)          // cb
  bufU2(w, 2)           // MajorRuntimeVersion
  bufU2(w, 5)           // MinorRuntimeVersion
  bufU4(w, 0x2054)      // MetaData.VirtualAddress (0x2000 + 0x48 CLR + 0x0C method)
  bufU4(w, 408)         // MetaData.Size
  bufU4(w, 1)           // Flags: COMIMAGE_FLAGS_ILONLY
  bufU4(w, 0x06000001)  // EntryPointToken: MethodDef[1]
  bufZero(w, 48)        // Resources/StrongName/CodeManager/VTable/Export/ManagedNative
}

// ---------------------------------------------------------------------------
// Method body for Main() (12 bytes, tiny format, at file offset 0x248, RVA 0x2048)
//
//   2E          tiny header: (11 << 2) | 2
//   72 01 00 00 70   ldstr  #US[1]       "Hello, World!\n"
//   28 01 00 00 0A   call   MemberRef[1] System.Console::WriteLine(string)
//   2A               ret
// ---------------------------------------------------------------------------
func writeMethodBody(w: in ByteWriter): Unit {
  bufU1(w, 0x2E)  // tiny header
  bufU1(w, 0x72)  // ldstr
  bufU1(w, 0x01)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x70)
  bufU1(w, 0x28)  // call
  bufU1(w, 0x01)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x0A)
  bufU1(w, 0x2A)  // ret
}

// ---------------------------------------------------------------------------
// Metadata streams
// ---------------------------------------------------------------------------
// #Strings heap (68 bytes)
func writeStringsHeap(w: in ByteWriter): Unit {
  bufU1(w, 0x00)  // empty string at offset 0
  // "<Module>\0" at offset 0x01
  bufU1(w, 0x3C)
  bufU1(w, 0x4D)
  bufU1(w, 0x6F)
  bufU1(w, 0x64)
  bufU1(w, 0x75)
  bufU1(w, 0x6C)
  bufU1(w, 0x65)
  bufU1(w, 0x3E)
  bufU1(w, 0x00)
  // "Hello\0" at offset 0x0A
  bufU1(w, 0x48)
  bufU1(w, 0x65)
  bufU1(w, 0x6C)
  bufU1(w, 0x6C)
  bufU1(w, 0x6F)
  bufU1(w, 0x00)
  // "Main\0" at offset 0x10
  bufU1(w, 0x4D)
  bufU1(w, 0x61)
  bufU1(w, 0x69)
  bufU1(w, 0x6E)
  bufU1(w, 0x00)
  // "System\0" at offset 0x15
  bufU1(w, 0x53)
  bufU1(w, 0x79)
  bufU1(w, 0x73)
  bufU1(w, 0x74)
  bufU1(w, 0x65)
  bufU1(w, 0x6D)
  bufU1(w, 0x00)
  // "Console\0" at offset 0x1C
  bufU1(w, 0x43)
  bufU1(w, 0x6F)
  bufU1(w, 0x6E)
  bufU1(w, 0x73)
  bufU1(w, 0x6F)
  bufU1(w, 0x6C)
  bufU1(w, 0x65)
  bufU1(w, 0x00)
  // "System.Runtime\0" at offset 0x24
  bufU1(w, 0x53)
  bufU1(w, 0x79)
  bufU1(w, 0x73)
  bufU1(w, 0x74)
  bufU1(w, 0x65)
  bufU1(w, 0x6D)
  bufU1(w, 0x2E)
  bufU1(w, 0x52)
  bufU1(w, 0x75)
  bufU1(w, 0x6E)
  bufU1(w, 0x74)
  bufU1(w, 0x69)
  bufU1(w, 0x6D)
  bufU1(w, 0x65)
  bufU1(w, 0x00)
  // "Object\0" at offset 0x33
  bufU1(w, 0x4F)
  bufU1(w, 0x62)
  bufU1(w, 0x6A)
  bufU1(w, 0x65)
  bufU1(w, 0x63)
  bufU1(w, 0x74)
  bufU1(w, 0x00)
  // "WriteLine\0" at offset 0x3A
  bufU1(w, 0x57)
  bufU1(w, 0x72)
  bufU1(w, 0x69)
  bufU1(w, 0x74)
  bufU1(w, 0x65)
  bufU1(w, 0x4C)
  bufU1(w, 0x69)
  bufU1(w, 0x6E)
  bufU1(w, 0x65)
  bufU1(w, 0x00)
}

// #US heap (32 bytes): "Hello, World!\n" in UTF-16LE
func writeUsHeap(w: in ByteWriter): Unit {
  bufU1(w, 0x00)  // empty string blob at offset 0
  bufU1(w, 0x1D)  // blob length: 29 (28 UTF-16LE bytes + 1 ECMA marker)
  bufU1(w, 0x48)
  bufU1(w, 0x00)  // H
  bufU1(w, 0x65)
  bufU1(w, 0x00)  // e
  bufU1(w, 0x6C)
  bufU1(w, 0x00)  // l
  bufU1(w, 0x6C)
  bufU1(w, 0x00)  // l
  bufU1(w, 0x6F)
  bufU1(w, 0x00)  // o
  bufU1(w, 0x2C)
  bufU1(w, 0x00)  // ,
  bufU1(w, 0x20)
  bufU1(w, 0x00)  // (space)
  bufU1(w, 0x57)
  bufU1(w, 0x00)  // W
  bufU1(w, 0x6F)
  bufU1(w, 0x00)  // o
  bufU1(w, 0x72)
  bufU1(w, 0x00)  // r
  bufU1(w, 0x6C)
  bufU1(w, 0x00)  // l
  bufU1(w, 0x64)
  bufU1(w, 0x00)  // d
  bufU1(w, 0x21)
  bufU1(w, 0x00)  // !
  bufU1(w, 0x0A)
  bufU1(w, 0x00)  // \n
  bufU1(w, 0x00)  // ECMA-335 §II.24.2.4 no-high-chars marker
  bufU1(w, 0x00)  // heap-size padding to 32 bytes
}

// #Blob heap (20 bytes)
func writeBlobHeap(w: in ByteWriter): Unit {
  bufU1(w, 0x00)  // empty blob at offset 0
  // Main() method signature at offset 0x01: calling-conv=default, 0 params, void
  bufU1(w, 0x03)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x01)
  // Console.WriteLine(string) signature at offset 0x05: default, 1 param, void, string
  bufU1(w, 0x04)
  bufU1(w, 0x00)
  bufU1(w, 0x01)
  bufU1(w, 0x01)
  bufU1(w, 0x0E)
  // System.Runtime public key token (8 bytes) at offset 0x0A: b03f5f7f11d50a3a
  bufU1(w, 0x08)
  bufU1(w, 0xB0)
  bufU1(w, 0x3F)
  bufU1(w, 0x5F)
  bufU1(w, 0x7F)
  bufU1(w, 0x11)
  bufU1(w, 0xD5)
  bufU1(w, 0x0A)
  bufU1(w, 0x3A)
  bufU1(w, 0x00)  // padding to 20 bytes
}

// #GUID heap (16 bytes): all-zero GUID for Mvid
func writeGuidHeap(w: in ByteWriter): Unit {
  bufZero(w, 16)
}

// #~ (tables) stream (164 bytes)
func writeTildeStream(w: in ByteWriter): Unit {
  // Stream header (24 bytes)
  bufU4(w, 0)           // Reserved
  bufU1(w, 2)           // MajorVersion
  bufU1(w, 0)           // MinorVersion
  bufU1(w, 0)           // HeapSizes: all indices 2 bytes
  bufU1(w, 1)           // Reserved (must be 1)
  // Valid mask (LE64): tables Module|TypeRef|TypeDef|MethodDef|MemberRef|Assembly|AssemblyRef
  bufU4(w, 0x447)       // low 32 bits: bits 0,1,2,6,10 = Module+TypeRef+TypeDef+MethodDef+MemberRef
  bufU4(w, 0x9)         // high 32 bits: bits 32,35 = Assembly+AssemblyRef
  // Sorted mask (LE64): standard Roslyn value
  bufU4(w, 0x16003325)
  bufU4(w, 0)

  // Row counts (7 × 4 bytes = 28 bytes)
  bufU4(w, 1)  // Module
  bufU4(w, 2)  // TypeRef
  bufU4(w, 2)  // TypeDef
  bufU4(w, 1)  // MethodDef
  bufU4(w, 1)  // MemberRef
  bufU4(w, 1)  // Assembly
  bufU4(w, 1)  // AssemblyRef

  // Module[1]: Generation=0, Name="Hello", Mvid=GUID[1]
  bufU2(w, 0)       // Generation
  bufU2(w, 0x0A)    // Name → "Hello"
  bufU2(w, 1)       // Mvid → GUID[1]
  bufU2(w, 0)       // EncId
  bufU2(w, 0)       // EncBaseId

  // TypeRef[1]: System.Console (in System, AssemblyRef[1])
  bufU2(w, 6)       // ResolutionScope: AssemblyRef[1] = (1<<2)|2
  bufU2(w, 0x1C)    // TypeName → "Console"
  bufU2(w, 0x15)    // TypeNamespace → "System"

  // TypeRef[2]: System.Object (in System, AssemblyRef[1])
  bufU2(w, 6)       // ResolutionScope: AssemblyRef[1]
  bufU2(w, 0x33)    // TypeName → "Object"
  bufU2(w, 0x15)    // TypeNamespace → "System"

  // TypeDef[1]: <Module> (pseudo-type for module-scope members)
  bufU4(w, 0)       // Flags
  bufU2(w, 1)       // TypeName → "<Module>"
  bufU2(w, 0)       // TypeNamespace → ""
  bufU2(w, 0)       // Extends: none
  bufU2(w, 1)       // FieldList
  bufU2(w, 1)       // MethodList (before Hello's methods)

  // TypeDef[2]: Hello extends TypeRef[2] (Object)
  bufU4(w, 1)       // Flags: tdPublic
  bufU2(w, 0x0A)    // TypeName → "Hello"
  bufU2(w, 0)       // TypeNamespace → ""
  bufU2(w, 9)       // Extends: TypeRef[2] = (2<<2)|1
  bufU2(w, 1)       // FieldList
  bufU2(w, 1)       // MethodList → MethodDef[1]

  // MethodDef[1]: Main (RVA 0x2048, public static HideBySig)
  bufU4(w, 0x2048)  // RVA
  bufU2(w, 0)       // ImplFlags: Managed|IL
  bufU2(w, 0x0096)  // Flags: Public|Static|HideBySig
  bufU2(w, 0x10)    // Name → "Main"
  bufU2(w, 1)       // Signature → blob[1] (void())
  bufU2(w, 1)       // ParamList

  // MemberRef[1]: System.Console.WriteLine(string)
  bufU2(w, 9)       // Class: TypeRef[1] = (1<<3)|1
  bufU2(w, 0x3A)    // Name → "WriteLine"
  bufU2(w, 5)       // Signature → blob[5] (void(string))

  // Assembly[1]: Hello v0.0.0.0
  bufU4(w, 0x8004)  // HashAlgId: SHA1
  bufU2(w, 0)       // MajorVersion
  bufU2(w, 0)       // MinorVersion
  bufU2(w, 0)       // BuildNumber
  bufU2(w, 0)       // RevisionNumber
  bufU4(w, 0)       // Flags
  bufU2(w, 0)       // PublicKey: none
  bufU2(w, 0x0A)    // Name → "Hello"
  bufU2(w, 0)       // Culture: neutral

  // AssemblyRef[1]: System.Runtime v10.0.0.0
  bufU2(w, 10)      // MajorVersion
  bufU2(w, 0)       // MinorVersion
  bufU2(w, 0)       // BuildNumber
  bufU2(w, 0)       // RevisionNumber
  bufU4(w, 0)       // Flags
  bufU2(w, 0x0A)    // PublicKeyOrToken → blob[0x0A] (b03f5f7f11d50a3a)
  bufU2(w, 0x24)    // Name → "System.Runtime"
  bufU2(w, 0)       // Culture
  bufU2(w, 0)       // HashValue
}

// Metadata root (BSJB header + stream headers, 108 bytes) followed by all streams
func writeMetadata(w: in ByteWriter): Unit {
  // BSJB root header (32 bytes)
  bufU1(w, 0x42)
  bufU1(w, 0x53)
  bufU1(w, 0x4A)
  bufU1(w, 0x42)  // "BSJB"
  bufU2(w, 1)     // MajorVersion
  bufU2(w, 1)     // MinorVersion
  bufU4(w, 0)     // Reserved
  bufU4(w, 12)    // VersionLength
  // "v4.0.30319\0\0"
  bufU1(w, 0x76)
  bufU1(w, 0x34)
  bufU1(w, 0x2E)
  bufU1(w, 0x30)
  bufU1(w, 0x2E)
  bufU1(w, 0x33)
  bufU1(w, 0x30)
  bufU1(w, 0x33)
  bufU1(w, 0x31)
  bufU1(w, 0x39)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU2(w, 0)     // Flags
  bufU2(w, 5)     // NumberOfStreams

  // Stream header 1: #~ (offset=108, size=164)
  bufU4(w, 108)
  bufU4(w, 164)
  bufU1(w, 0x23)
  bufU1(w, 0x7E)
  bufU1(w, 0x00)
  bufU1(w, 0x00)  // "#~\0\0"

  // Stream header 2: #Strings (offset=272, size=68)
  bufU4(w, 272)
  bufU4(w, 68)
  bufU1(w, 0x23)
  bufU1(w, 0x53)
  bufU1(w, 0x74)
  bufU1(w, 0x72)
  bufU1(w, 0x69)
  bufU1(w, 0x6E)
  bufU1(w, 0x67)
  bufU1(w, 0x73)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x00)  // "#Strings\0\0\0\0"

  // Stream header 3: #US (offset=340, size=32)
  bufU4(w, 340)
  bufU4(w, 32)
  bufU1(w, 0x23)
  bufU1(w, 0x55)
  bufU1(w, 0x53)
  bufU1(w, 0x00)  // "#US\0"

  // Stream header 4: #Blob (offset=372, size=20)
  bufU4(w, 372)
  bufU4(w, 20)
  bufU1(w, 0x23)
  bufU1(w, 0x42)
  bufU1(w, 0x6C)
  bufU1(w, 0x6F)
  bufU1(w, 0x62)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x00)  // "#Blob\0\0\0"

  // Stream header 5: #GUID (offset=392, size=16)
  bufU4(w, 392)
  bufU4(w, 16)
  bufU1(w, 0x23)
  bufU1(w, 0x47)
  bufU1(w, 0x55)
  bufU1(w, 0x49)
  bufU1(w, 0x44)
  bufU1(w, 0x00)
  bufU1(w, 0x00)
  bufU1(w, 0x00)  // "#GUID\0\0\0"

  // Streams in declared order
  writeTildeStream(w)    // 164 bytes
  writeStringsHeap(w)    //  68 bytes
  writeUsHeap(w)         //  32 bytes
  writeBlobHeap(w)       //  20 bytes
  writeGuidHeap(w)       //  16 bytes
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------
// Build the complete 1024-byte PE image into a fresh buffer and return it.
// Callers that only need the byte count can call bufLen on the result;
// callers that need the bytes call bufToList on the result.
pub func buildHelloAssemblyBuf(): ByteWriter {
  val w = bufNew()
  writeDosStub(w)    // 0x000–0x07F
  writePeHeaders(w)  // 0x080–0x1FF
  writeClrHeader(w)  // 0x200–0x247
  writeMethodBody(w) // 0x248–0x253
  writeMetadata(w)   // 0x254–0x3EB
  bufPadTo(w, 0x200) // 0x3EC–0x3FF (20 bytes padding)
  return w
}

pub func buildHelloAssembly(): List[Byte] {
  return bufToList(buildHelloAssemblyBuf())
}

// Return the byte length of the generated image (1024 expected).
pub func buildHelloAssemblySize(): Int {
  return bufLen(buildHelloAssemblyBuf())
}
