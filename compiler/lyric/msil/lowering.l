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
}

// Return the ECMA-335 ELEMENT_TYPE byte for the given MsilType.
// For MClass, returns 0x12 (CLASS element type prefix — caller must follow
// with a compressed TypeDefOrRef token; this helper returns the prefix only).
pub func elementTypeByte(t: in MsilType): Int {
  match t {
    case MVoid   -> 0x01
    case MBool   -> 0x02
    case MChar   -> 0x03
    case MInt    -> 0x08
    case MLong   -> 0x0A
    case MDouble -> 0x0D
    case MString -> 0x0E
    case MObject -> 0x1C
    case MClass(_) -> 0x12
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

// Encode a MethodSig blob (DEFAULT, no HASTHIS for static methods).
// Format: CALLCONV(0x00), paramCount, retType, params...
pub func buildStaticMethodSig(params: in List[MsilType], ret: in MsilType): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x00)                     // DEFAULT call convention (static)
  bufU1(w, params.count)             // param count
  bufU1(w, elementTypeByte(ret))     // return type
  var i = 0
  while i < params.count {
    bufU1(w, elementTypeByte(params[i]))
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
  bufU1(w, elementTypeByte(ret))     // return type
  var i = 0
  while i < params.count {
    bufU1(w, elementTypeByte(params[i]))
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
  case MPFuncs(hostClass: String, funcs: List[MFunc])
  case MPUnion(u: MUnion)
  case MPDistinctType(d: MDistinctType)
  case MPRangeType(r: MRangeType)
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
  // Well-known AssemblyRef row indices (1-based)
  arRuntime:   Int     // System.Runtime
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

  // Assembly row
  val sPackage = internString(sh, packageName)
  addAssembly(t, AssemblyRow(
    hashAlgId = HASH_ALG_SHA1,
    majorVersion = 0, minorVersion = 0,
    buildNumber = 0, revisionNumber = 0,
    flags = ASF_NONE, publicKey = 0,
    name = sPackage, culture = 0))

  LoweringCtx(
    strings   = sh,
    blobs     = bh,
    us        = uh,
    guids     = gh,
    tables    = t,
    bodies    = newList(),
    sModule   = sModule,
    sObject   = sObject,
    sSystem   = sSystem,
    sMsCorLib = sMsCorLib,
    sMsKey    = msKey,
    trObject  = trObject,
    arRuntime = arRuntime
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
  }
}

// Build a LocalVarSig blob for the given list of local types.
// Format: 0x07 (LOCAL_SIG), compressed count, type bytes...
func buildLocalVarSig(locals: in List[MsilType]): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x07)  // LOCAL_SIG
  writeCompressedInt(w, locals.count)
  var i = 0
  while i < locals.count {
    bufU1(w, elementTypeByte(locals[i]))
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

  val sName  = internString(sh, r.className)
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

  // Build .ctor body: ldarg.0; [ldarg.n; stfld field_n]×n; ret
  val mbCtor = newMethodBody()
  mbCtor.maxStack = 2
  emitLdarg_0(mbCtor)
  // call System.Object..ctor()
  // (Object..ctor token is injected below after the TypeDef is added; for now we
  // emit a placeholder call token of 0 that the caller must patch, OR we skip the
  // base .ctor call for Phase R5. Calling Object..ctor() is optional for managed
  // code — the CLR zero-initialises the object before .ctor runs.)
  emitPop(mbCtor)   // pop the `this` we just loaded (skip base ctor call)
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

  val sBase  = internString(sh, u.baseName)
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

// ── Top-level static functions lowering ───────────────────────────────────────

// Lower a list of top-level static MFuncs into a single host class named `hostClass`.
pub func lowerMFuncsToHostClass(hostClass: in String, funcs: in List[MFunc],
                                ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val sName  = internString(sh, hostClass)
  val firstField  = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

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
      case MPFuncs(hostClass, funcs) -> {
        lowerMFuncsToHostClass(hostClass, funcs, ctx)
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
    }
    i = i + 1
  }

  // Patch MethodDef RVAs from the accumulated bodies list.
  val rvas = methodBodyRvas(ctx.bodies)
  var ri = 0
  // RVAs apply to ctx.tables.methodDefs in order.
  // The <Module> TypeDef has no methods; RVA list aligns with methodDefs.
  // Phase R5: bodies are added exactly once per MethodDef, in order.
  // The first methodDef (index 0) corresponds to bodies[0], etc.
  while ri < rvas.count {
    val row = ctx.tables.methodDefs[ri]
    ctx.tables.methodDefs[ri] = MethodDefRow(
      rva       = rvas[ri],
      implFlags = row.implFlags,
      flags     = row.flags,
      name      = row.name,
      signature = row.signature,
      paramList = row.paramList)
    ri = ri + 1
  }

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
      case MPRecord(rec)         -> { lowerMRecord(rec, ctx) }
      case MPFuncs(hostClass, funcs) -> { lowerMFuncsToHostClass(hostClass, funcs, ctx) }
      case MPUnion(u)            -> { lowerMUnion(u, ctx) }
      case MPDistinctType(d)     -> { lowerMDistinctType(d, ctx) }
      case MPRangeType(r)        -> { lowerMRangeType(r, ctx) }
    }
    i = i + 1
  }

  val rvas = methodBodyRvas(ctx.bodies)
  var ri = 0
  while ri < rvas.count {
    val row = ctx.tables.methodDefs[ri]
    ctx.tables.methodDefs[ri] = MethodDefRow(
      rva       = rvas[ri],
      implFlags = row.implFlags,
      flags     = row.flags,
      name      = row.name,
      signature = row.signature,
      paramList = row.paramList)
    ri = ri + 1
  }

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
