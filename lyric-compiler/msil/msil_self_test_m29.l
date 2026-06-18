//! msil_self_test_m29.l — Stage M29: castclass (reference-type cast).
//!
//! Builds a PE whose Main() boxes 42 as System.Object, calls
//! callvirt System.Object::ToString() to get "42" as System.String, then
//! uses castclass System.String to perform an explicit cast (which succeeds),
//! and calls Console.WriteLine(string) to print "42".
//!
//! New instruction exercised:
//!   castclass (0x74) — casts an object reference to a given type; throws
//!                      InvalidCastException on failure
//!
//! Code layout (tiny header at 0x248):
//!   offset  0  1F 2A               ldc.i4.s 42               [2]
//!   offset  2  8C 03 00 00 01      box TypeRef[3]=Int32       [5] → object ref
//!   offset  7  6F 01 00 00 0A      callvirt MemberRef[1]      [5] → string "42"
//!   offset 12  74 04 00 00 01      castclass TypeRef[4]=String[5] → string ref
//!   offset 17  28 02 00 00 0A      call MemberRef[2]          [5] print "42"
//!   offset 22  2A                  ret                        [1]
//!
//! codeSize = 23 = 0x17. Tiny header = (23<<2)|2 = 94 = 0x5E.
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object  (resScope = AssemblyRef[1])
//!   TypeRef[3]: System.Int32   (resScope = AssemblyRef[1])
//!   TypeRef[4]: System.String  (resScope = AssemblyRef[1])
//!
//! MemberRef[1]: System.Object::ToString()  HASTHIS, 0 params, string {0x20,0x00,0x0E}
//! MemberRef[2]: Console.WriteLine(string)  DEFAULT, 1 param, void, string
//!
//! BSJB at 0x248 + 1 + 23 = 0x260.
//!
//! CLR: box 42 → ToString() → "42" → castclass succeeds → print "42".
package Msil.SelfTestM29

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
  val outPath = "/tmp/lyric_msil_m29_castclass.dll"

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
  val sString = internString(sh, "String")
  val sWriteLine = internString(sh, "WriteLine")
  val sToString = internString(sh, "ToString")

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

  // System.Object::ToString() : HASTHIS, 0 params, returns string(0x0E)
  val toStrSigW = bufNew()
  bufU1(toStrSigW, 0x20)
  bufU1(toStrSigW, 0x00)
  bufU1(toStrSigW, 0x0E)
  val sigToString = internBlob(bh, "tostring_sig", bufToList(toStrSigW))

  // Console.WriteLine(string): DEFAULT, 1 param, void, string(0x0E)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x0E)
  val sigWriteLineStr = internBlob(bh, "wl_str_sig", bufToList(wlSigW))

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

  emitLdc_I4_S(mbMain, 42)
  emitBox(mbMain, 0x01000003)               // box System.Int32 = TypeRef[3]
  emitCallvirt(mbMain, 0x0A000001)          // callvirt System.Object::ToString()
  emitCastclass(mbMain, 0x01000004)         // castclass System.String = TypeRef[4]
  emitCall(mbMain, 0x0A000002)              // call Console.WriteLine(string)
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
  // TypeRef[3]: System.Int32
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))
  // TypeRef[4]: System.String
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sString, typeNamespace = sSystem))

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

  // MemberRef[1]: System.Object::ToString()
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(2), name = sToString, signature = sigToString))
  // MemberRef[2]: Console.WriteLine(string)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineStr))

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

  // Tiny header at 0x248: (23<<2)|2 = 94 = 0x5E
  check("tiny_hdr_ok", bs[0x248] == 0x5E)

  // box (0x8C) at code offset 2 = file 0x24B
  check("box_ok", bs[0x24B] == 0x8C)

  // callvirt (0x6F) at code offset 7 = file 0x250
  check("callvirt_ok", bs[0x250] == 0x6F)

  // castclass (0x74) at code offset 12 = file 0x255
  check("castclass_ok", bs[0x255] == 0x74)

  // castclass token = TypeRef[4] = 0x01000004 at 0x256: 04 00 00 01
  check("castclass_tok_ok", bs[0x256] == 0x04 and bs[0x257] == 0 and bs[0x258] == 0 and bs[0x259] == 0x01)

  // BSJB at 0x248 + 1 + 23 = 0x260
  check("bsjb_ok", bs[0x260] == 0x42 and bs[0x261] == 0x53 and bs[0x262] == 0x4A and bs[0x263] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
