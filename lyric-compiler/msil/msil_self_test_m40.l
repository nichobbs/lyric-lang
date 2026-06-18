//! msil_self_test_m40.l — Stage M40: volatile. prefix.
//!
//! Builds a PE that exercises the volatile. prefix (0xFE 0x13) on both a
//! store and a load through a managed pointer:
//!   1. ldloca_S 0 / ldc.i4.s 42 / volatile. / stind.i4 — volatile-write 42 to local[0]
//!   2. ldloca_S 0 / volatile. / ldind.i4 / call         — volatile-read local[0] → 42
//!
//! New instruction exercised:
//!   volatile.  (0xFE 0x13) — prefix: memory access must not be cached/reordered.
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//!
//! MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//! StandAloneSig[1]: LocalVarSig {0x07, 0x01, 0x08} — one I4 local
//!
//! Code layout (fat header at 0x248, code at 0x254):
//!   offset  0  12 00              ldloca_S 0   [2]
//!   offset  2  1F 2A              ldc.i4.s 42  [2]
//!   offset  4  FE 13              volatile.    [2]
//!   offset  6  54                 stind.i4     [1]  volatile write
//!   offset  7  12 00              ldloca_S 0   [2]
//!   offset  9  FE 13              volatile.    [2]
//!   offset 11  4A                 ldind.i4     [1]  volatile read
//!   offset 12  28 01 00 00 0A     call WriteLineInt [5]
//!   offset 17  2A                 ret          [1]
//!
//! codeSize = 18. Fat header (12 bytes) at 0x248.
//!
//! localVarSigTok = 0x11000001 at bs[0x250..0x253].
//!
//! first volatile. at code offset 4 = file 0x258.
//! stind.i4 at code offset 6 = file 0x25A.
//! second volatile. at code offset 9 = file 0x25D.
//! ldind.i4 at code offset 11 = file 0x25F.
//!
//! BSJB at 0x248 + 12 + 18 = 0x266.
//!
//! CLR: volatile. store 42 → volatile. load 42 → prints "42".
package Msil.SelfTestM40

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Std.Core
import Std.Collections
import Std.File

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=false")
  }
}

func main(): Unit {
  val outPath = "/tmp/lyric_msil_m40_volatile.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")

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

  // void () sig for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4(0x08)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // LocalVarSig: LOCAL_SIG(0x07) + count=1 + ELEMENT_TYPE_I4(0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07)
  bufU1(lvW, 0x01)
  bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

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

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  // volatile. store: local[0] = 42
  emitLdloca_S(mbMain, 0)
  emitLdc_I4_S(mbMain, 42)
  emitVolatile(mbMain)
  emitStind_I4(mbMain)

  // volatile. load: push local[0] = 42
  emitLdloca_S(mbMain, 0)
  emitVolatile(mbMain)
  emitLdind_I4(mbMain)
  emitCall(mbMain, 0x0A000001)

  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (Hello extends)
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
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 1
    )
  )

  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaMain,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = sMain,
      signature = sigVoid,
      paramList = 1
    )
  )

  // StandAloneSig[1]: LocalVarSig for I4 local
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

  // MemberRef[1]: Console.WriteLine(int)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))

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
  addAssemblyRef(
    t,
    AssemblyRefRow(
      majorVersion = 10,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = keyToken,
      name = sConsoleAsm,
      culture = 0,
      hashValue = 0
    )
  )

  val inp = AssemblerInput(
    entryPointToken = 0x06000001,
    methodBodies = bodies,
    tables = t,
    strings = sh,
    us = uh,
    blobs = bh,
    guids = gh,
    resourceData = newList(),
    buildKind = "lib"
  )
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Fat header at 0x248: flags=0x13, size=0x30
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)

  // localVarSigTok = 0x11000001 at bs[0x250..0x253]
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // first volatile. (0xFE 0x13) at code offset 4 = file 0x258
  check("volatile_store_ok", bs[0x258] == 0xFE and bs[0x259] == 0x13)

  // stind.i4 (0x54) at code offset 6 = file 0x25A
  check("stind_ok", bs[0x25A] == 0x54)

  // second volatile. at code offset 9 = file 0x25D
  check("volatile_load_ok", bs[0x25D] == 0xFE and bs[0x25E] == 0x13)

  // ldind.i4 (0x4A) at code offset 11 = file 0x25F
  check("ldind_ok", bs[0x25F] == 0x4A)

  // BSJB at 0x248 + 12 + 18 = 0x266
  check("bsjb_ok", bs[0x266] == 0x42 and bs[0x267] == 0x53 and bs[0x268] == 0x4A and bs[0x269] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
