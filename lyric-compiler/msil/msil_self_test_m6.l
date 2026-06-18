// msil_self_test_m6.l — Stage M6: method arguments and non-void return values.
//
// Builds a two-method PE:
//   MethodDef[1] Add(int a, int b): int — ldarg.0, ldarg.1, add, ret (4 bytes CIL)
//   MethodDef[2] Main()             — ldc.i4.3, ldc.i4.4, call Add, call Console.WriteLine(int), ret (13 bytes)
//
// Add is a static int32-returning method with two int32 parameters.
// Main pushes 3 and 4, calls Add, and passes the result (7) to Console.WriteLine(int).
//
// Layout (FIRST_METHOD_RVA = 0x2048 → file offset 0x248):
//   Add  body (5 bytes:  1-byte tiny header + 4-byte code) starts at file 0x248
//   Main body (14 bytes: 1-byte tiny header + 13-byte code) starts at file 0x24D
//   Metadata BSJB root starts at file 0x25B
//
// Add body:
//   [0x248] 0x12 — tiny header (codeSize = 4; (4<<2)|2 = 0x12)
//   [0x249] 0x02 — ldarg.0
//   [0x24A] 0x03 — ldarg.1
//   [0x24B] 0x58 — add
//   [0x24C] 0x2A — ret
//
// Main body:
//   [0x24D] 0x36 — tiny header (codeSize = 13; (13<<2)|2 = 0x36)
//   [0x24E] 0x19 — ldc.i4.3
//   [0x24F] 0x1A — ldc.i4.4
//   [0x250] 0x28 — call
//   [0x251..0x254] 01 00 00 06  (MethodDef token 0x06000001 = Add, LE)
//   [0x255] 0x28 — call
//   [0x256..0x259] 01 00 00 0A  (MemberRef token 0x0A000001 = Console.WriteLine(int), LE)
//   [0x25A] 0x2A — ret
//
// CLR execution prints: "7"

