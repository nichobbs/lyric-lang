//! msil_self_test_m34.l — Stage M34: sizeof (byte size of a value type).
//!
//! Builds a PE with one method, Main(), that:
//!   1. Pushes the byte size of System.Int32 via sizeof.
//!   2. Prints the result (4) via Console.WriteLine(int).
//!
//! New instruction exercised:
//!   sizeof (0xFE 0x1C) — pushes the byte size of a value type as an unsigned
//!                        int32.  Encodes as Token2(6 bytes): 0xFE 0x1C + token.
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])  — Hello extends
//!   TypeRef[3]: System.Int32    (resScope = AssemblyRef[1])  — sizeof operand
//!
//! MemberRef[1]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//!
//! Code layout (tiny header at 0x248, code at 0x249):
//!   offset  0  FE 1C 03 00 00 01  sizeof TypeRef[3]=Int32 [6]
//!   offset  6  28 01 00 00 0A     call MemberRef[1]=Console.WriteLine(int) [5]
//!   offset 11  2A                 ret [1]
//!
//! codeSize = 12. Tiny header = (12<<2)|2 = 50 = 0x32.
//!
//! BSJB at 0x248 + 1 + 12 = 0x255.
//!
//! CLR: sizeof Int32 = 4 → Console.WriteLine(4) → prints "4".
package Msil.SelfTestM34

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
  val outPath = "/tmp/lyric_msil_m34_sizeof.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sInt32 = internString(sh, "Int32")
  val sWriteLine = internString(sh, "WriteLine")

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
  // sizeof TypeRef[3]=System.Int32 → pushes 4 (byte size of int32)
  emitSizeof(mbMain, 0x01000003)
  // call Console.WriteLine(int) → prints "4"
  emitCall(mbMain, 0x0A000001)
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
  // TypeRef[2]: System.Object (Hello extends)
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  // TypeRef[3]: System.Int32 (sizeof operand)
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))

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
    resourceData = newList(),
    buildKind = "lib"
  )
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Tiny header at 0x248: (12<<2)|2 = 50 = 0x32
  check("tiny_hdr_ok", bs[0x248] == 0x32)

  // sizeof prefix 0xFE at code offset 0 = file 0x249; second byte 0x1C at 0x24A
  check("sizeof_ok", bs[0x249] == 0xFE and bs[0x24A] == 0x1C)

  // sizeof token = TypeRef[3] = 0x01000003 at 0x24B: 03 00 00 01
  check("sizeof_tok_ok", bs[0x24B] == 0x03 and bs[0x24C] == 0 and bs[0x24D] == 0 and bs[0x24E] == 0x01)

  // call (0x28) at code offset 6 = file 0x24F
  check("call_ok", bs[0x24F] == 0x28)

  // BSJB at 0x248 + 1 + 12 = 0x255
  check("bsjb_ok", bs[0x255] == 0x42 and bs[0x256] == 0x53 and bs[0x257] == 0x4A and bs[0x258] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
