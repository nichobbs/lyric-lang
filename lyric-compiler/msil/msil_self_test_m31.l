// msil_self_test_m31.l — Stage M31: ldftn + delegate (System.Action).
//
// Builds a PE with two methods:
//   PrintFortyTwo() — static, prints 42 via Console.WriteLine(int)
//   Main()          — creates System.Action delegate pointing to PrintFortyTwo,
//                     then invokes it via callvirt Action::Invoke()
//
// New instruction exercised:
//   ldftn (0xFE 0x06) — loads a function pointer for a MethodDef onto the stack
//
// Helper: PrintFortyTwo is MethodDef[2], placed after Main in the method body
// stream.  Token = 0x06000002.
//
// Main code layout (tiny header at 0x248, code at 0x249):
//   offset  0  14                  ldnull                      [1]
//   offset  1  FE 06 02 00 00 06   ldftn MethodDef[2]          [6] fn ptr
//   offset  7  73 01 00 00 0A      newobj MemberRef[1]=Action..ctor  [5]
//   offset 12  6F 02 00 00 0A      callvirt MemberRef[2]=Action::Invoke [5]
//   offset 17  2A                  ret                         [1]
//
// Main codeSize = 18. Tiny header = (18<<2)|2 = 74 = 0x4A.
//
// PrintFortyTwo code layout (tiny header at 0x25B = 0x248+1+18, code at 0x25C):
//   offset  0  1F 2A               ldc.i4.s 42                 [2]
//   offset  2  28 03 00 00 0A      call MemberRef[3]=Console.WriteLine(int) [5]
//   offset  7  2A                  ret                         [1]
//
// PrintFortyTwo codeSize = 8. Tiny header = (8<<2)|2 = 34 = 0x22.
//
// TypeRefs:
//   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])
//   TypeRef[3]: System.Action   (resScope = AssemblyRef[1])
//
// MemberRef[1]: System.Action::.ctor — HASTHIS, 2 params, void, OBJECT(0x1C), I(0x18)
// MemberRef[2]: System.Action::Invoke — HASTHIS, 0 params, void
// MemberRef[3]: Console.WriteLine(int) — DEFAULT, 1 param, void, I4
//
// BSJB at 0x248 + 1 + 18 + 1 + 8 = 0x264.
//
// CLR: ldftn → Action ctor → Invoke() → PrintFortyTwo() → prints "42".

package Msil.SelfTestM31

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
  val outPath = "/tmp/lyric_msil_m31_ldftn.dll"

  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
  val sPrint42 = internString(sh, "PrintFortyTwo")
  val sSystem  = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject  = internString(sh, "Object")
  val sAction  = internString(sh, "Action")
  val sCtor    = internString(sh, ".ctor")
  val sInvoke  = internString(sh, "Invoke")
  val sWriteLine = internString(sh, "WriteLine")

  val gh    = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
  val mvid = appendGuid(gh, bufToList(guidW))

  val uh = newUsHeap()
  val bh = newBlobHeap()

  // void () sig for Main and PrintFortyTwo
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // System.Action::.ctor — HASTHIS, 2 params, void, OBJECT(0x1C), I(0x18)
  val ctorSigW = bufNew()
  bufU1(ctorSigW, 0x20)   // HASTHIS
  bufU1(ctorSigW, 0x02)   // 2 params
  bufU1(ctorSigW, 0x01)   // ret: void
  bufU1(ctorSigW, 0x1C)   // param 1: OBJECT
  bufU1(ctorSigW, 0x18)   // param 2: I (native int)
  val sigCtor = internBlob(bh, "action_ctor_sig", bufToList(ctorSigW))

  // System.Action::Invoke — HASTHIS, 0 params, void
  val invokeSigW = bufNew()
  bufU1(invokeSigW, 0x20); bufU1(invokeSigW, 0x00); bufU1(invokeSigW, 0x01)
  val sigInvoke = internBlob(bh, "action_invoke_sig", bufToList(invokeSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4(0x08)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method bodies ───────────────────────────────────────────────────
  // Main: ldnull / ldftn PrintFortyTwo / newobj Action..ctor / callvirt Invoke / ret
  val mbMain = newMethodBody()
  emitLdnull(mbMain)
  emitLdftn(mbMain, 0x06000002)        // ldftn MethodDef[2]=PrintFortyTwo
  emitNewobj(mbMain, 0x0A000001)       // newobj MemberRef[1]=Action::.ctor
  emitCallvirt(mbMain, 0x0A000002)     // callvirt MemberRef[2]=Action::Invoke
  emitRet(mbMain)

  // PrintFortyTwo: ldc.i4.s 42 / call Console.WriteLine(int) / ret
  val mbPrint = newMethodBody()
  emitLdc_I4_S(mbPrint, 42)
  emitCall(mbPrint, 0x0A000003)        // call MemberRef[3]=Console.WriteLine(int)
  emitRet(mbPrint)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  bodies.add(mbPrint)
  val rvas     = methodBodyRvas(bodies)
  val rvaMain  = rvas[0]
  val rvaPrint = rvas[1]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  // TypeRef[3]: System.Action
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sAction, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  // MethodDef[1]: Main (entry point)
  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))
  // MethodDef[2]: PrintFortyTwo (referenced by ldftn)
  addMethodDef(t, MethodDefRow(rva = rvaPrint, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sPrint42, signature = sigVoid, paramList = 1))

  // MemberRef[1]: System.Action::.ctor
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(3), name = sCtor, signature = sigCtor))
  // MemberRef[2]: System.Action::Invoke
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(3), name = sInvoke, signature = sigInvoke))
  // MemberRef[3]: Console.WriteLine(int)
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

  // Main tiny header at 0x248: (18<<2)|2 = 74 = 0x4A
  check("main_hdr_ok", bs[0x248] == 0x4A)

  // ldnull (0x14) at code offset 0 = file 0x249
  check("ldnull_ok", bs[0x249] == 0x14)

  // ldftn prefix (0xFE) at code offset 1 = file 0x24A; second byte 0x06 at 0x24B
  check("ldftn_ok", bs[0x24A] == 0xFE and bs[0x24B] == 0x06)

  // ldftn token = MethodDef[2] = 0x06000002 at 0x24C: 02 00 00 06
  check("ldftn_tok_ok", bs[0x24C] == 0x02 and bs[0x24D] == 0 and bs[0x24E] == 0 and bs[0x24F] == 0x06)

  // newobj (0x73) at code offset 7 = file 0x250
  check("newobj_ok", bs[0x250] == 0x73)

  // PrintFortyTwo tiny header at 0x248+1+18=0x25B: (8<<2)|2 = 34 = 0x22
  check("print_hdr_ok", bs[0x25B] == 0x22)

  // BSJB at 0x248+1+18+1+8=0x26A
  check("bsjb_ok",
    bs[0x264] == 0x42 and bs[0x265] == 0x53 and
    bs[0x266] == 0x4A and bs[0x267] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
