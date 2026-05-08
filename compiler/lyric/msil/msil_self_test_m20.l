// msil_self_test_m20.l — Stage M20: exception handling (try/catch).
//
// Builds a PE whose Main() throws a System.Exception in a try block and
// catches it, printing 42.
//
// New infrastructure exercised:
//   EHClause record + mbAddEHClause — exception handling sections in method body
//   MoreSects flag (0x1B) in fat header — signals EH section follows code
//   Fat EH section (0x41) — typed catch clause in fat format (24 bytes/clause)
//   leave (0xDD) — exits a try or handler block
//   throw (0x7A) — throws an exception object
//   newobj (0x73) — creates System.Exception
//
// Code layout (fat header at 0x248, code at 0x254):
//   [try_start]
//   offset  0  73 02 00 00 0A  newobj  MemberRef[2] = System.Exception::.ctor()
//   offset  5  7A              throw
//   offset  6  DD F3 FF FF FF  leave end  (unreachable; rel = end(23)-next(11) = 12 = 0x0C)
//   [handler_start = offset 11]
//   offset 11  26              pop   (discard exception object)
//   offset 12  1F 2A           ldc.i4.s 42
//   offset 14  0A              stloc.0
//   offset 15  DD 07 00 00 00  leave end  (rel = end(23)-next(20) = 3)
//   [try_end = handler_end = offset 20]  ← actually handler_end = 20, end_lbl = 20
//   Wait — let me recount:
//
// Actually the leave at offset 6 targets end_lbl.  next_pc for leave at offset 6 = 6+5=11.
// If end_lbl is at offset 23, rel = 23-11 = 12 = 0x0C.
// The leave at offset 15: next_pc = 15+5=20. end_lbl=23, rel=23-20=3.
// handler_end = 20 (exclusive = first insn after handler).
//
// Revised code layout:
//   offset  0  [try_start]
//   offset  0  73 02 00 00 0A   newobj System.Exception::.ctor()   [5 bytes]
//   offset  5  7A               throw                               [1 byte]
//   offset  6  DD 0C 00 00 00   leave end_lbl                       [5 bytes, rel=12]
//   offset 11  [handler_start]
//   offset 11  26               pop                                 [1 byte]
//   offset 12  1F 2A            ldc.i4.s 42                        [2 bytes]
//   offset 14  0A               stloc.0                            [1 byte]
//   offset 15  DD 03 00 00 00   leave end_lbl                       [5 bytes, rel=3]
//   offset 20  [handler_end / try_end]
//   offset 20  [end_lbl]
//   offset 20  06               ldloc.0                            [1 byte]
//   offset 21  28 01 00 00 0A   call Console.WriteLine(int)        [5 bytes]
//   offset 26  2A               ret                                [1 byte]
//
// EH clause (fat, 24 bytes):
//   flags=0 (typed catch), tryOffset=0, tryLength=11, handlerOffset=11,
//   handlerLength=9, catchToken=0x01000003 (TypeRef[3]=System.Exception)
//   Wait: handler_end=20, handler_start=11, length=20-11=9.  But the code
//   after the handler (end_lbl=20) is NOT in the handler region — the handler
//   ends at the leave instruction (exclusive), so handler_end label is placed
//   AFTER the leave, at offset 20.
//
// Code size = 27 bytes.
// Fat header (12 bytes) at 0x248: flags1=0x1B (FatFormat|InitLocals|MoreSects)
// Code (27 bytes) at 0x254 (= 0x248 + 12)
// Alignment: 0x254 + 27 = 0x26F; 0x26F % 4 = 3 → pad 1 byte → EH at 0x270
// Fat EH section at 0x270: kind=0x41, dataSize=28 (4+24), clause(24)
// BSJB at 0x270 + 4 + 24 = 0x270 + 28 = 0x28C
//
// CLR execution: throw → caught → prints "42"

