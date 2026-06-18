//! msil_self_test_m59.l — Stage M59: rem (0x5D), rem.un (0x5E), div.un (0x5C).
//!
//! Builds a PE that exercises remainder and unsigned division:
//!   rem    (0x5D) — signed remainder
//!   rem.un (0x5E) — unsigned remainder
//!   div.un (0x5C) — unsigned division
//!
//! Code flow:
//!   1. ldc.i4.s 85 / ldc.i4.s 43 / rem      → 85 % 43 = 42
//!   2. ldc.i4.0 / ldc.i4.1 / rem.un / add   → 0 % 1 = 0; 42 + 0 = 42
//!   3. ldc.i4.1 / div.un                     → 42 / 1 = 42
//!   4. call Console.WriteLine(int32) / ret   → prints "42"
//!
//! codeSize = 17.  Tiny header (1 byte) at 0x248.  Code at 0x249.
//!   rem    (0x5D) at code offset  4 = file 0x24D.
//!   rem.un (0x5E) at code offset  7 = file 0x250.
//!   div.un (0x5C) at code offset 10 = file 0x253.
//! BSJB at 0x249 + 17 = 0x25A.
//!
//! Tiny header byte = (17 << 2) | 2 = 0x46.
package Msil.SelfTestM59

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
  val outPath = "/tmp/lyric_msil_m59_divremainder.dll"

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

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  emitLdc_I4_S(mbMain, 85)     // push 85
  emitLdc_I4_S(mbMain, 43)     // push 43
  emitRem(mbMain)               // 85 % 43 = 42
  emitLdc_I4_0(mbMain)          // push 0
  emitLdc_I4_1(mbMain)          // push 1
  emitRemUn(mbMain)             // 0 % 1 = 0
  emitAdd(mbMain)               // 42 + 0 = 42
  emitLdc_I4_1(mbMain)          // push 1
  emitDivUn(mbMain)             // 42 / 1 = 42
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
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
    resourceData = newList()
  )
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header at 0x248: (17 << 2) | 2 = 0x46
  check("tiny_hdr_ok", bs[0x248] == 0x46)

  // rem (0x5D) at code offset 4 = file 0x24D
  check("rem_ok", bs[0x24D] == 0x5D)

  // rem.un (0x5E) at code offset 7 = file 0x250
  check("rem_un_ok", bs[0x250] == 0x5E)

  // div.un (0x5C) at code offset 10 = file 0x253
  check("div_un_ok", bs[0x253] == 0x5C)

  // BSJB at 0x249 + 17 = 0x25A
  check("bsjb_ok", bs[0x25A] == 0x42 and bs[0x25B] == 0x53 and bs[0x25C] == 0x4A and bs[0x25D] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
