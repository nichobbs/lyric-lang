//! msil/tables.l — ECMA-335 §II.22 metadata table model and row-index allocators.
//!
//! Provides:
//!   Row records     — one record per supported metadata table.
//!   MetadataTables  — mutable container for all rows.
//!   addXxx helpers  — append a row and return its 1-based row index.
//!   Coded-index helpers — encode (table-tag, row) into the packed wire forms
//!                         used as foreign-key fields in row records.
//!
//! Supported tables (the minimum set needed to emit a valid CLI assembly):
//!   Module (0x00), TypeRef (0x01), TypeDef (0x02), Field (0x04),
//!   MethodDef (0x06), Param (0x08), MemberRef (0x0A), CustomAttr (0x0C),
//!   StandAloneSig (0x11), Assembly (0x20), AssemblyRef (0x23).
//!
//! All heap references (name, signature, …) are stored as Int indices into
//! the corresponding heap (#Strings, #Blob, #GUID); the heap builder (heaps.l)
//! produces these indices, and the layout engine (assembler.l) resolves RVAs.
//!
//! Row indices are 1-based integers throughout (per ECMA-335 §II.22).
package Msil.Tables

import Msil.Kernel
import Std.Core
import Std.Collections

// ── TypeDef attribute flags (ECMA-335 §II.23.1.15) ────────────────────────────
pub val TDF_PRIVATE: Int = 0x00000000

pub val TDF_PUBLIC: Int = 0x00000001

pub val TDF_NESTED_PUBLIC: Int = 0x00000002

pub val TDF_NESTED_PRIVATE: Int = 0x00000003

pub val TDF_NESTED_FAMILY: Int = 0x00000004

pub val TDF_AUTO_LAYOUT: Int = 0x00000000

pub val TDF_SEQUENTIAL_LAYOUT: Int = 0x00000008

pub val TDF_EXPLICIT_LAYOUT: Int = 0x00000010

pub val TDF_CLASS: Int = 0x00000000

pub val TDF_INTERFACE: Int = 0x00000020

pub val TDF_ABSTRACT: Int = 0x00000080

pub val TDF_SEALED: Int = 0x00000100

pub val TDF_SPECIAL_NAME: Int = 0x00000400

pub val TDF_BEFORE_FIELD_INIT: Int = 0x00100000

pub val TDF_RT_SPECIAL_NAME: Int = 0x00000800

// ── MethodDef attribute flags (ECMA-335 §II.23.1.10) ─────────────────────────
pub val MDA_PRIVATE_SCOPE: Int = 0x0000

// not nameable
pub val MDA_PRIVATE: Int = 0x0001

pub val MDA_FAM_AND_ASSEM: Int = 0x0002

pub val MDA_ASSEM: Int = 0x0003

pub val MDA_FAMILY: Int = 0x0004

pub val MDA_FAM_OR_ASSEM: Int = 0x0005

pub val MDA_PUBLIC: Int = 0x0006

pub val MDA_STATIC: Int = 0x0010

pub val MDA_FINAL: Int = 0x0020

pub val MDA_VIRTUAL: Int = 0x0040

pub val MDA_HIDE_BY_SIG: Int = 0x0080

pub val MDA_VTABLE_LAYOUT_NEW: Int = 0x0100

pub val MDA_NEW_SLOT: Int = 0x0100

pub val MDA_STRICT: Int = 0x0200

pub val MDA_ABSTRACT: Int = 0x0400

pub val MDA_SPECIAL_NAME: Int = 0x0800

pub val MDA_RTS_SPECIAL_NAME: Int = 0x1000

pub val MDA_PINVOKE_IMPL: Int = 0x2000

// ── MethodImpl attribute flags (ECMA-335 §II.23.1.11) ────────────────────────
pub val MIA_IL: Int = 0x0000

pub val MIA_NATIVE: Int = 0x0001

pub val MIA_OPTIL: Int = 0x0002

pub val MIA_RUNTIME: Int = 0x0003

pub val MIA_MANAGED: Int = 0x0000

pub val MIA_UNMANAGED: Int = 0x0004

pub val MIA_NO_INLINING: Int = 0x0008

pub val MIA_FORWARD_REF: Int = 0x0010

pub val MIA_SYNCHRONIZED: Int = 0x0020

pub val MIA_NO_OPTIMIZATION: Int = 0x0040

pub val MIA_PRESERVE_SIG: Int = 0x0080

pub val MIA_INTERNAL_CALL: Int = 0x1000

// ── Field attribute flags (ECMA-335 §II.23.1.5) ──────────────────────────────
pub val FDA_PRIVATE_SCOPE: Int = 0x0000

pub val FDA_PRIVATE: Int = 0x0001

pub val FDA_FAM_AND_ASSEM: Int = 0x0002

pub val FDA_ASSEMBLY: Int = 0x0003

pub val FDA_FAMILY: Int = 0x0004

pub val FDA_FAM_OR_ASSEM: Int = 0x0005

pub val FDA_PUBLIC: Int = 0x0006

pub val FDA_STATIC: Int = 0x0010

pub val FDA_INIT_ONLY: Int = 0x0020

