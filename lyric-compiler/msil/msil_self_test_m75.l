//! msil_self_test_m75.l — Stage M75: ldloc.2/3 (0x08/0x09), stloc.2/3 (0x0C/0x0D),
//!                                   ldloc.s/stloc.s (0x11/0x13), ldloc/stloc wide (0xFE 0x0C/0x0E).
//!
//! Exercises:
//!   stloc.2  (0x0C) — store to local[2]
//!   ldloc.2  (0x08) — load from local[2]
//!   stloc.3  (0x0D) — store to local[3]
//!   ldloc.3  (0x09) — load from local[3]
//!   stloc.s  (0x13) — store to local[n] (short-form, n=4)
//!   ldloc.s  (0x11) — load from local[n] (short-form, n=4)
//!   stloc    (0xFE 0x0E) — store to local[n] (wide-form, n=4)
//!   ldloc    (0xFE 0x0C) — load from local[n] (wide-form, n=4)
//!
//! Fat method header required (5 I4 locals).
//! LocalVarSig: { 0x07, 0x05, 0x08, 0x08, 0x08, 0x08, 0x08 }
//!
//! Code layout (fat header at 0x248, code at 0x254):
//!   offset  0  1F 2A        ldc.i4.s 42   [2]
//!   offset  2  0C           stloc.2       [1]  → local[2] = 42
//!   offset  3  08           ldloc.2       [1]  → push local[2] = 42
//!   offset  4  0D           stloc.3       [1]  → local[3] = 42
//!   offset  5  09           ldloc.3       [1]  → push local[3] = 42
//!   offset  6  13 04        stloc.s 4     [2]  → local[4] = 42
//!   offset  8  11 04        ldloc.s 4     [2]  → push local[4] = 42
//!   offset 10  FE 0E 04 00  stloc 4       [4]  → local[4] = 42 (wide form)
//!   offset 14  FE 0C 04 00  ldloc 4       [4]  → push local[4] = 42 (wide form)
//!   offset 18  28 01 00 00 0A  call       [5]
//!   offset 23  2A           ret           [1]
//!
//! codeSize = 24.  BSJB at 0x248 + 12 + 24 = 0x26C.
//!
//! Checks:
//!   stloc_2_ok: bs[0x256] == 0x0C
//!   ldloc_2_ok: bs[0x257] == 0x08
//!   stloc_3_ok: bs[0x258] == 0x0D
//!   ldloc_3_ok: bs[0x259] == 0x09
//!   stloc_s_ok: bs[0x25A] == 0x13
//!   ldloc_s_ok: bs[0x25C] == 0x11
//!   stloc_ok:   bs[0x25E] == 0xFE and bs[0x25F] == 0x0E
//!   ldloc_ok:   bs[0x262] == 0xFE and bs[0x263] == 0x0C
package Msil.SelfTestM75

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
  val outPath = "/tmp/lyric_msil_m75_ldloc_stloc.dll"

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

  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // LocalVarSig: LOCAL_SIG(0x07) + count=5 + five I4(0x08) locals
  val lvW = bufNew()
  bufU1(lvW, 0x07)
  bufU1(lvW, 0x05)
  bufU1(lvW, 0x08)
  bufU1(lvW, 0x08)
  bufU1(lvW, 0x08)
  bufU1(lvW, 0x08)
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

  val mbMain = newMethodBody()
  emitLdc_I4_S(mbMain, 42)    // offset  0: push 42
  emitStloc_2(mbMain)          // offset  2: local[2] = 42  (stloc.2 = 0x0C)
  emitLdloc_2(mbMain)          // offset  3: push local[2]  (ldloc.2 = 0x08)
  emitStloc_3(mbMain)          // offset  4: local[3] = 42  (stloc.3 = 0x0D)
  emitLdloc_3(mbMain)          // offset  5: push local[3]  (ldloc.3 = 0x09)
  emitStloc_S(mbMain, 4)       // offset  6: local[4] = 42  (stloc.s 4 = 0x13 0x04)
  emitLdloc_S(mbMain, 4)       // offset  8: push local[4]  (ldloc.s 4 = 0x11 0x04)
  emitStloc(mbMain, 4)         // offset 10: local[4] = 42  (stloc 4 = 0xFE 0x0E 0x04 0x00)
  emitLdloc(mbMain, 4)         // offset 14: push local[4]  (ldloc 4 = 0xFE 0x0C 0x04 0x00)
  emitCall(mbMain, 0x0A000001)  // offset 18: print 42
  emitRet(mbMain)               // offset 23

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
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
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))
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

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("stloc_2_ok", bs[0x256] == 0x0C)
  check("ldloc_2_ok", bs[0x257] == 0x08)
  check("stloc_3_ok", bs[0x258] == 0x0D)
  check("ldloc_3_ok", bs[0x259] == 0x09)
  check("stloc_s_ok", bs[0x25A] == 0x13)
  check("ldloc_s_ok", bs[0x25C] == 0x11)
  check("stloc_ok", bs[0x25E] == 0xFE and bs[0x25F] == 0x0E)
  check("ldloc_ok", bs[0x262] == 0xFE and bs[0x263] == 0x0C)
  check("bsjb_ok", bs[0x26C] == 0x42 and bs[0x26D] == 0x53 and bs[0x26E] == 0x4A and bs[0x26F] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
