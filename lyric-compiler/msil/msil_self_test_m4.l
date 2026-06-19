//! msil_self_test_m4.l — Stage M4: multi-method PE assembler self-test.
//!
//! Builds a two-method PE using Msil.Assembler:
//!   MethodDef[1] Greet() — ldstr "Hello from Greet!" + call Console.WriteLine + ret
//!   MethodDef[2] Main()  — call Greet + call Greet + ret
//!
//! Entry point is Main (token 0x06000002).  Method bodies are laid out
//! consecutively; RVAs are computed via methodBodyRvas().
//!
//! Layout invariants:
//!   Greet body (12 bytes) starts at file offset 0x248 (RVA 0x2048)
//!   Main  body (12 bytes) starts at file offset 0x254 (RVA 0x2054)
//!   Metadata (BSJB root) starts at file offset 0x260 (RVA 0x2060)
//!
//! The assembled PE is also written to /tmp/lyric_msil_m4_hello.dll and the
//! F# harness runs it with `dotnet exec`, expecting:
//!   "Hello from Greet!\nHello from Greet!\n"
package Msil.SelfTestM4

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Msil.Kernel
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
  val outPath = "/tmp/lyric_msil_m4_hello.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sGreet = internString(sh, "Greet")
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

  // ── Build #US heap ────────────────────────────────────────────────────────
  val uh = newUsHeap()
  val _ = internUs(uh, "Hello from Greet!")

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  // Shared void() signature: DEFAULT cc, 0 params, void return
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(string) signature: DEFAULT, 1 param, void return, string param
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x0E)
  val sigWriteLine = internBlob(bh, "wl_sig", bufToList(wlSigW))

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

  // ── Build method bodies (before tables, to compute RVAs) ─────────────────

  // Greet(): ldstr US[1] + call MemberRef[1] + ret
  val mbGreet = newMethodBody()
  emitLdstr(mbGreet, 0x70000001)
  emitCall(mbGreet, 0x0A000001)
  emitRet(mbGreet)

  // Main(): call MethodDef[1] (Greet) twice + ret
  val mbMain = newMethodBody()
  emitCall(mbMain, 0x06000001)
  emitCall(mbMain, 0x06000001)
  emitRet(mbMain)

  // Compute RVAs from body sizes
  val bodies: List[MethodBody] = newList()
  bodies.add(mbGreet)
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaGreet = rvas[0]
  val rvaMain = rvas[1]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console (in System.Console assembly = AssemblyRef[2])
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (in System.Runtime assembly = AssemblyRef[1])
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module> (no methods — methodList matches TypeDef[2].methodList)
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  // TypeDef[2]: Hello (owns all methods: MethodDef[1..2])
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

  // MethodDef[1]: Greet
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaGreet,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = sGreet,
      signature = sigVoid,
      paramList = 1
    )
  )

  // MethodDef[2]: Main (entry point)
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

  // MemberRef[1]: Console.WriteLine(string) via TypeRef[1]
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLine))

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
    entryPointToken = 0x06000002,
    // Main = MethodDef[2]
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
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0 and bs[0x202] == 0 and bs[0x203] == 0)

  // EntryPointToken = 0x06000002 (Main) at 0x214
  check("entry_tok_ok", bs[0x214] == 0x02 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Greet tiny header 0x2E at file offset 0x248 (RVA 0x2048)
  check("greet_hdr_ok", bs[0x248] == 0x2E)

  // Greet starts with ldstr opcode (0x72) at 0x249
  check("greet_ldstr_ok", bs[0x249] == 0x72)

  // Main tiny header 0x2E at file offset 0x254 (RVA 0x2054 = 0x2048+12)
  check("main_hdr_ok", bs[0x254] == 0x2E)

  // Main starts with call opcode (0x28) at 0x255
  check("main_call_ok", bs[0x255] == 0x28)

  // BSJB magic at metadata root (file offset 0x260 = 0x200 + 0x60)
  check("bsjb_ok", bs[0x260] == 0x42 and bs[0x261] == 0x53 and bs[0x262] == 0x4A and bs[0x263] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
