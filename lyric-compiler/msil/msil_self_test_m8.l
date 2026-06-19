//! msil_self_test_m8.l — Stage M8: newobj + instance fields (ldfld / stfld).
//!
//! Builds a PE with a class `Hello` that has:
//!   Field[1]: x_val (int32 instance field)
//!   MethodDef[1]: .ctor(int v) — HASTHIS; stores v in x_val
//!   MethodDef[2]: Main()       — STATIC; creates Hello(99), reads x_val, prints it
//!
//! CIL for .ctor(int v):
//!   ldarg.0             — push this
//!   ldarg.1             — push v
//!   stfld 0x04000001    — this.x_val = v
//!   ret
//!
//! CIL for Main():
//!   ldc.i4.s 99         — push 99
//!   newobj 0x06000001   — allocates Hello, calls .ctor(99), pushes ref
//!   ldfld  0x04000001   — pop Hello ref, push x_val (= 99)
//!   call   0x0A000001   — Console.WriteLine(int)
//!   ret
//!
//! Layout (FIRST_METHOD_RVA = 0x2048 → file offset 0x248):
//!   .ctor body (9 bytes:  1-byte tiny header + 8-byte code) at file 0x248
//!   Main  body (19 bytes: 1-byte tiny header + 18-byte code) at file 0x251
//!   Metadata BSJB root at file 0x264 (= 0x248 + 9 + 19)
//!
//! .ctor body:
//!   [0x248] 0x22 — tiny header (codeSize=8; (8<<2)|2 = 0x22)
//!   [0x249] 0x02 — ldarg.0
//!   [0x24A] 0x03 — ldarg.1
//!   [0x24B] 0x7D — stfld
//!   [0x24C..0x24F] 01 00 00 04  (Field token 0x04000001 LE)
//!   [0x250] 0x2A — ret
//!
//! Main body:
//!   [0x251] 0x4A — tiny header (codeSize=18; (18<<2)|2 = 0x4A)
//!   [0x252] 0x1F — ldc.i4.s
//!   [0x253] 0x63 — 99
//!   [0x254] 0x73 — newobj
//!   [0x255..0x258] 01 00 00 06  (MethodDef token 0x06000001 LE)
//!   [0x259] 0x7B — ldfld
//!   [0x25A..0x25D] 01 00 00 04  (Field token 0x04000001 LE)
//!   [0x25E] 0x28 — call
//!   [0x25F..0x262] 01 00 00 0A  (MemberRef token 0x0A000001 LE)
//!   [0x263] 0x2A — ret
//!
//! CLR execution prints: "99"
package Msil.SelfTestM8

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
  val outPath = "/tmp/lyric_msil_m8_newobj.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sHello = internString(sh, "Hello")
  val sCtor = internString(sh, ".ctor")
  val sXVal = internString(sh, "x_val")
  val sMain = internString(sh, "Main")
  val sSystem = internString(sh, "System")
  val sConsole = internString(sh, "Console")
  val sRuntime = internString(sh, "System.Runtime")
  val sConsoleAsm = internString(sh, "System.Console")
  val sObject = internString(sh, "Object")
  val sWriteLine = internString(sh, "WriteLine")

  // ── Build #GUID heap ──────────────────────────────────────────────────────
  val gh = newGuidHeap()
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))

  // ── Build #US heap (empty — no string literals) ───────────────────────────
  val uh = newUsHeap()

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  // .ctor(int v) signature: HASTHIS (0x20), 1 param, void return, I4 param
  val ctorSigW = bufNew()
  bufU1(ctorSigW, 0x20)
  bufU1(ctorSigW, 0x01)
  bufU1(ctorSigW, 0x01)
  bufU1(ctorSigW, 0x08)
  val sigCtor = internBlob(bh, "ctor_sig", bufToList(ctorSigW))

  // void () signature: DEFAULT, 0 params, void return
  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x00)
  bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  // Console.WriteLine(int) signature: DEFAULT, 1 param, void return, I4
  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x01)
  bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // FieldSig for int32 instance field: FIELD marker (0x06) + ELEMENT_TYPE_I4 (0x08)
  val fieldSigW = bufNew()
  bufU1(fieldSigW, 0x06)
  bufU1(fieldSigW, 0x08)
  val sigField = internBlob(bh, "field_sig", bufToList(fieldSigW))

  // Microsoft framework assemblies public key token: b03f5f7f11d50a3a
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

  // .ctor(int v): ldarg.0, ldarg.1, stfld x_val, ret
  val mbCtor = newMethodBody()
  emitLdarg_0(mbCtor)
  emitLdarg_1(mbCtor)
  emitStfld(mbCtor, 0x04000001)    // Field[1] = x_val
  emitRet(mbCtor)

  // Main(): ldc.i4.s 99, newobj .ctor, ldfld x_val, call Console.WriteLine(int), ret
  val mbMain = newMethodBody()
  emitLdc_I4_S(mbMain, 99)
  emitNewobj(mbMain, 0x06000001)   // MethodDef[1] = .ctor
  emitLdfld(mbMain, 0x04000001)    // Field[1] = x_val
  emitCall(mbMain, 0x0A000001)     // MemberRef[1] = Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbCtor)
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaCtor = rvas[0]
  val rvaMain = rvas[1]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console (in System.Console.dll = AssemblyRef[2])
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object (in System.Runtime.dll = AssemblyRef[1])
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module> — no fields, no methods
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  // TypeDef[2]: Hello extends System.Object — owns Field[1] and MethodDef[1..2]
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

  // Field[1]: x_val — public int32 instance field
  addField(t, FieldRow(flags = FDA_PUBLIC, name = sXVal, signature = sigField))

  // MethodDef[1]: .ctor(int v) — HASTHIS instance constructor
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaCtor,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name = sCtor,
      signature = sigCtor,
      paramList = 1
    )
  )

  // MethodDef[2]: Main() — STATIC entry point
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

  // AssemblyRef[1]: System.Runtime (hosts System.Object)
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

  // AssemblyRef[2]: System.Console (hosts System.Console)
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

  // ── Assemble PE ───────────────────────────────────────────────────────────
  val inp = AssemblerInput(
    entryPointToken = 0x06000002,
    // Main = MethodDef[2]
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

  // DOS MZ magic
  check("dos_ok", bs[0] == 0x4D and bs[1] == 0x5A)

  // PE\0\0 signature at 0x80
  check("pe_sig_ok", bs[0x80] == 0x50 and bs[0x81] == 0x45 and bs[0x82] == 0 and bs[0x83] == 0)

  // CLR header cb=72 at 0x200
  check("clr_cb_ok", bs[0x200] == 72 and bs[0x201] == 0)

  // EntryPointToken = 0x06000002 (Main) at 0x214
  check("entry_tok_ok", bs[0x214] == 0x02 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // .ctor tiny header 0x22 at 0x248 (codeSize=8)
  check("ctor_hdr_ok", bs[0x248] == 0x22)

  // .ctor: stfld (0x7D) at 0x24B; token LE: 01 at 0x24C, 04 at 0x24F
  check("ctor_stfld_ok", bs[0x24B] == 0x7D and bs[0x24C] == 0x01 and bs[0x24F] == 0x04)

  // Main tiny header 0x4A at 0x251 (codeSize=18)
  check("main_hdr_ok", bs[0x251] == 0x4A)

  // newobj (0x73) at 0x254; token LE: 01 at 0x255, 06 at 0x258
  check("newobj_ok", bs[0x254] == 0x73 and bs[0x255] == 0x01 and bs[0x258] == 0x06)

  // ldfld (0x7B) at 0x259; token LE: 01 at 0x25A, 04 at 0x25D
  check("ldfld_ok", bs[0x259] == 0x7B and bs[0x25A] == 0x01 and bs[0x25D] == 0x04)

  // BSJB magic at 0x264
  check("bsjb_ok", bs[0x264] == 0x42 and bs[0x265] == 0x53 and bs[0x266] == 0x4A and bs[0x267] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
