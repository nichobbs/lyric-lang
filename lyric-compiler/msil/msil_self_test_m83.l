//! msil_self_test_m83.l — Stage M83: constrained. (0xFE 0x16), ldvirtftn (0xFE 0x07), ldsflda (0x7F).
//!
//! Exercises:
//!   constrained. (0xFE 0x16) — type-constraint prefix for callvirt on value types
//!   ldvirtftn    (0xFE 0x07) — load virtual method function pointer [dead path]
//!   ldsflda      (0x7F)      — load static field address [dead path]
//!
//! Code flow (one Int32 local, fat header):
//!   ldc.i4 42 / stloc.0     — store 42 into local[0]
//!   br LIVE                  — jump over dead block (br +17 → offset 28)
//!   [dead] ldnull / ldvirtftn MR2 / pop
//!   [dead] ldc.i4.0 / ldsflda MR1 / pop / pop / nop
//!   LIVE: ldloca.s 0 / constrained. TR3 / callvirt MR2 → Int32.GetHashCode(42) = 42
//!         call MR1 / ret
//!
//! Int32.GetHashCode() returns the value itself (42) → prints "42".
//!
//! codeSize = 47.  Fat header = 12 bytes.  Method body = 12 + 47 = 59 bytes.
//! Fat header at file 0x248.  Code starts at file 0x254.  BSJB at 0x248 + 59 = 0x283.
//!
//! Code layout:
//!   offset  0: ldc.i4 42       (5B: 20 2A 00 00 00)  file 0x254
//!   offset  5: stloc.0          (1B: 0A)
//!   offset  6: br +17 → 28     (5B: 38 11 00 00 00)  next=11
//!   offset 11: ldnull  [dead]   (1B: 14)
//!   offset 12: ldvirtftn MR2   (6B: FE 07 …)         file 0x260  ← ldvirtftn_ok
//!   offset 18: pop [dead]       (1B: 26)
//!   offset 19: ldc.i4.0 [dead]  (1B: 16)
//!   offset 20: ldsflda MR1     (5B: 7F …)            file 0x268  ← ldsflda_ok
//!   offset 25: pop [dead]       (1B: 26)
//!   offset 26: pop [dead]       (1B: 26)
//!   offset 27: nop [dead]       (1B: 00)
//!   offset 28: ldloca.s 0       (2B: 12 00)  ← LIVE
//!   offset 30: constrained. TR3 (6B: FE 16 …)        file 0x272  ← constrained_ok
//!   offset 36: callvirt MR2     (5B: 6F …)
//!   offset 41: call MR1         (5B: 28 …)
//!   offset 46: ret              (1B: 2A)
//!
//! Token assignments:
//!   TypeRef 1: System.Console  → rsAssemblyRef(2)  → 0x01000001
//!   TypeRef 2: System.Object   → rsAssemblyRef(1)  → 0x01000002
//!   TypeRef 3: System.Int32    → rsAssemblyRef(1)  → 0x01000003
//!   StandAloneSig 1: localVarSig → standaloneToken(1) = 0x11000001
//!   MemberRef 1: Console.WriteLine(int) → class TypeRef(1) → 0x0A000001
//!   MemberRef 2: Object.GetHashCode()   → class TypeRef(2) → 0x0A000002
//!   AssemblyRef 1: System.Runtime
//!   AssemblyRef 2: System.Console
package Msil.SelfTestM83

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
  val outPath = "/tmp/lyric_msil_m83_constrained.dll"

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
  val sGetHashCode = internString(sh, "GetHashCode")

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

  // Main() void sig: DEFAULT(0x00) + 0 params + void(0x01)
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int) sig: DEFAULT(0x00) + 1 param + void(0x01) + int32(0x08)
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // Object.GetHashCode() instance sig: HASTHIS(0x20) + 0 params + int32(0x08)
  val ghSigW = bufNew()
  bufU1(ghSigW, 0x20)
  bufU1(ghSigW, 0x00)
  bufU1(ghSigW, 0x08)
  val sigGetHashCode = internBlob(bh, "gh_sig", bufToList(ghSigW))

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

  // LocalVarSig: LOCAL_SIG(0x07) + count=1 + int32(0x08)
  val lvW = bufNew()
  bufU1(lvW, 0x07)
  bufU1(lvW, 0x01)
  bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  // Tokens resolved from table insertion order (see comment at top of file)
  val tokWriteLine = 0x0A000001
  val tokGetHashCode = 0x0A000002
  val tokInt32 = 0x01000003

  val mbMain = newMethodBody()
  emitLdc_I4(mbMain, 42)                     // offset  0: ldc.i4 42  (5B)
  emitStloc_0(mbMain)                        // offset  5: stloc.0    (1B)
  val lblLive = mbNewLabel(mbMain)
  emitBr(mbMain, lblLive)                    // offset  6: br LIVE    (5B) next=11 target=28 off=17
  // dead block (17 bytes, offsets 11–27)
  emitLdnull(mbMain)                         // offset 11: ldnull     (1B)
  emitLdvirtftn(mbMain, tokGetHashCode)      // offset 12: ldvirtftn  (6B) → FE 07 at file 0x260
  emitPop(mbMain)                            // offset 18: pop        (1B)
  emitLdc_I4_0(mbMain)                       // offset 19: ldc.i4.0   (1B)
  emitLdsflda(mbMain, tokWriteLine)          // offset 20: ldsflda    (5B) → 7F at file 0x268
  emitPop(mbMain)                            // offset 25: pop        (1B)
  emitPop(mbMain)                            // offset 26: pop        (1B)
  emitNop(mbMain)                            // offset 27: nop        (1B)
  // LIVE: offset 28
  mbMarkLabel(mbMain, lblLive)
  emitLdloca_S(mbMain, 0)                    // offset 28: ldloca.s 0 (2B)
  emitConstrained(mbMain, tokInt32)          // offset 30: constrained. (6B) → FE 16 at file 0x272
  emitCallvirt(mbMain, tokGetHashCode)       // offset 36: callvirt   (5B) → Int32.GetHashCode() = 42
  emitCall(mbMain, tokWriteLine)             // offset 41: call       (5B) → Console.WriteLine(42)
  emitRet(mbMain)                            // offset 46: ret        (1B)
  // codeSize = 47

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))   // TypeRef 1
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))   // TypeRef 2
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt32, typeNamespace = sSystem))   // TypeRef 3
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
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(1), name = sWriteLine, signature = sigWriteLineInt))  // MR 1
  addMemberRef(t, MemberRefRow(class = mrpTypeRef(2), name = sGetHashCode, signature = sigGetHashCode))   // MR 2
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

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("ldc_i4_ok", bs[0x254] == 0x20)
  check("ldvirtftn_ok", bs[0x260] == 0xFE and bs[0x261] == 0x07)
  check("ldsflda_ok", bs[0x268] == 0x7F)
  check("constrained_ok", bs[0x272] == 0xFE and bs[0x273] == 0x16)
  check("bsjb_ok", bs[0x283] == 0x42 and bs[0x284] == 0x53 and bs[0x285] == 0x4A and bs[0x286] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
