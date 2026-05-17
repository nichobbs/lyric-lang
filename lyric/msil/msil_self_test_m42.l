// msil_self_test_m42.l — Stage M42: stind.i1/i2 + ldind.u1/i2 (narrow indirect access).
//
// Builds a PE that exercises narrow indirect stores and loads through a managed pointer:
//   1. ldloca_S 0 / ldc.i4.s 42 / stind.i1 / ldloca_S 0 / ldind.u1 / call → 42
//   2. ldloca_S 0 / ldc.i4.s 42 / stind.i2 / ldloca_S 0 / ldind.i2 / call → 42
// Produces two lines of "42".
//
// New instructions exercised:
//   stind.i1 (0x52) — store low byte of I4 at managed pointer
//   ldind.u1 (0x47) — load unsigned byte, zero-extend to I4
//   stind.i2 (0x53) — store low two bytes of I4 at managed pointer
//   ldind.i2 (0x48) — load signed short, sign-extend to I4
//
// Fat method header (one I4 local).
// LocalVarSig: { 0x07, 0x01, 0x08 } — LOCAL_SIG, count=1, ELEMENT_TYPE_I4
//
// Code layout (fat header at 0x248, code at 0x254):
//   offset  0  12 00              ldloca_S 0   [2]
//   offset  2  1F 2A              ldc.i4.s 42  [2]
//   offset  4  52                 stind.i1     [1]
//   offset  5  12 00              ldloca_S 0   [2]
//   offset  7  47                 ldind.u1     [1]
//   offset  8  28 01 00 00 0A     call WriteLineInt [5]
//   offset 13  12 00              ldloca_S 0   [2]
//   offset 15  1F 2A              ldc.i4.s 42  [2]
//   offset 17  53                 stind.i2     [1]
//   offset 18  12 00              ldloca_S 0   [2]
//   offset 20  48                 ldind.i2     [1]
//   offset 21  28 01 00 00 0A     call WriteLineInt [5]
//   offset 26  2A                 ret          [1]
//
// codeSize = 27. Fat header at 0x248, code at 0x254.
// stind.i1 at file 0x258, ldind.u1 at 0x25B.
// stind.i2 at file 0x265, ldind.i2 at 0x268.
// BSJB at 0x248 + 12 + 27 = 0x26F.
//
// CLR: stind.i1 writes 0x2A; ldind.u1 reads 42 → "42".
//      stind.i2 writes 0x002A; ldind.i2 reads 42 → "42".

package Msil.SelfTestM42

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
  val outPath = "/tmp/lyric_msil_m42_narrow_ind.dll"

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

  // stind.i1 / ldind.u1: store byte 42, load as unsigned → 42
  emitLdloca_S(mbMain, 0)
  emitLdc_I4_S(mbMain, 42)
  emitStind_I1(mbMain)
  emitLdloca_S(mbMain, 0)
  emitLdind_U1(mbMain)
  emitCall(mbMain, 0x0A000001)

  // stind.i2 / ldind.i2: store short 42, load as signed → 42
  emitLdloca_S(mbMain, 0)
  emitLdc_I4_S(mbMain, 42)
  emitStind_I2(mbMain)
  emitLdloca_S(mbMain, 0)
  emitLdind_I2(mbMain)
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

  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

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

  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // stind.i1 (0x52) at code offset 4 = file 0x258
  check("stind_i1_ok", bs[0x258] == 0x52)

  // ldind.u1 (0x47) at code offset 7 = file 0x25B
  check("ldind_u1_ok", bs[0x25B] == 0x47)

  // stind.i2 (0x53) at code offset 17 = file 0x265
  check("stind_i2_ok", bs[0x265] == 0x53)

  // ldind.i2 (0x48) at code offset 20 = file 0x268
  check("ldind_i2_ok", bs[0x268] == 0x48)

  // BSJB at 0x248 + 12 + 27 = 0x26F
  check("bsjb_ok",
    bs[0x26F] == 0x42 and bs[0x270] == 0x53 and
    bs[0x271] == 0x4A and bs[0x272] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
