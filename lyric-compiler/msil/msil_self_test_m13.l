// msil_self_test_m13.l — Stage M13: while loop (backward branch).
//
// Builds a PE whose Main() computes sum = 1+2+3+4+5 = 15 using a while loop:
//   sum = 0; i = 1
//   while i <= 5 { sum = sum + i; i = i + 1 }
//   Console.WriteLine(sum)
//
// Implementation uses two int32 locals (fat method header + StandAloneSig),
// cgt + brtrue for the exit condition, and a backward br for the loop back-edge.
//
// Fat header (12 bytes) at 0x248:
//   0x248  13 30         flags = FatFormat | InitLocals, header size = 3 DWords
//   0x24A  08 00         maxStack = 8
//   0x24C  21 00 00 00   codeSize = 33
//   0x250  01 00 00 11   localVarSigTok = 0x11000001 (StandAloneSig[1])
//
// Code (33 bytes) starting at 0x254:
//   offset  0  16          ldc.i4.0        [init sum]
//   offset  1  0A          stloc.0
//   offset  2  17          ldc.i4.1        [init i]
//   offset  3  0B          stloc.1
//   [loop_start = offset 4]
//   offset  4  07          ldloc.1         [push i]
//   offset  5  1B          ldc.i4.5        [push 5]
//   offset  6  FE 02       cgt             [i > 5?]
//   offset  8  3A 0D 00 00 00  brtrue end  [if true exit; next instr=13, end=26, rel=13]
//   offset 13  06          ldloc.0         [push sum]
//   offset 14  07          ldloc.1         [push i]
//   offset 15  58          add
//   offset 16  0A          stloc.0         [sum += i]
//   offset 17  07          ldloc.1         [push i]
//   offset 18  17          ldc.i4.1
//   offset 19  58          add
//   offset 20  0B          stloc.1         [i += 1]
//   offset 21  38 EA FF FF FF  br loop_start [next=26, loop_start=4, rel=-22=0xFFFFFFEA]
//   [end_lbl = offset 26]
//   offset 26  06          ldloc.0         [push sum]
//   offset 27  28 01 00 00 0A  call Console.WriteLine(int)
//   offset 32  2A          ret
//
// File offsets: fat header 0x248, code 0x254, BSJB 0x275 (= 0x248 + 12 + 33)
// CLR execution prints: "15"

package Msil.SelfTestM13

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
  val outPath = "/tmp/lyric_msil_m13_loop.dll"

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

  // LocalVarSig: LOCALS (0x07), 2 vars, I4, I4
  val lvW = bufNew()
  bufU1(lvW, 0x07)   // LOCALS marker
  bufU1(lvW, 0x02)   // 2 variables
  bufU1(lvW, 0x08)   // var 0: I4 (sum)
  bufU1(lvW, 0x08)   // var 1: I4 (i)
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
  // Main(): sum=0; i=1; while i<=5 { sum+=i; i+=1 }; Console.WriteLine(sum)
  //
  val mbMain = newMethodBody()

  val loopStart = mbNewLabel(mbMain)
  val endLbl    = mbNewLabel(mbMain)

  // Initialization
  emitLdc_I4_0(mbMain)             // push 0
  emitStloc_0(mbMain)              // sum = 0
  emitLdc_I4_1(mbMain)             // push 1
  emitStloc_1(mbMain)              // i = 1

  // Loop condition
  mbMarkLabel(mbMain, loopStart)
  emitLdloc_1(mbMain)              // push i
  emitLdc_I4_5(mbMain)             // push 5
  emitCgt(mbMain)                  // i > 5?
  emitBrtrue(mbMain, endLbl)       // exit if true

  // Loop body
  emitLdloc_0(mbMain)              // push sum
  emitLdloc_1(mbMain)              // push i
  emitAdd(mbMain)                  // sum + i
  emitStloc_0(mbMain)              // sum = sum + i
  emitLdloc_1(mbMain)              // push i
  emitLdc_I4_1(mbMain)             // push 1
  emitAdd(mbMain)                  // i + 1
  emitStloc_1(mbMain)              // i = i + 1
  emitBr(mbMain, loopStart)        // backward branch

  // After loop
  mbMarkLabel(mbMain, endLbl)
  emitLdloc_0(mbMain)              // push sum
  emitCall(mbMain, 0x0A000001)     // call Console.WriteLine(int)
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

  // StandAloneSig[1]: LocalVarSig for 2 int32 locals
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
    guids           = gh, resourceData = newList(), buildKind = "lib")

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

  // Fat header at 0x248: flags=0x13,0x30; maxStack=8,0; codeSize=33,0,0,0
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("code_size_ok", bs[0x24C] == 0x21 and bs[0x24D] == 0 and bs[0x24E] == 0 and bs[0x24F] == 0)

  // LocalVarSigTok = 0x11000001 at 0x250
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // cgt: 0xFE at 0x25A, 0x02 at 0x25B
  check("cgt_ok", bs[0x25A] == 0xFE and bs[0x25B] == 0x02)

  // brtrue (0x3A) at 0x25C, relative offset +13 at 0x25D
  check("brtrue_ok", bs[0x25C] == 0x3A and bs[0x25D] == 0x0D)

  // backward br (0x38) at 0x269, relative offset -22 = 0xEA at 0x26A
  check("br_back_ok", bs[0x269] == 0x38 and bs[0x26A] == 0xEA and bs[0x26B] == 0xFF and bs[0x26C] == 0xFF and bs[0x26D] == 0xFF)

  // BSJB at 0x275
  check("bsjb_ok",
    bs[0x275] == 0x42 and bs[0x276] == 0x53 and
    bs[0x277] == 0x4A and bs[0x278] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
