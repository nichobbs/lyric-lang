// msil_self_test_m45.l — Stage M45: initblk + cpblk.
//
// Builds a PE that exercises:
//   initblk  (0xFE 0x18) — fill n bytes at address with a byte value
//   cpblk    (0xFE 0x17) — copy n bytes from source to destination address
//
// Two I4 locals to provide managed pointers without needing localloc:
//   local 0 — used as src buffer for cpblk (also target for initblk)
//   local 1 — used as dst buffer for cpblk
//
// Code flow:
//   Part 1 — initblk:
//     ldloca.s 0 / dup / ldc.i4.s 42 / ldc.i4.s 1 / initblk
//       → fills 1 byte at &local0 with value 42 (0x2A)
//     ldind.u1 → read back unsigned byte = 42
//     call Console.WriteLine(int) → prints 42
//
//   Part 2 — cpblk:
//     ldc.i4.s 42 / stloc.0  → local0 = 42
//     ldloca.s 1 / ldloca.s 0 / ldc.i4.s 4 / cpblk
//       → copies 4 bytes from &local0 to &local1
//     ldloc.1 → load local1 (= 42)
//     call Console.WriteLine(int) → prints 42
//
//   ret
//
// codeSize = 33. Fat header (12 bytes) at 0x248. Code at 0x254.
//   LocalVarSig {0x07, 0x02, 0x08, 0x08} (two I4 locals).
//
// initblk (0xFE 0x18) at code offset 7  = file 0x25B (0x254 + 7).
// cpblk   (0xFE 0x17) at code offset 24 = file 0x26C (0x254 + 24).
// BSJB at 0x248 + 12 + 33 = 0x275.
//
// CLR: initblk fills 1 byte with 42 → prints "42"; cpblk copies int 42 → prints "42".

package Msil.SelfTestM45

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
  val outPath = "/tmp/lyric_msil_m45_blk.dll"

  val sh       = newStringHeap()
  val sModule  = internString(sh, "<Module>")
  val sHello   = internString(sh, "Hello")
  val sMain    = internString(sh, "Main")
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

  val voidSigW = bufNew()
  bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x00); bufU1(voidSigW, 0x01)
  val sigVoid = internBlob(bh, "void_sig", bufToList(voidSigW))

  val wlSigW = bufNew()
  bufU1(wlSigW, 0x00); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x01); bufU1(wlSigW, 0x08)
  val sigWriteLineInt = internBlob(bh, "wl_int_sig", bufToList(wlSigW))

  // Two I4 locals.
  val lvW = bufNew()
  bufU1(lvW, 0x07); bufU1(lvW, 0x02); bufU1(lvW, 0x08); bufU1(lvW, 0x08)
  val localVarSig = internBlob(bh, "locals_sig", bufToList(lvW))

  val keyW = bufNew()
  bufU1(keyW, 0xB0); bufU1(keyW, 0x3F); bufU1(keyW, 0x5F); bufU1(keyW, 0x7F)
  bufU1(keyW, 0x11); bufU1(keyW, 0xD5); bufU1(keyW, 0x0A); bufU1(keyW, 0x3A)
  val keyToken = internBlob(bh, "ms_key", bufToList(keyW))

  // ── Build method body ─────────────────────────────────────────────────────
  val mbMain = newMethodBody()

  // Part 1: initblk — fill 1 byte at &local0 with 42, read back as u1
  emitLdloca_S(mbMain, 0)       // &local0
  emitDup(mbMain)               // &local0, &local0
  emitLdc_I4_S(mbMain, 42)      // &local0, &local0, 42
  emitLdc_I4_S(mbMain, 1)       // &local0, &local0, 42, 1
  emitInitblk(mbMain)           // fills 1 byte; &local0 remains
  emitLdind_U1(mbMain)          // read unsigned byte = 42
  emitCall(mbMain, 0x0A000001)  // print 42

  // Part 2: cpblk — copy 4 bytes from &local0 to &local1
  emitLdc_I4_S(mbMain, 42)
  emitStloc_0(mbMain)           // local0 = 42
  emitLdloca_S(mbMain, 1)       // &local1 (dst)
  emitLdloca_S(mbMain, 0)       // &local0 (src)
  emitLdc_I4_S(mbMain, 4)       // size = 4
  emitCpblk(mbMain)             // copies 4 bytes from &local0 to &local1
  emitLdloc_1(mbMain)           // load local1 (= 42)
  emitCall(mbMain, 0x0A000001)  // print 42

  emitRet(mbMain)

  val bodies: List[MethodBody] = newList()
  bodies.add(mbMain)
  val rvas    = methodBodyRvas(bodies)
  val rvaMain = rvas[0]

  // ── Build MetadataTables ──────────────────────────────────────────────────
  val t = newMetadataTables()

  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(2), typeName = sConsole, typeNamespace = sSystem))
  addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = sObject, typeNamespace = sSystem))

  addTypeDef(t, TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1))
  addTypeDef(t, TypeDefRow(flags = TDF_PUBLIC, typeName = sHello, typeNamespace = 0, extends = tdrTypeRef(2), fieldList = 1, methodList = 1))

  addMethodDef(t, MethodDefRow(rva = rvaMain, implFlags = 0, flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG, name = sMain, signature = sigVoid, paramList = 1))

  val sigIdx = addStandAloneSig(t, StandAloneSigRow(signature = localVarSig))
  mbSetLocalSig(mbMain, standaloneToken(sigIdx))

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

  // Fat header at 0x248
  check("fat_hdr_ok", bs[0x248] == 0x13 and bs[0x249] == 0x30)
  check("local_sig_ok", bs[0x250] == 0x01 and bs[0x251] == 0 and bs[0x252] == 0 and bs[0x253] == 0x11)

  // initblk (0xFE 0x18) at code offset 7 = file 0x25B
  check("initblk_ok", bs[0x25B] == 0xFE and bs[0x25C] == 0x18)

  // cpblk (0xFE 0x17) at code offset 24 = file 0x26C
  check("cpblk_ok", bs[0x26C] == 0xFE and bs[0x26D] == 0x17)

  // BSJB at 0x248 + 12 + 33 = 0x275
  check("bsjb_ok",
    bs[0x275] == 0x42 and bs[0x276] == 0x53 and
    bs[0x277] == 0x4A and bs[0x278] == 0x42)

  match writeBytes(outPath, bs) {
    case Ok(_)  -> println("wrote_pe=true")
    case Err(_) -> println("wrote_pe=false")
  }
}
