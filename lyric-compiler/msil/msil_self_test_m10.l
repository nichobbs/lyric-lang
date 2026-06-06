//! msil_self_test_m10.l — Stage M10: virtual method dispatch (callvirt).
//!
//! Builds a PE with an abstract base class and a concrete subclass:
//!   TypeDef[2] Base — abstract class; MethodDef[1] GetValue(): int (abstract virtual, rva=0)
//!   TypeDef[3] Impl — extends Base; owns MethodDef[2] .ctor() and MethodDef[3] GetValue(): int
//!   TypeDef[4] Hello — Main(); creates Impl, calls GetValue via callvirt, prints 77
//!
//! Virtual dispatch: callvirt uses MethodDef[1] (Base.GetValue) as the token
//! but the CLR dispatches to Impl.GetValue (the override) because Impl's vtable
//! slot points to it.  This mirrors how Lyric interface and union dispatch is emitted.
//!
//! MethodDef layout:
//!   MethodDef[1] Base.GetValue — abstract; flags = VIRTUAL|NEWSLOT|ABSTRACT; rva = 0
//!   MethodDef[2] Impl..ctor    — HASTHIS; body: ret only (1 byte)
//!   MethodDef[3] Impl.GetValue — virtual override; body: ldc.i4.s 77, ret (3 bytes)
//!   MethodDef[4] Hello.Main   — STATIC entry point; body: newobj + callvirt + call + ret
//!
//! Bodies for methodBodyRvas (abstract method has no body):
//!   bodies[0] → Impl..ctor   at file 0x248  (2 bytes: 1 header + 1 code)
//!   bodies[1] → Impl.GetValue at file 0x24A  (4 bytes: 1 header + 3 code)
//!   bodies[2] → Hello.Main  at file 0x24E  (17 bytes: 1 header + 16 code)
//!   Metadata BSJB root at file 0x25F (= 0x248 + 2 + 4 + 17)
//!
//! .ctor body:
//!   [0x248] 0x06 — tiny header (codeSize=1)
//!   [0x249] 0x2A — ret
//!
//! Impl.GetValue body:
//!   [0x24A] 0x0E — tiny header (codeSize=3)
//!   [0x24B] 0x1F — ldc.i4.s
//!   [0x24C] 0x4D — 77
//!   [0x24D] 0x2A — ret
//!
//! Main body:
//!   [0x24E] 0x42 — tiny header (codeSize=16)
//!   [0x24F] 0x73 — newobj
//!   [0x250..0x253] 02 00 00 06  (MethodDef token 0x06000002 = .ctor, LE)
//!   [0x254] 0x6F — callvirt
//!   [0x255..0x258] 01 00 00 06  (MethodDef token 0x06000001 = Base.GetValue, LE)
//!   [0x259] 0x28 — call
//!   [0x25A..0x25D] 01 00 00 0A  (MemberRef token 0x0A000001 = Console.WriteLine(int), LE)
//!   [0x25E] 0x2A — ret
//!
//! CLR execution prints: "77"
package Msil.SelfTestM10

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
  val outPath = "/tmp/lyric_msil_m10_callvirt.dll"

  // ── Build #Strings heap ───────────────────────────────────────────────────
  val sh = newStringHeap()
  val sModule = internString(sh, "<Module>")
  val sBase = internString(sh, "Base")
  val sImpl = internString(sh, "Impl")
  val sHello = internString(sh, "Hello")
  val sCtor = internString(sh, ".ctor")
  val sGetValue = internString(sh, "GetValue")
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

  // ── Build #US heap (empty) ────────────────────────────────────────────────
  val uh = newUsHeap()

  // ── Build #Blob heap ──────────────────────────────────────────────────────
  val bh = newBlobHeap()

  // int () instance method signature: HASTHIS, 0 params, I4 return
  val intSigW = bufNew()
  bufU1(intSigW, 0x20)
  bufU1(intSigW, 0x00)
  bufU1(intSigW, 0x08)
  val sigInt = internBlob(bh, "int_sig", bufToList(intSigW))

  // .ctor() signature: HASTHIS, 0 params, void return
  val ctorSigW = bufNew()
  bufU1(ctorSigW, 0x20)
  bufU1(ctorSigW, 0x00)
  bufU1(ctorSigW, 0x01)
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

  // ── Build method bodies (abstract GetValue has no body) ───────────────────

  // Impl..ctor(): ret only — codeSize=1, tiny header 0x06
  val mbCtor = newMethodBody()
  emitRet(mbCtor)

  // Impl.GetValue(): ldc.i4.s 77, ret — codeSize=3, tiny header 0x0E
  val mbGetValue = newMethodBody()
  emitLdc_I4_S(mbGetValue, 77)
  emitRet(mbGetValue)

  // Hello.Main(): newobj .ctor, callvirt Base.GetValue, call Console.WriteLine(int), ret
  val mbMain = newMethodBody()
  emitNewobj(mbMain, 0x06000002)  // MethodDef[2] = Impl..ctor
  emitCallvirt(mbMain, 0x06000001)  // MethodDef[1] = Base.GetValue (dispatches to Impl.GetValue)
  emitCall(mbMain, 0x0A000001)  // MemberRef[1] = Console.WriteLine(int)
  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbCtor)
  bodies.add(mbGetValue)
  bodies.add(mbMain)
  val rvas = methodBodyRvas(bodies)
  val rvaCtor = rvas[0]
  val rvaGetValue = rvas[1]
  val rvaMain = rvas[2]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // TypeRef[1]: System.Console
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  // TypeRef[2]: System.Object
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  // TypeDef[1]: <Module>
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )
  // TypeDef[2]: Base — abstract class; owns MethodDef[1]
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_ABSTRACT,
      typeName = sBase,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 1
    )
  )
  // TypeDef[3]: Impl — concrete; owns MethodDef[2..3]
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sImpl,
      typeNamespace = 0,
      extends = tdrTypeDef(2),
      fieldList = 1,
      methodList = 2
    )
  )
  // TypeDef[4]: Hello — owns MethodDef[4]
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC,
      typeName = sHello,
      typeNamespace = 0,
      extends = tdrTypeRef(2),
      fieldList = 1,
      methodList = 4
    )
  )

  // MethodDef[1]: Base.GetValue — abstract virtual; rva=0 (no body)
  addMethodDef(
    t,
    MethodDefRow(
      rva = 0,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_VIRTUAL + MDA_NEW_SLOT + MDA_ABSTRACT,
      name = sGetValue,
      signature = sigInt,
      paramList = 1
    )
  )

  // MethodDef[2]: Impl..ctor — HASTHIS constructor
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

  // MethodDef[3]: Impl.GetValue — virtual override (no NEWSLOT = override)
  addMethodDef(
    t,
    MethodDefRow(
      rva = rvaGetValue,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_VIRTUAL,
      name = sGetValue,
      signature = sigInt,
      paramList = 1
    )
  )

  // MethodDef[4]: Hello.Main — STATIC entry point
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

  // AssemblyRef[1]: System.Runtime
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

  // AssemblyRef[2]: System.Console
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
    entryPointToken = 0x06000004,
    // Main = MethodDef[4]
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

  // EntryPointToken = 0x06000004 (Main) at 0x214
  check("entry_tok_ok", bs[0x214] == 0x04 and bs[0x215] == 0 and bs[0x216] == 0 and bs[0x217] == 0x06)

  // Impl..ctor tiny header 0x06 at 0x248 (codeSize=1: just ret)
  check("ctor_hdr_ok", bs[0x248] == 0x06)

  // Impl.GetValue tiny header 0x0E at 0x24A (codeSize=3)
  check("getv_hdr_ok", bs[0x24A] == 0x0E)

  // ldc.i4.s (0x1F) at 0x24B, value 77 (0x4D) at 0x24C
  check("getv_ldc_ok", bs[0x24B] == 0x1F and bs[0x24C] == 0x4D)

  // Main tiny header 0x42 at 0x24E (codeSize=16)
  check("main_hdr_ok", bs[0x24E] == 0x42)

  // newobj (0x73) at 0x24F; .ctor token LE: 02 at 0x250, 06 at 0x253
  check("newobj_ok", bs[0x24F] == 0x73 and bs[0x250] == 0x02 and bs[0x253] == 0x06)

  // callvirt (0x6F) at 0x254; Base.GetValue token LE: 01 at 0x255, 06 at 0x258
  check("callvirt_ok", bs[0x254] == 0x6F and bs[0x255] == 0x01 and bs[0x258] == 0x06)

  // BSJB at 0x25F
  check("bsjb_ok", bs[0x25F] == 0x42 and bs[0x260] == 0x53 and bs[0x261] == 0x4A and bs[0x262] == 0x42)

  // ── Write PE and signal completion ────────────────────────────────────────
  match writeBytes(outPath, bs) {
    case Ok(_) -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
