// msil_self_test_m23.l — Stage M23: multiple static methods.
//
// Builds a PE with two MethodDef rows: Main() (entry point) calls a
// static helper Add(int, int): int, passing 20 and 22, printing 42.
//
// New infrastructure exercised:
//   Second MethodDef row — 'Add' is MethodDef[2], owned by TypeDef[2]
//   MethodDef token (0x06000002) in call instruction
//   Multi-body methodBodyRvas — bodies[0]=Main, bodies[1]=Add; RVAs assigned
//
// Method bodies (both tiny headers):
//   Main (MethodDef[1]) at RVA 0x2048 (file 0x248):
//     tiny hdr 0x3E (codeSize=15)  [1 byte]
//     ldc.i4.s 20  [2 bytes]
//     ldc.i4.s 22  [2 bytes]
//     call 0x06000002  [5 bytes]   — Add
//     call 0x0A000001  [5 bytes]   — Console.WriteLine(int)
//     ret              [1 byte]
//     total body = 16 bytes (0x248–0x257)
//
//   Add (MethodDef[2]) at RVA 0x2058 (file 0x258):
//     tiny hdr 0x12 (codeSize=4)   [1 byte]
//     ldarg.0  [1 byte]
//     ldarg.1  [1 byte]
//     add      [1 byte]
//     ret      [1 byte]
//     total body = 5 bytes (0x258–0x25C)
//
// BSJB at 0x258 + 5 = 0x25D.
//
// CLR execution: Add(20, 22) = 42 → prints "42".

package Msil.SelfTestM23

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
  val outPath = "/tmp/lyric_msil_m23_multimeth.dll"

  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
  val sAdd     = internString(sh, "Add")
  val sSystem  = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject  = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")

  val gh    = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  val bh = newBlobHeap()

  // void () sig for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Add(int, int): int  — DEFAULT, 2 params, I4, I4, I4
  val addSigW = bufNew()
  bufU1(addSigW, 0x00); bufU1(addSigW, 0x02); bufU1(addSigW, 0x08)
  bufU1(addSigW, 0x08); bufU1(addSigW, 0x08)
  val sigAdd = internBlob(bh, "add_sig", bufToList(addSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method bodies ───────────────────────────────────────────────────

  // Main: calls Add(20, 22) then Console.WriteLine(result)
  val mbMain = newMethodBody()
  emitLdc_I4_S(mbMain, 20)
  emitLdc_I4_S(mbMain, 22)
  emitCall(mbMain, 0x06000002)   // call Add = MethodDef[2]
  emitCall(mbMain, 0x0A000001)   // call Console.WriteLine(int)
  emitRet(mbMain)

  // Add: ldarg.0 + ldarg.1 + add + ret
  val mbAdd = newMethodBody()
  emitLdarg_0(mbAdd)
  emitLdarg_1(mbAdd)
  emitAdd(mbAdd)
  emitRet(mbAdd)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  bodies.add(mbAdd)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]
  val rvaAdd  = rvas[1]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  // MethodDef[1]: Main (entry point)
  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))
  // MethodDef[2]: Add
  addMethodDef(t, MethodDefRow(rva = rvaAdd, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sAdd, signature = sigAdd, paramList = 1))

  // MemberRef[1]: Console.WriteLine(int)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))

  addAssembly(t, AssemblyRow(hashAlgId = HASH_ALG_SHA1, majorVersion = 0, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = ASF_NONE, publicKey = 0, name = sHello, culture = 0))
  addAssemblyRef(t, AssemblyRefRow(majorVersion = 10, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = 0, publicKeyToken = keyToken, name = sRuntime,    culture = 0, hashValue = 0))
  addAssemblyRef(t, AssemblyRefRow(majorVersion = 10, minorVersion = 0, buildNumber = 0, revisionNumber = 0, flags = 0, publicKeyToken = keyToken, name = sConsoleAsm, culture = 0, hashValue = 0))

  val inp = AssemblerInput(entryPointToken = 0x06000001, methodBodies = bodies, tables = t, strings = sh, us = uh, blobs = bh, guids = gh, resourceData = newList(), buildKind = "lib")
  val peBuf = assemblePe(inp)
  val bs = bufToList(peBuf)

  // ── Structural checks ─────────────────────────────────────────────────────

  check("dos_ok",      bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok",   bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok",   bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Main tiny header at 0x248: (15 << 2) | 2 = 0x3E
  check("main_hdr_ok", bs[0x248] == 0x3E)

  // call Add (0x06000002) at Main code offset 4 = file 0x24D: 28 02 00 00 06
  check("call_add_ok", bs[0x24D] == 0x28 and bs[0x24E] == 0x02 and bs[0x24F] == 0 and bs[0x250] == 0 and bs[0x251] == 0x06)

  // Add tiny header at 0x258: (4 << 2) | 2 = 0x12
  check("add_hdr_ok", bs[0x258] == 0x12)

  // ldarg.0 (0x02) at Add code offset 0 = file 0x259
  check("ldarg0_ok", bs[0x259] == 0x02)

  // ldarg.1 (0x03) at Add code offset 1 = file 0x25A
  check("ldarg1_ok", bs[0x25A] == 0x03)

  // add (0x58) at Add code offset 2 = file 0x25B
  check("add_op_ok", bs[0x25B] == 0x58)

  // BSJB at 0x25D (= 0x248 + 16 + 5)
  check("bsjb_ok",
    bs[0x25D] == 0x42 and bs[0x25E] == 0x53 and
    bs[0x25F] == 0x4A and bs[0x260] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
