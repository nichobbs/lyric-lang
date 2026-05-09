// msil_self_test_m81.l — Stage M81: stelem.i4 (0x9E), ldelem.i4 (0x94),
//                                   stelem.i8 (0x9F), ldelem.i8 (0x96),
//                                   stelem.r4 (0xA0), ldelem.r4 (0x98),
//                                   stelem.r8 (0xA1), ldelem.r8 (0x99).
//
// Exercises typed array element store/load instructions.
//
// Fat method header required (4 locals: Int32[], Int64[], Single[], Double[]).
// LocalVarSig: { 0x07, 0x04, 0x1D, 0x08, 0x1D, 0x0A, 0x1D, 0x0C, 0x1D, 0x0D }
//
// TypeRef layout:
//   TypeRef[1]: System.Console  (AssemblyRef[2])
//   TypeRef[2]: System.Object   (AssemblyRef[1])
//   TypeRef[3]: System.Int32    (AssemblyRef[1]) — for Int32[]
//   TypeRef[4]: System.Int64    (AssemblyRef[1]) — for Int64[]
//   TypeRef[5]: System.Single   (AssemblyRef[1]) — for Single[]
//   TypeRef[6]: System.Double   (AssemblyRef[1]) — for Double[]
//
// Code layout (fat header at 0x248, code at 0x254, codeSize=88):
//   offset  0-3:  nop×4
//   offset  4-9:  ldc.i4.1 / newarr Int32 / stloc.0
//   offset 10-16: ldc.i4.1 / newarr Int64 / stloc.1
//   offset 17-23: ldc.i4.1 / newarr Single / stloc.2
//   offset 24-30: ldc.i4.1 / newarr Double / stloc.3
//   offset 31-35: ldloc.0 / ldc.i4.0 / ldc.i4.s 42 / stelem.i4  ← 0x9E at 0x278
//   offset 36-38: ldloc.0 / ldc.i4.0 / ldelem.i4                ← 0x94 at 0x27B
//   offset 39:    pop
//   offset 40-45: ldloc.1 / ldc.i4.0 / ldc.i4.s 42 / conv.i8 / stelem.i8 ← 0x9F at 0x282
//   offset 46-48: ldloc.1 / ldc.i4.0 / ldelem.i8                ← 0x96 at 0x285
//   offset 49:    pop
//   offset 50-57: ldloc.2 / ldc.i4.0 / ldc.r4 42.0 / stelem.r4 ← 0xA0 at 0x28E
//   offset 58-60: ldloc.2 / ldc.i4.0 / ldelem.r4                ← 0x98 at 0x291
//   offset 61:    pop
//   offset 62-71: ldloc.3 / ldc.i4.0 / ldc.r8 42.0 / stelem.r8 ← 0xA1 at 0x29E
//   offset 72-74: ldloc.3 / ldc.i4.0 / ldelem.r8                ← 0x99 at 0x2A1
//   offset 75:    pop
//   offset 76-81: ldloc.0 / ldc.i4.0 / ldelem.i4 → 42 / call / ret
//
// BSJB at 0x254 + 88 = 0x2AC.
//
// Checks:
//   stelem_i4_ok: bs[0x278] == 0x9E
//   ldelem_i4_ok: bs[0x27B] == 0x94
//   stelem_i8_ok: bs[0x282] == 0x9F
//   ldelem_i8_ok: bs[0x285] == 0x96
//   stelem_r4_ok: bs[0x28E] == 0xA0
//   ldelem_r4_ok: bs[0x291] == 0x98
//   stelem_r8_ok: bs[0x29E] == 0xA1
//   ldelem_r8_ok: bs[0x2A1] == 0x99

