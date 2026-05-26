// msil_self_test_m16.l — Stage M16: switch table.
//
// Builds a PE whose Main() pushes 2 and dispatches via a 3-target switch table.
// Target[2] (case 2) pushes 42 and falls through to Console.WriteLine.
//
// New opcode exercised: switch (0x45) — variable-length instruction:
//   0x45  count(u32)  target[0](i32) ... target[n-1](i32)
// Each target is a signed offset relative to the instruction AFTER the switch.
// Out-of-range values fall through to the instruction after the switch.
//
// Code layout (47 bytes), code starting at 0x249 (tiny header at 0x248):
//   offset  0  18                          ldc.i4.2          (value to dispatch)
//   offset  1  45 03 00 00 00              switch opcode + count=3
//              07 00 00 00                 target[0] → lbl0 (+7 from offset 18)
//              0E 00 00 00                 target[1] → lbl1 (+14 from offset 18)
//              15 00 00 00                 target[2] → lbl2 (+21 from offset 18)
//   offset 18  1F 63                       ldc.i4.s 99       (default)
//   offset 20  38 10 00 00 00              br end            (→ offset 41)
//   offset 25  [lbl0]
//   offset 25  1F 0A                       ldc.i4.s 10
//   offset 27  38 09 00 00 00              br end            (→ offset 41)
//   offset 32  [lbl1]
//   offset 32  1F 14                       ldc.i4.s 20
//   offset 34  38 02 00 00 00              br end            (→ offset 41)
//   offset 39  [lbl2]
//   offset 39  1F 2A                       ldc.i4.s 42
//   offset 41  [end]
//   offset 41  28 01 00 00 0A              call Console.WriteLine(int)
//   offset 46  2A                          ret
//
// Tiny header: (47<<2)|2 = 190 = 0xBE at 0x248
// Code at 0x249; BSJB at 0x278 (= 0x249 + 47)
// CLR execution prints: "42"  (input 2 → case 2 → push 42)

package Msil.SelfTestM16

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
  val outPath = "/tmp/lyric_msil_m16_switch.dll"

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

  // void () signature
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int) signature
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // Microsoft public key token
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
  val mbMain = newMethodBody()

  val lbl0    = mbNewLabel(mbMain)
  val lbl1    = mbNewLabel(mbMain)
  val lbl2    = mbNewLabel(mbMain)
  val endLbl  = mbNewLabel(mbMain)

  // Build switch target list [lbl0, lbl1, lbl2]
  val targets: List[Int] = newList()
  targets.add(lbl0)
  targets.add(lbl1)
  targets.add(lbl2)

  emitLdc_I4_2(mbMain)              // push 2
  emitSwitch(mbMain, targets)       // switch on 3 targets

  // default (fall-through when value out of [0,3))
  emitLdc_I4_S(mbMain, 99)
  emitBr(mbMain, endLbl)

  mbMarkLabel(mbMain, lbl0)
  emitLdc_I4_S(mbMain, 10)
  emitBr(mbMain, endLbl)

  mbMarkLabel(mbMain, lbl1)
  emitLdc_I4_S(mbMain, 20)
  emitBr(mbMain, endLbl)

  mbMarkLabel(mbMain, lbl2)
  emitLdc_I4_S(mbMain, 42)

  mbMarkLabel(mbMain, endLbl)
  emitCall(mbMain, 0x0A000001)      // call Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

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

  addMethodDef(t, MethodDefRow(
    rva       = rvaMain,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name      = sMain,
    signature = sigVoid,
    paramList = 1))

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
    guids           = gh, resourceData = newList())

  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",
    bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok",
    bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header: (47<<2)|2 = 0xBE
  check("tiny_hdr_ok", bs[0x248] == 0xBE)

  // switch opcode 0x45 at code offset 1 = file 0x24A
  check("switch_op_ok", bs[0x24A] == 0x45)

  // count = 3 at file 0x24B (LE u32)
  check("switch_n_ok",
    bs[0x24B] == 3 and bs[0x24C] == 0 and bs[0x24D] == 0 and bs[0x24E] == 0)

  // target[0] = 7 at file 0x24F (lbl0 at offset 25, next-after-switch at 18; 25-18=7)
  check("switch_t0_ok",
    bs[0x24F] == 7 and bs[0x250] == 0 and bs[0x251] == 0 and bs[0x252] == 0)

  // target[2] = 21 at file 0x257 (lbl2 at offset 39, next-after-switch at 18; 39-18=21)
  check("switch_t2_ok",
    bs[0x257] == 21 and bs[0x258] == 0 and bs[0x259] == 0 and bs[0x25A] == 0)

  // BSJB at 0x278 (= 0x249 + 47)
  check("bsjb_ok",
    bs[0x278] == 0x42 and bs[0x279] == 0x53 and
    bs[0x27A] == 0x4A and bs[0x27B] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
