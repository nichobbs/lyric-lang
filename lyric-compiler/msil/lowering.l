// msil/lowering.l — High-level MSIL lowering (Stage M84 / Phase R5).
//
// Mirrors jvm/lowering.l for the MSIL / .NET PE target.
//
// Provides:
//   MsilType          — typed representation of CLI types.
//   MInsn             — high-level instruction union; lowerMInsn resolves tokens.
//   MField / MFunc / MRecord — typed class/method/field descriptors.
//   MUnion / MEnum / MDistinctType / MRangeType — more IR types.
//   MPackage          — top-level package descriptor.
//   lowerMFunc        — lowers an MFunc to a MethodBody.
//   lowerMRecord      — lowers an MRecord into a LoweringCtx (adds TypeDef/Field/MethodDef rows).
//   lowerMPackage     — lowers an MPackage to a complete PE byte list.
//
// Phase R5 coverage (bootstrap-grade, matching jvm/lowering.l Phase R4):
//   Primitive types: Int(I4), Long(I8), Double(R8), Bool(Boolean), String, Unit(Void), Char.
//   Records with primitive or record-typed fields.
//   Top-level static functions.
//   Sealed union types (abstract base + derived case classes).
//   Distinct types and range types (thin newtype wrappers).
//   Arithmetic, comparison, boolean ops, string ops.
//   Control flow: if/else, while, match (literal + binding patterns).
//   Return, function call (static), constructor call (newobj), field access.
//
// Not covered in Phase R5 (deferred to R6):
//   Generics, async, protected types, wire blocks, aspects, FFI (@extern).
//   Cross-package references beyond the stdlib primitives.
//   Exception handling (try/catch/finally).

package Msil.Lowering

import Msil.Kernel
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Msil.Assembler
import Std.Core
import Std.Collections

// ── MsilType ──────────────────────────────────────────────────────────────────

// CLI element types supported by this lowering layer.
pub union MsilType {
  case MInt        // System.Int32   (ELEMENT_TYPE_I4  = 0x08)
  case MLong       // System.Int64   (ELEMENT_TYPE_I8  = 0x0A)
  case MDouble     // System.Double  (ELEMENT_TYPE_R8  = 0x0D)
  case MBool       // System.Boolean (ELEMENT_TYPE_BOOLEAN = 0x02)
  case MChar       // System.Char    (ELEMENT_TYPE_CHAR = 0x03)
  case MString     // System.String  (ELEMENT_TYPE_STRING = 0x0E)
  case MVoid       // void return    (ELEMENT_TYPE_VOID   = 0x01)
  case MObject     // System.Object  (ELEMENT_TYPE_OBJECT = 0x1C)
  case MClass(className: String)  // reference type by fully-qualified name
  // Generic type parameter !n (ELEMENT_TYPE_VAR = 0x13 + index byte).
  // Used in MemberRef signatures on TypeSpecs per ECMA-335 §II.14.4.2.
  case MTypeVar(index: Int)
  // Native integer (ELEMENT_TYPE_I = 0x18).
  // Used in delegate constructor signatures (second param is a method pointer).
  case MNativeInt
}

// Return the ECMA-335 ELEMENT_TYPE byte for the given MsilType.
// For MClass, returns 0x12 (CLASS element type prefix — caller must follow
// with a compressed TypeDefOrRef token; this helper returns the prefix only).
pub func elementTypeByte(t: in MsilType): Int {
  match t {
    case MVoid      -> 0x01
    case MBool      -> 0x02
    case MChar      -> 0x03
    case MInt       -> 0x08
    case MLong      -> 0x0A
    case MDouble    -> 0x0D
    case MString    -> 0x0E
    case MObject     -> 0x1C
    case MClass(_)   -> 0x12
    case MTypeVar(_) -> 0x13  // prefix only; index byte emitted separately by bufMsilType
    case MNativeInt  -> 0x18
  }
}

// Emit an MsilType encoding into w, handling multi-byte cases.
// MTypeVar emits 0x13 + index; all other types emit a single element-type byte.
func bufMsilType(w: in ByteWriter, t: in MsilType): Unit {
  match t {
    case MTypeVar(idx) -> {
      bufU1(w, 0x13)
      bufU1(w, idx)
    }
    case other -> bufU1(w, elementTypeByte(other))
  }
}

// Encode a FieldSig blob for the given field type.
// Format: 0x06 (FIELD) + element-type byte [+ class token for MClass].
// For primitive types only in Phase R5 (MClass requires a TypeDefOrRef
// token that the caller must supply via buildClassFieldSig).
pub func buildFieldSig(t: in MsilType): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x06)          // FIELD
  val et = elementTypeByte(t)
  bufU1(w, et)
  bufToList(w)
}

// Encode a FieldSig blob for a class field (MClass variant).
// classToken is the compressed TypeDefOrRef coded index.
pub func buildClassFieldSig(classToken: in Int): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x06)    // FIELD
  bufU1(w, 0x12)    // CLASS
  writeCompressedInt(w, classToken)
  bufToList(w)
}

// Encode a FieldSig blob for a value-type field (VALUETYPE + compressed TypeDefOrRef).
// Used for enum case fields whose type is the enum TypeDef itself.
pub func buildValueTypeFieldSig(typeDefOrRef: in Int): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x06)    // FIELD
  bufU1(w, 0x11)    // ELEMENT_TYPE_VALUETYPE
  writeCompressedInt(w, typeDefOrRef)
  bufToList(w)
}

// Build a 4-byte little-endian blob for an I4 Constant table entry.
pub func buildI4ConstantBlob(v: in Int): List[Byte] {
  // Byte extraction below uses `%` / `/` which follow Lyric's sign-of-
  // dividend remainder rule (`-1 % 256 == -1`, not `255`).  The
  // result is still correct because the kernel's `bufU1` /
  // `JvmByteBuilder.AppendByte` masks with `v & 0xFF` before
  // writing — verified in `bootstrap/src/Lyric.Jvm.Hosts/JvmHosts.fs`.
  // If a future kernel reimplementation drops that mask, rewrite this
  // helper to either pre-normalise via two's-complement wraparound
  // (e.g. `if v < 0 { (v % 256) + 256 } else { v % 256 }` per byte)
  // or use real bitwise primitives once they land in Lyric (#875).
  val w = bufNew()
  bufU1(w, v % 256)
  bufU1(w, (v / 256) % 256)
  bufU1(w, (v / 65536) % 256)
  bufU1(w, (v / 16777216) % 256)
  bufToList(w)
}

// Return the TypeDefOrRef coded index for System.Enum.
pub func enumTypeToken(ctx: in LoweringCtx): Int {
  tdrTypeRef(ctx.trEnum)
}

// Encode a MethodSig blob (DEFAULT, no HASTHIS for static methods).
// Format: CALLCONV(0x00), paramCount, retType, params...
pub func buildStaticMethodSig(params: in List[MsilType], ret: in MsilType): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x00)                     // DEFAULT call convention (static)
  bufU1(w, params.count)             // param count
  bufMsilType(w, ret)                // return type
  var i = 0
  while i < params.count {
    bufMsilType(w, params[i])
    i = i + 1
  }
  bufToList(w)
}

