// msil_self_test_m14.l — Stage M14: newarr + array element access.
//
// Builds a PE whose Main() creates an int32[3] array, stores values 10/20/30,
// sums arr[0]+arr[1]+arr[2]=60, and calls Console.WriteLine(60).
//
// New opcodes exercised: newarr (0x8D), stelem (0xA4), ldelem (0xA3).
// Requires TypeRef[3] = System.Int32 as the element-type token for all three.
//
// 1 local: int32[] arr — fat header + StandAloneSig (LocalVarSig = LOCALS,1,SZARRAY,I4).
//
// Fat header (12 bytes) at 0x248:
//   0x248  13 30         flags = FatFormat | InitLocals, header size = 3 DWords
//   0x24A  08 00         maxStack = 8
//   0x24C  3F 00 00 00   codeSize = 63
//   0x250  01 00 00 11   localVarSigTok = 0x11000001
//
// Code (63 bytes) starting at 0x254:
//   offset  0  19          ldc.i4.3           [array length]
//   offset  1  8D 03 00 00 01  newarr Int32   [tok = TypeRef[3] = 0x01000003]
//   offset  6  0A          stloc.0            [arr = new int[3]]
//   offset  7  06          ldloc.0
//   offset  8  16          ldc.i4.0
//   offset  9  1F 0A       ldc.i4.s 10
//   offset 11  A4 03 00 00 01  stelem Int32   [arr[0]=10]
//   offset 16  06          ldloc.0
//   offset 17  17          ldc.i4.1
//   offset 18  1F 14       ldc.i4.s 20
//   offset 20  A4 03 00 00 01  stelem Int32   [arr[1]=20]
//   offset 25  06          ldloc.0
//   offset 26  18          ldc.i4.2
//   offset 27  1F 1E       ldc.i4.s 30
//   offset 29  A4 03 00 00 01  stelem Int32   [arr[2]=30]
//   offset 34  06          ldloc.0
//   offset 35  16          ldc.i4.0
//   offset 36  A3 03 00 00 01  ldelem Int32   [arr[0] = 10]
//   offset 41  06          ldloc.0
//   offset 42  17          ldc.i4.1
//   offset 43  A3 03 00 00 01  ldelem Int32   [arr[1] = 20]
//   offset 48  58          add                [30]
//   offset 49  06          ldloc.0
//   offset 50  18          ldc.i4.2
//   offset 51  A3 03 00 00 01  ldelem Int32   [arr[2] = 30]
//   offset 56  58          add                [60]
//   offset 57  28 01 00 00 0A  call Console.WriteLine(int)
//   offset 62  2A          ret
//
// BSJB at 0x293 (= 0x254 + 63)
// CLR execution prints: "60"

package Msil.SelfTestM14

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
  val outPath = "/tmp/lyric_msil_m14_array.dll"

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
  val sInt32   = internString(sh, "Int32")
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

  // LocalVarSig: LOCALS (0x07), 1 var, SZARRAY (0x1D), I4 (0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07)   // LOCALS marker
  bufU1(lvW, 0x01)   // 1 variable
  bufU1(lvW, 0x1D)   // ELEMENT_TYPE_SZARRAY
  bufU1(lvW, 0x08)   // element: I4
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

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
  // Main(): arr = new int[3]; arr[0]=10; arr[1]=20; arr[2]=30;
  //         Console.WriteLine(arr[0]+arr[1]+arr[2])
  //
  // TypeRef[3] = System.Int32; token = 0x01000003
  val int32Tok = 0x01000003

  val mbMain = newMethodBody()

  emitLdc_I4_3(mbMain)                    // push 3 (array length)
  emitNewarr(mbMain, int32Tok)            // new int32[3]
  emitStloc_0(mbMain)                     // arr = ...

  emitLdloc_0(mbMain)                     // arr[0] = 10
  emitLdc_I4_0(mbMain)
  emitLdc_I4_S(mbMain, 10)
  emitStelem(mbMain, int32Tok)

  emitLdloc_0(mbMain)                     // arr[1] = 20
  emitLdc_I4_1(mbMain)
  emitLdc_I4_S(mbMain, 20)
  emitStelem(mbMain, int32Tok)

  emitLdloc_0(mbMain)                     // arr[2] = 30
  emitLdc_I4_2(mbMain)
  emitLdc_I4_S(mbMain, 30)
  emitStelem(mbMain, int32Tok)

  emitLdloc_0(mbMain)                     // arr[0] + arr[1] + arr[2]
  emitLdc_I4_0(mbMain)
  emitLdelem(mbMain, int32Tok)
  emitLdloc_0(mbMain)
  emitLdc_I4_1(mbMain)
  emitLdelem(mbMain, int32Tok)
  emitAdd(mbMain)
  emitLdloc_0(mbMain)
  emitLdc_I4_2(mbMain)
  emitLdelem(mbMain, int32Tok)
  emitAdd(mbMain)

  emitCall(mbMain, 0x0A000001)            // call Console.WriteLine(int)
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
  // TypeRef[3]: System.Int32 — element type for newarr/stelem/ldelem
  addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))

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

  // StandAloneSig[1]: LocalVarSig for 1 int32[] local
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

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
    guids           = gh)

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",
    bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)

  // EntryPointToken = 0x06000001 at 0x214
  check("entry_tok_ok",
    bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Fat header at 0x248
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("code_size_ok",
    bs[0x24C] == 0x3F and bs[0x24D] == 0 and bs[0x24E] == 0 and bs[0x24F] == 0)

  // LocalVarSigTok = 0x11000001 at 0x250
  check("local_sig_ok",
    bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // newarr (0x8D) at 0x255; TypeRef[3] token 0x01000003 LE at 0x256
  check("newarr_ok",
    bs[0x255] == 0x8D and
    bs[0x256] == 0x03 and bs[0x257] == 0 and bs[0x258] == 0 and bs[0x259] == 0x01)

  // stelem (0xA4) at 0x25F; TypeRef[3] token LE at 0x260
  check("stelem_ok",
    bs[0x25F] == 0xA4 and
    bs[0x260] == 0x03 and bs[0x261] == 0 and bs[0x262] == 0 and bs[0x263] == 0x01)

  // ldelem (0xA3) at 0x278; TypeRef[3] token LE at 0x279
  check("ldelem_ok",
    bs[0x278] == 0xA3 and
    bs[0x279] == 0x03 and bs[0x27A] == 0 and bs[0x27B] == 0 and bs[0x27C] == 0x01)

  // BSJB at 0x293
  check("bsjb_ok",
    bs[0x293] == 0x42 and bs[0x294] == 0x53 and
    bs[0x295] == 0x4A and bs[0x296] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
