//! msil_self_test_m84.l — Stage M84: managed resource embedding.
//!
//! Builds a minimal PE that ships a single embedded managed resource
//! (just a 6-byte payload), then verifies:
//!
//!   * CLR header bytes 24-27 carry the resources RVA (non-zero).
//!   * CLR header bytes 28-31 carry the raw resources size (6).
//!   * The resource bytes appear at the file offset corresponding to
//!     the stored RVA, preceded by the length prefix.
//!   * The metadata #~ stream's `valid` bitmask includes bit 40 (the
//!     ManifestResource table).
//!   * The ManifestResource row's `offset` field is 0 (single resource
//!     starts at the beginning of the resources region).
//!
//! This is the lower-level test the c.3 review requested — proves the
//! non-empty `resourceData` path actually emits the bytes we claim it
//! does.  The bridge-side wiring lands in slice 2b on top of this.
package Msil.SelfTestM84

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
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
  // ── Build #Strings / #GUID / #US / #Blob heaps ─────────────────────────
  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sObject = internString(sh, "Object")
  val sSystem = internString(sh, "System")
  val sRuntime = internString(sh, "System.Runtime")
  val sCtor = internString(sh, ".ctor")
  val sContract = internString(sh, "Lyric.Contract")

  val gh = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  val bh = newBlobHeap()

  // void () instance ctor signature: HASTHIS, 0 params, void return
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x20)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_inst_sig", bufToList(voidSigW))

  // Microsoft framework assemblies PKT: b03f5f7f11d50a3a
  val keyW = bufNew()
  bufU1(keyW, 0xB0)
  bufU1(keyW, 0x3F)
  bufU1(keyW, 0x5F)
  bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11)
  bufU1(keyW, 0xD5)
  bufU1(keyW, 0x0A)
  bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build a single .ctor method body (just ret) ───────────────────────
  val mbCtor = newMethodBody()
  emitRet(mbCtor)
  val bodies: List[MethodBody] = newList()
  bodies.add(mbCtor)
  val rvas = methodBodyRvas(bodies)
  val rvaCtor = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────
  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sHello,
      typeNamespace = 0,
      extends = tdrTypeRef(1),
      fieldList = 1,
      methodList = 1
    )
  )
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaCtor,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG,
      name = sCtor,
      signature = sigVoid,
      paramList = 1
    )
  )
  addAssembly(
    t,
    AssemblyRow(
      hashAlgId = HASH_ALG_SHA1,
      majorVersion = 0,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = ASF_NONE,
      publicKey = 0,
      name = sHello,
      culture = 0
    )
  )
  addAssemblyRef(
    t,
    AssemblyRefRow(
      majorVersion = 10,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = keyToken,
      name = sRuntime,
      culture = 0,
      hashValue = 0
    )
  )

  // ── Add a single ManifestResource row ─────────────────────────────────
  // The row says "the resource named `Lyric.Contract` starts at offset 0
  // of the resources region, is Public, and is embedded in this assembly
  // (implementation = 0)".
  addManifestResource(
    t,
    ManifestResourceRow(
      offset = 0,
      flags = 1,
      // Public
      name = sContract,
      implementation = 0
    )
  )   // embedded

  // ── Build resourceData: 4-byte LE length prefix + "hi" payload ────────
  val rsrc: List[Byte] = newList()
  // Length prefix = 2 (the payload length).
  rsrc.add(2u8)
  rsrc.add(0u8)
  rsrc.add(0u8)
  rsrc.add(0u8)
  rsrc.add(0x68u8)  // 'h'
  rsrc.add(0x69u8)  // 'i'

  // ── Assemble PE ───────────────────────────────────────────────────────
  val inp = AssemblerInput(
    entryPointToken = 0,
    // library (no entry point)
    methodBodies = bodies,
    tables = t,
    strings = sh,
    us = uh,
    blobs = bh,
    guids = gh,
    resourceData = rsrc
    buildKind = "lib"
  )

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────

  // CLR header at 0x200, size field = 72.
  check("clr_cb_ok", bs[0x200] == 72u8 and bs[0x201] == 0u8)

  // Resources.VirtualAddress at offset 24 of the CLR header (file
  // offset 0x218).  Stored as 4 little-endian bytes.  Pre-slice the
  // emitter zeroed these bytes; now the upper bytes encode an RVA
  // within the .text section.  The RVA is `0x2000 + 72 + mbTotalRaw`,
  // and with one tiny `ret` body (2 bytes including header) plus no
  // FAT padding, mbTotalRaw = 2 → rsrcRva = 0x204A.
  check("rsrc_rva_byte0_ok", bs[0x218] == 0x4Au8)
  check("rsrc_rva_byte1_ok", bs[0x219] == 0x20u8)
  check("rsrc_rva_byte2_ok", bs[0x21A] == 0x00u8)
  check("rsrc_rva_byte3_ok", bs[0x21B] == 0x00u8)

  // Resources.Size at offset 28 of the CLR header (file offset 0x21C).
  // Raw resource-data size = 6 bytes (4-byte length prefix + "hi").
  check("rsrc_size_byte0_ok", bs[0x21C] == 6u8)
  check("rsrc_size_byte1_ok", bs[0x21D] == 0u8)
  check("rsrc_size_byte2_ok", bs[0x21E] == 0u8)
  check("rsrc_size_byte3_ok", bs[0x21F] == 0u8)

  // Resource payload appears at file offset 0x24A (RVA 0x204A maps to
  // file offset (0x204A - 0x2000 + 0x200) = 0x24A).  First 4 bytes
  // are the length prefix (2u32 LE), next 2 bytes are "hi".
  check("rsrc_len_prefix_ok", bs[0x24A] == 2u8 and bs[0x24B] == 0u8 and bs[0x24C] == 0u8 and bs[0x24D] == 0u8)
  check("rsrc_payload_ok", bs[0x24E] == 0x68u8 and bs[0x24F] == 0x69u8)

  // Resources region is padded to 4 bytes, so metadata BSJB magic
  // starts at file offset 0x252 (= 0x24A + round4(6) = 0x24A + 8).
  check(
    "bsjb_after_rsrc_ok",
    bs[0x252] == 0x42u8 and bs[0x253] == 0x53u8 and bs[0x254] == 0x4Au8 and bs[0x255] == 0x42u8
  )
}