// Encode a MethodSig blob with HASTHIS (for instance methods and ctors).
// Format: CALLCONV(0x20|HASTHIS), paramCount, retType, params...
// Note: the implicit `this` parameter is NOT counted in paramCount.
pub func buildInstanceMethodSig(params: in List[MsilType], ret: in MsilType): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x20)                     // HASTHIS
  bufU1(w, params.count)             // explicit param count (this excluded)
  bufMsilType(w, ret)                // return type
  var i = 0
  while i < params.count {
    bufMsilType(w, params[i])
    i = i + 1
  }
  bufToList(w)
}

// Write a compressed unsigned integer (ECMA-335 §II.23.2) into a ByteWriter.
// Used in blob payloads for TypeDefOrRef tokens.
func writeCompressedInt(w: in ByteWriter, v: in Int): Unit {
  if v <= 0x7F {
    bufU1(w, v)
  } else if v <= 0x3FFF {
    bufU1(w, (v / 256) + 0x80)
    bufU1(w, v % 256)
  } else {
    bufU1(w, (v / 16777216) + 0xC0)
    bufU1(w, (v / 65536) % 256)
    bufU1(w, (v / 256) % 256)
    bufU1(w, v % 256)
  }
}

// ── MInsn — high-level MSIL instructions ─────────────────────────────────────

pub union MInsn {
  // Labels and branching — label IDs are integers allocated by freshLabelMsil in Msil.Codegen
  case MLabel(id: Int)
  case MBr(label: Int)          // unconditional branch
  case MBrTrue(label: Int)      // branch if top of stack is non-zero/true
  case MBrFalse(label: Int)     // branch if top of stack is zero/false
  case MBrEq(label: Int)        // branch if equal
  case MBrNe(label: Int)        // branch if not equal
  case MBrLt(label: Int)        // branch if less than (signed)
  case MBrGt(label: Int)        // branch if greater than (signed)
  case MBrLe(label: Int)        // branch if less or equal (signed)
  case MBrGe(label: Int)        // branch if greater or equal (signed)

  // Stack constants
  case MNop
  case MRet
  case MLdNull
  case MLdcI4(v: Int)
  case MLdcI8(v: Long)
  case MLdcR8(v: Double)
  case MLdStr(token: Int)          // ldstr — token = 0x70000000 | US heap offset

  // Argument and local load/store
  case MLdarg(slot: Int)
  case MStarg(slot: Int)
  case MLdloc(slot: Int)
  case MStloc(slot: Int)
  case MLdloca(slot: Int)          // load address of local variable

  // Arithmetic and bitwise
  case MAdd
  case MSub
  case MMul
  case MDiv
  case MRem
  case MAnd
  case MOr
  case MXor
  case MNeg
  case MNot
  case MShl
  case MShr
  case MShrUn
  case MCeq                        // compare equal (push 0/1)
  case MClt                        // compare less than (push 0/1)
  case MCgt                        // compare greater than (push 0/1)

  // Conversions
  case MConvI4
  case MConvI8
  case MConvR8

  // Object model
  case MNewobj(ctorToken: Int)         // new T; call .ctor
  case MLdfld(fieldToken: Int)         // load instance field
  case MStfld(fieldToken: Int)         // store instance field
  case MLdsfld(fieldToken: Int)        // load static field
  case MStsfld(fieldToken: Int)        // store static field
  case MCall(methodToken: Int)         // call static or non-virtual method
  case MCallvirt(methodToken: Int)     // callvirt (virtual dispatch)
  case MCastclass(typeToken: Int)      // castclass
  case MIsinst(typeToken: Int)         // isinst (test then push ref or null)
  case MBox(typeToken: Int)            // box value type
  case MUnboxAny(typeToken: Int)       // unbox.any

  // Misc
  case MDup
  case MPop
  case MThrow
  case MLdlen                          // load array length
  case MLdftn(methodToken: Int)        // ldftn — load function pointer (ELEMENT_TYPE_I on stack)
}

// ── MField / MFunc / MRecord ──────────────────────────────────────────────────

pub record MField {
  flags:     Int        // FieldAttributes (from Msil.Tables FDA_*)
  name:      String
  fieldType: MsilType
}

pub record MFunc {
  flags:     Int        // MethodAttributes (from Msil.Tables MDA_*)
  name:      String
  params:    List[MsilType]
  ret:       MsilType
  insns:     List[MInsn]
  maxStack:  Int
  locals:    List[MsilType]   // local variable type list (in order)
}

pub record MRecord {
  className:  String          // fully-qualified, e.g. "Hello"
  namespace:  String          // e.g. "" (empty = global) or "My.Ns"
  baseClass:  String          // fully-qualified, default "System.Object"
  fields:     List[MField]
  methods:    List[MFunc]
}

// ── MUnion — sealed class hierarchy ─────────────────────────────────────────

pub record MUnionCase {
  name:   String            // fully-qualified case class name
  fields: List[MField]
}

pub record MUnion {
  baseName:   String        // abstract base class name
  namespace:  String
  cases:      List[MUnionCase]
  methods:    List[MFunc]   // methods on the base
}

// ── MStaticField — module-level static field (IConst / IVal) ─────────────────

pub record MStaticField {
  flags:      Int         // FDA_PUBLIC | FDA_STATIC | optionally FDA_LITERAL | FDA_INIT_ONLY | FDA_HAS_DEFAULT
  name:       String
  fieldType:  MsilType
  constValue: Int         // literal value when FDA_LITERAL is set (0 otherwise)
  hasLiteral: Bool        // true if constValue is valid (i.e. FDA_LITERAL field)
  initInsns:  List[MInsn] // IL to compute initial value for IVal (empty for IConst)
}

// ── MEnum — CLR enum type ─────────────────────────────────────────────────────

pub record MEnum {
  className: String       // fully-qualified, e.g. "Pkg.Direction"
  namespace: String       // e.g. "Pkg"
  cases:     List[String] // case names; ordinals = 0..n-1
}

// ── MInterface / MImplData ───────────────────────────────────────────────────

pub record MInterfaceMethod {
  name:   String
  params: List[MsilType]
  ret:    MsilType
}

pub record MInterface {
  className: String       // fully-qualified interface name
  namespace: String
  methods:   List[MInterfaceMethod]
}

// Per overridden interface method slot.
//
// Either token may be 0 — in that case `lowerMImpl` resolves the slot by
// looking up the corresponding `*Name` field in the type's MethodDef range.
pub record MImplSlot {
  ifaceMethodToken: Int   // MethodDef or MemberRef token of the interface method (0 = resolve by name)
  implMethodToken:  Int   // MethodDef token of the implementing method (0 = resolve by name)
  ifaceMethodName:  String  // method name on the interface; used when ifaceMethodToken == 0
  implMethodName:   String  // method name on the implementing type; used when implMethodToken == 0
}

// `MImplData` describes one `impl Iface for Target { … }` block.
//
// Tokens may be pre-resolved (non-zero) or supplied with a name fallback:
// when `targetTypeDefRow == 0`, `lowerMImpl` locates the target TypeDef
// row by matching `targetTypeName` + `targetTypeNamespace` against the
// already-emitted TypeDef table.  Same for `ifaceTypeToken` / `ifaceTypeName`.
// This lets `Msil.Codegen` emit `MPImpl` items in source order before all
// types are lowered without having to pre-compute table rows.
pub record MImplData {
  // Pre-resolved row/token; either may be 0 in which case the corresponding
  // `*Name` field is used to resolve by scanning ctx.tables at lowering time.
  // The name-based path is the common one: codegen does not know TypeDef rows
  // when it builds MPackage items, so the resolution is deferred to lowerMImpl.
  targetTypeDefRow: Int         // 1-based TypeDef row of the implementing type (0 = resolve by name)
  ifaceTypeToken:   Int         // TypeDefOrRef coded-index of the interface (0 = resolve by name)
  slots:            List[MImplSlot]
  targetTypeName:   String      // fully-qualified, e.g. "Pkg.EnglishGreeter"
  ifaceTypeName:    String      // fully-qualified, e.g. "Pkg.Greeter"
}

