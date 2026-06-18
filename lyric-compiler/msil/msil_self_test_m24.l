//! msil_self_test_m24.l — Stage M24: instance methods + instance fields.
//!
//! Builds a PE with a class 'Counter' that has:
//!   - A Field row '_value' (int32, instance)
//!   - A constructor .ctor() that zeroes the field
//!   - An instance method Increment() that loads, adds 1, and stores _value
//!   - An instance method GetValue(): int that loads and returns _value
//!
//! Main() creates a Counter, calls Increment() three times via dup+call, then
//! calls GetValue() and passes the result to Console.WriteLine(int) → prints "3".
//!
//! New infrastructure exercised:
//!   Field table (0x04) — instance field '_value' owned by TypeDef[2]=Counter
//!   HASTHIS calling convention (0x20) — for .ctor, Increment, GetValue sigs
//!   ldfld (0x7B) / stfld (0x7D) — instance field access
//!   call with MethodDef token (0x06000002 / 0x06000003) — non-virtual instance call
//!   newobj with MethodDef token (0x06000001) — constructor in same assembly
//!   Three TypeDefs: <Module>, Counter, Hello (methodList / fieldList separations)
//!   MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME — required flags for .ctor
//!
//! Class layout:
//!   TypeDef[1]: <Module>   methodList=1, fieldList=1 → owns nothing
//!   TypeDef[2]: Counter    methodList=1, fieldList=1
//!                          → owns MethodDef[1..3] and Field[1]
//!   TypeDef[3]: Hello      methodList=4, fieldList=2 → owns MethodDef[4]=Main
//!
//! Entry point token: 0x06000004 (MethodDef[4] = Main).
//!
//! Signatures:
//!   .ctor():     HASTHIS(0x20), 0 params, void(0x01)   → {0x20,0x00,0x01}
//!   Increment(): HASTHIS(0x20), 0 params, void(0x01)   → {0x20,0x00,0x01}
//!   GetValue():  HASTHIS(0x20), 0 params, I4(0x08)     → {0x20,0x00,0x08}
//!   Main():      DEFAULT(0x00), 0 params, void(0x01)   → {0x00,0x00,0x01}
//!
//! Method bodies (all tiny, no locals):
//!
//! .ctor (codeSize=8): ldarg.0 / ldc.i4.0 / stfld 0x04000001 / ret
//!   hdr 0x22 at 0x248; code at 0x249
//!
//! Increment (codeSize=15): ldarg.0 / ldarg.0 / ldfld 0x04000001 /
//!   ldc.i4.1 / add / stfld 0x04000001 / ret
//!   hdr 0x3E at 0x251; code at 0x252
//!
//! GetValue (codeSize=7): ldarg.0 / ldfld 0x04000001 / ret
//!   hdr 0x1E at 0x261; code at 0x262
//!
//! Main (codeSize=34, tiny): newobj 0x06000001 /
//!   dup / call 0x06000002 / dup / call 0x06000002 / dup / call 0x06000002 /
//!   call 0x06000003 / call 0x0A000001 / ret
//!   hdr 0x8A at 0x269; code at 0x26A
//!
//!   offset 0:  73 01 00 00 06   newobj .ctor  [5]   → [c]
//!   offset 5:  25               dup           [1]   → [c, c]
//!   offset 6:  28 02 00 00 06   call Incr     [5]   → [c]
//!   offset 11: 25               dup           [1]   → [c, c]
//!   offset 12: 28 02 00 00 06   call Incr     [5]   → [c]
//!   offset 17: 25               dup           [1]   → [c, c]
//!   offset 18: 28 02 00 00 06   call Incr     [5]   → [c]
//!   offset 23: 28 03 00 00 06   call GetValue [5]   → [3]
//!   offset 28: 28 01 00 00 0A   call WriteLn  [5]   → []
//!   offset 33: 2A               ret           [1]
//!   codeSize = 34; (34<<2)|2 = 138 = 0x8A
//!
//! BSJB at 0x269 + 1 + 34 = 0x28C  — wait: Main body = 1+34=35 bytes
//! So Main at 0x269, ends at 0x269+35=0x28C; BSJB at 0x28C.
//!
//! CLR execution: .ctor zeros _value; each Increment adds 1; GetValue returns 3.
package Msil.SelfTestM24

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
  val outPath = "/tmp/lyric_msil_m24_instance.dll"

  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sMain = internString(sh, "Main")
  val sCounter = internString(sh, "Counter")
  val sCtor = internString(sh, ".ctor")
  val sIncr = internString(sh, "Increment")
  val sGetValue = internString(sh, "GetValue")
  val sValue = internString(sh, "_value")
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

  // HASTHIS void() — for .ctor and Increment
  val hasthisVoidW = bufNew()
  bufU1(hasthisVoidW, 0x20)
  bufU1(hasthisVoidW, 0x00)
  bufU1(hasthisVoidW, 0x01)
  val sigHasthisVoid = internBlob(bh, "hasthis_void", bufToList(hasthisVoidW))

  // HASTHIS I4() — for GetValue
  val hasthisI4W = bufNew()
  bufU1(hasthisI4W, 0x20)
  bufU1(hasthisI4W, 0x00)
  bufU1(hasthisI4W, 0x08)
  val sigHasthisI4 = internBlob(bh, "hasthis_i4", bufToList(hasthisI4W))

  // DEFAULT void() — for Main
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Field sig for _value: FIELD(0x06), I4(0x08)
  val fldSigW = bufNew()
  bufU1(fldSigW, 0x06)
  bufU1(fldSigW, 0x08)
  val sigField = internBlob(bh, "field_i4", bufToList(fldSigW))

  // Console.WriteLine(int): DEFAULT, 1 param, void, I4
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

  // ── Build method bodies ───────────────────────────────────────────────────

  // .ctor: ldarg.0 / ldc.i4.0 / stfld _value / ret
  val mbCtor = newMethodBody()
  emitLdarg_0(mbCtor)
  emitLdc_I4_0(mbCtor)
  emitStfld(mbCtor, 0x04000001)
  emitRet(mbCtor)

  // Increment: ldarg.0 / ldarg.0 / ldfld _value / ldc.i4.1 / add / stfld _value / ret
  val mbIncr = newMethodBody()
  emitLdarg_0(mbIncr)
  emitLdarg_0(mbIncr)
  emitLdfld(mbIncr, 0x04000001)
  emitLdc_I4_1(mbIncr)
  emitAdd(mbIncr)
  emitStfld(mbIncr, 0x04000001)
  emitRet(mbIncr)

  // GetValue: ldarg.0 / ldfld _value / ret
  val mbGet = newMethodBody()
  emitLdarg_0(mbGet)
  emitLdfld(mbGet, 0x04000001)
  emitRet(mbGet)

  // Main: newobj .ctor / dup / call Increment (×3) / call GetValue / call WriteLine / ret
  val mbMain = newMethodBody()
  emitNewobj(mbMain, 0x06000001)    // new Counter → [c]
  emitDup(mbMain)                   // [c, c]
  emitCall(mbMain, 0x06000002)      // Increment() → [c]
  emitDup(mbMain)                   // [c, c]
  emitCall(mbMain, 0x06000002)      // Increment() → [c]
  emitDup(mbMain)                   // [c, c]
  emitCall(mbMain, 0x06000002)      // Increment() → [c]
  emitCall(mbMain, 0x06000003)      // GetValue() → [3]
  emitCall(mbMain, 0x0A000001)      // Console.WriteLine(int) → []
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbCtor)
  bodies.add(mbIncr)
  bodies.add(mbGet)
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaCtorV = rvas[0]
  val rvaIncrV = rvas[1]
  val rvaGetV = rvas[2]
  val rvaMainV = rvas[3]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module>  methodList=1, fieldList=1 → owns nothing
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  // TypeDef[2]: Counter   methodList=1, fieldList=1 → owns MethodDef[1..3] + Field[1]
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sCounter,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 1
    )
  )
  // TypeDef[3]: Hello     methodList=4, fieldList=2 → owns MethodDef[4]; no fields
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sHello,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 2,
      methodList = 4
    )
  )

  // Field[1]: Counter._value  (int32, instance)
  addField(t, FieldRow(flags = 0, name = sValue, signature = sigField))

  // MethodDef[1]: Counter..ctor() — SpecialName + RTSpecialName required
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaCtorV,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name = sCtor,
      signature = sigHasthisVoid,
      paramList = 1
    )
  )
  // MethodDef[2]: Counter.Increment()
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaIncrV,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG,
      name = sIncr,
      signature = sigHasthisVoid,
      paramList = 1
    )
  )
  // MethodDef[3]: Counter.GetValue(): int
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaGetV,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG,
      name = sGetValue,
      signature = sigHasthisI4,
      paramList = 1
    )
  )
  // MethodDef[4]: Hello.Main()
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaMainV,
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
    entryPointToken = 0x06000004,
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
  // Entry point token = MethodDef[4] = 0x06000004
  check("entry_tok_ok", bs[0x214] == 0x04 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // .ctor tiny header at 0x248: (8<<2)|2 = 34 = 0x22
  check("ctor_hdr_ok", bs[0x248] == 0x22)

  // stfld (0x7D) in .ctor at code offset 2 = file 0x24B
  // ldarg.0[1] = offset 0; ldc.i4.0[1] = offset 1; stfld[5] starts at offset 2
  check("ctor_stfld_ok", bs[0x24B] == 0x7D)

  // Increment tiny header at 0x251: (15<<2)|2 = 62 = 0x3E
  check("incr_hdr_ok", bs[0x251] == 0x3E)

  // ldfld (0x7B) in Increment at code offset 2 = file 0x256
  // ldarg.0[1]=0; ldarg.0[1]=1; ldfld[5] at 2 → file 0x252+2=0x254
  check("ldfld_ok", bs[0x254] == 0x7B)

  // stfld (0x7D) in Increment at code offset 8 = file 0x25A
  // ldfld(5b)=2-6; ldc.i4.1(1)=7; add(1)=8... wait:
  // offset 0: ldarg.0(1)
  // offset 1: ldarg.0(1)
  // offset 2: ldfld(5) = offsets 2-6
  // offset 7: ldc.i4.1(1)
  // offset 8: add(1)
  // offset 9: stfld(5) = offsets 9-13 → file 0x252+9=0x25B
  check("stfld_ok", bs[0x25B] == 0x7D)

  // GetValue tiny header at 0x261: (7<<2)|2 = 30 = 0x1E
  check("get_hdr_ok", bs[0x261] == 0x1E)

  // ldfld (0x7B) in GetValue at code offset 1 = file 0x263
  // ldarg.0[1]=0; ldfld at 1 → file 0x262+1=0x263
  check("get_ldfld_ok", bs[0x263] == 0x7B)

  // Main tiny header at 0x269: (34<<2)|2 = 138 = 0x8A
  check("main_hdr_ok", bs[0x269] == 0x8A)

  // newobj (0x73) at Main code offset 0 = file 0x26A
  check("newobj_ok", bs[0x26A] == 0x73)

  // dup (0x25) at Main code offset 5 = file 0x26F
  check("dup_ok", bs[0x26F] == 0x25)

  // call 0x06000002 at Main code offset 6 = file 0x270: 28 02 00 00 06
  check(
    "call_incr_ok",
    bs[0x270] == 0x28 and bs[0x271] == 0x02 and bs[0x272] == 0 and bs[0x273] == 0 and bs[0x274] == 0x06
  )

  // BSJB at 0x269 + 35 = 0x28C
  check("bsjb_ok", bs[0x28C] == 0x42 and bs[0x28D] == 0x53 and bs[0x28E] == 0x4A and bs[0x28F] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