pub val FDA_LITERAL: Int = 0x0040

pub val FDA_SPECIAL_NAME: Int = 0x0200

pub val FDA_RT_SPECIAL_NAME: Int = 0x0400

pub val FDA_HAS_DEFAULT: Int = 0x8000

// field has a constant in the Constant table
// ── Param attribute flags (ECMA-335 §II.23.1.13) ─────────────────────────────
pub val PRA_NONE: Int = 0x0000

pub val PRA_IN: Int = 0x0001

pub val PRA_OUT: Int = 0x0002

pub val PRA_OPTIONAL: Int = 0x0010

pub val PRA_HAS_DEFAULT: Int = 0x1000

pub val PRA_HAS_FIELD_MARSHAL: Int = 0x2000

// ── Assembly flags (ECMA-335 §II.23.1.2) ─────────────────────────────────────
pub val ASF_NONE: Int = 0x0000

pub val ASF_PUBLIC_KEY: Int = 0x0001

pub val ASF_RETARGETABLE: Int = 0x0100

pub val ASF_DISABLE_JIT_COMPILE: Int = 0x4000

pub val ASF_ENABLE_JIT_TRACK: Int = 0x8000

// ── Hash algorithm IDs ────────────────────────────────────────────────────────
pub val HASH_ALG_NONE: Int = 0x0000

pub val HASH_ALG_MD5: Int = 0x8003

pub val HASH_ALG_SHA1: Int = 0x8004

pub val HASH_ALG_SHA256: Int = 0x800C

// ── Coded-index helpers ────────────────────────────────────────────────────────
//
// Each coded index encodes (row, table-tag) as row<<tagBits | tag.
// Row is 1-based; tag 0 means "null" (no reference).
// ResolutionScope (2-bit tag, §II.24.2.6 tag table 7):
//   Module=0, ModuleRef=1, AssemblyRef=2, TypeRef=3
pub func rsModule(row: in Int): Int = (row * 4) + 0

pub func rsModuleRef(row: in Int): Int = (row * 4) + 1

pub func rsAssemblyRef(row: in Int): Int = (row * 4) + 2

pub func rsTypeRef(row: in Int): Int = (row * 4) + 3

// TypeDefOrRef (2-bit tag, §II.24.2.6 tag table 14):
//   TypeDef=0, TypeRef=1, TypeSpec=2
pub func tdrTypeDef(row: in Int): Int = (row * 4) + 0

pub func tdrTypeRef(row: in Int): Int = (row * 4) + 1

pub func tdrTypeSpec(row: in Int): Int = (row * 4) + 2

// MemberRefParent (3-bit tag, §II.24.2.6 tag table 8):
//   TypeDef=0, TypeRef=1, ModuleRef=2, MethodDef=3, TypeSpec=4
pub func mrpTypeDef(row: in Int): Int = (row * 8) + 0

pub func mrpTypeRef(row: in Int): Int = (row * 8) + 1

pub func mrpModuleRef(row: in Int): Int = (row * 8) + 2

pub func mrpMethodDef(row: in Int): Int = (row * 8) + 3

pub func mrpTypeSpec(row: in Int): Int = (row * 8) + 4

// HasCustomAttribute (5-bit tag, §II.24.2.6 tag table 2):
//   MethodDef=0, Field=1, TypeRef=2, TypeDef=3, Param=4,
//   InterfaceImpl=5, MemberRef=6, Module=7, DeclSecurity=8,
//   Property=9, Event=10, StandAloneSig=11, ModuleRef=12,
//   TypeSpec=13, Assembly=14, AssemblyRef=15
pub func hcaMethodDef(row: in Int): Int = (row * 32) + 0

pub func hcaField(row: in Int): Int = (row * 32) + 1

pub func hcaTypeRef(row: in Int): Int = (row * 32) + 2

pub func hcaTypeDef(row: in Int): Int = (row * 32) + 3

pub func hcaParam(row: in Int): Int = (row * 32) + 4

pub func hcaMemberRef(row: in Int): Int = (row * 32) + 6

pub func hcaModule(row: in Int): Int = (row * 32) + 7

pub func hcaAssembly(row: in Int): Int = (row * 32) + 14

pub func hcaAssemblyRef(row: in Int): Int = (row * 32) + 15

// CustomAttributeType (3-bit tag, §II.24.2.6 tag table 1):
//   MethodDef=2, MemberRef=3
pub func catMethodDef(row: in Int): Int = (row * 8) + 2

pub func catMemberRef(row: in Int): Int = (row * 8) + 3

// ── Row records ───────────────────────────────────────────────────────────────
// Module (Table 0x00) — ECMA-335 §II.22.30.  Exactly one row per module.
pub record ModuleRow {
  generation: Int   // reserved, always 0
  name: Int   // #Strings index of the module name
  mvid: Int   // #GUID 1-based index (module version GUID)
  encId: Int   // #GUID 1-based index (0 if not EnC)
  encBaseId: Int   // #GUID 1-based index (0 if not EnC)
}