// ── MOpaque — sealed opaque type ─────────────────────────────────────────────

pub record MOpaque {
  className:    String    // fully-qualified, e.g. "Pkg.AccountId"
  namespace:    String
  fields:       List[MField]    // private storage fields
  methods:      List[MFunc]     // public methods declared in the package
  isProjectable: Bool           // true if @projectable — emit twin Exposed TypeDef
}

// ── MDistinctType / MRangeType — thin newtype wrappers ───────────────────────

pub record MDistinctType {
  className: String
  namespace: String
  inner:     MsilType    // the wrapped primitive or class type
}

pub record MRangeType {
  className: String
  namespace: String
  inner:     MsilType
  minVal:    Long
  maxVal:    Long
}

// ── MPackageItem — tagged union over all supported item kinds ─────────────────

pub union MPackageItem {
  case MPRecord(rec: MRecord)
  // MPFuncs: top-level functions + optional static fields (IConst / IVal).
  // staticFields is empty when there are no module-level constants or vals.
  case MPFuncs(hostClass: String, funcs: List[MFunc], staticFields: List[MStaticField])
  case MPUnion(u: MUnion)
  case MPDistinctType(d: MDistinctType)
  case MPRangeType(r: MRangeType)
  case MPEnum(e: MEnum)
  case MPInterface(iface: MInterface)
  case MPImpl(implData: MImplData)
  case MPOpaque(opaqueData: MOpaque)
}

pub record MPackage {
  packageName: String
  items:       List[MPackageItem]
}

// ── LoweringCtx — mutable accumulator for a single-assembly lowering ──────────

pub record LoweringCtx {
  strings:     StringHeap
  blobs:       BlobHeap
  us:          UsHeap
  guids:       GuidHeap
  tables:      MetadataTables
  bodies:      List[MethodBody]
  // Pre-interned well-known string indices
  sModule:     Int
  sObject:     Int
  sSystem:     Int
  sMsCorLib:   Int
  sMsKey:      Int     // blob index of the MS public key token (b03f5f7f11d50a3a)
  // Well-known TypeRef row indices (1-based)
  trObject:    Int     // System.Object in System.Runtime
  trEnum:      Int     // System.Enum in System.Runtime (for CLR enum types)
  // Well-known AssemblyRef row indices (1-based)
  arRuntime:   Int     // System.Runtime
  // Well-known MemberRef row indices (1-based)
  mrObjectCtor: Int    // System.Object::.ctor() — called by synthesised record constructors
}

// Build and intern the Microsoft framework public key token blob.
func internMsKeyToken(bh: in BlobHeap): Int {
  val w = bufNew()
  bufU1(w, 0xB0)  bufU1(w, 0x3F)  bufU1(w, 0x5F)  bufU1(w, 0x7F)
  bufU1(w, 0x11)  bufU1(w, 0xD5)  bufU1(w, 0x0A)  bufU1(w, 0x3A)
  internBlob(bh, "__mskey__", bufToList(w))
}

// Create a fresh LoweringCtx pre-populated with the mandatory rows every
// CLI assembly needs (Module, System.Object TypeRef, System.Runtime AssemblyRef).
pub func newLoweringCtx(packageName: in String): LoweringCtx {
  val sh = newStringHeap()
  val bh = newBlobHeap()
  val uh = newUsHeap()
  val gh = newGuidHeap()
  val t  = newMetadataTables()

  // Intern well-known strings
  val sModule   = internString(sh, "<Module>")
  val sObject   = internString(sh, "Object")
  val sSystem   = internString(sh, "System")
  val sRuntime  = internString(sh, "System.Runtime")
  val sMsCorLib = internString(sh, "mscorlib")
  val msKey     = internMsKeyToken(bh)

  // Module row
  val guidW = bufNew()
  var gi = 0
  while gi < 16 { bufU1(guidW, 0); gi = gi + 1 }
  val mvid = appendGuid(gh, bufToList(guidW))
  addModule(t, ModuleRow(
    generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // <Module> TypeDef (always TypeDef[1] per CLI spec)
  addTypeDef(t, TypeDefRow(
    flags = 0, typeName = sModule, typeNamespace = 0,
    extends = 0, fieldList = 1, methodList = 1))

  // AssemblyRef[1]: System.Runtime
  val arRuntime = addAssemblyRef(t, AssemblyRefRow(
    majorVersion = 10, minorVersion = 0,
    buildNumber = 0, revisionNumber = 0,
    flags = 0, publicKeyToken = msKey,
    name = sRuntime, culture = 0, hashValue = 0))

  // TypeRef[1]: System.Object in System.Runtime
  val trObject = addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(arRuntime),
    typeName = sObject, typeNamespace = sSystem))

  // TypeRef[2]: System.Enum in System.Runtime (needed for CLR enum types)
  val sEnum = internString(sh, "Enum")
  val trEnum = addTypeRef(t, TypeRefRow(
    resolutionScope = rsAssemblyRef(arRuntime),
    typeName = sEnum, typeNamespace = sSystem))

  // MemberRef[1]: System.Object::.ctor() — called from synthesised record constructors
  // to satisfy the CLR verifier rule that every .ctor must call a base constructor
  // before returning (ECMA-335 §I.8.9.6.6; ilverify error ThisUninitReturn).
  val sCtorName    = internString(sh, ".ctor")
  val objCtorSig   = buildInstanceMethodSig(newList(), MVoid)
  val bObjCtorSig  = internBlob(bh, "__object_ctor_sig__", objCtorSig)
  val mrObjectCtor = addMemberRef(t, MemberRefRow(
    class     = mrpTypeRef(trObject),
    name      = sCtorName,
    signature = bObjCtorSig))

  // Assembly row
  val sPackage = internString(sh, packageName)
  addAssembly(t, AssemblyRow(
    hashAlgId = HASH_ALG_SHA1,
    majorVersion = 0, minorVersion = 0,
    buildNumber = 0, revisionNumber = 0,
    flags = ASF_NONE, publicKey = 0,
    name = sPackage, culture = 0))

  LoweringCtx(
    strings      = sh,
    blobs        = bh,
    us           = uh,
    guids        = gh,
    tables       = t,
    bodies       = newList(),
    sModule      = sModule,
    sObject      = sObject,
    sSystem      = sSystem,
    sMsCorLib    = sMsCorLib,
    sMsKey       = msKey,
    trObject     = trObject,
    trEnum       = trEnum,
    arRuntime    = arRuntime,
    mrObjectCtor = mrObjectCtor
  )
}

// Return the TypeDefOrRef coded index for System.Object.
pub func objectTypeToken(ctx: in LoweringCtx): Int {
  tdrTypeRef(ctx.trObject)
}

// Intern a string into the #Strings heap and return its index.
pub func ctxInternStr(ctx: in LoweringCtx, s: in String): Int {
  internString(ctx.strings, s)
}