package Msil.SelfTestM6

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
  val outPath = "/tmp/lyric_msil_m6_add.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule     = internString(sh, "<Module>")
  val sHello      = internString(sh, "Hello")
  val sAdd        = internString(sh, "Add")
  val sMain       = internString(sh, "Main")
  val sSystem     = internString(sh, "System")
  val sConsole    = internString(sh, "Console")
  val sRuntime    = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject     = internString(sh, "Object")
  val sWriteLine  = internString(sh, "WriteLine")

  // ── Build #GUID heap ──────────────────────────────────────────────────────
  val gh    = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
  val mvid = appendGuid(gh, bufToList(guidW))

  // ── Build #US heap (empty — no string literals) ───────────────────────────
  val uh = newUsHeap()

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  // Add(int, int): int — DEFAULT, 2 params, I4 return, I4, I4
  val addSigW = bufNew()
  bufU1(addSigW, 0x00)
  bufU1(addSigW, 0x02)
  bufU1(addSigW, 0x08)
  bufU1(addSigW, 0x08)
  bufU1(addSigW, 0x08)
  val sigAdd = internBlob(bh, "add_sig", bufToList(addSigW))

  // void () — DEFAULT, 0 params, void return
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int) — DEFAULT, 1 param, void return, I4
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

  // Add(int a, int b): int — ldarg.0, ldarg.1, add, ret
  val mbAdd = newMethodBody()
  emitLdarg_0(mbAdd)
  emitLdarg_1(mbAdd)
  emitAdd(mbAdd)
  emitRet(mbAdd)

  // Main() — ldc.i4.3, ldc.i4.4, call Add, call Console.WriteLine(int), ret
  val mbMain = newMethodBody()
  emitLdc_I4_3(mbMain)
  emitLdc_I4_4(mbMain)
  emitCall(mbMain, 0x06000001)   // MethodDef[1] = Add
  emitCall(mbMain, 0x0A000001)   // MemberRef[1] = Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbAdd)
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaAdd  = rvas[0]
  val rvaMain = rvas[1]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(
    generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console (in System.Console.dll = AssemblyRef[2])
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (in System.Runtime.dll = AssemblyRef[1])
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module>
  addTypeDef(t, TypeDefRow(
    flags = 0, typeName = sModule, typeNamespace = 0,
    extends = 0, fieldList = 1, methodList = 1))
  // TypeDef[2]: Hello (owns MethodDef[1..2])
  addTypeDef(t, TypeDefRow(
    flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0,
    extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  // MethodDef[1]: Add
  addMethodDef(t, MethodDefRow(
    rva       = rvaAdd,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name      = sAdd,
    signature = sigAdd,
    paramList = 1))

  // MethodDef[2]: Main (entry point)
  addMethodDef(t, MethodDefRow(
    rva       = rvaMain,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name      = sMain,
    signature = sigVoid,
    paramList = 1))

  // MemberRef[1]: Console.WriteLine(int)
  addMemberRef(t, MemberRefRow(
    class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))

  addAssembly(t, AssemblyRow(
    hashAlgId      = HASH_ALG_SHA1,
    majorVersion   = 0,
    minorVersion   = 0,
    buildNumber    = 0,
    revisionNumber = 0,
    flags          = ASF_NONE,
    publicKey      = 0,
    name           = sHello,
    culture        = 0))

  // AssemblyRef[1]: System.Runtime (hosts System.Object)
  addAssemblyRef(t, AssemblyRefRow(
    majorVersion   = 10,
    minorVersion   = 0,
    buildNumber    = 0,
    revisionNumber = 0,
    flags          = 0,
    publicKeyToken = keyToken,
    name           = sRuntime,
    culture        = 0,
    hashValue      = 0))

  // AssemblyRef[2]: System.Console (hosts System.Console)
  addAssemblyRef(t, AssemblyRefRow(
    majorVersion   = 10,
    minorVersion   = 0,
    buildNumber    = 0,
    revisionNumber = 0,
    flags          = 0,
    publicKeyToken = keyToken,
    name           = sConsoleAsm,
    culture        = 0,
    hashValue      = 0))

  // ── Assemble PE ───────────────────────────────────────────────────────────
  val inp = AssemblerInput(
    entryPointToken = 0x06000002,   // Main = MethodDef[2]
    methodBodies    = bodies,
    tables          = t,
    strings         = sh,
    us              = uh,
    blobs           = bh,
    guids           = gh, resourceData = newList(), buildKind = "lib")

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  // DOS MZ magic
  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)

  // PE\0\0 signature at 0x80
  check("pe_sig_ok",
    bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)

  // CLR header cb=72 at 0x200
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)

  // EntryPointToken = 0x06000002 (Main) at 0x214
  check("entry_tok_ok",
    bs[0x214] == 0x02 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Add tiny header 0x12 at 0x248
  check("add_hdr_ok", bs[0x248] == 0x12)

  // Add: ldarg.0 (0x02) at 0x249, ldarg.1 (0x03) at 0x24A, add (0x58) at 0x24B
  check("add_ldarg0_ok", bs[0x249] == 0x02)
  check("add_ldarg1_ok", bs[0x24A] == 0x03)
  check("add_add_ok",    bs[0x24B] == 0x58)

  // Main tiny header 0x36 at 0x24D
  check("main_hdr_ok", bs[0x24D] == 0x36)

  // Main: ldc.i4.3 (0x19) at 0x24E, ldc.i4.4 (0x1A) at 0x24F, call (0x28) at 0x250
  check("main_ldc3_ok", bs[0x24E] == 0x19)
  check("main_ldc4_ok", bs[0x24F] == 0x1A)
  check("main_call_ok", bs[0x250] == 0x28)

  // BSJB magic at 0x25B
  check("bsjb_ok",
    bs[0x25B] == 0x42 and bs[0x25C] == 0x53 and
    bs[0x25D] == 0x4A and bs[0x25E] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
