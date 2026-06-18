//! msil_self_test_m37.l — Stage M37: ldelema (load managed pointer to array element).
//!
//! Builds a PE that:
//!   1. Allocates int32[1] via newarr.
//!   2. Gets a managed pointer to element [0] via ldelema.
//!   3. Stores 42 at that pointer via stind.i4.
//!   4. Loads element [0] via ldelem and prints via Console.WriteLine(int).
//!
//! New instruction exercised:
//!   ldelema (0x8F) — loads the address of array element[index] as a managed pointer.
//!
//! Fat method header required (one int32[] local).
//!
//! LocalVarSig: { 0x07, 0x01, 0x1D, 0x08 } — LOCAL_SIG, count=1, SZARRAY I4
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//!   TypeRef[3]: System.Int32    (resScope = AssemblyRef[1])  — newarr + ldelema + ldelem
//!
//! MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//! StandAloneSig[1]: LocalVarSig for the int32[] local
//!
//! Code layout (fat header at 0x248, code at 0x254):
//!   offset  0  17                 ldc.i4.1     [1]
//!   offset  1  8D 03 00 00 01     newarr TypeRef[3] [5]
//!   offset  6  0A                 stloc_0      [1]
//!   offset  7  06                 ldloc_0      [1]
//!   offset  8  15                 ldc.i4.0     [1]  wait, ldc.i4.0 = 0x16; 0 = 0x16
//!   ...
//!
//! Actually: ldc.i4.0 = OP_LDC_I4_0 = 0x16; ldc.i4.1 = OP_LDC_I4_1 = 0x17
//!
//! Code layout (corrected):
//!   offset  0  17                 ldc.i4.1             [1]
//!   offset  1  8D 03 00 00 01     newarr TypeRef[3]    [5]
//!   offset  6  0A                 stloc_0              [1]
//!   offset  7  06                 ldloc_0              [1]
//!   offset  8  16                 ldc.i4.0             [1]
//!   offset  9  8F 03 00 00 01     ldelema TypeRef[3]   [5]
//!   offset 14  1F 2A              ldc.i4.s 42          [2]
//!   offset 16  54                 stind.i4             [1]
//!   offset 17  06                 ldloc_0              [1]
//!   offset 18  16                 ldc.i4.0             [1]
//!   offset 19  A3 03 00 00 01     ldelem TypeRef[3]    [5]
//!   offset 24  28 01 00 00 0A     call MemberRef[1]    [5]
//!   offset 29  2A                 ret                  [1]
//!
//! codeSize = 30. maxStack = 3.
//!
//! BSJB at 0x248 + 12 + 30 = 0x272.
//!
//! CLR: ldelema returns byref to element[0]; stind.i4 stores 42; ldelem loads 42 → prints "42".
package Msil.SelfTestM37

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
  val outPath = "/tmp/lyric_msil_m37_ldelema.dll"

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

  // LocalVarSig: LOCAL_SIG(0x07) + count=1 + SZARRAY(0x1D) + I4(0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07)
  bufU1(lvW, 0x01)
  bufU1(lvW, 0x1D)
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
  // int32[] arr = new int32[1]
  emitLdc_I4_1(mbMain)
  emitNewarr(mbMain, 0x01000003)            // newarr System.Int32
  emitStloc_0(mbMain)
  // &arr[0] → stind.i4 → arr[0] = 42
  emitLdloc_0(mbMain)
  emitLdc_I4_0(mbMain)
  emitLdelema(mbMain, 0x01000003)           // ldelema System.Int32 → byref to arr[0]
  emitLdc_I4_S(mbMain, 42)
  emitStind_I4(mbMain)
  // Console.WriteLine(arr[0])
  emitLdloc_0(mbMain)
  emitLdc_I4_0(mbMain)
  emitLdelem(mbMain, 0x01000003)            // ldelem System.Int32 → 42
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
  // TypeRef[3]: System.Int32 (newarr + ldelema + ldelem token)
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

  // localVarSigTok = 0x11000001 at 0x248+8 = 0x250
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // newarr (0x8D) at code offset 1 = file 0x255
  check("newarr_ok", bs[0x255] == 0x8D)

  // ldelema (0x8F) at code offset 9 = file 0x25D
  check("ldelema_ok", bs[0x25D] == 0x8F)

  // ldelema token = TypeRef[3] = 0x01000003 at 0x25E: 03 00 00 01
  check("ldelema_tok_ok", bs[0x25E] == 0x03 and bs[0x25F] == 0 and bs[0x260] == 0 and bs[0x261] == 0x01)

  // BSJB at 0x248 + 12 + 30 = 0x272
  check("bsjb_ok", bs[0x272] == 0x42 and bs[0x273] == 0x53 and bs[0x274] == 0x4A and bs[0x275] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