// TypeRef (Table 0x01) — ECMA-335 §II.22.38.
pub record TypeRefRow {
  resolutionScope: Int  // coded: ResolutionScope
  typeName: Int  // #Strings
  typeNamespace: Int  // #Strings (0 = global namespace)
}

// TypeDef (Table 0x02) — ECMA-335 §II.22.37.
// fieldList and methodList are 1-based indices into Field and MethodDef tables.
// They point to the first row owned by this type; rows up to (but not including)
// the next TypeDef's list index are implicitly owned.
pub record TypeDefRow {
  flags: Int  // TypeAttributes
  typeName: Int  // #Strings
  typeNamespace: Int  // #Strings (0 = global)
  extends: Int  // coded: TypeDefOrRef (0 = no base, valid only for System.Object)
  fieldList: Int  // 1-based index into Field table (or Fields.count+1 if no fields)
  methodList: Int  // 1-based index into MethodDef table (or MethodDefs.count+1 if no methods)
}

// Field (Table 0x04) — ECMA-335 §II.22.15.
pub record FieldRow {
  flags: Int  // FieldAttributes
  name: Int  // #Strings
  signature: Int  // #Blob: FieldSig (starts with 0x06)
}

// MethodDef (Table 0x06) — ECMA-335 §II.22.26.
// rva is filled in by the layout engine; use 0 initially and patch during PE
// serialization.  paramList points to the first Param row owned by this method.
pub record MethodDefRow {
  rva: Int  // RVA of method body in .text; 0 = abstract/extern
  implFlags: Int  // MethodImplAttributes
  flags: Int  // MethodAttributes
  name: Int  // #Strings
  signature: Int  // #Blob: MethodSig
  paramList: Int  // 1-based index into Param table
}

// Param (Table 0x08) — ECMA-335 §II.22.33.
// sequence=0 is the return value; sequence=1..n are the positional parameters.
pub record ParamRow {
  flags: Int  // ParamAttributes
  sequence: Int  // 0=return, 1..n=params
  name: Int  // #Strings (may be 0 if unnamed)
}

// MemberRef (Table 0x0A) — ECMA-335 §II.22.25.
// References external fields and methods (those not defined in this module).
pub record MemberRefRow {
  class: Int  // coded: MemberRefParent
  name: Int  // #Strings
  signature: Int  // #Blob: MethodSig or FieldSig
}

// InterfaceImpl (Table 0x09) — ECMA-335 §II.22.23.
// Each row records that TypeDef[class_] implements the interface identified by
// the TypeDefOrRef coded index `interface_`.  Must be sorted by class_, then
// by interface_ (ascending) for CLR compatibility.
pub record InterfaceImplRow {
  class_: Int  // 1-based TypeDef row index
  interface_: Int  // coded: TypeDefOrRef
}

// CustomAttribute (Table 0x0C) — ECMA-335 §II.22.10.
// `type_` is the constructor being called; `value` is the serialized arguments.
pub record CustomAttrRow {
  parent: Int  // coded: HasCustomAttribute
  type_: Int  // coded: CustomAttributeType (ctor reference)
  value: Int  // #Blob (0 = no value / empty blob)
}

// Assembly (Table 0x20) — ECMA-335 §II.22.2.  Exactly one row per assembly.
pub record AssemblyRow {
  hashAlgId: Int  // AssemblyHashAlgorithm (HASH_ALG_*)
  majorVersion: Int
  minorVersion: Int
  buildNumber: Int
  revisionNumber: Int
  flags: Int  // AssemblyFlags
  publicKey: Int  // #Blob (0 = no public key / delay-signed)
  name: Int  // #Strings
  culture: Int  // #Strings (0 = culture-neutral)
}

// StandAloneSig (Table 0x11) — ECMA-335 §II.22.36.
// Holds a standalone signature blob, used for local variable type lists
// (LocalVarSig) referenced by a fat method header's LocalVarSigTok field.
pub record StandAloneSigRow {
  signature: Int  // #Blob: LocalVarSig or MethodSig
}

// TypeSpec (Table 0x1B) — ECMA-335 §II.22.39.
// Encodes a type that is not directly named by a TypeDef or TypeRef,
// such as a generic instantiation (e.g. List<object>).
pub record TypeSpecRow {
  signature: Int  // #Blob: type signature
}

// AssemblyRef (Table 0x23) — ECMA-335 §II.22.5.
pub record AssemblyRefRow {
  majorVersion: Int
  minorVersion: Int
  buildNumber: Int
  revisionNumber: Int
  flags: Int  // AssemblyFlags
  publicKeyToken: Int  // #Blob (8-byte token, or 0 if none)
  name: Int  // #Strings
  culture: Int  // #Strings (0 = culture-neutral)
  hashValue: Int  // #Blob (0 if no hash)
}

// ManifestResource (Table 0x28) — ECMA-335 §II.22.24.
//
// One row per managed resource exposed by the assembly.  For
// resources embedded in the assembly itself (the only kind the
// self-hosted bridge produces), `implementation` is the nil
// `Implementation` coded index (value 0); for resources in another
// file or assembly it would point into the File / AssemblyRef
// tables.  `offset` is the byte offset of this resource's
// length-prefixed payload inside the assembly's Resources data
// region (the region whose RVA + size live in the CLR header).
pub record ManifestResourceRow {
  offset: Int  // u4: byte offset into the Resources data region
  flags: Int  // u4: ManifestResourceAttributes (1 = Public, 2 = Private)
  name: Int  // #Strings: resource name
  implementation: Int  // coded: Implementation (0 = embedded in this assembly)
}

