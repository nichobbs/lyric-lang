// msil_self_test_m5.l — Stage M5: local variable / fat method header test.
//
// Builds a single-method PE whose Main() uses a local string variable:
//
//   ldstr US[1]  "Hello from locals!"   → push string
//   stloc.0                              → store into local[0]
//   ldloc.0                              → reload
//   call Console.WriteLine(string)
//   ldloc.0                              → reload again
//   call Console.WriteLine(string)
//   ret
//
// Because localSig != 0, serializeMethodBody emits a fat header (12 bytes)
// instead of the 1-byte tiny header used by M2d–M4.
//
// Fat header layout at file offset 0x248:
//   [0x248] 0x13 0x30  — FatFormat | InitLocals, headerSize=3 DWORDs
//   [0x24A] 0x08 0x00  — maxStack = 8
//   [0x24C] 0x13 0x00 0x00 0x00  — codeSize = 19
//   [0x250] 0x01 0x00 0x00 0x11  — localSig token = 0x11000001 (StandAloneSig[1])
//
// CIL code starts at 0x254; BSJB metadata root at 0x267.
//
// The assembled PE is written to /tmp/lyric_msil_m5_hello.dll; the F# harness
// executes it and verifies "Hello from locals!" appears twice in stdout.

package Msil.SelfTestM5

import Msil.Assembler
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Msil.Kernel
import Std.Core
import Std.Collections
import Std.File

func check(label: in String, ok: in Bool): Unit {
  if ok { println(label + "=true") } else { println(label + "=false") }
}

func main(): Unit {
  val outPath = "/tmp/lyric_msil_m5_hello.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule     = internString(sh, "<Module>")
  val sHello      = internString(sh, "Hello")
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

  // ── Build #US heap ────────────────────────────────────────────────────────
  val uh    = newUsHeap()
  val usIdx = internUs(uh, "Hello from locals!")

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  // void () signature: DEFAULT, 0 params, void return
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

  // LocalVarSig for one string local:  LOCAL_SIG(0x07) | count(0x01) | ELEMENT_TYPE_STRING(0x0E)
  val localSigW = bufNew()
  bufU1(localSigW, 0x07)
  bufU1(localSigW, 0x01)
  bufU1(localSigW, 0x0E)
  val localSigBlob = internBlob(bh, "local_var_sig", bufToList(localSigW))

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

  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(
    flags = 0, typeName = sModule, typeNamespace = 0,
    extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(
    flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0,
    extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  // Build method body before adding MethodDef so we can pass the localSig token
  val mbMain = newMethodBody()
  emitLdstr(mbMain, 0x70000001)
  emitStloc_0(mbMain)
  emitLdloc_0(mbMain)
  emitCall(mbMain, 0x0A000001)
  emitLdloc_0(mbMain)
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

  // StandAloneSig[1]: the local variable signature for Main()
  val ssIdx    = addStandAloneSig(t, StandAloneSigRow(signature = localSigBlob))
  val localTok = standaloneToken(ssIdx)  // = 0x11000001
  mbSetLocalSig(mbMain, localTok)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)

  addMethodDef(t, MethodDefRow(
    rva       = rvas[0],
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name      = sMain,
    signature = sigVoid,
    paramList = 1))

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
    entryPointToken = 0x06000001,
    methodBodies    = bodies,
    tables          = t,
    strings         = sh,
    us              = uh,
    blobs           = bh,
    guids           = gh)

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  // DOS MZ
  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)

  // PE\0\0
  check("pe_sig_ok",
    bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)

  // CLR header cb=72
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)

  // EntryPointToken = 0x06000001 at 0x214
  check("entry_tok_ok",
    bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Fat header flags at 0x248: 0x13, 0x30
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)

  // codeSize = 19 at 0x24C
  check("code_size_ok", bs[0x24C] == 19 and bs[0x24D] == 0)

  // localSig token = 0x11000001 at 0x250 (LE: 01 00 00 11)
  check("local_sig_ok",
    bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // ldstr opcode at start of CIL (0x254)
  check("ldstr_ok", bs[0x254] == 0x72)

  // BSJB at 0x267 (0x248 + 31)
  check("bsjb_ok",
    bs[0x267] == 0x42 and bs[0x268] == 0x53 and
    bs[0x269] == 0x4A and bs[0x26A] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