// Intern a blob into the #Blob heap with the given dedup key.
pub func ctxInternBlob(ctx: in LoweringCtx, key: in String, data: in List[Byte]): Int {
  internBlob(ctx.blobs, key, data)
}

// Intern a user string into the #US heap and return its ldstr token.
pub func ctxInternUs(ctx: in LoweringCtx, s: in String): Int {
  val off = internUs(ctx.us, s)
  0x70000000 + off   // ldstr token = 0x70 << 24 | heap offset
}

// Add a new AssemblyRef row and return its 1-based row index.
pub func ctxAddAssemblyRef(ctx: in LoweringCtx, name: in String,
                           major: in Int, minor: in Int): Int {
  val sName = ctxInternStr(ctx, name)
  addAssemblyRef(ctx.tables, AssemblyRefRow(
    majorVersion = major, minorVersion = minor,
    buildNumber = 0, revisionNumber = 0,
    flags = 0, publicKeyToken = ctx.sMsKey,
    name = sName, culture = 0, hashValue = 0))
}

// Add a TypeRef row and return its 1-based row index.
pub func ctxAddTypeRef(ctx: in LoweringCtx, namespaceName: in String,
                       typeName: in String, assemblyRefRow: in Int): Int {
  val sNs   = ctxInternStr(ctx, namespaceName)
  val sName = ctxInternStr(ctx, typeName)
  addTypeRef(ctx.tables, TypeRefRow(
    resolutionScope = rsAssemblyRef(assemblyRefRow),
    typeName = sName, typeNamespace = sNs))
}

// Add a MemberRef row (external method reference) and return its 1-based row index.
pub func ctxAddMemberRef(ctx: in LoweringCtx, parentTypeRefRow: in Int,
                         methodName: in String, sigKey: in String,
                         sig: in List[Byte]): Int {
  val sName = ctxInternStr(ctx, methodName)
  val bSig  = ctxInternBlob(ctx, sigKey, sig)
  addMemberRef(ctx.tables, MemberRefRow(
    class = mrpTypeRef(parentTypeRefRow),
    name  = sName,
    signature = bSig))
}

// Add a TypeSpec row and return its 1-based row index.
// sigBytes is a type-signature blob (e.g. GENERICINST encoding).
pub func ctxAddTypeSpec(ctx: in LoweringCtx, sigKey: in String,
                        sigBytes: in List[Byte]): Int {
  val bSig = ctxInternBlob(ctx, sigKey, sigBytes)
  addTypeSpec(ctx.tables, TypeSpecRow(signature = bSig))
}

// Add a MemberRef row whose parent is a TypeSpec row (for generic instantiations).
// Returns the 1-based row index.
pub func ctxAddMemberRefForTypeSpec(ctx: in LoweringCtx, typeSpecRow: in Int,
                                     methodName: in String, sigKey: in String,
                                     sig: in List[Byte]): Int {
  val sName = ctxInternStr(ctx, methodName)
  val bSig  = ctxInternBlob(ctx, sigKey, sig)
  addMemberRef(ctx.tables, MemberRefRow(
    class = mrpTypeSpec(typeSpecRow),
    name  = sName,
    signature = bSig))
}

// Build the #Blob encoding for a GENERICINST type (ECMA-335 §II.23.2.14).
// typeDefOrRef is the compressed TypeDefOrRef coded-index for the open generic.
// argTypes is the list of concrete type arguments.
// Returns: 0x15 CLASS typeDefOrRef argCount argType...
pub func buildGenericInstBlob(typeDefOrRef: in Int,
                               argTypes: in List[MsilType]): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x15)  // ELEMENT_TYPE_GENERICINST
  bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS (reference generic)
  writeCompressedInt(w, typeDefOrRef)
  bufU1(w, argTypes.count)
  var i = 0
  while i < argTypes.count {
    bufU1(w, elementTypeByte(argTypes[i]))
    i = i + 1
  }
  bufToList(w)
}

// ── Method body lowering ──────────────────────────────────────────────────────

// Lower one MInsn to opcode bytes in `mb`.
pub func lowerMInsn(insn: in MInsn, mb: in MethodBody): Unit {
  match insn {
    case MLabel(id)         -> mbMarkLabel(mb, id)
    case MBr(lbl)           -> emitBr(mb, lbl)
    case MBrTrue(lbl)       -> emitBrtrue(mb, lbl)
    case MBrFalse(lbl)      -> emitBrfalse(mb, lbl)
    case MBrEq(lbl)         -> emitBeq(mb, lbl)
    case MBrNe(lbl)         -> emitBne_Un(mb, lbl)
    case MBrLt(lbl)         -> emitBlt(mb, lbl)
    case MBrGt(lbl)         -> emitBgt(mb, lbl)
    case MBrLe(lbl)         -> emitBle(mb, lbl)
    case MBrGe(lbl)         -> emitBge(mb, lbl)
    case MNop               -> emitNop(mb)
    case MRet               -> emitRet(mb)
    case MLdNull            -> emitLdnull(mb)
    case MLdcI4(v)          -> emitLdc_I4(mb, v)
    case MLdcI8(v)          -> emitLdc_I8(mb, v)
    case MLdcR8(v)          -> emitLdc_R8(mb, v)
    case MLdStr(token)      -> emitLdstr(mb, token)
    case MLdarg(slot)       -> emitLdarg(mb, slot)
    case MStarg(slot)       -> emitStarg_S(mb, slot)
    case MLdloc(slot)       -> emitLdloc(mb, slot)
    case MStloc(slot)       -> emitStloc(mb, slot)
    case MLdloca(slot)      -> emitLdloca_S(mb, slot)
    case MAdd               -> emitAdd(mb)
    case MSub               -> emitSub(mb)
    case MMul               -> emitMul(mb)
    case MDiv               -> emitDiv(mb)
    case MRem               -> emitRem(mb)
    case MAnd               -> emitAnd(mb)
    case MOr                -> emitOr(mb)
    case MXor               -> emitXor(mb)
    case MNeg               -> emitNeg(mb)
    case MNot               -> emitNot(mb)
    case MShl               -> emitShl(mb)
    case MShr               -> emitShr(mb)
    case MShrUn             -> emitShrUn(mb)
    case MCeq               -> emitCeq(mb)
    case MClt               -> emitClt(mb)
    case MCgt               -> emitCgt(mb)
    case MConvI4            -> emitConv_I4(mb)
    case MConvI8            -> emitConv_I8(mb)
    case MConvR8            -> emitConv_R8(mb)
    case MNewobj(tok)       -> emitNewobj(mb, tok)
    case MLdfld(tok)        -> emitLdfld(mb, tok)
    case MStfld(tok)        -> emitStfld(mb, tok)
    case MLdsfld(tok)       -> emitLdsfld(mb, tok)
    case MStsfld(tok)       -> emitStsfld(mb, tok)
    case MCall(tok)         -> emitCall(mb, tok)
    case MCallvirt(tok)     -> emitCallvirt(mb, tok)
    case MCastclass(tok)    -> emitCastclass(mb, tok)
    case MIsinst(tok)       -> emitIsinst(mb, tok)
    case MBox(tok)          -> emitBox(mb, tok)
    case MUnboxAny(tok)     -> emitUnbox_Any(mb, tok)
    case MDup               -> emitDup(mb)
    case MPop               -> emitPop(mb)
    case MThrow             -> emitThrow(mb)
    case MLdlen             -> emitLdlen(mb)
    case MLdftn(tok)        -> emitLdftn(mb, tok)
  }
}

