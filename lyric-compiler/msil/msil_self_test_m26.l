//! msil_self_test_m26.l — Stage M26: newarr + ldelem + stelem (managed arrays).
//!
//! Builds a PE whose Main() creates a 2-element int32 array, stores 21 at
//! index 0 and 21 at index 1, then loads both elements, adds them (42), and
//! calls Console.WriteLine(int).  The CLR prints "42".
//!
//! New instructions exercised:
//!   newarr  (0x8D) — allocates a new zero-based, single-dimension array
//!   stelem  (0xA4) — stores an element into an array at a given index
//!   ldelem  (0xA3) — loads an element from an array at a given index
//!
//! Code layout (fat header at 0x248, code at 0x254):
//!   offset  0  19                  ldc.i4.2              [1]  array length = 2
//!   offset  1  8D 03 00 00 01      newarr TypeRef[3]     [5]  → int32[]
//!   offset  6  0A                  stloc.0               [1]  arr = local 0
//!
//!   offset  7  06                  ldloc.0               [1]
//!   offset  8  16                  ldc.i4.0              [1]  index 0
//!   offset  9  1F 15               ldc.i4.s 21           [2]
//!   offset 11  A4 03 00 00 01      stelem TypeRef[3]     [5]  arr[0] = 21
//!
//!   offset 16  06                  ldloc.0               [1]
//!   offset 17  17                  ldc.i4.1              [1]  index 1
//!   offset 18  1F 15               ldc.i4.s 21           [2]
//!   offset 20  A4 03 00 00 01      stelem TypeRef[3]     [5]  arr[1] = 21
//!
//!   offset 25  06                  ldloc.0               [1]
//!   offset 26  16                  ldc.i4.0              [1]  index 0
//!   offset 27  A3 03 00 00 01      ldelem TypeRef[3]     [5]  → 21
//!
//!   offset 32  06                  ldloc.0               [1]
//!   offset 33  17                  ldc.i4.1              [1]  index 1
//!   offset 34  A3 03 00 00 01      ldelem TypeRef[3]     [5]  → 21
//!
//!   offset 39  58                  add                   [1]  21+21 = 42
//!   offset 40  28 01 00 00 0A      call Console.WriteLine(int) [5]
//!   offset 45  2A                  ret                   [1]
//!
//! codeSize = 46 = 0x2E.
//!
//! Fat header (12 bytes) at 0x248:
//!   flags = 0x13 (FatFormat=0x03 | InitLocals=0x10), header size = 3 DWORDs
//!   maxStack = 3
//!   codeSize = 46
//!   localVarSigTok = 0x11000001
//!
//! LocalVarSig: {0x07, 0x01, 0x1D, 0x08} = 1 local: int32[] (SZARRAY I4)
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])
//!   TypeRef[3]: System.Int32    (resScope = AssemblyRef[1])
//!
//! MemberRef[1]: Console.WriteLine(int): DEFAULT, 1 param, void(0x01), I4(0x08)
//! StandAloneSig[1]: LocalVarSig for the int32[] local
//!
//! BSJB at 0x248 + 12 + 46 = 0x282.
//!
//! CLR execution: arr[0]=21, arr[1]=21; 21+21=42 → prints "42".
package Msil.SelfTestM26

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
  val outPath = "/tmp/lyric_msil_m26_newarr.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sInt32 = internString(sh, "Int32")
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

  // LocalVarSig: 1 local — int32[] = SZARRAY(0x1D) + I4(0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07)  // LOCAL_SIG
  bufU1(lvW, 0x01)  // 1 local
  bufU1(lvW, 0x1D)  // ELEMENT_TYPE_SZARRAY
  bufU1(lvW, 0x08)  // ELEMENT_TYPE_I4
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

  // create int32[2]
  emitLdc_I4_2(mbMain)
  emitNewarr(mbMain, 0x01000003)  // newarr System.Int32 = TypeRef[3]
  emitStloc_0(mbMain)

  // arr[0] = 21
  emitLdloc_0(mbMain)
  emitLdc_I4_0(mbMain)
  emitLdc_I4_S(mbMain, 21)
  emitStelem(mbMain, 0x01000003)  // stelem System.Int32

  // arr[1] = 21
  emitLdloc_0(mbMain)
  emitLdc_I4_1(mbMain)
  emitLdc_I4_S(mbMain, 21)
  emitStelem(mbMain, 0x01000003)

  // arr[0] + arr[1] = 42
  emitLdloc_0(mbMain)
  emitLdc_I4_0(mbMain)
  emitLdelem(mbMain, 0x01000003)  // ldelem System.Int32

  emitLdloc_0(mbMain)
  emitLdc_I4_1(mbMain)
  emitLdelem(mbMain, 0x01000003)

  emitAdd(mbMain)

  emitCall(mbMain, 0x0A000001)  // Console.WriteLine(int)
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
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  // TypeRef[3]: System.Int32
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))

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

  // StandAloneSig[1]: LocalVarSig for int32[] local
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
    resourceData = newList()
  )
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Fat header at 0x248: flags byte = 0x13 (Fat|InitLocals), size byte = 0x30
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)

  // localVarSigTok = 0x11000001 at offset 8 of fat header = 0x248+8 = 0x250: 01 00 00 11
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // newarr (0x8D) at code offset 1 = file 0x254+1 = 0x255
  check("newarr_ok", bs[0x255] == 0x8D)

  // newarr token = 0x01000003 (TypeRef[3]=System.Int32) at 0x256: 03 00 00 01
  check("newarr_tok_ok", bs[0x256] == 0x03 and bs[0x257] == 0 and bs[0x258] == 0 and bs[0x259] == 0x01)

  // stelem (0xA4) at code offset 11 = file 0x254+11 = 0x25F
  check("stelem_ok", bs[0x25F] == 0xA4)

  // ldelem (0xA3) at code offset 27 = file 0x254+27 = 0x26F
  check("ldelem_ok", bs[0x26F] == 0xA3)

  // BSJB at 0x248 + 12 + 46 = 0x282
  check("bsjb_ok", bs[0x282] == 0x42 and bs[0x283] == 0x53 and bs[0x284] == 0x4A and bs[0x285] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