package Msil.SelfTestM81

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
  val outPath = "/tmp/lyric_msil_m81_stelem_ldelem_typed.dll"

  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
  val sSystem  = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject  = internString(sh, "Object")
  val sInt32   = internString(sh, "Int32")
  val sInt64   = internString(sh, "Int64")
  val sSingle  = internString(sh, "Single")
  val sDouble  = internString(sh, "Double")
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

  // LocalVarSig: LOCAL_SIG + count=4 + SZARRAY×I4, SZARRAY×I8, SZARRAY×R4, SZARRAY×R8
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x04)
  bufU1(lvW, 0x1D); bufU1(lvW, 0x08)
  bufU1(lvW, 0x1D); bufU1(lvW, 0x0A)
  bufU1(lvW, 0x1D); bufU1(lvW, 0x0C)
  bufU1(lvW, 0x1D); bufU1(lvW, 0x0D)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // Tokens for TypeRef[3..6]
  val tokInt32  = 0x01000003
  val tokInt64  = 0x01000004
  val tokSingle = 0x01000005
  val tokDouble = 0x01000006

  val mbMain = newMethodBody()
  // Create arrays
  emitNop(mbMain)                          // offset  0
  emitNop(mbMain)                          // offset  1
  emitNop(mbMain)                          // offset  2
  emitNop(mbMain)                          // offset  3
  emitLdc_I4_1(mbMain)                     // offset  4
  emitNewarr(mbMain, tokInt32)             // offset  5-9
  emitStloc_0(mbMain)                      // offset 10
  emitLdc_I4_1(mbMain)                     // offset 11
  emitNewarr(mbMain, tokInt64)             // offset 12-16
  emitStloc_1(mbMain)                      // offset 17
  emitLdc_I4_1(mbMain)                     // offset 18
  emitNewarr(mbMain, tokSingle)            // offset 19-23
  emitStloc_2(mbMain)                      // offset 24
  emitLdc_I4_1(mbMain)                     // offset 25
  emitNewarr(mbMain, tokDouble)            // offset 26-30
  emitStloc_3(mbMain)                      // offset 31
  // stelem.i4 + ldelem.i4
  emitLdloc_0(mbMain)                      // offset 32
  emitLdc_I4_0(mbMain)                     // offset 33
  emitLdc_I4_S(mbMain, 42)                // offset 34-35
  emitStelem_I4(mbMain)                    // offset 36 ← 0x9E at 0x254+36=0x278
  emitLdloc_0(mbMain)                      // offset 37
  emitLdc_I4_0(mbMain)                     // offset 38
  emitLdelem_I4(mbMain)                    // offset 39 ← 0x94 at 0x254+39=0x27B
  emitPop(mbMain)                          // offset 40
  // stelem.i8 + ldelem.i8
  emitLdloc_1(mbMain)                      // offset 41
  emitLdc_I4_0(mbMain)                     // offset 42
  emitLdc_I4_S(mbMain, 42)                // offset 43-44
  emitConv_I8(mbMain)                      // offset 45
  emitStelem_I8(mbMain)                    // offset 46 ← 0x9F at 0x254+46=0x282
  emitLdloc_1(mbMain)                      // offset 47
  emitLdc_I4_0(mbMain)                     // offset 48
  emitLdelem_I8(mbMain)                    // offset 49 ← 0x96 at 0x254+49=0x285
  emitPop(mbMain)                          // offset 50
  // stelem.r4 + ldelem.r4
  emitLdloc_2(mbMain)                      // offset 51
  emitLdc_I4_0(mbMain)                     // offset 52
  emitLdc_R4(mbMain, 42.0)                // offset 53-57
  emitStelem_R4(mbMain)                    // offset 58 ← 0xA0 at 0x254+58=0x28E
  emitLdloc_2(mbMain)                      // offset 59
  emitLdc_I4_0(mbMain)                     // offset 60
  emitLdelem_R4(mbMain)                    // offset 61 ← 0x98 at 0x254+61=0x291
  emitPop(mbMain)                          // offset 62
  // stelem.r8 + ldelem.r8
  emitLdloc_3(mbMain)                      // offset 63
  emitLdc_I4_0(mbMain)                     // offset 64
  emitLdc_R8(mbMain, 42.0)                // offset 65-73
  emitStelem_R8(mbMain)                    // offset 74 ← 0xA1 at 0x254+74=0x29E
  emitLdloc_3(mbMain)                      // offset 75
  emitLdc_I4_0(mbMain)                     // offset 76
  emitLdelem_R8(mbMain)                    // offset 77 ← 0x99 at 0x254+77=0x2A1
  emitPop(mbMain)                          // offset 78
  // print 42 and return
  emitLdloc_0(mbMain)                      // offset 79
  emitLdc_I4_0(mbMain)                     // offset 80
  emitLdelem_I4(mbMain)                    // offset 81 → 42
  emitCall(mbMain, 0x0A000001)            // offset 82-86
  emitRet(mbMain)                          // offset 87

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt64, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sSingle, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sDouble, typeNamespace = sSystem))
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

  check("dos_ok",       bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",    bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",    bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok",   bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("stelem_i4_ok", bs[0x278] == 0x9E)
  check("ldelem_i4_ok", bs[0x27B] == 0x94)
  check("stelem_i8_ok", bs[0x282] == 0x9F)
  check("ldelem_i8_ok", bs[0x285] == 0x96)
  check("stelem_r4_ok", bs[0x28E] == 0xA0)
  check("ldelem_r4_ok", bs[0x291] == 0x98)
  check("stelem_r8_ok", bs[0x29E] == 0xA1)
  check("ldelem_r8_ok", bs[0x2A1] == 0x99)
  check("bsjb_ok",
    bs[0x2AC] == 0x42 and bs[0x2AD] == 0x53 and
    bs[0x2AE] == 0x4A and bs[0x2AF] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