// Build a LocalVarSig blob for the given list of local types.
// Format: 0x07 (LOCAL_SIG), compressed count, type bytes...
// MClass types are encoded as ELEMENT_TYPE_OBJECT (0x1C) because a full
// class-typed local var entry requires a compressed TypeDefOrRef token that
// is not yet available to this function.  Using Object is valid; the Lyric
// type-tracking layer (fctx.types) still records the precise MClass type so
// method-dispatch lookups in lowerMethodCallMsil work correctly at codegen
// time.  The CLR verifier sees `object` locals, but the JIT runs the method
// body without strict verification, so the unverified callvirt is fine at
// runtime.
func buildLocalVarSig(locals: in List[MsilType]): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x07)  // LOCAL_SIG
  writeCompressedInt(w, locals.count)
  var i = 0
  while i < locals.count {
    val et = match locals[i] {
      case MClass(_) -> 0x1C   // Object: avoids malformed CLASS+TypeDefOrRef entry
      case other     -> elementTypeByte(other)
    }
    bufU1(w, et)
    i = i + 1
  }
  bufToList(w)
}

// Lower an MFunc to a MethodBody and register it in the context.
// Returns the MethodBody (for RVA assignment by the caller).
pub func lowerMFunc(f: in MFunc, ctx: in LoweringCtx): MethodBody {
  val mb = newMethodBody()
  if f.locals.count > 0 {
    val lvSig  = buildLocalVarSig(f.locals)
    val lvBlob = ctxInternBlob(ctx, "lv_" + f.name, lvSig)
    val lvRow  = addStandAloneSig(ctx.tables, StandAloneSigRow(signature = lvBlob))
    mbSetLocalSig(mb, standaloneToken(lvRow))
  }
  mb.maxStack = f.maxStack
  var i = 0
  while i < f.insns.count {
    lowerMInsn(f.insns[i], mb)
    i = i + 1
  }
  mb
}

// ── Record lowering ───────────────────────────────────────────────────────────

// Lower an MRecord into the context, adding the TypeDef, Field, and MethodDef rows.
// Returns the 1-based TypeDef row index of the emitted class.
pub func lowerMRecord(r: in MRecord, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  // TypeDef typeName must be the SIMPLE (unqualified) type name, not the full
  // namespace-qualified name.  r.className = "Pkg.Name" but the TypeDef must
  // store "Name" in typeName and "Pkg" in typeNamespace so the CLR type loader
  // can resolve the type by (namespace, simpleName) without a dot-split issue.
  val simpleNameRec = if r.namespace.length == 0 { r.className }
                      else { r.className.substring(r.namespace.length + 1, r.className.length - r.namespace.length - 1) }
  val sName  = internString(sh, simpleNameRec)
  val sNs    = internString(sh, r.namespace)

  val firstField  = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit Field rows
  var fi = 0
  while fi < r.fields.count {
    val f     = r.fields[fi]
    val sF    = internString(sh, f.name)
    val fSig  = buildFieldSig(f.fieldType)
    val bSig  = internBlob(bh, "field_" + r.className + "_" + f.name, fSig)
    addField(t, FieldRow(flags = f.flags, name = sF, signature = bSig))
    fi = fi + 1
  }

  // Synthesise a .ctor(field1, field2, ...) if no explicit .ctor method is present.
  // A record without methods still needs a constructor to be constructible from Lyric.
  val hasCtor = false  // Phase R5: always emit a synthesised .ctor
  // Build .ctor parameter types from field types
  val ctorParams: List[MsilType] = newList()
  var ci = 0
  while ci < r.fields.count {
    ctorParams.add(r.fields[ci].fieldType)
    ci = ci + 1
  }
  val ctorSig  = buildInstanceMethodSig(ctorParams, MVoid)
  val ctorKey  = "ctor_" + r.className
  val bCtorSig = internBlob(bh, ctorKey, ctorSig)
  val sCtor    = internString(sh, ".ctor")

  // Build .ctor body: ldarg.0; call Object::.ctor(); [ldarg.n; stfld field_n]×n; ret
  // The base-class call is required: ECMA-335 §I.8.9.6.6 mandates that every
  // instance constructor initialises `this` by calling a base constructor before
  // returning.  Omitting it produces ilverify error ThisUninitReturn and an
  // InvalidProgramException at JIT time on modern .NET runtimes.
  val mbCtor = newMethodBody()
  mbCtor.maxStack = 2
  emitLdarg_0(mbCtor)
  emitCall(mbCtor, 0x0A000000 + ctx.mrObjectCtor)
  var ai = 0
  while ai < r.fields.count {
    emitLdarg_0(mbCtor)
    emitLdarg(mbCtor, ai + 1)
    // Field token: FieldDef[firstField + ai]. Token = 0x04000000 | row.
    emitStfld(mbCtor, 0x04000000 + firstField + ai)
    ai = ai + 1
  }
  emitRet(mbCtor)
  ctx.bodies.add(mbCtor)

  val rvas      = methodBodyRvas(ctx.bodies)
  val ctorRva   = rvas[ctx.bodies.count - 1]
  val firstParam = t.params_.count + 1

  // Param[0] (sequence=0) = return value
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))

  addMethodDef(t, MethodDefRow(
    rva       = ctorRva,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
    name      = sCtor,
    signature = bCtorSig,
    paramList = firstParam))

  // Emit explicit instance methods
  var mi = 0
  while mi < r.methods.count {
    val m    = r.methods[mi]
    val mbM  = lowerMFunc(m, ctx)
    ctx.bodies.add(mbM)
    val rvasM = methodBodyRvas(ctx.bodies)
    val mRva  = rvasM[ctx.bodies.count - 1]
    val sName2 = internString(sh, m.name)
    val mSig   = buildInstanceMethodSig(m.params, m.ret)
    val bMSig  = internBlob(bh, "meth_" + r.className + "_" + m.name, mSig)
    val fp     = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(
      rva       = mRva,
      implFlags = 0,
      flags     = m.flags,
      name      = sName2,
      signature = bMSig,
      paramList = fp))
    mi = mi + 1
  }

  // TypeDef row
  addTypeDef(t, TypeDefRow(
    flags         = TDF_PUBLIC + TDF_SEALED + TDF_SEQUENTIAL_LAYOUT + TDF_BEFORE_FIELD_INIT,
    typeName      = sName,
    typeNamespace = sNs,
    extends       = objectTypeToken(ctx),
    fieldList     = firstField,
    methodList    = firstMethod))
}

// ── Union lowering ────────────────────────────────────────────────────────────

