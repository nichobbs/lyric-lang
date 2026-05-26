// msil_self_test_m78.l — Stage M78: newarr (0x8D), ldlen (0x8E), ldelema (0x8F).
//
// Exercises:
//   newarr (0x8D) — create zero-initialized single-dimension array
//   ldlen  (0x8E) — push array length as native int
//   ldelema (0x8F) — push address of array element
//
// Fat method header required (1 local: Int32[] = SZARRAY I4).
// LocalVarSig: { 0x07, 0x01, 0x1D, 0x08 }
//
// TypeRef layout:
//   TypeRef[1]: System.Console (AssemblyRef[2])
//   TypeRef[2]: System.Object  (AssemblyRef[1])
//   TypeRef[3]: System.Int32   (AssemblyRef[1]) — for newarr / ldelema
//
// Code layout (fat header at 0x248, code at 0x254, codeSize=32):
//   offset  0-2:  nop nop nop
//   offset  3:    ldc.i4.1 (1b)            → push 1 (array size)
//   offset  4:    newarr 0x01000003 (5b)   ← 0x8D at file 0x258
//   offset  9:    stloc.0 (1b)             → local[0] = Int32[1]
//   offset 10:    ldloc.0 (1b)
//   offset 11:    ldc.i4.0 (1b)
//   offset 12:    ldc.i4.s 42 (2b)
//   offset 14:    stelem.i4 (1b)           → arr[0] = 42
//   offset 15:    ldloc.0 (1b)
//   offset 16:    ldlen (1b)               ← 0x8E at file 0x264
//   offset 17:    pop (1b)                 → discard length
//   offset 18:    ldloc.0 (1b)
//   offset 19:    ldc.i4.0 (1b)
//   offset 20:    ldelema 0x01000003 (5b)  ← 0x8F at file 0x268
//   offset 25:    ldind.i4 (1b)            → load arr[0] = 42
//   offset 26:    call (5b)                → Console.WriteLine(42)
//   offset 31:    ret (1b)
//
// BSJB at 0x254 + 32 = 0x274.
//
// Checks:
//   newarr_ok:  bs[0x258] == 0x8D
//   ldlen_ok:   bs[0x264] == 0x8E
//   ldelema_ok: bs[0x268] == 0x8F

package Msil.SelfTestM78

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
  val outPath = "/tmp/lyric_msil_m78_newarr_ldlen_ldelema.dll"

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

  // LocalVarSig: LOCAL_SIG(0x07) + count=1 + SZARRAY(0x1D) + I4(0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x01)
  bufU1(lvW, 0x1D); bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // TypeRef[3] = System.Int32 → token 0x01000003
  val tokInt32 = 0x01000003

  val mbMain = newMethodBody()
  emitNop(mbMain)                          // offset  0: nop (1b)
  emitNop(mbMain)                          // offset  1: nop (1b)
  emitNop(mbMain)                          // offset  2: nop (1b)
  emitLdc_I4_1(mbMain)                     // offset  3: push 1 (1b)
  emitNewarr(mbMain, tokInt32)             // offset  4: new Int32[1] (5b) ← 0x8D at 0x258
  emitStloc_0(mbMain)                      // offset  9: store array (1b)
  emitLdloc_0(mbMain)                      // offset 10: load array (1b)
  emitLdc_I4_0(mbMain)                     // offset 11: push 0 (1b)
  emitLdc_I4_S(mbMain, 42)                // offset 12: push 42 (2b)
  emitStelem_I4(mbMain)                    // offset 14: arr[0]=42 (1b)
  emitLdloc_0(mbMain)                      // offset 15: load array (1b)
  emitLdlen(mbMain)                        // offset 16: push length (1b) ← 0x8E at 0x264
  emitPop(mbMain)                          // offset 17: discard (1b)
  emitLdloc_0(mbMain)                      // offset 18: load array (1b)
  emitLdc_I4_0(mbMain)                     // offset 19: push 0 (1b)
  emitLdelema(mbMain, tokInt32)            // offset 20: &arr[0] (5b) ← 0x8F at 0x268
  emitLdind_I4(mbMain)                     // offset 25: load 42 (1b)
  emitCall(mbMain, 0x0A000001)            // offset 26: print (5b)
  emitRet(mbMain)                          // offset 31

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))
  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))
  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))
  addAssembly(t, AssemblyRow(hashAlgId = HASH_ALG_SHA1, majorVersion = 0, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = ASF_NONE, publicKey = 0, name = sHello, culture = 0))
  addAssemblyRef(t, AssemblyRefRow(majorVersion = 10, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = 0, publicKeyToken = keyToken, name = sRuntime,    culture = 0, hashValue = 0))
  addAssemblyRef(t, AssemblyRefRow(majorVersion = 10, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = 0, publicKeyToken = keyToken, name = sConsoleAsm, culture = 0, hashValue = 0))

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh, resourceData = newList())
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok",  bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("newarr_ok",   bs[0x258] == 0x8D)
  check("ldlen_ok",    bs[0x264] == 0x8E)
  check("ldelema_ok",  bs[0x268] == 0x8F)
  check("bsjb_ok",
    bs[0x274] == 0x42 and bs[0x275] == 0x53 and
    bs[0x276] == 0x4A and bs[0x277] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
