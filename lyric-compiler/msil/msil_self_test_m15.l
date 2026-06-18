//! msil_self_test_m15.l — Stage M15: ldc.i8 + conv.i4 (64-bit literals).
//!
//! Builds a PE whose Main() pushes 1000000000L and 2L via ldc.i8, multiplies
//! them (result = 2000000000L), narrows to int32 via conv.i4, and prints it.
//!
//! New opcodes exercised:
//!   ldc.i8 (0x21) — 9-byte instruction: opcode + 8-byte LE constant
//!   conv.i4 (0x69) — 1-byte widening/narrowing conversion
//!
//! Code (26 bytes) starting at 0x249 (tiny header at 0x248):
//!   offset  0  21 00 CA 9A 3B 00 00 00 00  ldc.i8 1000000000L
//!   offset  9  21 02 00 00 00 00 00 00 00  ldc.i8 2L
//!   offset 18  5A                           mul     (→ 2000000000L)
//!   offset 19  69                           conv.i4 (→ 2000000000i32)
//!   offset 20  28 01 00 00 0A              call Console.WriteLine(int)
//!   offset 25  2A                           ret
//!
//! Tiny header: (26<<2)|2 = 106 = 0x6A at 0x248
//! Code at 0x249; BSJB at 0x263 (= 0x249 + 26)
//! CLR execution prints: "2000000000"
package Msil.SelfTestM15

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
  val outPath = "/tmp/lyric_msil_m15_i64.dll"

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

  // void () signature: DEFAULT, 0 params, void return
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int) signature: DEFAULT, 1 param, void, I4
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // Microsoft framework assemblies public key token: b03f5f7f11d50a3a
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
  // Main(): Console.WriteLine((int)(1000000000L * 2L))
  //
  val mbMain = newMethodBody()

  emitLdc_I8(mbMain, 1000000000i64)  // push 1000000000 as int64
  emitLdc_I8(mbMain, 2i64)          // push 2 as int64
  emitMul(mbMain)                   // 2000000000L
  emitConv_I4(mbMain)               // narrow to int32 (2000000000 < 2^31)
  emitCall(mbMain, 0x0A000001)      // call Console.WriteLine(int)
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
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module>
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  // TypeDef[2]: Hello
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

  // MethodDef[1]: Hello.Main — STATIC entry point
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

  // AssemblyRef[1]: System.Runtime
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

  // AssemblyRef[2]: System.Console
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

  // Tiny header at 0x248: (26<<2)|2 = 0x6A
  check("tiny_hdr_ok", bs[0x248] == 0x6A)

  // ldc.i8 opcode (0x21) at 0x249; 1000000000 = 0x3B9ACA00 LE
  // LE: 00 CA 9A 3B 00 00 00 00
  check(
    "ldc_i8_ok",
    bs[0x249] == 0x21 and bs[0x24A] == 0x00 and bs[0x24B] == 0xCA and bs[0x24C] == 0x9A and bs[0x24D] == 0x3B and
      bs[0x24E] == 0x00 and
      bs[0x24F] == 0x00 and
      bs[0x250] == 0x00 and
      bs[0x251] == 0x00
  )

  // mul (0x5A) at code offset 18 = file 0x25B
  check("mul_ok", bs[0x25B] == 0x5A)

  // conv.i4 (0x69) at code offset 19 = file 0x25C
  check("conv_i4_ok", bs[0x25C] == 0x69)

  // BSJB at 0x263 (= 0x249 + 26)
  check("bsjb_ok", bs[0x263] == 0x42 and bs[0x264] == 0x53 and bs[0x265] == 0x4A and bs[0x266] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
