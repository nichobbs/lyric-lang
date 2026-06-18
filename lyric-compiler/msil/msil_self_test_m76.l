// msil_self_test_m76.l — Stage M76: ldloca.s (0x12), ldind.i1 (0x46), ldind.u2 (0x49),
//                                   ldind.u4 (0x4B), ldind.i8 (0x4C).
//
// Exercises:
//   ldloca.s (0x12) — load address of local variable (short form)
//   ldind.i1 (0x46) — load int8 from address (sign-extended to I4)
//   ldind.u2 (0x49) — load uint16 from address (zero-extended to I4)
//   ldind.u4 (0x4B) — load uint32 from address (as I4)
//   ldind.i8 (0x4C) — load int64 from address
//
// Fat method header required (4 locals: I1, U2, U4, I8).
// LocalVarSig: { 0x07, 0x04, 0x04, 0x07, 0x09, 0x0A }
//
// Code layout (fat header at 0x248, code at 0x254, codeSize=40):
//   offsets  0-12: store 42 into each local via ldc.i4.s/conv.i8/stloc
//   offset  13  12 00        ldloca.s 0   → &local[0] (I1)
//   offset  15  46           ldind.i1     → 42 as I4
//   offset  16  26           pop
//   offset  17  12 01        ldloca.s 1   → &local[1] (U2)
//   offset  19  49           ldind.u2     → 42 as I4
//   offset  20  26           pop
//   offset  21  12 02        ldloca.s 2   → &local[2] (U4)
//   offset  23  4B           ldind.u4     → 42 as I4
//   offset  24  26           pop
//   offset  25  12 03        ldloca.s 3   → &local[3] (I8)
//   offset  27  4C           ldind.i8     → 42 as I8
//   offset  28  26           pop
//   offset  29  12 00        ldloca.s 0   (byte check)
//   offset  31  26           pop
//   offset  32  1F 2A        ldc.i4.s 42
//   offset  34  28 01 00 00 0A  call
//   offset  39  2A           ret
//
// BSJB at 0x254 + 40 = 0x27C.
//
// Checks:
//   ldloca_s_ok: bs[0x261] == 0x12 (ldloca.s at code offset 13)
//   ldind_i1_ok: bs[0x263] == 0x46 (ldind.i1 at code offset 15)
//   ldind_u2_ok: bs[0x267] == 0x49 (ldind.u2 at code offset 19)
//   ldind_u4_ok: bs[0x26B] == 0x4B (ldind.u4 at code offset 23)
//   ldind_i8_ok: bs[0x26F] == 0x4C (ldind.i8 at code offset 27)

package Msil.SelfTestM76

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
  val outPath = "/tmp/lyric_msil_m76_ldloca_ldind.dll"

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

  // LocalVarSig: LOCAL_SIG(0x07) + count=4 + I1(0x04) + U2(0x07) + U4(0x09) + I8(0x0A)
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x04)
  bufU1(lvW, 0x04); bufU1(lvW, 0x07); bufU1(lvW, 0x09); bufU1(lvW, 0x0A)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  val mbMain = newMethodBody()
  // Store 42 into each local
  emitLdc_I4_S(mbMain, 42)          // offset  0: push 42 (2b)
  emitStloc_0(mbMain)                // offset  2: local[0]=42 (I1) (1b)
  emitLdc_I4_S(mbMain, 42)          // offset  3: (2b)
  emitStloc_1(mbMain)                // offset  5: local[1]=42 (U2) (1b)
  emitLdc_I4_S(mbMain, 42)          // offset  6: (2b)
  emitStloc_2(mbMain)                // offset  8: local[2]=42 (U4) (1b)
  emitLdc_I4_S(mbMain, 42)          // offset  9: (2b)
  emitConv_I8(mbMain)                // offset 11: to I8 (1b)
  emitStloc_3(mbMain)                // offset 12: local[3]=42 (I8) (1b)
  // ldloca.s + ldind.i1
  emitLdloca_S(mbMain, 0)           // offset 13: &local[0] (2b) ← 0x12 at file 0x261
  emitLdind_I1(mbMain)               // offset 15: load I1→I4 (1b) ← 0x46 at file 0x263
  emitPop(mbMain)                    // offset 16: (1b)
  // ldloca.s + ldind.u2
  emitLdloca_S(mbMain, 1)           // offset 17: &local[1] (2b)
  emitLdind_U2(mbMain)               // offset 19: load U2→I4 (1b) ← 0x49 at file 0x267
  emitPop(mbMain)                    // offset 20: (1b)
  // ldloca.s + ldind.u4
  emitLdloca_S(mbMain, 2)           // offset 21: &local[2] (2b)
  emitLdind_U4(mbMain)               // offset 23: load U4→I4 (1b) ← 0x4B at file 0x26B
  emitPop(mbMain)                    // offset 24: (1b)
  // ldloca.s + ldind.i8
  emitLdloca_S(mbMain, 3)           // offset 25: &local[3] (2b)
  emitLdind_I8(mbMain)               // offset 27: load I8 (1b)   ← 0x4C at file 0x26F
  emitPop(mbMain)                    // offset 28: (1b)
  // extra ldloca.s (byte check for opcode 0x12 at known offset)
  emitLdloca_S(mbMain, 0)           // offset 29: &local[0] (2b) ← 0x12 at file 0x271
  emitPop(mbMain)                    // offset 31: (1b)
  emitLdc_I4_S(mbMain, 42)          // offset 32: push 42 (2b)
  emitCall(mbMain, 0x0A000001)       // offset 34: print 42 (5b)
  emitRet(mbMain)                    // offset 39

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

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh, resourceData = newList(), buildKind = "lib")
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok",  bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("ldloca_s_ok", bs[0x261] == 0x12)
  check("ldind_i1_ok", bs[0x263] == 0x46)
  check("ldind_u2_ok", bs[0x267] == 0x49)
  check("ldind_u4_ok", bs[0x26B] == 0x4B)
  check("ldind_i8_ok", bs[0x26F] == 0x4C)
  check("bsjb_ok",
    bs[0x27C] == 0x42 and bs[0x27D] == 0x53 and
    bs[0x27E] == 0x4A and bs[0x27F] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
