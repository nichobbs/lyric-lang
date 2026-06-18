// msil_self_test_m21.l — Stage M21: finally block.
//
// Builds a PE whose Main() executes a try block that sets a local to 10,
// then a finally block that adds 32, printing 42.
//
// New infrastructure exercised:
//   EHClause with flags=2 (finally) — catchToken = 0 (no type token)
//   endfinally (0xDC) — exits a finally handler
//
// Code layout (fat header at 0x248, code at 0x254):
//   offset  0  1F 0A            ldc.i4.s 10         [2 bytes]
//   offset  2  0A               stloc.0             [1 byte]
//   offset  3  DD 06 00 00 00   leave end_lbl        [5 bytes, rel=end(14)-next(8)=6]
//   offset  8  [finally_start]
//   offset  8  06               ldloc.0             [1 byte]
//   offset  9  1F 20            ldc.i4.s 32         [2 bytes]
//   offset 11  58               add                 [1 byte]
//   offset 12  0A               stloc.0             [1 byte]
//   offset 13  DC               endfinally          [1 byte]
//   offset 14  [finally_end / try_end / end_lbl]
//   offset 14  06               ldloc.0             [1 byte]
//   offset 15  28 01 00 00 0A   call Console.WriteLine(int) [5 bytes]
//   offset 20  2A               ret                 [1 byte]
//
// Code size = 21 = 0x15.
//
// EH clause (fat, 24 bytes):
//   flags=2 (finally), tryOffset=0, tryLength=8, handlerOffset=8,
//   handlerLength=6, catchToken=0
//
// Fat header (12 bytes) at 0x248: flags1=0x1B (FatFormat|InitLocals|MoreSects)
// Code (21 bytes) at 0x254.
// 0x254 + 21 = 0x269; 0x269 % 4 = 1 → pad 3 bytes → EH at 0x26C.
// Fat EH section at 0x26C: kind=0x41, dataSize=28=0x1C, clause(24).
// BSJB at 0x26C + 28 = 0x288.
//
// CLR execution: try sets 10, finally adds 32 → prints "42".

package Msil.SelfTestM21

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
  val outPath = "/tmp/lyric_msil_m21_finally.dll"

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

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // LocalVarSig: 1 int32 local
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x01); bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  val tryStart     = mbNewLabel(mbMain)
  val finallyStart = mbNewLabel(mbMain)
  val finallyEnd   = mbNewLabel(mbMain)
  val endLbl       = mbNewLabel(mbMain)    // same position as finallyEnd

  // try block: set local to 10
  mbMarkLabel(mbMain, tryStart)
  emitLdc_I4_S(mbMain, 10)
  emitStloc_0(mbMain)
  emitLeave(mbMain, endLbl)

  // finally handler: add 32
  mbMarkLabel(mbMain, finallyStart)
  emitLdloc_0(mbMain)
  emitLdc_I4_S(mbMain, 32)
  emitAdd(mbMain)
  emitStloc_0(mbMain)
  emitEndfinally(mbMain)
  mbMarkLabel(mbMain, finallyEnd)

  // continuation
  mbMarkLabel(mbMain, endLbl)
  emitLdloc_0(mbMain)
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

  // Attach EH clause: finally (flags=2, catchToken=0)
  mbAddEHClause(mbMain, EHClause(
    flags        = 2,           // finally
    tryStart     = tryStart,
    tryEnd       = finallyStart,
    handlerStart = finallyStart,
    handlerEnd   = finallyEnd,
    catchToken   = 0))

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))

  // StandAloneSig[1]: 1 int32 local
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

  // MemberRef[1]: Console.WriteLine(int)
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

  // Fat header with MoreSects at 0x248: flags1=0x1B, flags2=0x30
  check("fat_more_sects_ok", bs[0x248] == 0x1B and bs[0x249] == 0x30)

  // codeSize = 21 = 0x15 at 0x24C
  check("code_size_ok", bs[0x24C] == 0x15 and bs[0x24D] == 0 and bs[0x24E] == 0 and bs[0x24F] == 0)

  // localVarSigTok = 0x11000001 at 0x250
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // leave (0xDD) at code offset 3 = file 0x257
  check("leave_ok", bs[0x257] == 0xDD)

  // endfinally (0xDC) at code offset 13 = file 0x261
  check("endfinally_ok", bs[0x261] == 0xDC)

  // EH section at 0x26C: kind=0x41
  // Code ends at 0x254 + 21 = 0x269; 0x269 % 4 = 1 → pad 3 bytes → EH at 0x26C
  check("eh_sect_ok", bs[0x26C] == 0x41)

  // EH section dataSize = 28 = 0x1C at 0x26D
  check("eh_size_ok", bs[0x26D] == 0x1C and bs[0x26E] == 0 and bs[0x26F] == 0)

  // EH clause at 0x270: flags=2 (finally)
  check("eh_flags_ok",   bs[0x270] == 2 and bs[0x271] == 0 and bs[0x272] == 0 and bs[0x273] == 0)
  check("eh_try_ok",     bs[0x274] == 0 and bs[0x275] == 0 and bs[0x276] == 0 and bs[0x277] == 0)
  check("eh_trylen_ok",  bs[0x278] == 8 and bs[0x279] == 0 and bs[0x27A] == 0 and bs[0x27B] == 0)
  check("eh_hstart_ok",  bs[0x27C] == 8 and bs[0x27D] == 0 and bs[0x27E] == 0 and bs[0x27F] == 0)
  check("eh_hlen_ok",    bs[0x280] == 6 and bs[0x281] == 0 and bs[0x282] == 0 and bs[0x283] == 0)

  // catchToken = 0 for finally at 0x284
  check("catch_tok_ok",  bs[0x284] == 0 and bs[0x285] == 0 and bs[0x286] == 0 and bs[0x287] == 0)

  // BSJB at 0x288 (= 0x26C + 28)
  check("bsjb_ok",
    bs[0x288] == 0x42 and bs[0x289] == 0x53 and
    bs[0x28A] == 0x4A and bs[0x28B] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
