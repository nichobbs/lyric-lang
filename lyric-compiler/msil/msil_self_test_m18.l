//! msil_self_test_m18.l — Stage M18: ldc.r8 (64-bit float literals).
//!
//! Builds a PE whose Main() pushes 3.0 and 2.0 via ldc.r8, multiplies them
//! (result = 6.0), and calls Console.WriteLine(double).
//!
//! New opcode exercised:
//!   ldc.r8 (0x23) — 9-byte instruction: opcode + 8-byte IEEE 754 f64 LE
//!
//! New MemberRef: Console.WriteLine(double) — signature {0x00,0x01,0x01,0x0D}
//!   where 0x0D = ELEMENT_TYPE_R8.
//!
//! Code layout (25 bytes), code starting at 0x249 (tiny header at 0x248):
//!   offset  0  23 00 00 00 00 00 00 08 40  ldc.r8 3.0
//!              (3.0 = 0x4008000000000000 LE = 00 00 00 00 00 00 08 40)
//!   offset  9  23 00 00 00 00 00 00 00 40  ldc.r8 2.0
//!              (2.0 = 0x4000000000000000 LE = 00 00 00 00 00 00 00 40)
//!   offset 18  5A                           mul  (→ 6.0)
//!   offset 19  28 02 00 00 0A              call Console.WriteLine(double) [MemberRef[2]]
//!   offset 24  2A                           ret
//!
//! Tiny header: (25<<2)|2 = 102 = 0x66 at 0x248
//! Code at 0x249; BSJB at 0x262 (= 0x249 + 25)
//! CLR execution prints: "6"
package Msil.SelfTestM18

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
  val outPath = "/tmp/lyric_msil_m18_float.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
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

  // ── Build #GUID heap ──────────────────────────────────────────────────────
  val gh = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))

  // ── Build #US / #Blob heaps ───────────────────────────────────────────────
  val uh = newUsHeap()
  val bh = newBlobHeap()

  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(double) signature: DEFAULT, 1 param, void, R8 (0x0D)
  val wlDblW = bufNew()
  bufU1(wlDblW, 0x00)
  bufU1(wlDblW, 0x01)
  bufU1(wlDblW, 0x01)
  bufU1(wlDblW, 0x0D)
  val sigWriteLineDouble = internBlob(bh, "wl_dbl_sig", bufToList(wlDblW))

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
  //
  // Main(): Console.WriteLine(3.0 * 2.0)  →  "6"
  //
  val mbMain = newMethodBody()

  emitLdc_R8(mbMain, 3.0)
  emitLdc_R8(mbMain, 2.0)
  emitMul(mbMain)
  emitCall(mbMain, 0x0A000001)  // MemberRef[1] = Console.WriteLine(double)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
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

  // MemberRef[1]: Console.WriteLine(double)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineDouble))

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

  // ── Assemble PE ───────────────────────────────────────────────────────────
  val inp = AssemblerInput(
    entryPointToken = 0x06000001,
    methodBodies = bodies,
    tables = t,
    strings = sh,
    us = uh,
    blobs = bh,
    guids = gh,
    resourceData = newList()
  )

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header: (25<<2)|2 = 0x66
  check("tiny_hdr_ok", bs[0x248] == 0x66)

  // ldc.r8 opcode (0x23) at code offset 0 = file 0x249
  check("ldc_r8_op_ok", bs[0x249] == 0x23)

  // 3.0 = 0x4008000000000000 LE at 0x24A–0x251
  // bytes: 00 00 00 00 00 00 08 40
  check("ldc_r8_3_ok", bs[0x24A] == 0x00 and bs[0x24F] == 0x00 and bs[0x250] == 0x08 and bs[0x251] == 0x40)

  // mul (0x5A) at code offset 18 = file 0x25B
  check("mul_ok", bs[0x25B] == 0x5A)

  // BSJB at 0x262 (= 0x249 + 25)
  check("bsjb_ok", bs[0x262] == 0x42 and bs[0x263] == 0x53 and bs[0x264] == 0x4A and bs[0x265] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
