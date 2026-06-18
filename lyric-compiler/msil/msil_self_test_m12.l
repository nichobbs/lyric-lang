// msil_self_test_m12.l — Stage M12: conditional branch (brfalse / br / cgt).
//
// Builds a single-method PE whose Main() computes `if 7 > 4 { 1 } else { 0 }`
// using cgt + brfalse + br + label resolution, then prints the result with
// Console.WriteLine(int).  CLR execution prints "1".
//
// Body layout (codeSize = 22 bytes, tiny header 0x5A):
//   offset  0  1D         ldc.i4.7
//   offset  1  1A         ldc.i4.4
//   offset  2  FE 02      cgt
//   offset  4  39 06 00 00 00  brfalse else_lbl  (relative +6, targets offset 15)
//   offset  9  17         ldc.i4.1
//   offset 10  38 01 00 00 00  br end_lbl        (relative +1, targets offset 16)
//   [else_lbl = offset 15]
//   offset 15  16         ldc.i4.0
//   [end_lbl = offset 16]
//   offset 16  28 01 00 00 0A  call MemberRef[1] (Console.WriteLine(int))
//   offset 21  2A         ret
//
// File layout:
//   0x248  5A          Main tiny header (codeSize=22)
//   0x249  1D 1A       ldc.i4.7, ldc.i4.4
//   0x24B  FE 02       cgt
//   0x24D  39 06 00 00 00  brfalse (offset +6)
//   0x252  17          ldc.i4.1
//   0x253  38 01 00 00 00  br (offset +1)
//   0x258  16          ldc.i4.0
//   0x259  28 01 00 00 0A  call Console.WriteLine(int)
//   0x25E  2A          ret
//   0x25F  BSJB metadata root

package Msil.SelfTestM12

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
  val outPath = "/tmp/lyric_msil_m12_branch.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
  val sSystem  = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject  = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")

  // ── Build #GUID heap ──────────────────────────────────────────────────────
  val gh    = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
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
  // Main(): if 7 > 4 { Console.WriteLine(1) } else { Console.WriteLine(0) }
  //
  val mbMain = newMethodBody()

  val elseLbl = mbNewLabel(mbMain)
  val endLbl  = mbNewLabel(mbMain)

  emitLdc_I4_7(mbMain)                  // push 7
  emitLdc_I4_4(mbMain)                  // push 4
  emitCgt(mbMain)                       // compare: 7 > 4 → 1
  emitBrfalse(mbMain, elseLbl)          // if 0 (false) → else
  emitLdc_I4_1(mbMain)                  // true branch: push 1
  emitBr(mbMain, endLbl)                // jump to end
  mbMarkLabel(mbMain, elseLbl)          // else:
  emitLdc_I4_0(mbMain)                  // false branch: push 0
  mbMarkLabel(mbMain, endLbl)           // end:
  emitCall(mbMain, 0x0A000001)          // call Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(
    generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module>
  addTypeDef(t, TypeDefRow(
    flags = 0, typeName = sModule, typeNamespace = 0,
    extends = 0, fieldList = 1, methodList = 1))
  // TypeDef[2]: Hello
  addTypeDef(t, TypeDefRow(
    flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0,
    extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  // MethodDef[1]: Hello.Main — STATIC entry point
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

  // AssemblyRef[1]: System.Runtime
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

  // AssemblyRef[2]: System.Console
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
    entryPointToken = 0x06000001,   // Main = MethodDef[1]
    methodBodies    = bodies,
    tables          = t,
    strings         = sh,
    us              = uh,
    blobs           = bh,
    guids           = gh, resourceData = newList(), buildKind = "lib")

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",
    bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)

  // EntryPointToken = 0x06000001 (Main) at 0x214
  check("entry_tok_ok",
    bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Main tiny header 0x5A at 0x248 (codeSize=22)
  check("main_hdr_ok", bs[0x248] == 0x5A)

  // ldc.i4.7 (0x1D) at 0x249, ldc.i4.4 (0x1A) at 0x24A
  check("ldc_ok", bs[0x249] == 0x1D and bs[0x24A] == 0x1A)

  // cgt prefix 0xFE at 0x24B, second byte 0x02 at 0x24C
  check("cgt_ok", bs[0x24B] == 0xFE and bs[0x24C] == 0x02)

  // brfalse (0x39) at 0x24D, relative offset 6 (LE) at 0x24E
  check("brfalse_ok", bs[0x24D] == 0x39 and bs[0x24E] == 0x06 and bs[0x24F] == 0 and bs[0x250] == 0 and bs[0x251] == 0)

  // br (0x38) at 0x253, relative offset 1 (LE) at 0x254
  check("br_ok", bs[0x253] == 0x38 and bs[0x254] == 0x01 and bs[0x255] == 0 and bs[0x256] == 0 and bs[0x257] == 0)

  // ldc.i4.1 (0x17) at 0x252 (true branch), ldc.i4.0 (0x16) at 0x258 (else branch)
  check("branches_ok", bs[0x252] == 0x17 and bs[0x258] == 0x16)

  // BSJB at 0x25F
  check("bsjb_ok",
    bs[0x25F] == 0x42 and bs[0x260] == 0x53 and
    bs[0x261] == 0x4A and bs[0x262] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