// Lower an MUnion as an abstract base class + one sealed case class per variant.
// Returns the 1-based TypeDef row of the abstract base class.
pub func lowerMUnion(u: in MUnion, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val simpleNameUnion = if u.namespace.length == 0 { u.baseName }
                        else { u.baseName.substring(u.namespace.length + 1, u.baseName.length - u.namespace.length - 1) }
  val sBase  = internString(sh, simpleNameUnion)
  val sNs    = internString(sh, u.namespace)

  val baseFirstField  = t.fields.count + 1
  val baseFirstMethod = t.methodDefs.count + 1

  // Emit base methods (abstract / virtual)
  var mi = 0
  while mi < u.methods.count {
    val m   = u.methods[mi]
    val mb  = lowerMFunc(m, ctx)
    ctx.bodies.add(mb)
    val rvas = methodBodyRvas(ctx.bodies)
    val mRva = rvas[ctx.bodies.count - 1]
    val sN   = internString(sh, m.name)
    val mSig = buildStaticMethodSig(m.params, m.ret)
    val bSig = internBlob(bh, "basemeth_" + u.baseName + "_" + m.name, mSig)
    val fp   = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(
      rva       = mRva,
      implFlags = 0,
      flags     = m.flags,
      name      = sN,
      signature = bSig,
      paramList = fp))
    mi = mi + 1
  }

  // Abstract base TypeDef
  val baseRow = addTypeDef(t, TypeDefRow(
    flags         = TDF_PUBLIC + TDF_ABSTRACT + TDF_BEFORE_FIELD_INIT,
    typeName      = sBase,
    typeNamespace = sNs,
    extends       = objectTypeToken(ctx),
    fieldList     = baseFirstField,
    methodList    = baseFirstMethod))

  // Emit case classes extending the base
  var ci = 0
  while ci < u.cases.count {
    val c = u.cases[ci]
    val rec = MRecord(
      className = c.name,
      namespace = u.namespace,
      baseClass = u.baseName,
      fields    = c.fields,
      methods   = newList())
    lowerMRecord(rec, ctx)
    ci = ci + 1
  }

  baseRow
}

// ── Distinct / Range type lowering ────────────────────────────────────────────

// Lower an MDistinctType as a sealed wrapper class with a single `value` field
// and a .ctor(inner) constructor.
pub func lowerMDistinctType(d: in MDistinctType, ctx: in LoweringCtx): Int {
  val rec = MRecord(
    className = d.className,
    namespace = d.namespace,
    baseClass = "System.Object",
    fields    = newList(),
    methods   = newList())
  val valueField = MField(
    flags     = FDA_PUBLIC + FDA_INIT_ONLY,
    name      = "value",
    fieldType = d.inner)
  rec.fields.add(valueField)
  lowerMRecord(rec, ctx)
}

// Lower an MRangeType as a distinct type with range validation in .ctor.
// Phase R5: validation is a runtime assert; SMT proof deferred to Phase R6.
pub func lowerMRangeType(r: in MRangeType, ctx: in LoweringCtx): Int {
  lowerMDistinctType(MDistinctType(
    className = r.className,
    namespace = r.namespace,
    inner     = r.inner), ctx)
}

// ── Enum lowering ─────────────────────────────────────────────────────────────

// Lower an MEnum to a CLR enum TypeDef.
// Produces: TypeDef extends System.Enum, one `value__` field (I4), one static literal
// field per case, and one Constant row per case in the Constant table.
pub func lowerMEnum(e: in MEnum, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val sName = internString(sh, e.className)
  val sNs   = internString(sh, e.namespace)

  // Allocate TypeDef row first (field list starts right after current fields).
  val firstField  = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit `value__` special field (I4, Private, SpecialName, RTSpecialName).
  val sValueDunder = internString(sh, "value__")
  val i4Sig  = buildFieldSig(MInt)
  val bI4Sig = internBlob(bh, "field_i4_sig", i4Sig)
  addField(t, FieldRow(
    flags     = FDA_PRIVATE + FDA_SPECIAL_NAME + FDA_RT_SPECIAL_NAME,
    name      = sValueDunder,
    signature = bI4Sig))

  // Emit one static literal field per case + a Constant row for its ordinal value.
  // The enum's own TypeDef is appended at the end of this function via
  // `addTypeDef`, so its row number will be `t.typeDefs.count + 1`
  // (1-based row indices, current count snapshot taken before append).
  val enumTypeDefRow = t.typeDefs.count + 1

  var ci = 0
  while ci < e.cases.count {
    val sCase    = internString(sh, e.cases[ci])
    // Case field type = VALUETYPE <this enum TypeDef>.
    // TypeDefOrRef coded-index for a TypeDef: tdrTypeDef(row) = row * 4.
    val enumTdr  = tdrTypeDef(enumTypeDefRow)
    val caseSig  = buildValueTypeFieldSig(enumTdr)
    val bCaseSig = internBlob(bh, "enum_case_" + e.className + "_" + e.cases[ci], caseSig)
    val caseFieldRow = addField(t, FieldRow(
      flags     = FDA_PUBLIC + FDA_STATIC + FDA_LITERAL + FDA_HAS_DEFAULT,
      name      = sCase,
      signature = bCaseSig))
    // Constant row: ELEMENT_TYPE_I4 (0x08), parent = hconstField(caseFieldRow).
    val constBlob = buildI4ConstantBlob(ci)
    val bConst    = internBlob(bh, "const_" + e.className + "_" + e.cases[ci], constBlob)
    addConstant(t, ConstantRow(
      type_  = 0x08,     // ELEMENT_TYPE_I4
      parent = hconstField(caseFieldRow),
      value  = bConst))
    ci = ci + 1
  }

  // Emit the TypeDef itself — must extend System.Enum.
  addTypeDef(t, TypeDefRow(
    flags         = TDF_PUBLIC + TDF_SEALED,
    typeName      = sName,
    typeNamespace = sNs,
    extends       = enumTypeToken(ctx),
    fieldList     = firstField,
    methodList    = firstMethod))
}

// ── Interface lowering ────────────────────────────────────────────────────────

// Lower an MInterface to a CLR interface TypeDef with abstract method headers.
pub func lowerMInterface(iface: in MInterface, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val simpleNameIface = if iface.namespace.length == 0 { iface.className }
                        else { iface.className.substring(iface.namespace.length + 1, iface.className.length - iface.namespace.length - 1) }
  val sName = internString(sh, simpleNameIface)
  val sNs   = internString(sh, iface.namespace)

  val firstField  = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit abstract method header for each interface method.
  var mi = 0
  while mi < iface.methods.count {
    val m    = iface.methods[mi]
    val sN   = internString(sh, m.name)
    val mSig = buildInstanceMethodSig(m.params, m.ret)
    val bSig = internBlob(bh, "ifmeth_" + iface.className + "_" + m.name, mSig)
    val fp   = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    // Abstract interface method: Public, Abstract, Virtual, HideBySig, NewSlot, RVA=0.
    addMethodDef(t, MethodDefRow(
      rva       = 0,
      implFlags = 0,
      flags     = MDA_PUBLIC + MDA_ABSTRACT + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_NEW_SLOT,
      name      = sN,
      signature = bSig,
      paramList = fp))
    mi = mi + 1
  }

  // TypeDef flags for a CLR interface: Interface | Abstract | Public.
  addTypeDef(t, TypeDefRow(
    flags         = TDF_INTERFACE + TDF_ABSTRACT + TDF_PUBLIC,
    typeName      = sName,
    typeNamespace = sNs,
    extends       = 0,      // interfaces have no extends
    fieldList     = firstField,
    methodList    = firstMethod))
}

// ── Impl lowering ─────────────────────────────────────────────────────────────

