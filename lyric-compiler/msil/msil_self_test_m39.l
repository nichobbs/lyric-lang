// msil_self_test_m39.l — Stage M39: conv.ovf.i4 + conv.ovf.i8.
//
// Builds a PE that exercises two overflow-checked conversion opcodes:
//   1. ldc.i8 42L / conv.ovf.i4  → 42 (int64 → int32, in-range)
//   2. ldc.i4.s 42 / conv.ovf.i8 / conv.ovf.i4  → 42 (int32 → int64 → int32)
// Each result is printed, producing two lines of "42".
//
// New instructions exercised:
//   conv.ovf.i4  (0xB7) — overflow-checked convert-to-int32
//   conv.ovf.i8  (0xB9) — overflow-checked convert-to-int64
//
// TypeRefs:
//   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//
// MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//
// Code layout (tiny header at 0x248, code at 0x249):
//   offset  0  21 2A 00 00 00 00 00 00 00  ldc.i8 42  [9]
//   offset  9  B7                          conv.ovf.i4 [1]
//   offset 10  28 01 00 00 0A              call WriteLineInt [5]
//   offset 15  1F 2A                       ldc.i4.s 42 [2]
//   offset 17  B9                          conv.ovf.i8 [1]
//   offset 18  B7                          conv.ovf.i4 [1]
//   offset 19  28 01 00 00 0A              call WriteLineInt [5]
//   offset 24  2A                          ret         [1]
//
// codeSize = 25. Tiny header = (25<<2)|2 = 102 = 0x66.
//
// BSJB at 0x248 + 1 + 25 = 0x262.
//
// CLR: conv.ovf.i4(42L)=42, conv.ovf.i4(conv.ovf.i8(42))=42 → prints "42\n42".

package Msil.SelfTestM39

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
  val outPath = "/tmp/lyric_msil_m39_conv_ovf.dll"

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

  // conv.ovf.i4: int64(42) → int32(42)
  emitLdc_I8(mbMain, 42i64)
  emitConv_Ovf_I4(mbMain)
  emitCall(mbMain, 0x0A000001)

  // conv.ovf.i8 then conv.ovf.i4: int32(42) → int64(42) → int32(42)
  emitLdc_I4_S(mbMain, 42)
  emitConv_Ovf_I8(mbMain)
  emitConv_Ovf_I4(mbMain)
  emitCall(mbMain, 0x0A000001)

  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (Hello extends)
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))

  // MemberRef[1]: Console.WriteLine(int)
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

  // Tiny header at 0x248: (25<<2)|2 = 102 = 0x66
  check("tiny_hdr_ok", bs[0x248] == 0x66)

  // conv.ovf.i4 (0xB7) at code offset 9 = file 0x252
  check("conv_ovf_i4_ok", bs[0x252] == 0xB7)

  // conv.ovf.i8 (0xB9) at code offset 17 = file 0x25A
  check("conv_ovf_i8_ok", bs[0x25A] == 0xB9)

  // second conv.ovf.i4 at code offset 18 = file 0x25B
  check("conv_ovf_i4b_ok", bs[0x25B] == 0xB7)

  // BSJB at 0x248 + 1 + 25 = 0x262
  check("bsjb_ok",
    bs[0x262] == 0x42 and bs[0x263] == 0x53 and
    bs[0x264] == 0x4A and bs[0x265] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
