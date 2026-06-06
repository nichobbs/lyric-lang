//! msil_self_test_m79.l — Stage M79: ldarg.2 (0x04), ldarg.3 (0x05),
//!                                   ldarg.s (0x0E), ldarga.s (0x0F), starg.s (0x10).
//!
//! Exercises:
//!   ldarg.2  (0x04) — load argument at index 2
//!   ldarg.3  (0x05) — load argument at index 3
//!   ldarg.s  (0x0E) — load argument (short form, 1-byte index)
//!   ldarga.s (0x0F) — load address of argument (short form)
//!   starg.s  (0x10) — store to argument slot (short form)
//!
//! Two-method PE: Helper + Main.
//! Helper(a: I4, b: I4, c: I4, d: I4, e: I4): I4 — exercises all arg opcodes; returns 42.
//! Main(): void — calls Helper(1, 2, 3, 4, 32) → gets 42 → Console.WriteLine(42).
//!
//! Helper body (codeSize=21, tiny header 0x56 at 0x248, code at 0x249):
//!   offset  0: ldarg.2 (1b) ← 0x04 at file 0x249  (c=3)
//!   offset  1: ldarg.3 (1b) ← 0x05 at file 0x24A  (d=4)
//!   offset  2: ldarg.s 4 (2b) ← 0x0E at file 0x24B (e=32)
//!   offset  4: add (1b)                              → 4+32=36
//!   offset  5: add (1b)                              → 3+36=39
//!   offset  6: starg.s 0 (2b) ← 0x10 at file 0x24F  → arg[0]=39
//!   offset  8: ldarg.s 1 (2b)                        → push b=2
//!   offset 10: ldarg.s 0 (2b)                        → push arg[0]=39
//!   offset 12: add (1b)                               → 41
//!   offset 13: ldarga.s 1 (2b) ← 0x0F at file 0x256  → push &arg[1]
//!   offset 15: pop (1b)                               → discard address
//!   offset 16: nop (1b)
//!   offset 17: nop (1b)
//!   offset 18: ldc.i4.1 (1b)                         → push 1
//!   offset 19: add (1b)                               → 42
//!   offset 20: ret (1b)                               → return 42
//!
//! Main body (codeSize=17, tiny header 0x46 at 0x25E, code at 0x25F):
//!   ldc.i4.1 / ldc.i4.2 / ldc.i4.3 / ldc.i4.4 / ldc.i4.s 32 → push 5 args
//!   call MethodDef[1] (Helper) → 42
//!   call MemberRef[1] (Console.WriteLine) → prints "42"
//!   ret
//!
//! Total bytes: 22 (Helper) + 18 (Main) = 40.
//! BSJB at 0x248 + 40 = 0x270.
//!
//! Checks:
//!   ldarg2_ok:  bs[0x249] == 0x04
//!   ldarg3_ok:  bs[0x24A] == 0x05
//!   ldargs_ok:  bs[0x24B] == 0x0E
//!   stargas_ok: bs[0x24F] == 0x10
//!   ldarga_s_ok: bs[0x256] == 0x0F
package Msil.SelfTestM79

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
  val outPath = "/tmp/lyric_msil_m79_ldarg_starg.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sHelper = internString(sh, "Helper")
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

  // Helper(I4,I4,I4,I4,I4): I4 — DEFAULT cc, 5 params, I4 return, 5×I4 params
  val helperSigW = bufNew()
  bufU1(helperSigW, 0x00)
  bufU1(helperSigW, 0x05)
  bufU1(helperSigW, 0x08)
  bufU1(helperSigW, 0x08)
  bufU1(helperSigW, 0x08)
  bufU1(helperSigW, 0x08)
  bufU1(helperSigW, 0x08)
  bufU1(helperSigW, 0x08)
  val sigHelper = internBlob(bh, "helper_sig", bufToList(helperSigW))

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

  // Helper body: exercises ldarg.2/3, ldarg.s, starg.s, ldarga.s; returns 42
  val mbHelper = newMethodBody()
  emitLdarg_2(mbHelper)  // offset  0: push c=3 (1b) ← 0x04 at file 0x249
  emitLdarg_3(mbHelper)  // offset  1: push d=4 (1b) ← 0x05 at file 0x24A
  emitLdarg_S(mbHelper, 4)  // offset  2: push e=32 (2b) ← 0x0E at file 0x24B
  emitAdd(mbHelper)  // offset  4: 4+32=36 (1b)
  emitAdd(mbHelper)  // offset  5: 3+36=39 (1b)
  emitStarg_S(mbHelper, 0)  // offset  6: arg[0]=39 (2b) ← 0x10 at file 0x24F
  emitLdarg_S(mbHelper, 1)  // offset  8: push b=2 (2b)
  emitLdarg_S(mbHelper, 0)  // offset 10: push arg[0]=39 (2b)
  emitAdd(mbHelper)  // offset 12: 2+39=41 (1b)
  emitLdarga_S(mbHelper, 1)  // offset 13: push &arg[1] (2b) ← 0x0F at file 0x256
  emitPop(mbHelper)  // offset 15: discard address (1b)
  emitNop(mbHelper)  // offset 16: nop (1b)
  emitNop(mbHelper)  // offset 17: nop (1b)
  emitLdc_I4_1(mbHelper)  // offset 18: push 1 (1b)
  emitAdd(mbHelper)  // offset 19: 41+1=42 (1b)
  emitRet(mbHelper)  // offset 20: return 42 (1b)

  // Main body: push 5 args, call Helper, call Console.WriteLine, ret
  val mbMain = newMethodBody()
  emitLdc_I4_1(mbMain)  // push a=1
  emitLdc_I4_2(mbMain)  // push b=2
  emitLdc_I4_3(mbMain)  // push c=3
  emitLdc_I4_4(mbMain)  // push d=4
  emitLdc_I4_S(mbMain, 32)  // push e=32
  emitCall(mbMain, 0x06000001)  // call Helper → 42
  emitCall(mbMain, 0x0A000001)  // call Console.WriteLine(42)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbHelper)
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaHelper = rvas[0]
  val rvaMain = rvas[1]

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
      rva = rvaHelper,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = sHelper,
      signature = sigHelper,
      paramList = 1
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
    entryPointToken = 0x06000002,
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

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x02 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("tiny_hdr_ok", bs[0x248] == 0x56)
  check("ldarg2_ok", bs[0x249] == 0x04)
  check("ldarg3_ok", bs[0x24A] == 0x05)
  check("ldargs_ok", bs[0x24B] == 0x0E)
  check("stargas_ok", bs[0x24F] == 0x10)
  check("ldarga_s_ok", bs[0x256] == 0x0F)
  check("bsjb_ok", bs[0x270] == 0x42 and bs[0x271] == 0x53 and bs[0x272] == 0x4A and bs[0x273] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
