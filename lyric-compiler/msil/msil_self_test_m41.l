// msil_self_test_m41.l — Stage M41: conv.ovf.*.un (unsigned-input overflow conversions).
//
// Builds a PE that exercises two unsigned-input overflow-checked conversion opcodes:
//   1. ldc.i4.s 42 / conv.ovf.i8.un  → int64(42)   (treat I4 as unsigned, convert to I8)
//      / conv.ovf.i4.un → int32(42) / print         (treat I8 as unsigned, convert to I4)
//   2. ldc.i4.s 42 / conv.ovf.u4.un  → uint32(42)  (treat I4 as unsigned, convert to U4)
//      / call                                        (U4 = int32 bits, prints 42)
// Produces two lines of "42".
//
// New instructions exercised:
//   conv.ovf.i4.un  (0x84) — overflow-checked convert unsigned-int to I4
//   conv.ovf.i8.un  (0x85) — overflow-checked convert unsigned-int to I8
//   conv.ovf.u4.un  (0x88) — overflow-checked convert unsigned-int to U4
//
// TypeRefs:
//   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//
// MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//
// Code layout (tiny header at 0x248, code at 0x249):
//   offset  0  1F 2A              ldc.i4.s 42    [2]
//   offset  2  85                 conv.ovf.i8.un [1]
//   offset  3  84                 conv.ovf.i4.un [1]
//   offset  4  28 01 00 00 0A     call WriteLineInt [5]
//   offset  9  1F 2A              ldc.i4.s 42    [2]
//   offset 11  88                 conv.ovf.u4.un [1]
//   offset 12  28 01 00 00 0A     call WriteLineInt [5]
//   offset 17  2A                 ret            [1]
//
// codeSize = 18. Tiny header = (18<<2)|2 = 74 = 0x4A.
//
// BSJB at 0x248 + 1 + 18 = 0x25B.
//
// CLR: 42 printed twice ("42\n42").

package Msil.SelfTestM41

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
  val outPath = "/tmp/lyric_msil_m41_convovfun.dll"

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

  // void () sig for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4(0x08)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  // conv.ovf.i8.un then conv.ovf.i4.un: int32(42) → int64(42) → int32(42)
  emitLdc_I4_S(mbMain, 42)
  emitConv_Ovf_I8_Un(mbMain)
  emitConv_Ovf_I4_Un(mbMain)
  emitCall(mbMain, 0x0A000001)

  // conv.ovf.u4.un: int32(42) → uint32(42) — same bits, prints 42
  emitLdc_I4_S(mbMain, 42)
  emitConv_Ovf_U4_Un(mbMain)
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

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh)
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header at 0x248: (18<<2)|2 = 74 = 0x4A
  check("tiny_hdr_ok", bs[0x248] == 0x4A)

  // conv.ovf.i8.un (0x85) at code offset 2 = file 0x24B
  check("conv_i8un_ok", bs[0x24B] == 0x85)

  // conv.ovf.i4.un (0x84) at code offset 3 = file 0x24C
  check("conv_i4un_ok", bs[0x24C] == 0x84)

  // conv.ovf.u4.un (0x88) at code offset 11 = file 0x254
  check("conv_u4un_ok", bs[0x254] == 0x88)

  // BSJB at 0x248 + 1 + 18 = 0x25B
  check("bsjb_ok",
    bs[0x25B] == 0x42 and bs[0x25C] == 0x53 and
    bs[0x25D] == 0x4A and bs[0x25E] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
