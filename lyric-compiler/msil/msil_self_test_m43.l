// msil_self_test_m43.l — Stage M43: localloc (stack allocation).
//
// Builds a PE that exercises localloc (0xFE 0x0F):
//   1. ldc.i4.s 4 / localloc  → push pointer to 4 bytes of stack memory
//   2. dup / ldc.i4.s 42 / stind.i4  → write 42 at the address
//   3. ldind.i4 / call Console.WriteLine(int)  → read 42, print
//
// localloc requires a fat header (InitLocals flag). A dummy I4 local forces fat.
//
// New instruction exercised:
//   localloc  (0xFE 0x0F) — allocate zeroed stack memory; pushes native-int pointer.
//
// TypeRefs:
//   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])
//
// MemberRef[1]: Console.WriteLine(int)
// StandAloneSig[1]: LocalVarSig {0x07, 0x01, 0x08} (dummy I4 local for fat header)
//
// Code layout (fat header at 0x248, code at 0x254):
//   offset  0  1F 04              ldc.i4.s 4   [2]  alloc size
//   offset  2  FE 0F              localloc     [2]  push ptr
//   offset  4  25                 dup          [1]  copy ptr
//   offset  5  1F 2A              ldc.i4.s 42  [2]  value
//   offset  7  54                 stind.i4     [1]  *ptr = 42
//   offset  8  4A                 ldind.i4     [1]  push *ptr = 42
//   offset  9  28 01 00 00 0A     call WriteLineInt [5]
//   offset 14  2A                 ret          [1]
//
// codeSize = 15. Fat header (12 bytes) at 0x248. Code at 0x254.
//
// localloc at file 0x256 (0x254+2).
// stind.i4 at file 0x25B (0x254+7).
// ldind.i4 at file 0x25C (0x254+8).
// BSJB at 0x248 + 12 + 15 = 0x263.
//
// CLR: localloc 4 bytes → write 42 → read 42 → prints "42".

package Msil.SelfTestM43

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
  val outPath = "/tmp/lyric_msil_m43_localloc.dll"

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

  // Dummy local to force fat header with InitLocals.
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x01); bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  emitLdc_I4_S(mbMain, 4)        // push alloc size = 4
  emitLocalloc(mbMain)           // push ptr to 4 zeroed stack bytes
  emitDup(mbMain)                // dup ptr
  emitLdc_I4_S(mbMain, 42)      // push 42
  emitStind_I4(mbMain)           // *ptr = 42
  emitLdind_I4(mbMain)           // push *ptr = 42
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

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh, resourceData = newList(), buildKind = "lib")
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Fat header at 0x248
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // localloc (0xFE 0x0F) at code offset 2 = file 0x256
  check("localloc_ok", bs[0x256] == 0xFE and bs[0x257] == 0x0F)

  // stind.i4 (0x54) at code offset 7 = file 0x25B
  check("stind_ok", bs[0x25B] == 0x54)

  // ldind.i4 (0x4A) at code offset 8 = file 0x25C
  check("ldind_ok", bs[0x25C] == 0x4A)

  // BSJB at 0x248 + 12 + 15 = 0x263
  check("bsjb_ok",
    bs[0x263] == 0x42 and bs[0x264] == 0x53 and
    bs[0x265] == 0x4A and bs[0x266] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
