//! msil_self_test_m28.l — Stage M28: ldsfld + stsfld (static fields).
//!
//! Builds a PE whose Hello class declares two public static I4 fields _x and
//! _y.  Main stores 20 in _x and 22 in _y via stsfld, then loads both via
//! ldsfld, adds them (42), and calls Console.WriteLine(int).
//!
//! New instructions exercised:
//!   stsfld (0x80) — stores a value to a static field
//!   ldsfld (0x7E) — loads a value from a static field
//!
//! Code layout (tiny header at 0x248):
//!   offset  0  1F 14               ldc.i4.s 20           [2]
//!   offset  2  80 01 00 00 04      stsfld Field[1]=_x    [5]
//!   offset  7  1F 16               ldc.i4.s 22           [2]
//!   offset  9  80 02 00 00 04      stsfld Field[2]=_y    [5]
//!   offset 14  7E 01 00 00 04      ldsfld Field[1]=_x    [5]
//!   offset 19  7E 02 00 00 04      ldsfld Field[2]=_y    [5]
//!   offset 24  58                  add                   [1]
//!   offset 25  28 01 00 00 0A      call Console.WriteLine(int) [5]
//!   offset 30  2A                  ret                   [1]
//!
//! codeSize = 31 = 0x1F. Tiny header = (31<<2)|2 = 126 = 0x7E.
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])
//!
//! Fields:
//!   Field[1]: _x  flags = FDA_PUBLIC + FDA_STATIC = 0x0016, sig {0x06, 0x08}
//!   Field[2]: _y  flags = FDA_PUBLIC + FDA_STATIC = 0x0016, sig {0x06, 0x08}
//!
//! MemberRef[1]: Console.WriteLine(int): DEFAULT, 1 param, void, I4
//!
//! BSJB at 0x248 + 1 + 31 = 0x268.
//!
//! CLR execution: _x=20, _y=22; 20+22=42 → prints "42".
package Msil.SelfTestM28

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
  val outPath = "/tmp/lyric_msil_m28_stsfld.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")
  val sX = internString(sh, "_x")
  val sY = internString(sh, "_y")

  val gh = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  val bh = newBlobHeap()

  // void () sig for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4(0x08)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // Static I4 field sig: FIELD(0x06) + I4(0x08)
  val fldSigW = bufNew()
  bufU1(fldSigW, 0x06)
  bufU1(fldSigW, 0x08)
  val sigField = internBlob(bh, "field_sig", bufToList(fldSigW))

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

  emitLdc_I4_S(mbMain, 20)
  emitStsfld(mbMain, 0x04000001)  // stsfld _x = Field[1]
  emitLdc_I4_S(mbMain, 22)
  emitStsfld(mbMain, 0x04000002)  // stsfld _y = Field[2]

  emitLdsfld(mbMain, 0x04000001)  // ldsfld _x
  emitLdsfld(mbMain, 0x04000002)  // ldsfld _y
  emitAdd(mbMain)

  emitCall(mbMain, 0x0A000001)  // Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
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

  // Field[1]: _x — public static I4
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_STATIC, name = sX, signature = sigField))
  // Field[2]: _y — public static I4
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_STATIC, name = sY, signature = sigField))

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

  val inp = AssemblerInput(
    entryPointToken = 0x06000001,
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

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header at 0x248: (31<<2)|2 = 126 = 0x7E
  check("tiny_hdr_ok", bs[0x248] == 0x7E)

  // stsfld (0x80) at code offset 2 = file 0x24B
  check("stsfld_ok", bs[0x24B] == 0x80)

  // stsfld token = Field[1] = 0x04000001 at 0x24C: 01 00 00 04
  check("stsfld_tok_ok", bs[0x24C] == 0x01 and bs[0x24D] == 0 and bs[0x24E] == 0 and bs[0x24F] == 0x04)

  // ldsfld (0x7E) at code offset 14 = file 0x249+14 = 0x257
  check("ldsfld_ok", bs[0x257] == 0x7E)

  // ldsfld token = Field[1] = 0x04000001 at 0x258: 01 00 00 04
  check("ldsfld_tok_ok", bs[0x258] == 0x01 and bs[0x259] == 0 and bs[0x25A] == 0 and bs[0x25B] == 0x04)

  // BSJB at 0x248 + 1 + 31 = 0x268
  check("bsjb_ok", bs[0x268] == 0x42 and bs[0x269] == 0x53 and bs[0x26A] == 0x4A and bs[0x26B] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
