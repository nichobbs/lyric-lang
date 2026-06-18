//! msil_self_test_m38.l — Stage M38: add.ovf + sub.ovf + mul.ovf.
//!
//! Builds a PE that exercises the three overflow-checked arithmetic opcodes:
//!   1. ldc.i4.s 21 / ldc.i4.s 21 / add.ovf  → 42
//!   2. ldc.i4.s 43 / ldc.i4.1    / sub.ovf  → 42
//!   3. ldc.i4.s 21 / ldc.i4.s 2  / mul.ovf  → 42
//! Each result is printed, producing three lines of "42".
//!
//! New instructions exercised:
//!   add.ovf  (0xD6) — overflow-checked add (throws OverflowException on overflow)
//!   sub.ovf  (0xDA) — overflow-checked subtract
//!   mul.ovf  (0xD8) — overflow-checked multiply
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//!
//! MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//!
//! Code layout (tiny header at 0x248, code at 0x249):
//!   offset  0  1F 15  ldc.i4.s 21  [2]
//!   offset  2  1F 15  ldc.i4.s 21  [2]
//!   offset  4  D6     add.ovf      [1]
//!   offset  5  28 01 00 00 0A  call WriteLineInt [5]
//!   offset 10  1F 2B  ldc.i4.s 43  [2]
//!   offset 12  17     ldc.i4.1     [1]
//!   offset 13  DA     sub.ovf      [1]
//!   offset 14  28 01 00 00 0A  call WriteLineInt [5]
//!   offset 19  1F 15  ldc.i4.s 21  [2]
//!   offset 21  1F 02  ldc.i4.s 2   [2]
//!   offset 23  D8     mul.ovf      [1]
//!   offset 24  28 01 00 00 0A  call WriteLineInt [5]
//!   offset 29  2A     ret          [1]
//!
//! codeSize = 30. Tiny header = (30<<2)|2 = 122 = 0x7A.
//!
//! BSJB at 0x248 + 1 + 30 = 0x267.
//!
//! CLR: add.ovf(21+21)=42, sub.ovf(43-1)=42, mul.ovf(21*2)=42 → prints "42\n42\n42".
package Msil.SelfTestM38

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Std.Core
import Std.Collections
import Std.File

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=false")
  }
}

func main(): Unit {
  val outPath = "/tmp/lyric_msil_m38_ovf.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")

  val gh = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  val bh = newBlobHeap()

  // void () sig for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4(0x08)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0)
  bufU1(keyW, 0x3F)
  bufU1(keyW, 0x5F)
  bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11)
  bufU1(keyW, 0xD5)
  bufU1(keyW, 0x0A)
  bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  // add.ovf: 21 + 21 = 42
  emitLdc_I4_S(mbMain, 21)
  emitLdc_I4_S(mbMain, 21)
  emitAdd_Ovf(mbMain)
  emitCall(mbMain, 0x0A000001)

  // sub.ovf: 43 - 1 = 42
  emitLdc_I4_S(mbMain, 43)
  emitLdc_I4_1(mbMain)
  emitSub_Ovf(mbMain)
  emitCall(mbMain, 0x0A000001)

  // mul.ovf: 21 * 2 = 42
  emitLdc_I4_S(mbMain, 21)
  emitLdc_I4_S(mbMain, 2)
  emitMul_Ovf(mbMain)
  emitCall(mbMain, 0x0A000001)

  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (Hello extends)
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sHello,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 1
    )
  )

  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaMain,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = sMain,
      signature = sigVoid,
      paramList = 1
    )
  )

  // MemberRef[1]: Console.WriteLine(int)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))

  addAssembly(
    t,
    AssemblyRow(
      hashAlgId = HASH_ALG_SHA1,
      majorVersion = 0,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = ASF_NONE,
      publicKey = 0,
      name = sHello,
      culture = 0
    )
  )
  addAssemblyRef(
    t,
    AssemblyRefRow(
      majorVersion = 10,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = keyToken,
      name = sRuntime,
      culture = 0,
      hashValue = 0
    )
  )
  addAssemblyRef(
    t,
    AssemblyRefRow(
      majorVersion = 10,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = keyToken,
      name = sConsoleAsm,
      culture = 0,
      hashValue = 0
    )
  )

  val inp = AssemblerInput(
    entryPointToken = 0x06000001,
    methodBodies = bodies,
    tables = t,
    strings = sh,
    us = uh,
    blobs = bh,
    guids = gh,
    resourceData = newList(),
    buildKind = "lib"
  )
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header at 0x248: (30<<2)|2 = 122 = 0x7A
  check("tiny_hdr_ok", bs[0x248] == 0x7A)

  // add.ovf (0xD6) at code offset 4 = file 0x24D
  check("add_ovf_ok", bs[0x24D] == 0xD6)

  // sub.ovf (0xDA) at code offset 13 = file 0x256
  check("sub_ovf_ok", bs[0x256] == 0xDA)

  // mul.ovf (0xD8) at code offset 23 = file 0x260
  check("mul_ovf_ok", bs[0x260] == 0xD8)

  // BSJB at 0x248 + 1 + 30 = 0x267
  check("bsjb_ok", bs[0x267] == 0x42 and bs[0x268] == 0x53 and bs[0x269] == 0x4A and bs[0x26A] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