// Constant (Table 0x0B) — ECMA-335 §II.22.9.
// Records a compile-time constant value for a Field, Param, or Property.
pub record ConstantRow {
  type_: Int  // ELEMENT_TYPE_* constant (e.g., 0x08 = ELEMENT_TYPE_I4)
  parent: Int  // coded: HasConstant (Field=0, Param=1, Property=2), 2-bit tag
  value: Int  // #Blob index of little-endian constant value bytes
}

// MethodImpl (Table 0x19) — ECMA-335 §II.22.27.
// Maps an interface method slot to its implementing method in a type.
pub record MethodImplRow {
  class_: Int  // 1-based TypeDef row of the implementing type
  methodBody: Int  // coded: MethodDefOrRef — the implementing method
  methodDeclaration: Int  // coded: MethodDefOrRef — the interface slot being implemented
}

// MethodSpec (Table 0x2B) — ECMA-335 §II.22.29.
// Instantiates a generic method: `method` is a MethodDefOrRef coded index to
// the open generic method (a MemberRef or MethodDef), and `instantiation` is a
// #Blob index to a MethodSpec signature (GENERICINST + arg count + type args,
// §II.23.2.15).  A call site references the resulting row via a 0x2B token.
pub record MethodSpecRow {
  method: Int  // coded: MethodDefOrRef
  instantiation: Int  // #Blob: MethodSpec signature
}

// GenericParam (Table 0x2A) — ECMA-335 §II.22.20.
// One row per generic type parameter owned by a generic TypeDef or MethodDef.
// `number` is the 0-based ordinal of the parameter within its owner; `flags`
// carries variance + special constraints (0 for invariant, no constraints —
// the only form the self-hosted emitter produces); `owner` is a TypeOrMethodDef
// coded index (mtdTypeDef / mtdMethodDef); `name` is the #Strings index of the
// parameter name (e.g. "T", "E").  The CLR binary-searches this table by owner,
// so rows MUST be physically sorted by (owner, number) before serialization and
// the table's sorted-mask bit (42) set — see serializeTablesStream.
pub record GenericParamRow {
  number: Int  // u2: 0-based ordinal within the owner
  flags: Int  // u2: GenericParamAttributes (0 = invariant, no constraints)
  owner: Int  // coded: TypeOrMethodDef
  name: Int  // #Strings
}

// ── Coded-index helpers (additional) ─────────────────────────────────────────
// HasConstant (2-bit tag, §II.24.2.6 tag table 3):
//   Field=0, Param=1, Property=2
pub func hconstField(row: in Int): Int = (row * 4) + 0

pub func hconstParam(row: in Int): Int = (row * 4) + 1

// MethodDefOrRef (1-bit tag, §II.24.2.6 tag table 10):
//   MethodDef=0, MemberRef=1
pub func mdorMethodDef(row: in Int): Int = (row * 2) + 0

pub func mdorMemberRef(row: in Int): Int = (row * 2) + 1

// TypeOrMethodDef (1-bit tag, §II.24.2.6 tag table 13):
//   TypeDef=0, MethodDef=1.  The `owner` field of a GenericParam row uses this
//   coded index to point at the generic TypeDef (type-level generic parameter)
//   or the generic MethodDef (method-level generic parameter).
pub func mtdTypeDef(row: in Int): Int = (row * 2) + 0

pub func mtdMethodDef(row: in Int): Int = (row * 2) + 1

// ── MetadataTables container ───────────────────────────────────────────────────
pub record MetadataTables {
  modules: List[ModuleRow]
  typeRefs: List[TypeRefRow]
  typeDefs: List[TypeDefRow]
  fields: List[FieldRow]
  methodDefs: List[MethodDefRow]
  params_: List[ParamRow]
  interfaceImpls: List[InterfaceImplRow]
  memberRefs: List[MemberRefRow]
  constants: List[ConstantRow]
  customAttrs: List[CustomAttrRow]
  standAloneSigs: List[StandAloneSigRow]
  methodImpls: List[MethodImplRow]
  typeSpecs: List[TypeSpecRow]
  assemblies: List[AssemblyRow]
  assemblyRefs: List[AssemblyRefRow]
  manifestResources: List[ManifestResourceRow]
  genericParams: List[GenericParamRow]
  methodSpecs: List[MethodSpecRow]
}

pub func newMetadataTables(): MetadataTables {
  MetadataTables(
    modules = newList(),
    typeRefs = newList(),
    typeDefs = newList(),
    fields = newList(),
    methodDefs = newList(),
    params_ = newList(),
    interfaceImpls = newList(),
    memberRefs = newList(),
    constants = newList(),
    customAttrs = newList(),
    standAloneSigs = newList(),
    methodImpls = newList(),
    typeSpecs = newList(),
    assemblies = newList(),
    assemblyRefs = newList(),
    manifestResources = newList(),
    genericParams = newList(),
    methodSpecs = newList()
  )
}