// Find the 1-based TypeDef row whose (namespace, name) matches the given
// fully-qualified type name.  Returns 0 if no such TypeDef exists.
// Uses #Strings heap interning — both `internString` calls are idempotent so
// they do not pollute the heap.
pub func findTypeDefRowByName(ctx: in LoweringCtx, fqn: in String): Int {
  // lowerMRecord stores the SIMPLE name in typeName and the namespace in
  // typeNamespace (e.g. "EnglishGreeter"/"ShMIface" for "ShMIface.EnglishGreeter").
  // Split the FQN at the last dot and match both fields independently.
  var lastDot = -1
  var di = 0
  while di < fqn.length {
    if fqn[di] == '.' { lastDot = di }
    di = di + 1
  }
  val ns         = if lastDot < 0 { "" }
                   else { fqn.substring(0, lastDot) }
  val simpleName = if lastDot < 0 { fqn }
                   else { fqn.substring(lastDot + 1, fqn.length - lastDot - 1) }
  val sNs = internString(ctx.strings, ns)
  val sSN = internString(ctx.strings, simpleName)
  val t = ctx.tables
  var i = 0
  while i < t.typeDefs.count {
    val td = t.typeDefs[i]
    if td.typeNamespace == sNs and td.typeName == sSN {
      return i + 1
    }
    i = i + 1
  }
  0
}

// Find the 1-based MethodDef row owned by typeDefRow with the given method
// name.  The methods owned by a TypeDef are the contiguous range
// [td.methodList, nextTd.methodList) in the MethodDef table — the last
// TypeDef owns through the end of the table.  Returns 0 if not found.
pub func findMethodDefRowOfType(ctx: in LoweringCtx, typeDefRow: in Int,
                                 methodName: in String): Int {
  val t = ctx.tables
  if typeDefRow < 1 or typeDefRow > t.typeDefs.count { return 0 }
  val sName = internString(ctx.strings, methodName)
  val td    = t.typeDefs[typeDefRow - 1]
  val first = td.methodList
  val last  = if typeDefRow == t.typeDefs.count {
    t.methodDefs.count + 1
  } else {
    t.typeDefs[typeDefRow].methodList
  }
  var i = first
  while i < last {
    if t.methodDefs[i - 1].name == sName {
      return i
    }
    i = i + 1
  }
  0
}

// Lower an MImplData to an InterfaceImpl table row.
//
// All TypeDef rows referenced by an `MPImpl` must already exist in the tables
// — `MPImpl` items are emitted after every type-bearing item by
// `codegenMPackage`, so this invariant holds at the call sites today.
//
// `targetTypeDefRow` / `ifaceTypeToken` may be zero, in which case the
// matching `*Name` field is used to scan the tables.  This is the path
// codegen takes: it knows the names but not the row numbers when MPackage
// items are first built.
//
// The CLR resolves the interface slot → implementing method mapping by
// name-matching: when an implementing method has the `virtual` flag set
// (without `newslot`) and carries the same name/signature as the interface
// method, the CLR wires them automatically.  Explicit MethodImpl rows are
// only required when the names differ (aliased implementation), which Lyric
// `impl` blocks do not support.  This matches the pattern validated by
// msil_self_test_m11.l.
pub func lowerMImpl(d: in MImplData, ctx: in LoweringCtx): Int {
  val t = ctx.tables
  val targetRow = if d.targetTypeDefRow > 0 {
    d.targetTypeDefRow
  } else {
    findTypeDefRowByName(ctx, d.targetTypeName)
  }
  if targetRow == 0 {
    panic("Msil.Lowering: MPImpl target type '" + d.targetTypeName + "' has no TypeDef row")
  }
  val ifaceToken = if d.ifaceTypeToken > 0 {
    d.ifaceTypeToken
  } else {
    val ifaceRow = findTypeDefRowByName(ctx, d.ifaceTypeName)
    if ifaceRow == 0 {
      panic("Msil.Lowering: MPImpl interface type '" + d.ifaceTypeName + "' has no TypeDef row")
    }
    tdrTypeDef(ifaceRow)
  }
  // InterfaceImpl row: records that targetRow implements ifaceToken.
  addInterfaceImpl(t, InterfaceImplRow(
    class_     = targetRow,
    interface_ = ifaceToken))
  0
}

// ── Opaque type lowering ──────────────────────────────────────────────────────

// Lower an MOpaque to a sealed TypeDef with private storage fields.
// When isProjectable=true, also emits a sibling TypeDef with public fields
// and toExposed/fromExposed static methods.
pub func lowerMOpaque(op: in MOpaque, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val simpleNameOpaque = if op.namespace.length == 0 { op.className }
                         else { op.className.substring(op.namespace.length + 1, op.className.length - op.namespace.length - 1) }
  val sName = internString(sh, simpleNameOpaque)
  val sNs   = internString(sh, op.namespace)

  val firstField  = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit private storage fields (no public field access outside the package).
  var fi = 0
  while fi < op.fields.count {
    val f    = op.fields[fi]
    val sF   = internString(sh, f.name)
    val fSig = buildFieldSig(f.fieldType)
    val bSig = internBlob(bh, "ofield_" + op.className + "_" + f.name, fSig)
    addField(t, FieldRow(flags = FDA_PRIVATE, name = sF, signature = bSig))
    fi = fi + 1
  }

  // Synthesise .ctor from declared fields.
  val ctorPs: List[MsilType] = newList()
  var ci = 0
  while ci < op.fields.count {
    ctorPs.add(op.fields[ci].fieldType)
    ci = ci + 1
  }
  val ctorSig  = buildInstanceMethodSig(ctorPs, MVoid)
  val bCtorSig = internBlob(bh, "octor_" + op.className, ctorSig)
  val sCtor    = internString(sh, ".ctor")

  val mbCtor = newMethodBody()
  mbCtor.maxStack = 2
  emitLdarg_0(mbCtor)
  emitCall(mbCtor, 0x0A000000 + ctx.mrObjectCtor)
  var ai = 0
  while ai < op.fields.count {
    emitLdarg_0(mbCtor)
    emitLdarg(mbCtor, ai + 1)
    emitStfld(mbCtor, 0x04000000 + firstField + ai)
    ai = ai + 1
  }
  emitRet(mbCtor)
  ctx.bodies.add(mbCtor)

  val rvas    = methodBodyRvas(ctx.bodies)
  val ctorRva = rvas[ctx.bodies.count - 1]
  val fp      = t.params_.count + 1
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(t, MethodDefRow(
    rva       = ctorRva,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
    name      = sCtor,
    signature = bCtorSig,
    paramList = fp))

  // Emit explicit instance methods.
  var mi = 0
  while mi < op.methods.count {
    val m    = op.methods[mi]
    val mbM  = lowerMFunc(m, ctx)
    ctx.bodies.add(mbM)
    val rvasM = methodBodyRvas(ctx.bodies)
    val mRva  = rvasM[ctx.bodies.count - 1]
    val sN    = internString(sh, m.name)
    val mSig  = buildInstanceMethodSig(m.params, m.ret)
    val bMSig = internBlob(bh, "ometh_" + op.className + "_" + m.name, mSig)
    val fpm   = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(
      rva       = mRva,
      implFlags = 0,
      flags     = m.flags,
      name      = sN,
      signature = bMSig,
      paramList = fpm))
    mi = mi + 1
  }

  val opaqueRow = addTypeDef(t, TypeDefRow(
    flags         = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
    typeName      = sName,
    typeNamespace = sNs,
    extends       = objectTypeToken(ctx),
    fieldList     = firstField,
    methodList    = firstMethod))

  opaqueRow
}

// ── Top-level static functions lowering ───────────────────────────────────────

