// msil_self_test_m36.l — Stage M36: ldind.i4 + stind.i4 (indirect int32 load/store).
//
// Builds a PE with one method, Main(), that:
//   1. Takes the address of local[0] (I4) via ldloca_S 0.
//   2. Pushes 42 and stores it at the address via stind.i4.
//   3. Reloads the address and reads the value back via ldind.i4.
//   4. Prints the result (42) via Console.WriteLine(int).
//
// New instructions exercised:
//   stind.i4 (0x54) — stores an int32 at a managed pointer address.
//   ldind.i4 (0x4A) — loads an int32 from a managed pointer address.
//
// Fat method header required (one I4 local).
//
// LocalVarSig: { 0x07, 0x01, 0x08 } — LOCAL_SIG, count=1, ELEMENT_TYPE_I4
//
// TypeRefs:
//   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//
// MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
// StandAloneSig[1]: LocalVarSig for the I4 local
//
// Code layout (fat header at 0x248, code at 0x254):
//   offset  0  12 00              ldloca_S 0   [2]  addr of local[0]
//   offset  2  1F 2A              ldc.i4.s 42  [2]
//   offset  4  54                 stind.i4     [1]  local[0] = 42
//   offset  5  12 00              ldloca_S 0   [2]  addr of local[0]
//   offset  7  4A                 ldind.i4     [1]  push local[0] = 42
//   offset  8  28 01 00 00 0A     call MemberRef[1] [5]
//   offset 13  2A                 ret          [1]
//
// codeSize = 14. maxStack = 2.
//
// Fat header (12 bytes) at 0x248:
//   flags=0x13, size=0x30, maxStack=2, codeSize=14, localVarSigTok=0x11000001
//
// BSJB at 0x248 + 12 + 14 = 0x262.
//
// CLR: stind.i4 writes 42 into local[0]; ldind.i4 reads it back → prints "42".

package Msil.SelfTestM36

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
  val outPath = "/tmp/lyric_msil_m36_ldind.dll"

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

  // LocalVarSig: LOCAL_SIG(0x07) + count=1 + ELEMENT_TYPE_I4(0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x01); bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()
  // addr, 42 → stind.i4 stores 42 at local[0]
  emitLdloca_S(mbMain, 0)
  emitLdc_I4_S(mbMain, 42)
  emitStind_I4(mbMain)
  // addr → ldind.i4 loads local[0] = 42
  emitLdloca_S(mbMain, 0)
  emitLdind_I4(mbMain)
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

  // StandAloneSig[1]: LocalVarSig for I4 local
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

  // MemberRef[1]: Console.WriteLine(int)
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

  // Fat header at 0x248: flags=0x13, size=0x30
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)

  // localVarSigTok = 0x11000001 at 0x248+8 = 0x250
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // ldloca_S (0x12) at code offset 0 = file 0x254
  check("ldloca_ok", bs[0x254] == 0x12)

  // stind.i4 (0x54) at code offset 4 = file 0x258
  check("stind_ok", bs[0x258] == 0x54)

  // ldind.i4 (0x4A) at code offset 7 = file 0x25B
  check("ldind_ok", bs[0x25B] == 0x4A)

  // BSJB at 0x248 + 12 + 14 = 0x262
  check("bsjb_ok",
    bs[0x262] == 0x42 and bs[0x263] == 0x53 and
    bs[0x264] == 0x4A and bs[0x265] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
