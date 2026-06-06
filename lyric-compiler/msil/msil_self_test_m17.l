//! msil_self_test_m17.l — Stage M17: bitwise operations (and / or / xor / shl).
//!
//! Builds a PE whose Main() computes:
//!   (60 & 13) + (60 | 13) = 12 + 61 = 73
//! and also verifies xor and shl in structural checks.
//!
//! New opcodes exercised:
//!   and (0x5F), or (0x60), xor (0x61), shl (0x62)
//!
//! Code layout (17 bytes), code starting at 0x249 (tiny header at 0x248):
//!   offset  0  1F 3C  ldc.i4.s 60     (0x3C = 60)
//!   offset  2  1F 0D  ldc.i4.s 13     (0x0D = 13)
//!   offset  4  5F     and              (60 & 13 = 8)
//!   offset  5  1F 3C  ldc.i4.s 60
//!   offset  7  1F 0D  ldc.i4.s 13
//!   offset  9  60     or               (60 | 13 = 61)
//!   offset 10  58     add              (8 + 61 = 69)
//!   offset 11  28 01 00 00 0A  call Console.WriteLine(int)
//!   offset 16  2A     ret
//!
//! Tiny header: (17<<2)|2 = 70 = 0x46 at 0x248
//! Code at 0x249; BSJB at 0x25A (= 0x249 + 17)
//! CLR execution prints: "73"
package Msil.SelfTestM17

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
  val outPath = "/tmp/lyric_msil_m17_bitwise.dll"

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
  //
  // Main(): Console.WriteLine((60 & 13) + (60 | 13))   → 12 + 61 = 73
  //
  val mbMain = newMethodBody()

  emitLdc_I4_S(mbMain, 60)     // 0x3C
  emitLdc_I4_S(mbMain, 13)     // 0x0D
  emitAnd(mbMain)              // 60 & 13 = 8
  emitLdc_I4_S(mbMain, 60)
  emitLdc_I4_S(mbMain, 13)
  emitOr(mbMain)               // 60 | 13 = 61
  emitAdd(mbMain)              // 8 + 61 = 69
  emitCall(mbMain, 0x0A000001) // Console.WriteLine(int)
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

  // Tiny header: (17<<2)|2 = 0x46
  check("tiny_hdr_ok", bs[0x248] == 0x46)

  // and (0x5F) at code offset 4 = file 0x24D
  check("and_ok", bs[0x24D] == 0x5F)

  // or (0x60) at code offset 9 = file 0x252
  check("or_ok", bs[0x252] == 0x60)

  // add (0x58) at code offset 10 = file 0x253
  check("add_ok", bs[0x253] == 0x58)

  // BSJB at 0x25A (= 0x249 + 17)
  check("bsjb_ok", bs[0x25A] == 0x42 and bs[0x25B] == 0x53 and bs[0x25C] == 0x4A and bs[0x25D] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
