//! msil_self_test_m80.l — Stage M80: cgt (0xFE 0x02), cgt.un (0xFE 0x03),
//!                                   clt (0xFE 0x04), clt.un (0xFE 0x05),
//!                                   conv.r.un (0x76).
//!
//! Exercises:
//!   cgt     (0xFE 0x02) — compare greater-than (signed), push 0/1
//!   cgt.un  (0xFE 0x03) — compare greater-than (unsigned), push 0/1
//!   clt     (0xFE 0x04) — compare less-than (signed), push 0/1
//!   clt.un  (0xFE 0x05) — compare less-than (unsigned), push 0/1
//!   conv.r.un (0x76)    — convert to float (treating value as unsigned)
//!
//! Code flow (all comparisons yield 1; product = 1; 1 × 42 = 42 → print):
//!   ldc.i4.s 43 / ldc.i4.s 40 / cgt    → 1  (43>40 signed)
//!   ldc.i4.s 45 / ldc.i4.s 41 / cgt.un → 1  (45>41 unsigned)
//!   ldc.i4.s 41 / ldc.i4.s 45 / clt    → 1  (41<45 signed)
//!   ldc.i4.s 43 / ldc.i4.s 44 / clt.un → 1  (43<44 unsigned)
//!   mul / mul / mul → 1
//!   ldc.i4.s 42 / conv.r.un / conv.i4 → 42 as I4
//!   mul → 42 / call / ret
//!
//! codeSize = 38. Tiny header byte = (38 << 2) | 2 = 0x9A.
//! Code at 0x249.
//!   cgt     opcode (0xFE 0x02) at code offset  4 = file 0x24D / 0x24E
//!   cgt.un  opcode (0xFE 0x03) at code offset 10 = file 0x253 / 0x254
//!   clt     opcode (0xFE 0x04) at code offset 16 = file 0x259 / 0x25A
//!   clt.un  opcode (0xFE 0x05) at code offset 22 = file 0x25F / 0x260
//!   conv.r.un (0x76)           at code offset 29 = file 0x266
//! BSJB at 0x249 + 38 = 0x26F.
package Msil.SelfTestM80

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
  val outPath = "/tmp/lyric_msil_m80_cgt_clt_conv.dll"

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
  emitLdc_I4_S(mbMain, 43)          // offset  0 (2b): push 43
  emitLdc_I4_S(mbMain, 40)          // offset  2 (2b): push 40
  emitCgt(mbMain)                    // offset  4 (2b): 43>40 → 1  ← 0xFE at 0x24D, 0x02 at 0x24E
  emitLdc_I4_S(mbMain, 45)          // offset  6 (2b): push 45
  emitLdc_I4_S(mbMain, 41)          // offset  8 (2b): push 41
  emitCgt_Un(mbMain)                 // offset 10 (2b): 45>41 → 1  ← 0xFE at 0x253, 0x03 at 0x254
  emitLdc_I4_S(mbMain, 41)          // offset 12 (2b): push 41
  emitLdc_I4_S(mbMain, 45)          // offset 14 (2b): push 45
  emitClt(mbMain)                    // offset 16 (2b): 41<45 → 1  ← 0xFE at 0x259, 0x04 at 0x25A
  emitLdc_I4_S(mbMain, 43)          // offset 18 (2b): push 43
  emitLdc_I4_S(mbMain, 44)          // offset 20 (2b): push 44
  emitClt_Un(mbMain)                 // offset 22 (2b): 43<44 → 1  ← 0xFE at 0x25F, 0x05 at 0x260
  emitMul(mbMain)                    // offset 24 (1b): 1×1=1
  emitMul(mbMain)                    // offset 25 (1b): 1×1=1
  emitMul(mbMain)                    // offset 26 (1b): 1×1=1
  emitLdc_I4_S(mbMain, 42)          // offset 27 (2b): push 42
  emitConv_R_Un(mbMain)              // offset 29 (1b): 42 as R  ← 0x76 at 0x266
  emitConv_I4(mbMain)                // offset 30 (1b): back to I4
  emitMul(mbMain)                    // offset 31 (1b): 1×42=42
  emitCall(mbMain, 0x0A000001)      // offset 32 (5b): print 42
  emitRet(mbMain)                    // offset 37

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
  check("tiny_hdr_ok", bs[0x248] == 0x9A)
  check("cgt_ok", bs[0x24D] == 0xFE and bs[0x24E] == 0x02)
  check("cgt_un_ok", bs[0x253] == 0xFE and bs[0x254] == 0x03)
  check("clt_ok", bs[0x259] == 0xFE and bs[0x25A] == 0x04)
  check("clt_un_ok", bs[0x25F] == 0xFE and bs[0x260] == 0x05)
  check("conv_r_un_ok", bs[0x266] == 0x76)
  check("bsjb_ok", bs[0x26F] == 0x42 and bs[0x270] == 0x53 and bs[0x271] == 0x4A and bs[0x272] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
