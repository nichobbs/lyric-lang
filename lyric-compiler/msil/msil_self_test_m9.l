//! msil_self_test_m9.l — Stage M9: multiple TypeDefs in one PE.
//!
//! Builds a PE with three classes in a single assembly:
//!   TypeDef[2] Foo   — static GetFoo(): int  → returns 10
//!   TypeDef[3] Bar   — static GetBar(): int  → returns 20
//!   TypeDef[4] Hello — static Main(): void   → calls GetFoo + GetBar, prints 30
//!
//! This verifies that TypeDef.methodList correctly partitions MethodDef rows
//! across multiple TypeDefs, which is a prerequisite for emitting Lyric records
//! and module functions as separate .NET types.
//!
//! TypeDef / MethodDef layout:
//!   TypeDef[1] <Module> — methodList=1 (owns none: range [1,0])
//!   TypeDef[2] Foo      — methodList=1 (owns MethodDef[1]: range [1,1])
//!   TypeDef[3] Bar      — methodList=2 (owns MethodDef[2]: range [2,2])
//!   TypeDef[4] Hello    — methodList=3 (owns MethodDef[3]: range [3,end])
//!
//! CIL for Foo.GetFoo():
//!   ldc.i4.s 10  → 2 bytes; ret → 1 byte; tiny header (3<<2)|2 = 0x0E; total 4 bytes
//!
//! CIL for Bar.GetBar():
//!   ldc.i4.s 20  → 2 bytes; ret → 1 byte; tiny header 0x0E; total 4 bytes
//!
//! CIL for Hello.Main():
//!   call GetFoo, call GetBar, add, call Console.WriteLine(int), ret
//!   = 5+5+1+5+1 = 17 bytes; tiny header (17<<2)|2 = 0x46; total 18 bytes
//!
//! Layout (FIRST_METHOD_RVA = 0x2048 → file offset 0x248):
//!   GetFoo body (4 bytes) at file 0x248
//!   GetBar body (4 bytes) at file 0x24C
//!   Main   body (18 bytes) at file 0x250
//!   Metadata BSJB root at file 0x262 (= 0x248 + 4 + 4 + 18)
//!
//! CLR execution prints: "30"
package Msil.SelfTestM9

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
  val outPath = "/tmp/lyric_msil_m9_multitypedef.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sFoo = internString(sh, "Foo")
  val sBar = internString(sh, "Bar")
  val sHello = internString(sh, "Hello")
  val sGetFoo = internString(sh, "GetFoo")
  val sGetBar = internString(sh, "GetBar")
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

  // int () signature: DEFAULT, 0 params, I4 return
  val intSigW = bufNew()
  bufU1(intSigW, 0x00)
  bufU1(intSigW, 0x00)
  bufU1(intSigW, 0x08)
  val sigInt = internBlob(bh, "int_sig", bufToList(intSigW))

  // void () signature: DEFAULT, 0 params, void return
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

  // ── Build method bodies ───────────────────────────────────────────────────

  // Foo.GetFoo(): ldc.i4.s 10, ret  (3 bytes CIL → tiny header 0x0E)
  val mbGetFoo = newMethodBody()
  emitLdc_I4_S(mbGetFoo, 10)
  emitRet(mbGetFoo)

  // Bar.GetBar(): ldc.i4.s 20, ret  (3 bytes CIL → tiny header 0x0E)
  val mbGetBar = newMethodBody()
  emitLdc_I4_S(mbGetBar, 20)
  emitRet(mbGetBar)

  // Hello.Main(): call GetFoo, call GetBar, add, call Console.WriteLine(int), ret
  val mbMain = newMethodBody()
  emitCall(mbMain, 0x06000001)  // MethodDef[1] = GetFoo
  emitCall(mbMain, 0x06000002)  // MethodDef[2] = GetBar
  emitAdd(mbMain)
  emitCall(mbMain, 0x0A000001)  // MemberRef[1] = Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbGetFoo)
  bodies.add(mbGetBar)
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaGetFoo = rvas[0]
  val rvaGetBar = rvas[1]
  val rvaMain = rvas[2]

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
  // TypeDef[2]: Foo — no fields, owns MethodDef[1] (methodList=1, next is 2)
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sFoo,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 1
    )
  )
  // TypeDef[3]: Bar — no fields, owns MethodDef[2] (methodList=2, next is 3)
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sBar,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 2
    )
  )
  // TypeDef[4]: Hello — no fields, owns MethodDef[3] (methodList=3, owns to end)
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sHello,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 3
    )
  )

  // MethodDef[1]: Foo.GetFoo() — returns int
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaGetFoo,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = sGetFoo,
      signature = sigInt,
      paramList = 1
    )
  )

  // MethodDef[2]: Bar.GetBar() — returns int
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaGetBar,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = sGetBar,
      signature = sigInt,
      paramList = 1
    )
  )

  // MethodDef[3]: Hello.Main() — entry point
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
    entryPointToken = 0x06000003,
    // Main = MethodDef[3]
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

  // EntryPointToken = 0x06000003 (Main) at 0x214
  check("entry_tok_ok", bs[0x214] == 0x03 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Foo.GetFoo tiny header 0x0E at 0x248 (codeSize=3)
  check("foo_hdr_ok", bs[0x248] == 0x0E)

  // GetFoo: ldc.i4.s (0x1F) at 0x249, value 10 (0x0A) at 0x24A
  check("foo_ldc_ok", bs[0x249] == 0x1F and bs[0x24A] == 0x0A)

  // Bar.GetBar tiny header 0x0E at 0x24C (codeSize=3)
  check("bar_hdr_ok", bs[0x24C] == 0x0E)

  // GetBar: ldc.i4.s (0x1F) at 0x24D, value 20 (0x14) at 0x24E
  check("bar_ldc_ok", bs[0x24D] == 0x1F and bs[0x24E] == 0x14)

  // Main tiny header 0x46 at 0x250 (codeSize=17)
  check("main_hdr_ok", bs[0x250] == 0x46)

  // Main: first call (0x28) at 0x251, token first byte 0x01 at 0x252, table 0x06 at 0x255
  check("main_call1_ok", bs[0x251] == 0x28 and bs[0x252] == 0x01 and bs[0x255] == 0x06)

  // Main: add (0x58) at 0x25B
  check("main_add_ok", bs[0x25B] == 0x58)

  // BSJB magic at 0x262
  check("bsjb_ok", bs[0x262] == 0x42 and bs[0x263] == 0x53 and bs[0x264] == 0x4A and bs[0x265] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