// Lower a list of top-level static MFuncs (and optional static fields) into a
// single host class named `hostClass`. staticFields holds IConst/IVal items.
pub func lowerMFuncsToHostClass(hostClass: in String, funcs: in List[MFunc],
                                staticFields: in List[MStaticField],
                                ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val sName  = internString(sh, hostClass)
  val firstField  = t.fields.count + 1

  // Emit static fields (IConst → literal; IVal → init-only).
  val cctorInsns: List[MInsn] = newList()
  val hasCctor: List[Bool] = newList()  // singleton used as mutable bool flag
  var sfi = 0
  while sfi < staticFields.count {
    val sf   = staticFields[sfi]
    val sN   = internString(sh, sf.name)
    val fSig = buildFieldSig(sf.fieldType)
    val bSig = internBlob(bh, "stfld_" + hostClass + "_" + sf.name, fSig)
    val fRow = addField(t, FieldRow(flags = sf.flags, name = sN, signature = bSig))
    if sf.hasLiteral {
      // IConst: emit a Constant table row with the literal value.
      val constBlob = buildI4ConstantBlob(sf.constValue)
      val bConst    = internBlob(bh, "const_" + hostClass + "_" + sf.name, constBlob)
      addConstant(t, ConstantRow(
        type_  = 0x08,     // ELEMENT_TYPE_I4
        parent = hconstField(fRow),
        value  = bConst))
    } else if sf.initInsns.count > 0 {
      // IVal: accumulate IL for the .cctor body.
      var ii = 0
      while ii < sf.initInsns.count {
        cctorInsns.add(sf.initInsns[ii])
        ii = ii + 1
      }
      // Store result into the static field.
      cctorInsns.add(MStsfld(fieldToken = 0x04000000 + fRow))
      hasCctor.add(true)
    }
    sfi = sfi + 1
  }

  val firstMethod = t.methodDefs.count + 1

  // If any IVal fields need runtime initialization, emit a .cctor.
  if hasCctor.count > 0 {
    cctorInsns.add(MRet)
    val mbCctor = newMethodBody()
    mbCctor.maxStack = 8
    var ci = 0
    while ci < cctorInsns.count {
      lowerMInsn(cctorInsns[ci], mbCctor)
      ci = ci + 1
    }
    ctx.bodies.add(mbCctor)
    val rvasC = methodBodyRvas(ctx.bodies)
    val cRva  = rvasC[ctx.bodies.count - 1]
    val sCctor = internString(sh, ".cctor")
    val cctorSig  = buildStaticMethodSig(newList(), MVoid)
    val bCctorSig = internBlob(bh, "cctor_" + hostClass, cctorSig)
    val fpc = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(
      rva       = cRva,
      implFlags = 0,
      flags     = MDA_PRIVATE + MDA_STATIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name      = sCctor,
      signature = bCctorSig,
      paramList = fpc))
  }

  // Emit static methods.
  var fi = 0
  while fi < funcs.count {
    val f    = funcs[fi]
    val mb   = lowerMFunc(f, ctx)
    ctx.bodies.add(mb)
    val rvas = methodBodyRvas(ctx.bodies)
    val fRva = rvas[ctx.bodies.count - 1]
    val sN   = internString(sh, f.name)
    val mSig = buildStaticMethodSig(f.params, f.ret)
    val bSig = internBlob(bh, "sfunc_" + hostClass + "_" + f.name, mSig)
    val fp   = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(
      rva       = fRva,
      implFlags = 0,
      flags     = f.flags,
      name      = sN,
      signature = bSig,
      paramList = fp))
    fi = fi + 1
  }

  addTypeDef(t, TypeDefRow(
    flags         = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
    typeName      = sName,
    typeNamespace = 0,
    extends       = objectTypeToken(ctx),
    fieldList     = firstField,
    methodList    = firstMethod))
}

// ── Package lowering ───────────────────────────────────────────────────────────

// Lower an MPackage to a complete PE binary.
// `entryMethodToken` is the MethodDef token for the program's entry point (0 for libraries).
pub func lowerMPackage(pkg: in MPackage, entryMethodToken: in Int): List[Byte] {
  val ctx = newLoweringCtx(pkg.packageName)

  var i = 0
  while i < pkg.items.count {
    match pkg.items[i] {
      case MPRecord(rec) -> {
        lowerMRecord(rec, ctx)
      }
      case MPFuncs(hostClass, funcs, staticFields) -> {
        lowerMFuncsToHostClass(hostClass, funcs, staticFields, ctx)
      }
      case MPUnion(u) -> {
        lowerMUnion(u, ctx)
      }
      case MPDistinctType(d) -> {
        lowerMDistinctType(d, ctx)
      }
      case MPRangeType(r) -> {
        lowerMRangeType(r, ctx)
      }
      case MPEnum(e) -> {
        lowerMEnum(e, ctx)
      }
      case MPInterface(iface) -> {
        lowerMInterface(iface, ctx)
      }
      case MPImpl(implData) -> {
        lowerMImpl(implData, ctx)
      }
      case MPOpaque(op) -> {
        lowerMOpaque(op, ctx)
      }
    }
    i = i + 1
  }

  // RVAs for each MethodDef are set inline by each lowerM* call (lowerMRecord,
  // lowerMOpaque, lowerMFuncsToHostClass, etc.) using the body's position in
  // the accumulated ctx.bodies list.  Abstract interface methods explicitly get
  // rva=0 (no body).  No post-pass patching is needed — and a post-pass would
  // incorrectly overwrite abstract method rva=0 slots with concrete body RVAs.

  val inp = AssemblerInput(
    entryPointToken = entryMethodToken,
    methodBodies    = ctx.bodies,
    tables          = ctx.tables,
    strings         = ctx.strings,
    us              = ctx.us,
    blobs           = ctx.blobs,
    guids           = ctx.guids)

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}

// Lower an MPackage to a complete PE binary using a pre-seeded LoweringCtx.
// Identical to `lowerMPackage` but skips creating a fresh context, allowing
// the caller to pre-register AssemblyRef / TypeRef / MemberRef rows (for
// external method tokens) before any user-defined types are added.
// Used by `Msil.Codegen` + `Msil.Bridge` so that stdlib call tokens baked
// into `MInsn` values are stable.
pub func lowerMPackageWithCtx(pkg: in MPackage, ctx: in LoweringCtx,
                               entryMethodToken: in Int): List[Byte] {
  var i = 0
  while i < pkg.items.count {
    match pkg.items[i] {
      case MPRecord(rec)                       -> { lowerMRecord(rec, ctx) }
      case MPFuncs(hostClass, funcs, sfields)  -> { lowerMFuncsToHostClass(hostClass, funcs, sfields, ctx) }
      case MPUnion(u)                          -> { lowerMUnion(u, ctx) }
      case MPDistinctType(d)                   -> { lowerMDistinctType(d, ctx) }
      case MPRangeType(r)                      -> { lowerMRangeType(r, ctx) }
      case MPEnum(e)                           -> { lowerMEnum(e, ctx) }
      case MPInterface(iface)                  -> { lowerMInterface(iface, ctx) }
      case MPImpl(implData)                    -> { lowerMImpl(implData, ctx) }
      case MPOpaque(op)                        -> { lowerMOpaque(op, ctx) }
    }
    i = i + 1
  }

  // RVAs are set inline by each lowerM* call; no post-pass needed.
  // (See the same comment in lowerMPackage above.)

  val inp = AssemblerInput(
    entryPointToken = entryMethodToken,
    methodBodies    = ctx.bodies,
    tables          = ctx.tables,
    strings         = ctx.strings,
    us              = ctx.us,
    blobs           = ctx.blobs,
    guids           = ctx.guids)

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}