package Msil.SelfTestM20

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
  val outPath = "/tmp/lyric_msil_m20_trycatch.dll"

  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
  val sSystem  = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject  = internString(sh, "Object")
  val sException = internString(sh, "Exception")
  val sCtorName  = internString(sh, ".ctor")
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

  // System.Exception::.ctor() sig: HASTHIS(0x20), 0 params, void(0x01)
  val ctorSigW = bufNew()
  bufU1(ctorSigW, 0x20); bufU1(ctorSigW, 0x00); bufU1(ctorSigW, 0x01)
  val sigCtor = internBlob(bh, "ctor_sig", bufToList(ctorSigW))

  // LocalVarSig: 1 int32 local (for result storage)
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x01); bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  val tryStart    = mbNewLabel(mbMain)
  val handlerStart = mbNewLabel(mbMain)
  val handlerEnd  = mbNewLabel(mbMain)
  val endLbl      = mbNewLabel(mbMain)

  // try block
  mbMarkLabel(mbMain, tryStart)
  emitNewobj(mbMain, 0x0A000002)       // new System.Exception()
  emitThrow(mbMain)
  emitLeave(mbMain, endLbl)            // unreachable but required by verifier

  // catch handler
  mbMarkLabel(mbMain, handlerStart)
  emitPop(mbMain)                      // discard exception object
  emitLdc_I4_S(mbMain, 42)
  emitStloc_0(mbMain)
  emitLeave(mbMain, endLbl)
  mbMarkLabel(mbMain, handlerEnd)      // handler_end = try_end = first insn after handler

  // continuation
  mbMarkLabel(mbMain, endLbl)
  emitLdloc_0(mbMain)
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

  // Attach EH clause: typed catch of System.Exception (TypeRef[3] = 0x01000003)
  mbAddEHClause(mbMain, EHClause(
    flags        = 0,           // typed catch
    tryStart     = tryStart,
    tryEnd       = handlerStart, // try region ends where handler begins
    handlerStart = handlerStart,
    handlerEnd   = handlerEnd,
    catchToken   = 0x01000003)) // TypeRef[3] = System.Exception

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
  // TypeRef[3]: System.Exception
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sException, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))

  // StandAloneSig[1]: 1 int32 local
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

  // MemberRef[1]: Console.WriteLine(int)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))
  // MemberRef[2]: System.Exception::.ctor()
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(3), name = sCtorName, signature = sigCtor))

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

  // Fat header with MoreSects at 0x248: flags1=0x1B, flags2=0x30
  check("fat_more_sects_ok", bs[0x248] == 0x1B and bs[0x249] == 0x30)

  // codeSize = 27 = 0x1B at 0x24C
  check("code_size_ok", bs[0x24C] == 0x1B and bs[0x24D] == 0 and bs[0x24E] == 0 and bs[0x24F] == 0)

  // localVarSigTok = 0x11000001 at 0x250
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // newobj (0x73) at code offset 0 = file 0x254
  check("newobj_ok", bs[0x254] == 0x73)

  // throw (0x7A) at code offset 5 = file 0x259
  check("throw_ok", bs[0x259] == 0x7A)

  // leave (0xDD) at code offset 6 = file 0x25A
  check("leave_ok", bs[0x25A] == 0xDD)

  // EH section at 0x270: kind=0x41
  // Code ends at 0x254 + 27 = 0x26F; aligned to 4 bytes → 0x270 (0x26F + 1 padding byte)
  check("eh_sect_ok", bs[0x270] == 0x41)

  // EH section dataSize = 28 = 0x1C at 0x271 (low byte)
  check("eh_size_ok", bs[0x271] == 0x1C and bs[0x272] == 0 and bs[0x273] == 0)

  // EH clause: flags=0, tryOffset=0, tryLength=11, handlerOffset=11, handlerLength=9
  check("eh_flags_ok",   bs[0x274] == 0 and bs[0x275] == 0 and bs[0x276] == 0 and bs[0x277] == 0)
  check("eh_try_ok",     bs[0x278] == 0 and bs[0x279] == 0 and bs[0x27A] == 0 and bs[0x27B] == 0)
  check("eh_trylen_ok",  bs[0x27C] == 11 and bs[0x27D] == 0 and bs[0x27E] == 0 and bs[0x27F] == 0)
  check("eh_hstart_ok",  bs[0x280] == 11 and bs[0x281] == 0 and bs[0x282] == 0 and bs[0x283] == 0)
  check("eh_hlen_ok",    bs[0x284] == 9 and bs[0x285] == 0 and bs[0x286] == 0 and bs[0x287] == 0)

  // BSJB at 0x28C (= 0x270 + 4 + 24)
  check("bsjb_ok",
    bs[0x28C] == 0x42 and bs[0x28D] == 0x53 and
    bs[0x28E] == 0x4A and bs[0x28F] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
