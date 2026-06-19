//! msil_self_test_m2c.l — Stage M2c self-test for the metadata table model.
//!
//! Exercises Msil.Tables: row records, MetadataTables accumulator, row-index
//! allocators (addXxx), coded-index helpers, and the #~ stream serializer.
//!
//! Run in CI via native `lyric test` (D-progress-474 / #66), linking the
//! already-compiled compiler DLLs as restored deps:
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_self_test_m2c.l
//!
//! Regression coverage for #3086: `Msil.Tables` exports module-level
//! `pub val` flag constants (MIA_*, MDA_*, TDF_*, HASH_ALG_SHA1, ASF_NONE);
//! the F#-emitted stage-1 metadata omits `pub val` decls, so this test
//! links the self-hosted-emitted compiler DLLs staged under
//! `<libdir>/selfhosted` — without them every constant reference is a
//! T0020 "unknown name".
@test_module
package Msil.SelfTestM2c

import Msil.Tables
import Msil.Kernel
import Std.Core
import Std.Collections
import Std.Testing

test "row-index allocators return 1-based indices" {
  val t = newMetadataTables()

  // Add two TypeRef rows; should get indices 1 and 2.
  val tr1 = addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = 10, typeNamespace = 20))
  val tr2 = addTypeRef(t, TypeRefRow(resolutionScope = rsAssemblyRef(1), typeName = 11, typeNamespace = 20))

  // Add one MethodDef row; should get index 1.
  val md1 = addMethodDef(
    t,
    MethodDefRow(
      rva = 0,
      implFlags = MIA_IL + MIA_MANAGED,
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = 30,
      signature = 40,
      paramList = 1
    )
  )

  assertEqualInt(tr1, 1, "first TypeRef index")
  assertEqualInt(tr2, 2, "second TypeRef index")
  assertEqualInt(md1, 1, "first MethodDef index")
  assertEqualInt(t.typeRefs.count, 2, "TypeRef row count")
  assertEqualInt(t.methodDefs.count, 1, "MethodDef row count")
}

test "coded-index helpers encode tag bits" {
  // ResolutionScope: tag bits=2
  //   rsModule(1) = 1*4+0 = 4
  //   rsAssemblyRef(2) = 2*4+2 = 10
  //   rsTypeRef(3) = 3*4+3 = 15
  assertEqualInt(rsModule(1), 4, "rsModule")
  assertEqualInt(rsAssemblyRef(2), 10, "rsAssemblyRef")
  assertEqualInt(rsTypeRef(3), 15, "rsTypeRef")

  // TypeDefOrRef: tag bits=2
  //   tdrTypeDef(1) = 1*4+0 = 4
  //   tdrTypeRef(2) = 2*4+1 = 9
  //   tdrTypeSpec(1) = 1*4+2 = 6
  assertEqualInt(tdrTypeDef(1), 4, "tdrTypeDef")
  assertEqualInt(tdrTypeRef(2), 9, "tdrTypeRef")
  assertEqualInt(tdrTypeSpec(1), 6, "tdrTypeSpec")

  // MemberRefParent: tag bits=3
  //   mrpTypeRef(1) = 1*8+1 = 9
  //   mrpMethodDef(2) = 2*8+3 = 19
  assertEqualInt(mrpTypeRef(1), 9, "mrpTypeRef")
  assertEqualInt(mrpMethodDef(2), 19, "mrpMethodDef")
}

test "#~ stream serializer lays out header, bitmasks, and rows" {
  // Build a minimal MetadataTables with one Module row and one Assembly row.
  val t2 = newMetadataTables()
  addModule(t2, ModuleRow(generation = 0, name = 5, mvid = 1, encId = 0, encBaseId = 0))
  addAssembly(
    t2,
    AssemblyRow(
      hashAlgId = HASH_ALG_SHA1,
      majorVersion = 1,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = ASF_NONE,
      publicKey = 0,
      name = 7,
      culture = 0
    )
  )

  val buf = bufNew()
  serializeTablesStream(t2, 0, buf)
  val bs = bufToList(buf)

  // Header: bytes[0..3]=reserved=0, [4]=2, [5]=0, [6]=heapSizes=0, [7]=1
  assertTrue(
    bs[0] == 0 and bs[1] == 0 and bs[2] == 0 and bs[3] == 0 and bs[4] == 2 and bs[5] == 0 and bs[6] == 0 and bs[7] == 1,
    "stream header bytes"
  )

  // Valid bitmask: Module(bit 0)=1 + Assembly(bit 32)=4294967296
  // LE bytes[8..15] encode this 64-bit value.
  // valid = 1 + 4294967296 = 4294967297
  // Bytes: 0x01 0x00 0x00 0x00 0x01 0x00 0x00 0x00
  assertTrue(
    bs[8] == 1 and bs[9] == 0 and bs[10] == 0 and bs[11] == 0 and bs[12] == 1 and bs[13] == 0 and bs[14] == 0 and
      bs[15] == 0,
    "valid bitmask bytes"
  )

  // Sorted bitmask (bytes[16..23]) = all zeros.
  // Then row counts: Module=1 (4 bytes), Assembly=1 (4 bytes).
  // bytes[24..27] = LE(1) for Module count
  // bytes[28..31] = LE(1) for Assembly count
  assertTrue(
    bs[24] == 1 and bs[25] == 0 and bs[26] == 0 and bs[27] == 0 and bs[28] == 1 and bs[29] == 0 and bs[30] == 0 and
      bs[31] == 0,
    "row count bytes"
  )

  // Module row starts at byte 32.
  // Fields: generation(2) name(2) mvid(2) encId(2) encBaseId(2) = 10 bytes total
  //   generation=0 → bytes[32..33]=0x00 0x00
  //   name=5       → bytes[34..35]=0x05 0x00
  //   mvid=1       → bytes[36..37]=0x01 0x00
  //   encId=0      → bytes[38..39]=0x00 0x00
  //   encBaseId=0  → bytes[40..41]=0x00 0x00
  assertTrue(
    bs[32] == 0 and bs[33] == 0 and bs[34] == 5 and bs[35] == 0 and bs[36] == 1 and bs[37] == 0 and bs[38] == 0 and
      bs[39] == 0 and
      bs[40] == 0 and
      bs[41] == 0,
    "Module row bytes"
  )

  // Assembly row starts at byte 42.
  // Fields: hashAlgId(4) major(2) minor(2) build(2) rev(2) flags(4)
  //         publicKey(2) name(2) culture(2) = 22 bytes total
  //   hashAlgId=0x8004=32772 → bytes[42..45] LE: 0x04 0x80 0x00 0x00
  //   major=1      → bytes[46..47]=0x01 0x00
  //   minor=0      → bytes[48..49]=0x00 0x00
  assertTrue(
    bs[42] == 4 and bs[43] == 128 and bs[44] == 0 and bs[45] == 0 and bs[46] == 1 and bs[47] == 0 and bs[48] == 0 and
      bs[49] == 0,
    "Assembly row bytes"
  )
}
