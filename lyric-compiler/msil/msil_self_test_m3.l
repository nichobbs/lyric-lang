// msil_self_test_m3.l — Stage M3: end-to-end PE execution test.
//
// Builds a Hello-World PE using Msil.Assembler, writes it to
// /tmp/lyric_msil_m3_hello.dll via Std.File.writeBytes, then prints
// "wrote_pe=true".  The F# harness runs the produced binary with
// `dotnet exec` and verifies the output contains "Hello, World!".
//
// Assembly-reference layout (two refs required on .NET 5+):
//   AssemblyRef[1] = System.Runtime   (for System.Object base class)
//   AssemblyRef[2] = System.Console   (for System.Console.WriteLine)
// In .NET 5+, System.Console is its own assembly; System.Runtime no
// longer has a type-forwarder for it.

package Msil.SelfTestM3

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Msil.Kernel
import Std.Core
import Std.Collections
import Std.File

func main(): Unit {
  val outPath = "/tmp/lyric_msil_m3_hello.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule      = internString(sh, "<Module>")
  // Test-unique type + assembly name so a stale `/tmp/hello.dll` from
  // an unrelated experiment can't collide on `Hello.Main` during JIT
  // resolution (#870).  The string literal "Hello, World!" is the
  // ldstr payload below, not affected by this rename.
  val sHello       = internString(sh, "LyricM3Hello")
  val sMain        = internString(sh, "Main")
  val sSystem      = internString(sh, "System")
  val sConsole     = internString(sh, "Console")
  val sRuntime     = internString(sh, "System.Runtime")
  val sConsoleAsm  = internString(sh, "System.Console")
  val sObject      = internString(sh, "Object")
  val sWriteLine   = internString(sh, "WriteLine")

  // ── Build #GUID heap ──────────────────────────────────────────────────────
  val gh    = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
  val mvid = appendGuid(gh, bufToList(guidW))

  // ── Build #US heap ────────────────────────────────────────────────────────
  val uh    = newUsHeap()
  val _ = internUs(uh, "Hello, World!")

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  val mainSigW = bufNew()
  bufU1(mainSigW, 0x00)
  bufU1(mainSigW, 0x00)
  bufU1(mainSigW, 0x01)
  val sigMain = internBlob(bh, "main_sig", bufToList(mainSigW))

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

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(
    generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console in System.Console assembly (ref 2)
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object in System.Runtime assembly (ref 1)
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(
    flags = 0, typeName = sModule, typeNamespace = 0,
    extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(
    flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0,
    extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  addMethodDef(t, MethodDefRow(
    rva       = FIRST_METHOD_RVA,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name      = sMain,
    signature = sigMain,
    paramList = 1))

  // MemberRef[1]: Console.WriteLine(string) — resolved via TypeRef[1]
  addMemberRef(t, MemberRefRow(
    class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLine))

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

  // ── Build method body ─────────────────────────────────────────────────────
  val mb = newMethodBody()
  emitLdstr(mb, 0x70000001)
  emitCall(mb, 0x0A000001)
  emitRet(mb)

  // ── Assemble PE ───────────────────────────────────────────────────────────
  val bodies: List[MethodBody] = newList()
  bodies.add(mb)
  val inp = AssemblerInput(
    entryPointToken = 0x06000001,
    methodBodies    = bodies,
    tables          = t,
    strings         = sh,
    us              = uh,
    blobs           = bh,
    guids           = gh)

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
