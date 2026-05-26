// msil_self_test_m71.l — Stage M71: div (0x5B), beq (0x3B), bgt (0x3D).
//
// Exercises:
//   div (0x5B) — integer divide
//   beq (0x3B) — branch if equal (4-byte signed offset)
//   bgt (0x3D) — branch if greater-than
//
// Code flow:
//   ldc.i4.s 84 / ldc.i4.s 2 / div → 42
//   ldc.i4.s 42 / beq BEQ_OK        (42==42 → jump; dead: push 0/call/ret, empty stack)
//   BEQ_OK: ldc.i4.s 42 / ldc.i4.s 41 / bgt BGT_OK (42>41 → jump; dead: push 0/call/ret)
//   BGT_OK: ldc.i4.s 42 / call Console.WriteLine / ret  → prints "42"
//
// codeSize = 45.  Tiny header byte = (45 << 2) | 2 = 0xB6.
//   div   (0x5B) at code offset  4 = file 0x24D.
//   beq   (0x3B) at code offset  7 = file 0x250.
//   bgt   (0x3D) at code offset 24 = file 0x261.
// BSJB at 0x249 + 45 = 0x276.
//
// beq branch offset: BEQ_OK(20) - next_instr(12) = 8 → LE32: 08 00 00 00
// bgt branch offset: BGT_OK(37) - next_instr(29) = 8 → LE32: 08 00 00 00
//
// Stack discipline: beq pops both operands → dead fall-through has empty stack.
//                   bgt pops both operands → dead fall-through has empty stack.

package Msil.SelfTestM71

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
  val outPath = "/tmp/lyric_msil_m71_div_beq_bgt.dll"

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
  val lblBeqOk = mbNewLabel(mbMain)
  val lblBgtOk = mbNewLabel(mbMain)
  emitLdc_I4_S(mbMain, 84)         // offset  0: push 84      (2 bytes) → [84]
  emitLdc_I4_S(mbMain, 2)          // offset  2: push 2       (2 bytes) → [84, 2]
  emitDiv(mbMain)                   // offset  4: 84/2 = 42   (1 byte)  → [42]
  emitLdc_I4_S(mbMain, 42)         // offset  5: push 42      (2 bytes) → [42, 42]
  emitBeq(mbMain, lblBeqOk)        // offset  7: beq → BEQ_OK(20); next=12; offset=+8; pops 2 → []
  emitLdc_I4_S(mbMain, 0)          // offset 12: dead → [0]
  emitCall(mbMain, 0x0A000001)      // offset 14: dead → []
  emitRet(mbMain)                   // offset 19: dead, empty stack ✓
  // BEQ_OK: offset 20
  mbMarkLabel(mbMain, lblBeqOk)
  emitLdc_I4_S(mbMain, 42)         // offset 20: push 42      (2 bytes) → [42]
  emitLdc_I4_S(mbMain, 41)         // offset 22: push 41      (2 bytes) → [42, 41]
  emitBgt(mbMain, lblBgtOk)        // offset 24: bgt → BGT_OK(37); next=29; offset=+8; 42>41 → jump; pops 2 → []
  emitLdc_I4_S(mbMain, 0)          // offset 29: dead → [0]
  emitCall(mbMain, 0x0A000001)      // offset 31: dead → []
  emitRet(mbMain)                   // offset 36: dead, empty stack ✓
  // BGT_OK: offset 37
  mbMarkLabel(mbMain, lblBgtOk)
  emitLdc_I4_S(mbMain, 42)         // offset 37: push 42      (2 bytes) → [42]
  emitCall(mbMain, 0x0A000001)      // offset 39: print 42    (5 bytes) → []
  emitRet(mbMain)                   // offset 44

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

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh, resourceData = newList())
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("tiny_hdr_ok", bs[0x248] == 0xB6)
  check("div_ok",  bs[0x24D] == 0x5B)
  check("beq_ok",  bs[0x250] == 0x3B)
  check("bgt_ok",  bs[0x261] == 0x3D)
  check("bsjb_ok",
    bs[0x276] == 0x42 and bs[0x277] == 0x53 and
    bs[0x278] == 0x4A and bs[0x279] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
