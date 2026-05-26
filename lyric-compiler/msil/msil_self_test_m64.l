// msil_self_test_m64.l — Stage M64: floating-point conversion opcodes.
//
// Exercises:
//   conv.r8    (0x6C) — convert integer to float64
//   conv.r4    (0x6B) — convert integer to float32
//   conv.r.un  (0x76) — convert unsigned integer to floating-point
//
// Code flow (all conversions round-trip back to int32 = 42):
//   ldc.i4.s 42 / conv.r8 / conv.i4   → 42 (i4→f8→i4 round-trip)
//   ldc.i4.0 / conv.r4 / conv.i4 / add → 42 + 0 = 42
//   ldc.i4.0 / conv.r.un / conv.i4 / add → 42 + 0 = 42
//   call Console.WriteLine(int32) / ret  → prints "42"
//
// codeSize = 18.  Tiny header (1 byte) at 0x248.  Code at 0x249.
//   conv.r8   (0x6C) at code offset 2 = file 0x24B.
//   conv.r4   (0x6B) at code offset 5 = file 0x24E.
//   conv.r.un (0x76) at code offset 9 = file 0x252.
// BSJB at 0x249 + 18 = 0x25B.
//
// Tiny header byte = (18 << 2) | 2 = 0x4A.

package Msil.SelfTestM64

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
  val outPath = "/tmp/lyric_msil_m64_conv_float.dll"

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

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  emitLdc_I4_S(mbMain, 42)     // push 42
  emitConv_R8(mbMain)           // 42 → 42.0 (float64)
  emitConv_I4(mbMain)           // 42.0 → 42 (i4)
  emitLdc_I4_0(mbMain)          // push 0
  emitConv_R4(mbMain)           // 0 → 0.0f (float32)
  emitConv_I4(mbMain)           // 0.0f → 0 (i4)
  emitAdd(mbMain)               // 42 + 0 = 42
  emitLdc_I4_0(mbMain)          // push 0
  emitConv_R_Un(mbMain)         // 0 → 0.0 (float, from unsigned int)
  emitConv_I4(mbMain)           // 0.0 → 0 (i4)
  emitAdd(mbMain)               // 42 + 0 = 42
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
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

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh, resourceData = newList())
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header at 0x248: (18 << 2) | 2 = 0x4A
  check("tiny_hdr_ok", bs[0x248] == 0x4A)

  // conv.r8 (0x6C) at code offset 2 = file 0x24B
  check("conv_r8_ok", bs[0x24B] == 0x6C)

  // conv.r4 (0x6B) at code offset 5 = file 0x24E
  check("conv_r4_ok", bs[0x24E] == 0x6B)

  // conv.r.un (0x76) at code offset 9 = file 0x252
  check("conv_r_un_ok", bs[0x252] == 0x76)

  // BSJB at 0x249 + 18 = 0x25B
  check("bsjb_ok",
    bs[0x25B] == 0x42 and bs[0x25C] == 0x53 and
    bs[0x25D] == 0x4A and bs[0x25E] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