// ── Row-index allocators ──────────────────────────────────────────────────────
// Each returns the 1-based index of the newly-added row.
pub func addModule(t: in MetadataTables, r: in ModuleRow): Int {
  t.modules.add(r)
  t.modules.count
}

pub func addTypeRef(t: in MetadataTables, r: in TypeRefRow): Int {
  t.typeRefs.add(r)
  t.typeRefs.count
}

pub func addTypeDef(t: in MetadataTables, r: in TypeDefRow): Int {
  t.typeDefs.add(r)
  t.typeDefs.count
}

pub func addField(t: in MetadataTables, r: in FieldRow): Int {
  t.fields.add(r)
  t.fields.count
}

pub func addMethodDef(t: in MetadataTables, r: in MethodDefRow): Int {
  t.methodDefs.add(r)
  t.methodDefs.count
}

pub func addParam(t: in MetadataTables, r: in ParamRow): Int {
  t.params_.add(r)
  t.params_.count
}

pub func addInterfaceImpl(t: in MetadataTables, r: in InterfaceImplRow): Int {
  t.interfaceImpls.add(r)
  t.interfaceImpls.count
}

pub func addConstant(t: in MetadataTables, r: in ConstantRow): Int {
  t.constants.add(r)
  t.constants.count
}

pub func addMethodImpl(t: in MetadataTables, r: in MethodImplRow): Int {
  t.methodImpls.add(r)
  t.methodImpls.count
}

pub func addMemberRef(t: in MetadataTables, r: in MemberRefRow): Int {
  t.memberRefs.add(r)
  t.memberRefs.count
}

pub func addCustomAttr(t: in MetadataTables, r: in CustomAttrRow): Int {
  t.customAttrs.add(r)
  t.customAttrs.count
}

pub func addAssembly(t: in MetadataTables, r: in AssemblyRow): Int {
  t.assemblies.add(r)
  t.assemblies.count
}

pub func addStandAloneSig(t: in MetadataTables, r: in StandAloneSigRow): Int {
  t.standAloneSigs.add(r)
  t.standAloneSigs.count
}

pub func addTypeSpec(t: in MetadataTables, r: in TypeSpecRow): Int {
  t.typeSpecs.add(r)
  t.typeSpecs.count
}

pub func addMethodSpec(t: in MetadataTables, r: in MethodSpecRow): Int {
  t.methodSpecs.add(r)
  t.methodSpecs.count
}

pub func addAssemblyRef(t: in MetadataTables, r: in AssemblyRefRow): Int {
  t.assemblyRefs.add(r)
  t.assemblyRefs.count
}

pub func addManifestResource(t: in MetadataTables, r: in ManifestResourceRow): Int {
  t.manifestResources.add(r)
  t.manifestResources.count
}

pub func addGenericParam(t: in MetadataTables, r: in GenericParamRow): Int {
  t.genericParams.add(r)
  t.genericParams.count
}

/// Build the StandAloneSig metadata token for the given 1-based row index.
/// Token = (table 0x11) << 24 | rowIndex.
pub func standaloneToken(row: in Int): Int {
  0x11000000 + row
}

// ── Metadata stream serializer (#~ stream) ────────────────────────────────────
//
// Serializes `MetadataTables` into the `#~` stream body (ECMA-335 §II.24.2.6).
// Format:
//   u32 reserved=0
//   u8  major=2, u8 minor=0
//   u8  heapSizes  (bit 0=Strings>64K, bit 1=GUID>64K, bit 2=Blob>64K)
//   u8  reserved=1
//   u64 valid      (bitmask of present tables)
//   u64 sorted     (bitmask of tables that are sorted by key; all zero for now)
//   for each table bit set in valid (LSB first):
//     u32 rowCount
//   for each present table in table-number order:
//     rows in wire format
//
// Row wire format uses 2-byte heap refs (heapSizes=0) and 2-byte simple
// table indices.  All multi-byte fields are little-endian.
//
// This serializer writes rows for tables 0x00..0x0C, 0x11, 0x1B, 0x20, and
// 0x23.  Tables not in that set are omitted from the valid bitmask.
// Table presence bitmask bits (one bit per table ID 0x00..0x3F).
val TABLE_BIT_MODULE: Long = 1i64

// table 0x00, bit 0
val TABLE_BIT_TYPE_REF: Long = 2i64

// table 0x01, bit 1
val TABLE_BIT_TYPE_DEF: Long = 4i64

// table 0x02, bit 2
val TABLE_BIT_FIELD: Long = 16i64

// table 0x04, bit 4
val TABLE_BIT_METHOD_DEF: Long = 64i64

// table 0x06, bit 6
val TABLE_BIT_PARAM: Long = 256i64

// table 0x08, bit 8
val TABLE_BIT_INTERFACE_IMPL: Long = 512i64

// table 0x09, bit 9
val TABLE_BIT_MEMBER_REF: Long = 1024i64

