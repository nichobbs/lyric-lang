// msil_self_test_m70.l — Stage M70: ldc.r8 (0x23), ldc.r4 (0x22), ckfinite (0xC3).
//
// Exercises:
//   ldc.r8   (0x23) — push float64 literal (opcode + 8 bytes LE)
//   ckfinite (0xC3) — verify top-of-stack float is finite
//   ldc.r4   (0x22) — push float32 literal (opcode + 4 bytes LE)
//
// Code flow:
//   ldc.r8 42.0 (9B) / ckfinite (1B) / conv.i4 → 42
//   ldc.r4 0.0  (5B) / conv.i4 / add           → 42 + 0 = 42
//   call Console.WriteLine(int32) / ret  → prints "42"
//
// codeSize = 24.  Tiny header byte = (24 << 2) | 2 = 0x62.
//   ldc.r8   (0x23) at code offset  0 = file 0x249.
//   ckfinite (0xC3) at code offset  9 = file 0x252.
//   ldc.r4   (0x22) at code offset 11 = file 0x254.
// BSJB at 0x249 + 24 = 0x261.

package Msil.SelfTestM70

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
  val outPath = "/tmp/lyric_msil_m70_float_load.dll"

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

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  val mbMain = newMethodBody()
  emitLdc_R8(mbMain, 42.0)      // push 42.0 (float64, 9 bytes: opcode + 8)
  emitCkfinite(mbMain)           // verify 42.0 is finite → stays 42.0
  emitConv_I4(mbMain)            // 42.0 → 42 (i4)
  emitLdc_R4(mbMain, 0.0)       // push 0.0 (float32, 5 bytes: opcode + 4)
  emitConv_I4(mbMain)            // 0.0f → 0 (i4)
  emitAdd(mbMain)                // 42 + 0 = 42
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

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
  check("tiny_hdr_ok", bs[0x248] == 0x62)
  check("ldc_r8_ok", bs[0x249] == 0x23)
  check("ckfinite_ok", bs[0x252] == 0xC3)
  check("ldc_r4_ok", bs[0x254] == 0x22)
  check("bsjb_ok",
    bs[0x261] == 0x42 and bs[0x262] == 0x53 and
    bs[0x263] == 0x4A and bs[0x264] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
