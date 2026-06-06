//! msil_self_test_m62.l — Stage M62: signed integer conversions.
//!
//! Exercises:
//!   conv.i1 (0x67) — truncate to int8,  sign-extend to int32
//!   conv.i2 (0x68) — truncate to int16, sign-extend to int32
//!   conv.i4 (0x69) — truncate to int32
//!   conv.i8 (0x6A) — sign-extend to int64
//!
//! Code flow:
//!   ldc.i4.s 42  →  42 (i4)
//!   conv.i1      →  42 (sign-extended i1 → i4)
//!   conv.i2      →  42 (sign-extended i2 → i4... but conv.i2 leaves i4 on stack)
//!   conv.i4      →  42 (i4)
//!   conv.i8      →  42 (i8 / long)
//!   conv.i4      →  42 (back to i4 for the call)
//!   call Console.WriteLine(int32) / ret  → prints "42"
//!
//! codeSize = 13.  Tiny header (1 byte) at 0x248.  Code at 0x249.
//!   conv.i1 (0x67) at code offset 2 = file 0x24B.
//!   conv.i2 (0x68) at code offset 3 = file 0x24C.
//!   conv.i4 (0x69) at code offset 4 = file 0x24D.
//!   conv.i8 (0x6A) at code offset 5 = file 0x24E.
//! BSJB at 0x249 + 13 = 0x256.
//!
//! Tiny header byte = (13 << 2) | 2 = 0x36.
package Msil.SelfTestM62

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
  val outPath = "/tmp/lyric_msil_m62_conv_signed.dll"

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

  emitLdc_I4_S(mbMain, 42)     // push 42
  emitConv_I1(mbMain)           // 42 as i1 → 42 (fits in i1)
  emitConv_I2(mbMain)           // 42 as i2 → 42 (fits in i2)
  emitConv_I4(mbMain)           // 42 as i4 → 42
  emitConv_I8(mbMain)           // 42 as i8 → 42L
  emitConv_I4(mbMain)           // back to i4 → 42
  emitCall(mbMain, 0x0A000001)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
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

  // Tiny header at 0x248: (13 << 2) | 2 = 0x36
  check("tiny_hdr_ok", bs[0x248] == 0x36)

  // conv.i1 (0x67) at code offset 2 = file 0x24B
  check("conv_i1_ok", bs[0x24B] == 0x67)

  // conv.i2 (0x68) at code offset 3 = file 0x24C
  check("conv_i2_ok", bs[0x24C] == 0x68)

  // conv.i4 (0x69) at code offset 4 = file 0x24D
  check("conv_i4_ok", bs[0x24D] == 0x69)

  // conv.i8 (0x6A) at code offset 5 = file 0x24E
  check("conv_i8_ok", bs[0x24E] == 0x6A)

  // BSJB at 0x249 + 13 = 0x256
  check("bsjb_ok", bs[0x256] == 0x42 and bs[0x257] == 0x53 and bs[0x258] == 0x4A and bs[0x259] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
