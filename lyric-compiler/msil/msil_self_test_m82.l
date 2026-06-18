//! msil_self_test_m82.l — Stage M82: ldelem.i1 (0x90), ldelem.u1 (0x91),
//!                                   ldelem.i2 (0x92), stelem.i1 (0x9C),
//!                                   stelem.i2 (0x9D), ldelem.u4 (0x95),
//!                                   ldelem token (0xA3), stelem token (0xA4).
//!
//! Exercises:
//!   stelem.i1  (0x9C) — store 8-bit element into array
//!   ldelem.u1  (0x91) — load 8-bit element zero-extended to I4
//!   ldelem.i1  (0x90) — load 8-bit element sign-extended to I4
//!   stelem.i2  (0x9D) — store 16-bit element into array
//!   ldelem.i2  (0x92) — load 16-bit element sign-extended to I4
//!   ldelem.u4  (0x95) — load 32-bit element as unsigned I4
//!   stelem tok (0xA4) — store element (generic, takes TypeRef token)
//!   ldelem tok (0xA3) — load element (generic, takes TypeRef token)
//!
//! Fat header required (3 locals: byte[], short[], int32[]).
//! LocalVarSig: { 0x07, 0x03, 0x1D, 0x05, 0x1D, 0x06, 0x1D, 0x08 }
//!
//! TypeRef layout:
//!   TypeRef[1]: System.Console (AssemblyRef[2])
//!   TypeRef[2]: System.Object  (AssemblyRef[1])
//!   TypeRef[3]: System.Byte    (AssemblyRef[1]) → token 0x01000003
//!   TypeRef[4]: System.Int16   (AssemblyRef[1]) → token 0x01000004
//!   TypeRef[5]: System.Int32   (AssemblyRef[1]) → token 0x01000005
//!
//! Code layout (fat header at 0x248, code at 0x254, codeSize=86):
//!   offset  0-5:  nop×6
//!   offset  6-12: ldc.i4.1 / newarr Byte / stloc.0
//!   offset 13-19: ldc.i4.1 / newarr Int16 / stloc.1
//!   offset 20-26: ldc.i4.1 / newarr Int32 / stloc.2
//!   offset 27-31: ldloc.0 / ldc.i4.0 / ldc.i4.s 42 / stelem.i1  ← 0x9C at 0x273
//!   offset 32-34: ldloc.0 / ldc.i4.0 / ldelem.u1                ← 0x91 at 0x276
//!   offset 35:    pop
//!   offset 36-38: ldloc.0 / ldc.i4.0 / ldelem.i1                ← 0x90 at 0x27A
//!   offset 39:    pop
//!   offset 40-44: ldloc.1 / ldc.i4.0 / ldc.i4.s 42 / stelem.i2 ← 0x9D at 0x280
//!   offset 45-47: ldloc.1 / ldc.i4.0 / ldelem.i2                ← 0x92 at 0x283
//!   offset 48:    pop
//!   offset 49-53: ldloc.2 / ldc.i4.0 / ldc.i4.s 42 / stelem.i4
//!   offset 54-56: ldloc.2 / ldc.i4.0 / ldelem.u4                ← 0x95 at 0x28C
//!   offset 57:    pop
//!   offset 58-66: ldloc.2 / ldc.i4.0 / ldc.i4.s 42 / stelem Int32 ← 0xA4 at 0x292
//!   offset 67-73: ldloc.2 / ldc.i4.0 / ldelem Int32             ← 0xA3 at 0x299
//!   offset 74:    pop
//!   offset 75-76: nop×2 (pad so BSJB lands at 0x254+86=0x2AA)
//!   offset 77-85: ldloc.2 / ldc.i4.0 / ldelem.i4 → 42 / call / ret
//!
//! BSJB at 0x248 + 98 = 0x2AA  (fat=12 + code=86; no padding before metadata).
package Msil.SelfTestM82

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
  val outPath = "/tmp/lyric_msil_m82_stelem_ldelem_b.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sByte = internString(sh, "Byte")
  val sInt16 = internString(sh, "Int16")
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

  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // LocalVarSig: LOCAL_SIG + count=3 + SZARRAY×U1, SZARRAY×I2, SZARRAY×I4
  val lvW = bufNew()
  bufU1(lvW, 0x07)
  bufU1(lvW, 0x03)
  bufU1(lvW, 0x1D)
  bufU1(lvW, 0x05)
  bufU1(lvW, 0x1D)
  bufU1(lvW, 0x06)
  bufU1(lvW, 0x1D)
  bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

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

  val tokByte = 0x01000003
  val tokInt16 = 0x01000004
  val tokInt32 = 0x01000005

  val mbMain = newMethodBody()
  // Padding nops
  emitNop(mbMain)                          // offset  0
  emitNop(mbMain)                          // offset  1
  emitNop(mbMain)                          // offset  2
  emitNop(mbMain)                          // offset  3
  emitNop(mbMain)                          // offset  4
  emitNop(mbMain)                          // offset  5
  // Create byte[]
  emitLdc_I4_1(mbMain)                     // offset  6
  emitNewarr(mbMain, tokByte)              // offset  7-11
  emitStloc_0(mbMain)                      // offset 12
  // Create short[]
  emitLdc_I4_1(mbMain)                     // offset 13
  emitNewarr(mbMain, tokInt16)             // offset 14-18
  emitStloc_1(mbMain)                      // offset 19
  // Create int[]
  emitLdc_I4_1(mbMain)                     // offset 20
  emitNewarr(mbMain, tokInt32)             // offset 21-25
  emitStloc_2(mbMain)                      // offset 26
  // stelem.i1 + ldelem.u1 + ldelem.i1 on byte[]
  emitLdloc_0(mbMain)                      // offset 27
  emitLdc_I4_0(mbMain)                     // offset 28
  emitLdc_I4_S(mbMain, 42)                // offset 29-30
  emitStelem_I1(mbMain)                    // offset 31 ← 0x9C at 0x254+31=0x273
  emitLdloc_0(mbMain)                      // offset 32
  emitLdc_I4_0(mbMain)                     // offset 33
  emitLdelem_U1(mbMain)                    // offset 34 ← 0x91 at 0x254+34=0x276
  emitPop(mbMain)                          // offset 35
  emitLdloc_0(mbMain)                      // offset 36
  emitLdc_I4_0(mbMain)                     // offset 37
  emitLdelem_I1(mbMain)                    // offset 38 ← 0x90 at 0x254+38=0x27A
  emitPop(mbMain)                          // offset 39
  // stelem.i2 + ldelem.i2 on short[]
  emitLdloc_1(mbMain)                      // offset 40
  emitLdc_I4_0(mbMain)                     // offset 41
  emitLdc_I4_S(mbMain, 42)                // offset 42-43
  emitStelem_I2(mbMain)                    // offset 44 ← 0x9D at 0x254+44=0x280
  emitLdloc_1(mbMain)                      // offset 45
  emitLdc_I4_0(mbMain)                     // offset 46
  emitLdelem_I2(mbMain)                    // offset 47 ← 0x92 at 0x254+47=0x283
  emitPop(mbMain)                          // offset 48
  // stelem.i4 + ldelem.u4 on int[]
  emitLdloc_2(mbMain)                      // offset 49
  emitLdc_I4_0(mbMain)                     // offset 50
  emitLdc_I4_S(mbMain, 42)                // offset 51-52
  emitStelem_I4(mbMain)                    // offset 53 (stelem.i4, byte check not needed here)
  emitLdloc_2(mbMain)                      // offset 54
  emitLdc_I4_0(mbMain)                     // offset 55
  emitLdelem_U4(mbMain)                    // offset 56 ← 0x95 at 0x254+56=0x28C
  emitPop(mbMain)                          // offset 57
  // stelem (generic) + ldelem (generic) on int[]
  emitLdloc_2(mbMain)                      // offset 58
  emitLdc_I4_0(mbMain)                     // offset 59
  emitLdc_I4_S(mbMain, 42)                // offset 60-61
  emitStelem(mbMain, tokInt32)             // offset 62-66 ← 0xA4 at 0x254+62=0x292
  emitLdloc_2(mbMain)                      // offset 67
  emitLdc_I4_0(mbMain)                     // offset 68
  emitLdelem(mbMain, tokInt32)             // offset 69-73 ← 0xA3 at 0x254+69=0x299
  emitPop(mbMain)                          // offset 74
  emitNop(mbMain)                          // offset 75: pad so BSJB reaches 0x2AA
  emitNop(mbMain)                          // offset 76
  // print 42 from int[]
  emitLdloc_2(mbMain)                      // offset 77
  emitLdc_I4_0(mbMain)                     // offset 78
  emitLdelem_I4(mbMain)                    // offset 79 → 42
  emitCall(mbMain, 0x0A000001)            // offset 80-84
  emitRet(mbMain)                          // offset 85; codeSize=86

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  val t = newMetadataTables()
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sByte, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sInt16, typeNamespace = sSystem))
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
  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))
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

  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)
  check("entry_tok_ok", bs[0x214] == 0x01 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("stelem_i1_ok", bs[0x273] == 0x9C)
  check("ldelem_u1_ok", bs[0x276] == 0x91)
  check("ldelem_i1_ok", bs[0x27A] == 0x90)
  check("stelem_i2_ok", bs[0x280] == 0x9D)
  check("ldelem_i2_ok", bs[0x283] == 0x92)
  check("ldelem_u4_ok", bs[0x28C] == 0x95)
  check("stelem_tok_ok", bs[0x292] == 0xA4)
  check("ldelem_tok_ok", bs[0x299] == 0xA3)
  check("bsjb_ok", bs[0x2AA] == 0x42 and bs[0x2AB] == 0x53 and bs[0x2AC] == 0x4A and bs[0x2AD] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
