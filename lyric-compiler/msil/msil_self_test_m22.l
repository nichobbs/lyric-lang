//! msil_self_test_m22.l — Stage M22: ldstr + #US heap.
//!
//! Builds a PE whose Main() loads the user string "Hello, World!" via ldstr
//! and passes it to Console.WriteLine(string), printing "Hello, World!".
//!
//! New infrastructure exercised:
//!   internUs — intern a string into the #US heap (UTF-16LE + flag byte)
//!   ldstr (0x72) — load a user string token (0x70xxxxxx) onto the stack
//!   Console.WriteLine(string) — MemberRef with return=void, param=String(0x0E)
//!
//! The #US heap layout:
//!   offset 0  00                      — empty entry
//!   offset 1  1B                      — length prefix: 27 = 13*2+1 bytes
//!             48 00  65 00  6C 00  6C 00  6F 00  2C 00  20 00
//!             57 00  6F 00  72 00  6C 00  64 00  21 00  — "Hello, World!" UTF-16LE
//!             00                      — flag byte (0 = no high code units)
//!
//! ldstr token: 0x70000001  (table 0x70 = user strings, offset 1)
//!
//! Code layout (tiny header at 0x248, code at 0x249):
//!   offset  0  72 01 00 00 70   ldstr 0x70000001       [5 bytes]
//!   offset  5  28 01 00 00 0A   call MemberRef[1]      [5 bytes]
//!   offset 10  2A               ret                    [1 byte]
//!
//! codeSize = 11. Tiny header = (11 << 2) | 2 = 46 = 0x2E.
//! Method body = 1 + 11 = 12 bytes.
//! BSJB at 0x248 + 12 = 0x254.
//!
//! CLR execution: prints "Hello, World!".
package Msil.SelfTestM22

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
  val outPath = "/tmp/lyric_msil_m22_ldstr.dll"

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

  val gh = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  // Intern the user string; returns byte offset 1 (0 is the empty entry).
  val usOff = internUs(uh, "Hello, World!")
  // ldstr token: table 0x70 (UserString) | offset
  val ldstrTok = 0x70000000 + usOff

  val bh = newBlobHeap()

  // void () sig for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(string): DEFAULT, 1 param, void, STRING(0x0E)
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

  emitLdstr(mbMain, ldstrTok)
  emitCall(mbMain, 0x0A000001)   // Console.WriteLine(string) = MemberRef[1]
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

  // MemberRef[1]: Console.WriteLine(string)
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

  // Tiny header at 0x248: (11 << 2) | 2 = 0x2E
  check("tiny_hdr_ok", bs[0x248] == 0x2E)

  // ldstr (0x72) at code offset 0 = file 0x249
  check("ldstr_ok", bs[0x249] == 0x72)

  // ldstr token 0x70000001 LE at 0x24A: 01 00 00 70
  check("ldstr_tok_ok", bs[0x24A] == 0x01 and bs[0x24B] == 0 and bs[0x24C] == 0 and bs[0x24D] == 0x70)

  // BSJB at 0x254 (= 0x248 + 12)
  check("bsjb_ok", bs[0x254] == 0x42 and bs[0x255] == 0x53 and bs[0x256] == 0x4A and bs[0x257] == 0x42)

  // usOff should be 1
  check("us_off_ok", usOff == 1)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