// table 0x0A, bit 10
val TABLE_BIT_CONSTANT: Long = 2048i64

// table 0x0B, bit 11 (2^11)
val TABLE_BIT_CUSTOM_ATTR: Long = 4096i64

// table 0x0C, bit 12
val TABLE_BIT_STAND_ALONE_SIG: Long = 131072i64

// table 0x11, bit 17 (2^17)
val TABLE_BIT_METHOD_IMPL: Long = 33554432i64

// table 0x19, bit 25 (2^25)
val TABLE_BIT_TYPE_SPEC: Long = 134217728i64

// table 0x1B, bit 27 (2^27)
val TABLE_BIT_ASSEMBLY: Long = 4294967296i64

// table 0x20, bit 32 (2^32)
val TABLE_BIT_ASSEMBLY_REF: Long = 34359738368i64

// table 0x23, bit 35 (2^35)
val TABLE_BIT_MANIFEST_RESOURCE: Long = 1099511627776i64

// table 0x28, bit 40 (2^40)
val TABLE_BIT_GENERIC_PARAM: Long = 4398046511104i64

// table 0x2A, bit 42 (2^42)
val TABLE_BIT_METHOD_SPEC: Long = 8796093022208i64

// table 0x2B, bit 43 (2^43)
// Emit a 2-byte LE integer.
func w2(buf: in ByteWriter, v: in Int): Unit {
  bufU1(buf, v % 256)
  bufU1(buf, (v / 256) % 256)
}

// Emit a 4-byte LE integer.
func w4(buf: in ByteWriter, v: in Int): Unit {
  bufU1(buf, v % 256)
  bufU1(buf, (v / 256) % 256)
  bufU1(buf, (v / 65536) % 256)
  bufU1(buf, (v / 16777216) % 256)
}

// Emit an 8-byte LE integer (from a Long).
func w8(buf: in ByteWriter, v: in Long): Unit {
  bufI8Le(buf, v)
}

