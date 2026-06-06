//! msil_self_test_m7.l — Stage M7: static fields (ldsfld / stsfld).
//!
//! Builds a PE with a single static int32 field `s_val` on class `Hello` and
//! a `Main()` that stores 42 into the field then reads it back and prints it.
//!
//!   CIL for Main():
//!     ldc.i4.s 42           — push 42
//!     stsfld  0x04000001    — store into Field[1] (s_val)
//!     ldsfld  0x04000001    — reload
//!     call    0x0A000001    — Console.WriteLine(int)
//!     ret
//!
//! Layout (FIRST_METHOD_RVA = 0x2048 → file offset 0x248):
//!   Main body (19 bytes: 1-byte tiny header + 18-byte code) at file 0x248
//!   Metadata BSJB root at file 0x25B (= 0x248 + 19)
//!
//! Main body:
//!   [0x248] 0x4A — tiny header (codeSize=18; (18<<2)|2 = 0x4A)
//!   [0x249] 0x1F — ldc.i4.s
//!   [0x24A] 0x2A — 42
//!   [0x24B] 0x80 — stsfld
//!   [0x24C..0x24F] 01 00 00 04  (Field token 0x04000001 LE)
//!   [0x250] 0x7E — ldsfld
//!   [0x251..0x254] 01 00 00 04  (Field token 0x04000001 LE)
//!   [0x255] 0x28 — call
//!   [0x256..0x259] 01 00 00 0A  (MemberRef token 0x0A000001 LE)
//!   [0x25A] 0x2A — ret
//!
//! CLR execution prints: "42"
package Msil.SelfTestM7

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
  val outPath = "/tmp/lyric_msil_m7_fields.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sSVal = internString(sh, "s_val")
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

  // ── Build #US heap (empty — no string literals) ───────────────────────────
  val uh = newUsHeap()

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  // void () signature
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int) signature: DEFAULT, 1 param, void return, I4
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // FieldSig for int32: FIELD marker (0x06) + ELEMENT_TYPE_I4 (0x08)
  val fieldSigW = bufNew()
  bufU1(fieldSigW, 0x06)
  bufU1(fieldSigW, 0x08)
  val sigField = internBlob(bh, "field_sig", bufToList(fieldSigW))

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

  // Main(): ldc.i4.s 42, stsfld Field[1], ldsfld Field[1], call Console.WriteLine(int), ret
  val mbMain = newMethodBody()
  emitLdc_I4_S(mbMain, 42)
  emitStsfld(mbMain, 0x04000001)  // Field[1] = s_val
  emitLdsfld(mbMain, 0x04000001)  // Field[1] = s_val
  emitCall(mbMain, 0x0A000001)  // MemberRef[1] = Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console (in System.Console.dll = AssemblyRef[2])
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (in System.Runtime.dll = AssemblyRef[1])
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module> — no fields, no methods
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  // TypeDef[2]: Hello — owns Field[1] (s_val) and MethodDef[1] (Main)
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

  // Field[1]: Hello.s_val — public static int32
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_STATIC, name = sSVal, signature = sigField))

  // MethodDef[1]: Main (entry point)
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

  // AssemblyRef[1]: System.Runtime (hosts System.Object)
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

  // AssemblyRef[2]: System.Console (hosts System.Console)
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
    // Main = MethodDef[1]
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

  // DOS MZ magic
  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)

  // PE\0\0 signature at 0x80
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)

  // CLR header cb=72 at 0x200
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)

  // EntryPointToken = 0x06000001 (Main) at 0x214
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Main tiny header 0x4A at 0x248 (codeSize=18)
  check("main_hdr_ok", bs[0x248] == 0x4A)

  // ldc.i4.s (0x1F) at 0x249, value 42 (0x2A) at 0x24A
  check("ldc42_ok", bs[0x249] == 0x1F and bs[0x24A] == 0x2A)

  // stsfld (0x80) at 0x24B; token LE: first byte 0x01 at 0x24C, table byte 0x04 at 0x24F
  check("stsfld_ok", bs[0x24B] == 0x80 and bs[0x24C] == 0x01 and bs[0x24F] == 0x04)

  // ldsfld (0x7E) at 0x250; token LE: first byte 0x01 at 0x251, table byte 0x04 at 0x254
  check("ldsfld_ok", bs[0x250] == 0x7E and bs[0x251] == 0x01 and bs[0x254] == 0x04)

  // BSJB magic at 0x25B
  check("bsjb_ok", bs[0x25B] == 0x42 and bs[0x25C] == 0x53 and bs[0x25D] == 0x4A and bs[0x25E] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
