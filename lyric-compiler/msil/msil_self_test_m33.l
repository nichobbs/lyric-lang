// msil_self_test_m33.l — Stage M33: ldtoken + Type.GetTypeFromHandle.
//
// Builds a PE that:
//   1. Pushes a RuntimeTypeHandle for System.Int32 via ldtoken.
//   2. Calls Type.GetTypeFromHandle(RuntimeTypeHandle) to get a Type object.
//   3. Calls Type::get_Name() on the result to get the string "Int32".
//   4. Prints it via Console.WriteLine(string).
//
// New instruction exercised:
//   ldtoken (0xD0) — loads a RuntimeTypeHandle / RuntimeMethodHandle /
//                    RuntimeFieldHandle for a metadata token onto the stack.
//
// TypeRefs:
//   TypeRef[1]: System.Console     (resScope = AssemblyRef[2])
//   TypeRef[2]: System.Object      (resScope = AssemblyRef[1])  — Hello extends
//   TypeRef[3]: System.Int32       (resScope = AssemblyRef[1])  — ldtoken target
//   TypeRef[4]: System.Type        (resScope = AssemblyRef[1])
//
// MemberRef[1]: Type::GetTypeFromHandle — DEFAULT, 1 param, Class Type(0x12,TypeRef[4]),
//               param: VALUETYPE RuntimeTypeHandle (0x11 TypeSpec — but encoding is complex;
//               actually use RuntimeTypeHandle which is in mscorlib)
//
// Simpler approach: use Type.GetTypeFromHandle which takes a
// System.RuntimeTypeHandle (a struct).  Its sig in blob is:
//   DEFAULT (0x00), 1 param, ret: CLASS TypeRef[4], param: VALUETYPE TypeRef[5]
// where TypeRef[5]=System.RuntimeTypeHandle.
//
// MemberRefs in this PE:
//   MemberRef[1]: Type::GetTypeFromHandle(RuntimeTypeHandle) → Type
//     sig: DEFAULT, 1 param, ELEMENT_TYPE_CLASS + TypeRef[4], ELEMENT_TYPE_VALUETYPE + TypeRef[5]
//   MemberRef[2]: Type::get_Name() → string
//     sig: HASTHIS, 0 params, ELEMENT_TYPE_STRING(0x0E)
//   MemberRef[3]: Console::WriteLine(string)
//     sig: DEFAULT, 1 param, void, ELEMENT_TYPE_STRING(0x0E)
//
// TypeRefs (revised):
//   TypeRef[1]: System.Console            (AssemblyRef[2])
//   TypeRef[2]: System.Object             (AssemblyRef[1]) — Hello extends
//   TypeRef[3]: System.Int32              (AssemblyRef[1]) — ldtoken target
//   TypeRef[4]: System.Type               (AssemblyRef[1])
//   TypeRef[5]: System.RuntimeTypeHandle  (AssemblyRef[1])
//
// Code layout (tiny header at 0x248, code at 0x249):
//   offset  0  D0 03 00 00 01   ldtoken TypeRef[3]=Int32  [5]
//   offset  5  28 01 00 00 0A   call MemberRef[1]=GetTypeFromHandle [5]
//   offset 10  6F 02 00 00 0A   callvirt MemberRef[2]=get_Name [5]
//   offset 15  28 03 00 00 0A   call MemberRef[3]=Console.WriteLine(string) [5]
//   offset 20  2A               ret [1]
//
// codeSize = 21. Tiny header = (21<<2)|2 = 86 = 0x56.
//
// BSJB at 0x248 + 1 + 21 = 0x25E.
//
// CLR: ldtoken Int32 → GetTypeFromHandle → Type → get_Name → "Int32" → prints "Int32".

