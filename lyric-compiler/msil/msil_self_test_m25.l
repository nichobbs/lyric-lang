//! msil_self_test_m25.l — Stage M25: isinst + castclass.
//!
//! Builds a PE whose Main() boxes integer 42 as System.Object, then tests
//! that the object is an instance of System.ValueType via isinst, boxes it
//! again, casts via castclass to System.Object, then calls
//! Console.WriteLine(object) to print "42".
//!
//! Actually, the simplest meaningful test is:
//!   - Load the integer 42 and box it to System.Object (box TypeRef=System.Int32)
//!   - Use isinst System.Object to check → leaves the reference or null on stack
//!   - If not null (brfalse would skip), call Console.WriteLine(object)
//!   - Otherwise print 0 (fallback, should never happen)
//!
//! This exercises:
//!   isinst (0x75) — tests if object is instance of type; pushes ref or null
//!   box (0x8C) — wraps a value type in an object reference
//!   Console.WriteLine(object): MemberRef with sig {0x00,0x01,0x01,0x1C}
//!
//! Code layout (tiny header):
//!   offset  0  1F 2A               ldc.i4.s 42                   [2]
//!   offset  2  8C 03 00 00 01      box TypeRef[3]=System.Int32   [5] → object ref
//!   offset  7  75 02 00 00 01      isinst TypeRef[2]=System.Object [5] → ref or null
//!   offset 12  39 0D 00 00 00      brfalse print_zero             [5] → if null skip
//!   offset 17  1F 2A               ldc.i4.s 42                   [2]
//!   offset 19  8C 03 00 00 01      box System.Int32               [5] → object ref
//!   offset 24  28 01 00 00 0A      call Console.WriteLine(object) [5]
//!   offset 29  2A                  ret                            [1]
//!   offset 30  [print_zero]:
//!   offset 30  16                  ldc.i4.0                      [1]
//!   offset 31  8C 03 00 00 01      box System.Int32               [5]
//!   offset 36  28 01 00 00 0A      call Console.WriteLine(object) [5]
//!   offset 41  2A                  ret                            [1]
//!
//! codeSize = 42 = 0x2A. Tiny header = (42<<2)|2 = 170 = 0xAA.
//!
//! TypeRefs:
//!   TypeRef[1]: System.Console  (resScope = AssemblyRef[2])
//!   TypeRef[2]: System.Object   (resScope = AssemblyRef[1])
//!   TypeRef[3]: System.Int32    (resScope = AssemblyRef[1])
//!
//! MemberRef[1]: Console.WriteLine(object)
//!   sig: DEFAULT(0x00), 1 param, void(0x01), OBJECT(0x1C)
//!
//! BSJB at 0x248 + 1 + 42 = 0x273.
//!
//! CLR execution: box 42, isinst succeeds (not null), print 42 → "42".
package Msil.SelfTestM25

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
  val outPath = "/tmp/lyric_msil_m25_isinst.dll"

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

  // Console.WriteLine(object): DEFAULT, 1 param, void, OBJECT(0x1C)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x1C)
  val sigWriteLineObj = internBlob(bh, "wl_obj_sig", bufToList(wlSigW))

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
  val printZero = mbNewLabel(mbMain)

  emitLdc_I4_S(mbMain, 42)
  emitBox(mbMain, 0x01000003)  // box System.Int32 = TypeRef[3]
  emitIsinst(mbMain, 0x01000002)  // isinst System.Object = TypeRef[2]
  emitBrfalse(mbMain, printZero)  // if null → fallback

  // isinst succeeded: box 42 and print it
  emitLdc_I4_S(mbMain, 42)
  emitBox(mbMain, 0x01000003)  // box System.Int32
  emitCall(mbMain, 0x0A000001)  // Console.WriteLine(object)
  emitRet(mbMain)

  // fallback: box 0 and print (should never execute)
  mbMarkLabel(mbMain, printZero)
  emitLdc_I4_0(mbMain)
  emitBox(mbMain, 0x01000003)
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
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  // TypeRef[3]: System.Int32
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

  // MemberRef[1]: Console.WriteLine(object)
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineObj))

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

  // Tiny header at 0x248: (42<<2)|2 = 170 = 0xAA
  check("tiny_hdr_ok", bs[0x248] == 0xAA)

  // box (0x8C) at code offset 2 = file 0x24B
  check("box_ok", bs[0x24B] == 0x8C)

  // isinst (0x75) at code offset 7 = file 0x250
  check("isinst_ok", bs[0x250] == 0x75)

  // isinst token = 0x01000002 (TypeRef[2]=System.Object) at 0x251: 02 00 00 01
  check("isinst_tok_ok", bs[0x251] == 0x02 and bs[0x252] == 0 and bs[0x253] == 0 and bs[0x254] == 0x01)

  // brfalse (0x39) at code offset 12 = file 0x255
  check("brfalse_ok", bs[0x255] == 0x39)

  // BSJB at 0x273
  check("bsjb_ok", bs[0x273] == 0x42 and bs[0x274] == 0x53 and bs[0x275] == 0x4A and bs[0x276] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