// Write the #~ stream body for `t` into `buf`.
// `heapSizes` is a 3-bit flags byte:
//   bit 0: Strings heap uses 4-byte indices (set if > 0xFFFF bytes)
//   bit 1: GUID heap uses 4-byte indices
//   bit 2: Blob heap uses 4-byte indices
// For small assemblies, pass 0.
pub func serializeTablesStream(t: in MetadataTables, heapSizes: in Int, buf: in ByteWriter): Unit {
  // Header
  w4(buf, 0)         // reserved
  bufU1(buf, 2)      // major version
  bufU1(buf, 0)      // minor version
  bufU1(buf, heapSizes)
  bufU1(buf, 1)      // reserved (bit 1 always set)

  // Valid bitmask
  var valid: Long = 0i64
  if t.modules.count > 0 {
    valid = valid + TABLE_BIT_MODULE
  }
  if t.typeRefs.count > 0 {
    valid = valid + TABLE_BIT_TYPE_REF
  }
  if t.typeDefs.count > 0 {
    valid = valid + TABLE_BIT_TYPE_DEF
  }
  if t.fields.count > 0 {
    valid = valid + TABLE_BIT_FIELD
  }
  if t.methodDefs.count > 0 {
    valid = valid + TABLE_BIT_METHOD_DEF
  }
  if t.params_.count > 0 {
    valid = valid + TABLE_BIT_PARAM
  }
  if t.interfaceImpls.count > 0 {
    valid = valid + TABLE_BIT_INTERFACE_IMPL
  }
  if t.memberRefs.count > 0 {
    valid = valid + TABLE_BIT_MEMBER_REF
  }
  if t.constants.count > 0 {
    valid = valid + TABLE_BIT_CONSTANT
  }
  if t.customAttrs.count > 0 {
    valid = valid + TABLE_BIT_CUSTOM_ATTR
  }
  if t.standAloneSigs.count > 0 {
    valid = valid + TABLE_BIT_STAND_ALONE_SIG
  }
  if t.methodImpls.count > 0 {
    valid = valid + TABLE_BIT_METHOD_IMPL
  }
  if t.typeSpecs.count > 0 {
    valid = valid + TABLE_BIT_TYPE_SPEC
  }
  if t.assemblies.count > 0 {
    valid = valid + TABLE_BIT_ASSEMBLY
  }
  if t.assemblyRefs.count > 0 {
    valid = valid + TABLE_BIT_ASSEMBLY_REF
  }
  if t.manifestResources.count > 0 {
    valid = valid + TABLE_BIT_MANIFEST_RESOURCE
  }
  if t.genericParams.count > 0 {
    valid = valid + TABLE_BIT_GENERIC_PARAM
  }
  if t.methodSpecs.count > 0 {
    valid = valid + TABLE_BIT_METHOD_SPEC
  }
  w8(buf, valid)

  // Sorted bitmask.  The CLR binary-searches GenericParam by owner, so when
  // GenericParam rows are present they MUST be physically sorted by (owner,
  // number) — done just below before emission — AND the table's sorted-mask
  // bit (42) MUST be set so the loader trusts the ordering.  No other table is
  // declared sorted (matching the historical emitter behaviour).
  val sorted: Long = if t.genericParams.count > 0 { TABLE_BIT_GENERIC_PARAM } else { 0i64 }
  w8(buf, sorted)

  // Row counts (only for present tables, in table-number order)
  if t.modules.count > 0 {
    w4(buf, t.modules.count)
  }
  if t.typeRefs.count > 0 {
    w4(buf, t.typeRefs.count)
  }
  if t.typeDefs.count > 0 {
    w4(buf, t.typeDefs.count)
  }
  if t.fields.count > 0 {
    w4(buf, t.fields.count)
  }
  if t.methodDefs.count > 0 {
    w4(buf, t.methodDefs.count)
  }
  if t.params_.count > 0 {
    w4(buf, t.params_.count)
  }
  if t.interfaceImpls.count > 0 {
    w4(buf, t.interfaceImpls.count)
  }
  if t.memberRefs.count > 0 {
    w4(buf, t.memberRefs.count)
  }
  if t.constants.count > 0 {
    w4(buf, t.constants.count)
  }
  if t.customAttrs.count > 0 {
    w4(buf, t.customAttrs.count)
  }
  if t.standAloneSigs.count > 0 {
    w4(buf, t.standAloneSigs.count)
  }
  if t.methodImpls.count > 0 {
    w4(buf, t.methodImpls.count)
  }
  if t.typeSpecs.count > 0 {
    w4(buf, t.typeSpecs.count)
  }
  if t.assemblies.count > 0 {
    w4(buf, t.assemblies.count)
  }
  if t.assemblyRefs.count > 0 {
    w4(buf, t.assemblyRefs.count)
  }
  if t.manifestResources.count > 0 {
    w4(buf, t.manifestResources.count)
  }
  if t.genericParams.count > 0 {
    w4(buf, t.genericParams.count)
  }
  if t.methodSpecs.count > 0 {
    w4(buf, t.methodSpecs.count)
  }

  // Row data — each table in table-number order.
  // Row wire format: all heap indices (Strings, GUID, Blob) and simple table
  // indices are written as 2 bytes.  The `heapSizes` byte is written into the
  // stream header above so the CLR knows the intended index widths, but the
  // row data always uses 2-byte indices here.  This is valid as long as no
  // individual heap exceeds 65535 bytes (heapSizes=0 is the only supported
  // value for the current self-hosted emitter).  Assemblies with heaps ≥ 64 KB
  // would require 4-byte indices and a heapSizes != 0 header — that path is not
  // yet implemented; all heap-index writes below must be widened when needed.

  // Module rows (table 0x00)
  var mi = 0
  while mi < t.modules.count {
    val r = t.modules[mi]
    w2(buf, r.generation)
    w2(buf, r.name)
    w2(buf, r.mvid)
    w2(buf, r.encId)
    w2(buf, r.encBaseId)
    mi = mi + 1
  }

  // TypeRef rows (table 0x01)
  var tri = 0
  while tri < t.typeRefs.count {
    val r = t.typeRefs[tri]
    w2(buf, r.resolutionScope)
    w2(buf, r.typeName)
    w2(buf, r.typeNamespace)
    tri = tri + 1
  }

  // TypeDef rows (table 0x02)
  var tdi = 0
  while tdi < t.typeDefs.count {
    val r = t.typeDefs[tdi]
    w4(buf, r.flags)
    w2(buf, r.typeName)
    w2(buf, r.typeNamespace)
    w2(buf, r.extends)
    w2(buf, r.fieldList)
    w2(buf, r.methodList)
    tdi = tdi + 1
  }

  // Field rows (table 0x04)
  var fi = 0
  while fi < t.fields.count {
    val r = t.fields[fi]
    w2(buf, r.flags)
    w2(buf, r.name)
    w2(buf, r.signature)
    fi = fi + 1
  }

  // MethodDef rows (table 0x06)
  var mdi = 0
  while mdi < t.methodDefs.count {
    val r = t.methodDefs[mdi]
    w4(buf, r.rva)
    w2(buf, r.implFlags)
    w2(buf, r.flags)
    w2(buf, r.name)
    w2(buf, r.signature)
    w2(buf, r.paramList)
    mdi = mdi + 1
  }

  // Param rows (table 0x08)
  var pi = 0
  while pi < t.params_.count {
    val r = t.params_[pi]
    w2(buf, r.flags)
    w2(buf, r.sequence)
    w2(buf, r.name)
    pi = pi + 1
  }

  // InterfaceImpl rows (table 0x09)
  var ifii = 0
  while ifii < t.interfaceImpls.count {
    val r = t.interfaceImpls[ifii]
    w2(buf, r.class_)
    w2(buf, r.interface_)
    ifii = ifii + 1
  }

  // MemberRef rows (table 0x0A)
  var mri = 0
  while mri < t.memberRefs.count {
    val r = t.memberRefs[mri]
    w2(buf, r.class)
    w2(buf, r.name)
    w2(buf, r.signature)
    mri = mri + 1
  }

  // Constant rows (table 0x0B)
  var coni = 0
  while coni < t.constants.count {
    val r = t.constants[coni]
    bufU1(buf, r.type_)
    bufU1(buf, 0)           // padding byte (always 0)
    w2(buf, r.parent)
    w2(buf, r.value)
    coni = coni + 1
  }

  // CustomAttribute rows (table 0x0C)
  var cai = 0
  while cai < t.customAttrs.count {
    val r = t.customAttrs[cai]
    w2(buf, r.parent)
    w2(buf, r.type_)
    w2(buf, r.value)
    cai = cai + 1
  }

  // StandAloneSig rows (table 0x11)
  var ssi = 0
  while ssi < t.standAloneSigs.count {
    val r = t.standAloneSigs[ssi]
    w2(buf, r.signature)
    ssi = ssi + 1
  }

  // MethodImpl rows (table 0x19)
  var impi = 0
  while impi < t.methodImpls.count {
    val r = t.methodImpls[impi]
    w2(buf, r.class_)
    w2(buf, r.methodBody)
    w2(buf, r.methodDeclaration)
    impi = impi + 1
  }

  // TypeSpec rows (table 0x1B)
  var tsi = 0
  while tsi < t.typeSpecs.count {
    val r = t.typeSpecs[tsi]
    w2(buf, r.signature)
    tsi = tsi + 1
  }

  // Assembly rows (table 0x20)
  var ai = 0
  while ai < t.assemblies.count {
    val r = t.assemblies[ai]
    w4(buf, r.hashAlgId)
    w2(buf, r.majorVersion)
    w2(buf, r.minorVersion)
    w2(buf, r.buildNumber)
    w2(buf, r.revisionNumber)
    w4(buf, r.flags)
    w2(buf, r.publicKey)
    w2(buf, r.name)
    w2(buf, r.culture)
    ai = ai + 1
  }

  // AssemblyRef rows (table 0x23)
  var ari = 0
  while ari < t.assemblyRefs.count {
    val r = t.assemblyRefs[ari]
    w2(buf, r.majorVersion)
    w2(buf, r.minorVersion)
    w2(buf, r.buildNumber)
    w2(buf, r.revisionNumber)
    w4(buf, r.flags)
    w2(buf, r.publicKeyToken)
    w2(buf, r.name)
    w2(buf, r.culture)
    w2(buf, r.hashValue)
    ari = ari + 1
  }

  // ManifestResource rows (table 0x28).  Wire format per ECMA-335
  // §II.22.24: u4 offset, u4 flags, u2 name (Strings), u2
  // implementation (coded Implementation: 0 = embedded in this
  // assembly).  The 2-byte Strings index here shares the 64-KB heap-
  // size limitation documented near the top of this function — the
  // serializer will need widening to u4 alongside the other heap
  // indices when the assembly's Strings heap exceeds 65 535 bytes.
  var mri = 0
  while mri < t.manifestResources.count {
    val r = t.manifestResources[mri]
    w4(buf, r.offset)
    w4(buf, r.flags)
    w2(buf, r.name)
    w2(buf, r.implementation)
    mri = mri + 1
  }

  // GenericParam rows (table 0x2A).  Wire format per ECMA-335 §II.22.20:
  // u2 number, u2 flags, u2 owner (coded TypeOrMethodDef), u2 name (#Strings).
  // The CLR binary-searches this table by `owner`, so the rows must be sorted
  // by (owner, number) ascending.  Copy + insertion-sort a local view so the
  // caller's `genericParams` order (TypeDef-emission order) is preserved while
  // the wire image is correctly sorted.
  val sortedGp: List[GenericParamRow] = newList()
  var gpc = 0
  while gpc < t.genericParams.count {
    sortedGp.add(t.genericParams[gpc])
    gpc = gpc + 1
  }
  var gsi = 1
  while gsi < sortedGp.count {
    val key = sortedGp[gsi]
    var gsj = gsi - 1
    while gsj >= 0 and genericParamGreater(sortedGp[gsj], key) {
      sortedGp[gsj + 1] = sortedGp[gsj]
      gsj = gsj - 1
    }
    sortedGp[gsj + 1] = key
    gsi = gsi + 1
  }
  var gpi = 0
  while gpi < sortedGp.count {
    val r = sortedGp[gpi]
    w2(buf, r.number)
    w2(buf, r.flags)
    w2(buf, r.owner)
    w2(buf, r.name)
    gpi = gpi + 1
  }

  // MethodSpec rows (table 0x2B).  Wire format per ECMA-335 §II.22.29:
  // u2 method (coded MethodDefOrRef), u2 instantiation (#Blob).
  var msi = 0
  while msi < t.methodSpecs.count {
    val r = t.methodSpecs[msi]
    w2(buf, r.method)
    w2(buf, r.instantiation)
    msi = msi + 1
  }
}

// Ordering predicate for GenericParam rows: sort by `owner` ascending, then by
// `number` ascending within the same owner.  Used by serializeTablesStream to
// produce the CLR-required (owner, number) sort.
func genericParamGreater(a: in GenericParamRow, b: in GenericParamRow): Bool {
  if a.owner != b.owner {
    a.owner > b.owner
  } else {
    a.number > b.number
  }
}
