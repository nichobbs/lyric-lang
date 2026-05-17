// msil_self_test_m74.l — Stage M74: ble.un (0x43), blt.un (0x44), ldc.i4 (0x20), ldc.i4.6/7/8 (0x1C/0x1D/0x1E).
//
// Exercises:
//   ble.un (0x43)   — branch if less-than-or-equal (unsigned)
//   blt.un (0x44)   — branch if less-than (unsigned)
//   ldc.i4  (0x20)  — push int32 literal (full 4-byte form)
//   ldc.i4.6 (0x1C) — push constant 6
//   ldc.i4.7 (0x1D) — push constant 7
//   ldc.i4.8 (0x1E) — push constant 8
//
// Code flow:
//   ldc.i4 42 / ldc.i4.s 43 / ble.un BLE_OK  (42<=43 unsigned → jump; dead path)
//   BLE_OK: ldc.i4 42 / ldc.i4.s 43 / blt.un BLT_OK  (42<43 unsigned → jump; dead)
//   BLT_OK: ldc.i4.6 / ldc.i4.7 / mul → 42
//           ldc.i4.8 / ldc.i4.8 / sub / add → 42 + 0 = 42
//           call / ret  → prints "42"
//
// codeSize = 53.  Tiny header byte = (53 << 2) | 2 = 0xD6.
//   ldc.i4  (0x20) at code offset  0 = file 0x249.
//   ble.un  (0x43) at code offset  7 = file 0x250.
//   blt.un  (0x44) at code offset 27 = file 0x264.
//   ldc.i4.6 (0x1C) at code offset 40 = file 0x271.
//   ldc.i4.7 (0x1D) at code offset 41 = file 0x272.
//   ldc.i4.8 (0x1E) at code offset 43 = file 0x274.
// BSJB at 0x249 + 53 = 0x27E.
//
// ble.un branch offset: BLE_OK(20) - next(12) = 8 → LE32: 08 00 00 00
// blt.un branch offset: BLT_OK(40) - next(32) = 8 → LE32: 08 00 00 00

package Msil.SelfTestM74

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
  val outPath = "/tmp/lyric_msil_m74_ble_blt_un_ldc.dll"

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
  val lblBleOk = mbNewLabel(mbMain)
  val lblBltOk = mbNewLabel(mbMain)
  emitLdc_I4(mbMain, 42)           // offset  0: ldc.i4 42 (5B: 0x20 + 4 bytes) — full form
  emitLdc_I4_S(mbMain, 43)         // offset  5: push 43
  emitBle_Un(mbMain, lblBleOk)     // offset  7: ble.un → BLE_OK(20); next=12; offset=+8; 42<=43 → jump
  emitLdc_I4_S(mbMain, 0)          // offset 12: dead
  emitCall(mbMain, 0x0A000001)      // offset 14: dead
  emitRet(mbMain)                   // offset 19: dead
  // BLE_OK: offset 20
  mbMarkLabel(mbMain, lblBleOk)
  emitLdc_I4(mbMain, 42)           // offset 20: ldc.i4 42 (5B) — full form again
  emitLdc_I4_S(mbMain, 43)         // offset 25: push 43
  emitBlt_Un(mbMain, lblBltOk)     // offset 27: blt.un → BLT_OK(40); next=32; offset=+8; 42<43 → jump
  emitLdc_I4_S(mbMain, 0)          // offset 32: dead
  emitCall(mbMain, 0x0A000001)      // offset 34: dead
  emitRet(mbMain)                   // offset 39: dead
  // BLT_OK: offset 40
  mbMarkLabel(mbMain, lblBltOk)
  emitLdc_I4_6(mbMain)             // offset 40: push 6
  emitLdc_I4_7(mbMain)             // offset 41: push 7
  emitMul(mbMain)                   // offset 42: 6*7=42
  emitLdc_I4_8(mbMain)             // offset 43: push 8
  emitLdc_I4_8(mbMain)             // offset 44: push 8
  emitSub(mbMain)                   // offset 45: 8-8=0
  emitAdd(mbMain)                   // offset 46: 42+0=42
  emitCall(mbMain, 0x0A000001)      // offset 47: print 42
  emitRet(mbMain)                   // offset 52

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

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh)
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("tiny_hdr_ok", bs[0x248] == 0xD6)
  check("ldc_i4_ok",  bs[0x249] == 0x20)
  check("ble_un_ok",  bs[0x250] == 0x43)
  check("blt_un_ok",  bs[0x264] == 0x44)
  check("ldc_i4_6_ok", bs[0x271] == 0x1C)
  check("ldc_i4_7_ok", bs[0x272] == 0x1D)
  check("ldc_i4_8_ok", bs[0x274] == 0x1E)
  check("bsjb_ok",
    bs[0x27E] == 0x42 and bs[0x27F] == 0x53 and
    bs[0x280] == 0x4A and bs[0x281] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
