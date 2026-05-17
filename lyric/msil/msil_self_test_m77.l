// msil_self_test_m77.l — Stage M77: ldind.r4 (0x4E), ldind.r8 (0x4F),
//                                   stind.i8 (0x55), stind.r4 (0x56), stind.r8 (0x57).
//
// Exercises:
//   ldind.r4 (0x4E) — load float32 from address
//   ldind.r8 (0x4F) — load float64 from address
//   stind.i8 (0x55) — store int64 to address
//   stind.r4 (0x56) — store float32 to address
//   stind.r8 (0x57) — store float64 to address
//
// Fat method header required (3 locals: I8, R4, R8).
// LocalVarSig: { 0x07, 0x03, 0x0A, 0x0C, 0x0D }
//
// Code layout (fat header at 0x248, code at 0x254, codeSize=64):
//   offset  0-1:  nop nop
//   offset  2:    ldc.i4.s 42 (2b)
//   offset  4:    conv.i8 (1b)
//   offset  5:    stloc.0 (1b)      → local[0] (I8) = 42
//   offset  6:    ldc.r4 42.0 (5b)
//   offset  11:   stloc.1 (1b)      → local[1] (R4) = 42.0
//   offset  12:   ldc.r8 42.0 (9b)
//   offset  21:   stloc.2 (1b)      → local[2] (R8) = 42.0
//   offset  22:   ldloca.s 1 (2b)
//   offset  24:   ldind.r4 (1b)     ← 0x4E at file 0x26C
//   offset  25:   pop (1b)
//   offset  26:   ldloca.s 2 (2b)
//   offset  28:   ldind.r8 (1b)     ← 0x4F at file 0x270
//   offset  29:   pop (1b)
//   offset  30:   ldloca.s 0 (2b)
//   offset  32:   ldc.i4.s 42 (2b)
//   offset  34:   conv.i8 (1b)
//   offset  35:   stind.i8 (1b)     ← 0x55 at file 0x277
//   offset  36:   ldloca.s 1 (2b)
//   offset  38:   ldc.r4 42.0 (5b)
//   offset  43:   stind.r4 (1b)     ← 0x56 at file 0x27F
//   offset  44:   ldloca.s 2 (2b)
//   offset  46:   ldc.r8 42.0 (9b)
//   offset  55:   stind.r8 (1b)     ← 0x57 at file 0x28B
//   offset  56:   ldc.i4.s 42 (2b)
//   offset  58:   call (5b)
//   offset  63:   ret (1b)
//
// BSJB at 0x254 + 64 = 0x294.
//
// Checks:
//   ldind_r4_ok: bs[0x26C] == 0x4E
//   ldind_r8_ok: bs[0x270] == 0x4F
//   stind_i8_ok: bs[0x277] == 0x55
//   stind_r4_ok: bs[0x27F] == 0x56
//   stind_r8_ok: bs[0x28B] == 0x57

package Msil.SelfTestM77

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Std.Core
import Std.Collections
import Std.File

func check(label: in String, ok: in Bool): Unit {
  if ok { println(label + "=true") } else { println(label + "=false") }
}

func main(): Unit {
  val outPath = "/tmp/lyric_msil_m77_ldind_stind_r.dll"

  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
  val sSystem  = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject  = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")

  val gh    = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  val bh = newBlobHeap()

  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // LocalVarSig: LOCAL_SIG(0x07) + count=3 + I8(0x0A) + R4(0x0C) + R8(0x0D)
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x03)
  bufU1(lvW, 0x0A); bufU1(lvW, 0x0C); bufU1(lvW, 0x0D)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  val mbMain = newMethodBody()
  // Initialize locals
  emitNop(mbMain)                     // offset  0: nop (1b)
  emitNop(mbMain)                     // offset  1: nop (1b)
  emitLdc_I4_S(mbMain, 42)           // offset  2: push 42 (2b)
  emitConv_I8(mbMain)                 // offset  4: to I8 (1b)
  emitStloc_0(mbMain)                 // offset  5: local[0]=42 (I8) (1b)
  emitLdc_R4(mbMain, 42.0)           // offset  6: push 42.0 (R4) (5b)
  emitStloc_1(mbMain)                 // offset 11: local[1]=42.0 (R4) (1b)
  emitLdc_R8(mbMain, 42.0)           // offset 12: push 42.0 (R8) (9b)
  emitStloc_2(mbMain)                 // offset 21: local[2]=42.0 (R8) (1b)
  // ldloca.s + ldind.r4
  emitLdloca_S(mbMain, 1)            // offset 22: &local[1] (2b)
  emitLdind_R4(mbMain)                // offset 24: load R4 (1b) ← 0x4E at file 0x26C
  emitPop(mbMain)                     // offset 25: discard (1b)
  // ldloca.s + ldind.r8
  emitLdloca_S(mbMain, 2)            // offset 26: &local[2] (2b)
  emitLdind_R8(mbMain)                // offset 28: load R8 (1b) ← 0x4F at file 0x270
  emitPop(mbMain)                     // offset 29: discard (1b)
  // ldloca.s + stind.i8
  emitLdloca_S(mbMain, 0)            // offset 30: &local[0] (2b)
  emitLdc_I4_S(mbMain, 42)           // offset 32: push 42 (2b)
  emitConv_I8(mbMain)                 // offset 34: to I8 (1b)
  emitStind_I8(mbMain)                // offset 35: store I8 (1b) ← 0x55 at file 0x277
  // ldloca.s + stind.r4
  emitLdloca_S(mbMain, 1)            // offset 36: &local[1] (2b)
  emitLdc_R4(mbMain, 42.0)           // offset 38: push 42.0 (5b)
  emitStind_R4(mbMain)                // offset 43: store R4 (1b) ← 0x56 at file 0x27F
  // ldloca.s + stind.r8
  emitLdloca_S(mbMain, 2)            // offset 44: &local[2] (2b)
  emitLdc_R8(mbMain, 42.0)           // offset 46: push 42.0 (9b)
  emitStind_R8(mbMain)                // offset 55: store R8 (1b) ← 0x57 at file 0x28B
  // print 42 and return
  emitLdc_I4_S(mbMain, 42)           // offset 56: push 42 (2b)
  emitCall(mbMain, 0x0A000001)       // offset 58: print (5b)
  emitRet(mbMain)                     // offset 63

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))
  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))
  addAssembly(t, AssemblyRow(hashAlgId = HASH_ALG_SHA1, majorVersion = 0, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = ASF_NONE, publicKey = 0, name = sHello, culture = 0))
  addAssemblyRef(t, AssemblyRefRow(majorVersion = 10, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = 0, publicKeyToken = keyToken, name = sRuntime,    culture = 0, hashValue = 0))
  addAssemblyRef(t, AssemblyRefRow(majorVersion = 10, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = 0, publicKeyToken = keyToken, name = sConsoleAsm, culture = 0, hashValue = 0))

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh)
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok",  bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("ldind_r4_ok", bs[0x26C] == 0x4E)
  check("ldind_r8_ok", bs[0x270] == 0x4F)
  check("stind_i8_ok", bs[0x277] == 0x55)
  check("stind_r4_ok", bs[0x27F] == 0x56)
  check("stind_r8_ok", bs[0x28B] == 0x57)
  check("bsjb_ok",
    bs[0x294] == 0x42 and bs[0x295] == 0x53 and
    bs[0x296] == 0x4A and bs[0x297] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