package Msil.SelfTestM33

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
  val outPath = "/tmp/lyric_msil_m33_ldtoken.dll"

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
  val sType    = internString(sh, "Type")
  val sRTH     = internString(sh, "RuntimeTypeHandle")
  val sGetTypeFromHandle = internString(sh, "GetTypeFromHandle")
  val sGetName = internString(sh, "get_Name")
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

  // Type::GetTypeFromHandle(RuntimeTypeHandle) → Type
  // DEFAULT, 1 param, ret: CLASS TypeRef[4] (compressed token), param: VALUETYPE TypeRef[5]
  // TypeRef token encoding (compressed): TypeRef row index compressed as TypeDefOrRefOrSpec
  //   TypeRef[4] = 0x01000004 → TypeDefOrRefOrSpec coded: (4 << 2) | 1 = 0x11 (fits 1 byte)
  //   TypeRef[5] = 0x01000005 → TypeDefOrRefOrSpec coded: (5 << 2) | 1 = 0x15 (fits 1 byte)
  val gthSigW = bufNew()
  bufU1(gthSigW, 0x00)   // DEFAULT
  bufU1(gthSigW, 0x01)   // 1 param
  bufU1(gthSigW, 0x12)   // ret: ELEMENT_TYPE_CLASS
  bufU1(gthSigW, 0x11)   // compressed TypeRef[4] token in TypeDefOrRefOrSpec = (4<<2)|1
  bufU1(gthSigW, 0x11)   // param: ELEMENT_TYPE_VALUETYPE
  bufU1(gthSigW, 0x15)   // compressed TypeRef[5] token = (5<<2)|1
  val sigGetTypeFromHandle = internBlob(bh, "gth_sig", bufToList(gthSigW))

  // Type::get_Name() → string
  // HASTHIS, 0 params, ELEMENT_TYPE_STRING(0x0E)
  val getNameSigW = bufNew()
  bufU1(getNameSigW, 0x20); bufU1(getNameSigW, 0x00); bufU1(getNameSigW, 0x0E)
  val sigGetName = internBlob(bh, "getname_sig", bufToList(getNameSigW))

  // Console::WriteLine(string): DEFAULT, 1 param, void, ELEMENT_TYPE_STRING(0x0E)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x0E)
  val sigWriteLineStr = internBlob(bh, "wl_str_sig", bufToList(wlSigW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()
  emitLdtoken(mbMain, 0x01000003)       // ldtoken TypeRef[3]=System.Int32
  emitCall(mbMain, 0x0A000001)          // call MemberRef[1]=Type::GetTypeFromHandle
  emitCallvirt(mbMain, 0x0A000002)      // callvirt MemberRef[2]=Type::get_Name
  emitCall(mbMain, 0x0A000003)          // call MemberRef[3]=Console::WriteLine(string)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (Hello extends)
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  // TypeRef[3]: System.Int32 (ldtoken target)
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))
  // TypeRef[4]: System.Type
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sType, typeNamespace = sSystem))
  // TypeRef[5]: System.RuntimeTypeHandle
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sRTH, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))

  // MemberRef[1]: Type::GetTypeFromHandle(RuntimeTypeHandle)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(4), name = sGetTypeFromHandle, signature = sigGetTypeFromHandle))
  // MemberRef[2]: Type::get_Name()
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(4), name = sGetName, signature = sigGetName))
  // MemberRef[3]: Console::WriteLine(string)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineStr))

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

  // Tiny header at 0x248: (21<<2)|2 = 86 = 0x56
  check("tiny_hdr_ok", bs[0x248] == 0x56)

  // ldtoken (0xD0) at code offset 0 = file 0x249
  check("ldtoken_ok", bs[0x249] == 0xD0)

  // ldtoken token = TypeRef[3] = 0x01000003 at 0x24A: 03 00 00 01
  check("ldtoken_tok_ok", bs[0x24A] == 0x03 and bs[0x24B] == 0 and bs[0x24C] == 0 and bs[0x24D] == 0x01)

  // call (0x28) GetTypeFromHandle at code offset 5 = file 0x24E
  check("gth_ok", bs[0x24E] == 0x28)

  // BSJB at 0x248 + 1 + 21 = 0x25E
  check("bsjb_ok",
    bs[0x25E] == 0x42 and bs[0x25F] == 0x53 and
    bs[0x260] == 0x4A and bs[0x261] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
