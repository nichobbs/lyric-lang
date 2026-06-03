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
  // GENERICINST CLASS (ELEMENT_TYPE_GENERICINST = 0x15).
  // Used in MemberRef return-type signatures for stdlib functions that return
  // generic types such as `Option[Int]`.  `typeRefCode` is the compressed
  // TypeDefOrRef coded index (tdrTypeRef(row)) for the open generic type; the
  // CLR matches it by resolving the TypeRef to its declared type identity, not
  // by row number, so the consumer module's TypeRef row differs from the
  // producer DLL's without causing a MissingMethodException (#1142).
  // `headFqn` is the dotted FQN of the generic type head (e.g. "Std.Core.Option")
  // and is used by pattern-matching codegen to construct case-class names such
  // as "Std.Core.Option$Some" for isinst/field-read instructions.
  case MGenericInst(typeRefCode: Int, headFqn: String, typeArgs: List[MsilType])
  // Lyric List[T] — runtime representation is List<object>, so this
  // serialises as MObject (0x1C) in all MSIL signatures.  The element
  // type is carried purely for codegen tracking: EIndex on an MListOf
  // receiver emits castclass to the element type, enabling correct
  // cross-package field access on list elements (#1442).
  case MListOf(elemTy: MsilType)
  // Lyric Map[K, V] — runtime representation is Dictionary<object,object>,
  // serialises as MObject (0x1C).  Carried to distinguish Maps from Lists
  // so that `.count` dispatch uses Dictionary.get_Count rather than
  // List.get_Count.
  case MMapOf(keyTy: MsilType, valTy: MsilType)
  // System.Byte (ELEMENT_TYPE_U1 = 0x05).  Used for `slice[Byte]` elements
  // so cross-package signatures match the F# stdlib's `byte[]` (e.g.
  // `Std.Encoding.tryDecodeBase64 -> Option[byte[]]`).
  case MByte
  // CLI single-dimension zero-based array `T[]` (ELEMENT_TYPE_SZARRAY = 0x1D
  // followed by the element type).  Lyric `slice[T]` lowers to `T[]` so that
  // cross-package MemberRef signatures agree with the F#-compiled stdlib,
  // which represents slices as real arrays rather than erasing to object.
  case MArray(elemTy: MsilType)
  // BCL value type referenced by a TypeRef (ELEMENT_TYPE_VALUETYPE = 0x11
  // followed by a compressed TypeDefOrRef coded index).  Used for extern
  // types that map to a .NET struct — e.g. `extern type Uuid = "System.Guid"`,
  // `Instant = "System.DateTime"`, `Duration = "System.TimeSpan"`.  Without
  // this, such a type degraded to ELEMENT_TYPE_OBJECT (0x1C) in cross-package
  // MemberRef signatures, so a consumer's `newUuid(): Uuid` reference encoded
  // `():object` while the producer DLL emits `():valuetype System.Guid` — the
  // CLR signature mismatch faulted at runtime with `Method not found` (#1602).
  // `typeRefCode` is the compressed TypeDefOrRef coded index (tdrTypeRef(row))
  // for the struct's TypeRef; `clrFqn` is the dotted CLR FQN (e.g.
  // "System.Guid") carried for diagnostics / box-token resolution.
  case MValueTypeRef(typeRefCode: Int, clrFqn: String)
  // A reference (class) type identified by a pre-interned TypeRef — the
  // counterpart of MValueTypeRef for ref types.  Unlike MClass it carries its
  // TypeRef, so a method signature encodes CLASS + TypeRef (required for a
  // MemberRef return/param to bind to the real method) rather than degrading
  // to Object.  Used by metadata-resolved auto-FFI for class returns/params.
  case MClassRef(typeRefCode: Int, clrFqn: String)
  // A managed pointer (`T&`) to `inner` — ELEMENT_TYPE_BYREF.  Used ONLY to
  // encode an `out`/`inout` parameter in a method signature's parameter list.
  // It never represents a stack value, local, field, return, or generic
  // argument, so `bufMsilType` (signature encoding) is the only consumer that
  // must decode it; `elementTypeByte` carries a defensive case for the same
  // reason.  See #1761.
  case MByRef(inner: MsilType)
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
    case MObject          -> 0x1C
    case MClass(_)        -> 0x12
    case MTypeVar(_)      -> 0x13  // prefix only; index byte emitted separately by bufMsilType
    case MNativeInt       -> 0x18
    case MGenericInst(_, _, _) -> 0x15  // prefix only; full encoding via bufMsilType
    case MListOf(_)       -> 0x1C  // same as Object: runtime rep is List<object>
    case MMapOf(_, _)     -> 0x1C  // same as Object: runtime rep is Dictionary<object,object>
    case MByte            -> 0x05  // ELEMENT_TYPE_U1
    case MArray(_)        -> 0x1D  // ELEMENT_TYPE_SZARRAY prefix; element follows (bufMsilType)
    case MValueTypeRef(_, _) -> 0x11  // ELEMENT_TYPE_VALUETYPE prefix; TypeRef follows (bufMsilType)
    case MClassRef(_, _)     -> 0x12  // ELEMENT_TYPE_CLASS prefix; TypeRef follows (bufMsilType)
    case MByRef(_)           -> 0x10  // ELEMENT_TYPE_BYREF prefix; pointee follows (bufMsilType)
  }
}

// Emit the `ldind.*` opcode that dereferences a managed pointer whose pointee
// is `ty`.  Used to read an `inout` parameter (whose slot holds a `T&`).  Lyric
// primitives load natively (i4/i8/r8); every reference-shaped type (object,
// string, class, list/map, generic instance, type variable) uses `ldind.ref`.
func emitLdindForType(mb: in MethodBody, ty: in MsilType): Unit {
  match ty {
    case MInt    -> emitLdind_I4(mb)
    case MLong   -> emitLdind_I8(mb)
    case MDouble -> emitLdind_R8(mb)
    case MBool   -> emitLdind_I1(mb)
    case MChar   -> emitLdind_U2(mb)
    case MByte   -> emitLdind_I1(mb)
    case _       -> emitLdind_Ref(mb)
  }
}

// Emit the `stind.*` opcode that stores through a managed pointer whose pointee
// is `ty`.  Counterpart of `emitLdindForType`; used to write an `out`/`inout`
// parameter.
func emitStindForType(mb: in MethodBody, ty: in MsilType): Unit {
  match ty {
    case MInt    -> emitStind_I4(mb)
    case MLong   -> emitStind_I8(mb)
    case MDouble -> emitStind_R8(mb)
    case MBool   -> emitStind_I1(mb)
    case MChar   -> emitStind_I2(mb)
    case MByte   -> emitStind_I1(mb)
    case _       -> emitStind_Ref(mb)
  }
}

// Normalise a type when it appears as a *generic type argument*.  `Unit`
// lowers to `MVoid`, but `ELEMENT_TYPE_VOID` (0x01) is illegal inside a
// GENERICINST signature (ECMA-335 §II.23.2.14) — emitting it produces a
// malformed blob that the CLR rejects with "The signature is incorrect"
// when it loads any method whose signature references the instantiation
// (e.g. `Result[Unit, E]`).  Erase it to `object`, matching how `Unit`
// values are represented at run time.  Only applied to type arguments;
// a `Unit`/`void` *return* type still encodes as 0x01.
func genericArgType(t: in MsilType): MsilType {
  match t {
    case MVoid          -> MObject
    // Recurse into array elements so a `slice[Unit]` argument encodes as
    // `object[]` rather than the illegal `void[]` (#1582).
    case MArray(elem)   -> MArray(elemTy = genericArgType(elem))
    case _              -> t
  }
}

// Emit an MsilType encoding into w, handling multi-byte cases.
// MTypeVar emits 0x13 + index; MClass currently degrades to
// ELEMENT_TYPE_OBJECT (0x1C) — same workaround the local-var sig builder
// applies (see `buildLocalVarSig` comment).  A full CLASS+TypeDefOrRef
// encoding requires the LoweringCtx so the writer can look up the TypeDef
// row by class name; that refactor is tracked alongside #1183 Phase 2/3.
// All other types emit a single element-type byte.
pub func bufMsilType(w: in ByteWriter, t: in MsilType): Unit {
  match t {
    case MTypeVar(idx) -> {
      bufU1(w, 0x13)
      bufU1(w, idx)
    }
    case MClass(_) -> bufU1(w, 0x1C)   // Object: avoids malformed CLASS+TypeDefOrRef entry
    case MValueTypeRef(typeRefCode, _) -> {
      bufU1(w, 0x11)   // ELEMENT_TYPE_VALUETYPE
      writeCompressedInt(w, typeRefCode)
    }
    case MClassRef(typeRefCode, _) -> {
      bufU1(w, 0x12)   // ELEMENT_TYPE_CLASS
      writeCompressedInt(w, typeRefCode)
    }
    case MArray(elem) -> {
      bufU1(w, 0x1D)   // ELEMENT_TYPE_SZARRAY
      bufMsilType(w, elem)
    }
    case MByRef(inner) -> {
      bufU1(w, 0x10)   // ELEMENT_TYPE_BYREF (out/inout parameter)
      bufMsilType(w, inner)
    }
    case MGenericInst(typeRefCode, _, typeArgs) -> {
      bufU1(w, 0x15)   // ELEMENT_TYPE_GENERICINST
      bufU1(w, 0x12)   // ELEMENT_TYPE_CLASS (reference type)
      writeCompressedInt(w, typeRefCode)
      bufU1(w, typeArgs.count)
      var gi = 0
      while gi < typeArgs.count {
        bufMsilType(w, genericArgType(typeArgs[gi]))
        gi = gi + 1
      }
    }
    case other -> bufU1(w, elementTypeByte(other))
  }
}

// Encode a FieldSig blob for the given field type.
// Format: 0x06 (FIELD) + bufMsilType(t).
// MClass degrades to ELEMENT_TYPE_OBJECT (0x1C) via bufMsilType so that
// field access uses object-typed fields throughout (matching the bootstrap
// emitter's object-typed approach and avoiding a malformed CLASS+token entry).
pub func buildFieldSig(t: in MsilType): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x06)          // FIELD
  bufMsilType(w, t)
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

// Encode a FieldSig blob for a generic type-parameter field (VAR element type).
// Used for cross-assembly union case fields whose declared type is a type
// generic parameter (e.g. `value: T` on `Option_Some<T>`).
// Format: FIELD(0x06) + VAR(0x13) + paramIndex.
pub func buildGenericParamFieldSig(paramIndex: in Int): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x06)   // FIELD
  bufU1(w, 0x13)   // VAR (type generic parameter)
  bufU1(w, paramIndex)
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
pub func writeCompressedInt(w: in ByteWriter, v: in Int): Unit {
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
  case MLdarga(slot: Int)          // load address of argument (byref out/inout param)
  case MLdind(ty: MsilType)        // load indirect through a managed pointer (deref)
  case MStind(ty: MsilType)        // store indirect through a managed pointer

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
  // Like `MIsinstByName` but emits `castclass` instead of `isinst`.
  // Used by EIndex to narrow a list element from object to its
  // declared type (e.g. castclass Lyric.Parser.Item) so subsequent
  // field accesses can use the MClass token path (#1442).
  case MCastclassByName(className: String)
  case MIsinst(typeToken: Int)         // isinst (test then push ref or null)
  // Like `MIsinst` but defers TypeDef row resolution until lowering time
  // — used by `lowerPatternTestMsil` to test against a user-defined
  // case TypeDef whose row isn't allocated until `lowerMUnion` runs
  // (i.e. AFTER the codegen pass that emits this instruction).  Looked
  // up via `findTypeDefRowByName`; falls back to `isinst System.Object`
  // when the type isn't in the assembly (e.g. cross-bundle reference).
  case MIsinstByName(className: String)
  // Like `MIsinstByName` but for generic types: builds a closed TypeSpec
  // (GENERICINST encoding) using the given concrete type arguments, then
  // emits `isinst TypeSpec`.  Required for stdlib union cases such as
  // `Option_None<T>` where a bare open TypeRef would mis-behave at runtime.
  case MIsinstGeneric(className: String, typeArgs: List[MsilType])
  // Like `MCastclassByName` but for generic types: builds a closed TypeSpec at
  // lowering time (Phase 5) using `buildGenericInstBlobWithCtx` so the TypeDef
  // table is fully populated before the blob is constructed.  Required for
  // stdlib union case classes (e.g. `Option_Some<Keyword>`) where the type arg
  // is a TypeDef that isn't in the table during codegen Phase 3.
  case MCastclassGeneric(className: String, typeArgs: List[MsilType])
  // ldfld on a field of a generic type instantiation.  TypeSpec and TypeSpec-
  // parented MemberRef are built at lowering time (Phase 5) so all TypeDefs are
  // available.  `fieldSig` is the FIELD signature blob (e.g. `FIELD VAR(0)`).
  case MLdfldGeneric(baseClassName: String, typeArgs: List[MsilType], fieldName: String, fieldSig: List[Byte])
  // newobj for a generic union case constructor.  TypeSpec and TypeSpec-parented
  // MemberRef are built at Phase 5 (lowering) so TypeDefs for in-bundle type
  // arguments (e.g. Lyric.Lexer.Keyword) are fully allocated before the
  // GENERICINST blob is constructed.  At Phase 3 (codegen), `Lyric.Lexer.Keyword`
  // is not yet in the TypeDef table (lowerMUnion runs at Phase 5), so building
  // the blob at Phase 3 would degrade MClass("Lyric.Lexer.Keyword") to
  // ELEMENT_TYPE_OBJECT — mismatching the isinst TypeSpec and causing the
  // "match not exhaustive" panic (#1442).
  // `typeRefRow` — 1-based TypeRef row for the case class (e.g. Option_None).
  // `typeArgs`   — concrete type arguments (e.g. [MClass("Lyric.Lexer.Keyword")]).
  // `ctorParams` — constructor parameter MSIL types (empty for nullary cases;
  //                [MTypeVar(0)] for a single generic-parameter field).
  case MNewobjGenericCase(typeRefRow: Int, typeArgs: List[MsilType], ctorParams: List[MsilType])
  case MBox(typeToken: Int)            // box value type
  case MUnboxAny(typeToken: Int)       // unbox.any

  // Misc
  case MDup
  case MPop
  case MThrow
  case MLdlen                          // load array length (pushes native int)
  case MLdelemRef                      // ldelem.ref — reference array element (String[], object[])
  case MLdelemU1                       // ldelem.u1  — byte array element (byte[])
  case MLdelemI4                       // ldelem.i4  — int32 array element (int[])
  case MLdftn(methodToken: Int)        // ldftn — load function pointer (ELEMENT_TYPE_I on stack)

  // Exception-handling instructions and meta-instruction
  case MLeave(label: Int)              // leave — exit protected region (clears stack, branches)
  case MEndfinally                     // endfinally — exit finally/fault handler
  case MEHClause(                      // meta-insn: register one exception-handler clause
    flags:        Int,                 //   0=typed catch, 2=finally, 4=fault
    tryStart:     Int,                 //   label ID for start of protected region
    tryEnd:       Int,                 //   label ID for first insn after protected region
    handlerStart: Int,                 //   label ID for start of handler code
    handlerEnd:   Int,                 //   label ID for first insn after handler code
    catchToken:   Int)                 //   TypeRef/TypeDef token (0 for finally/fault)
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
  // Resource payload to embed in the PE.  Each resource is encoded as
  // a 4-byte little-endian length prefix followed by the resource
  // bytes; multiple resources are concatenated in `ManifestResource`
  // table row order.  Empty when the bridge doesn't embed any
  // resources (the common case before `Lyric.Contract` embedding
  // shipped).
  resourceData: List[Byte]
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
// `major` / `minor` populate the Assembly row's version (`addAssembly`
// at the bottom of this function); pass `(0, 0)` for the bootstrap-
// compatible default.  Consumers thread the manifest's `[package].version`
// through `Msil.Bridge` (see #1364).
pub func newLoweringCtx(packageName: in String,
                        major: in Int, minor: in Int): LoweringCtx {
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
    majorVersion = major, minorVersion = minor,
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
    mrObjectCtor = mrObjectCtor,
    resourceData = newList()
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

// Parse a `<major>.<minor>(.<patch>)?` semver string into `[major, minor]`
// for the Assembly / AssemblyRef rows.  An empty or unparseable input
// returns `[0, 0]` — matching the bootstrap-grade default both rows used
// before manifest-version threading landed (#1364).  Patch and pre-
// release segments are ignored; ECMA-335 only carries major / minor /
// build / revision, and the `Lyric.Contract` resource captures the full
// semver string separately for `public-api-diff`.
//
// Lives in `lowering.l` (not `bridge.l`) because both the bridge entry
// points and the codegen-side `ensureAssemblyRefForArtifact` consume it,
// and `codegen.l` already imports `Msil.Lowering`.
pub func parseSemverMajorMinor(version: in String): List[Int] {
  val parts: List[Int] = newList()
  if version.length == 0 {
    parts.add(0)
    parts.add(0)
    return parts
  }
  val firstDot = version.indexOf(".")
  if firstDot < 0 {
    parts.add(parseIntOr0(version))
    parts.add(0)
    return parts
  }
  val majStr = version.substring(0, firstDot)
  val rest   = version.substring(firstDot + 1, version.length - firstDot - 1)
  val secondDot = rest.indexOf(".")
  val minStr = if secondDot < 0 { rest }
               else { rest.substring(0, secondDot) }
  parts.add(parseIntOr0(majStr))
  parts.add(parseIntOr0(minStr))
  parts
}

// Parse an ASCII decimal int, returning 0 on any non-digit / overflow.
// Local helper to avoid an `Std.Parse` dependency from the lowering layer.
func parseIntOr0(s: in String): Int {
  if s.length == 0 { return 0 }
  var i = 0
  var n = 0
  while i < s.length {
    val ch = s.substring(i, 1)
    if ch < "0" or ch > "9" { return 0 }
    n = n * 10 + semverParseDigit(ch)
    i = i + 1
  }
  n
}

func semverParseDigit(ch: in String): Int {
  if ch == "0" { 0 }
  else if ch == "1" { 1 }
  else if ch == "2" { 2 }
  else if ch == "3" { 3 }
  else if ch == "4" { 4 }
  else if ch == "5" { 5 }
  else if ch == "6" { 6 }
  else if ch == "7" { 7 }
  else if ch == "8" { 8 }
  else if ch == "9" { 9 }
  else { 0 }
}

// Add a new AssemblyRef row for a BCL / framework assembly and return
// its 1-based row index.  Uses the Microsoft framework public key
// token (`b03f5f7f11d50a3a`) so the loader binds against the
// strong-named host runtime assemblies.  Lyric package refs use
// `ctxAddLyricPackageAssemblyRef` below (no public key token).
pub func ctxAddAssemblyRef(ctx: in LoweringCtx, name: in String,
                           major: in Int, minor: in Int): Int {
  val sName = ctxInternStr(ctx, name)
  addAssemblyRef(ctx.tables, AssemblyRefRow(
    majorVersion = major, minorVersion = minor,
    buildNumber = 0, revisionNumber = 0,
    flags = 0, publicKeyToken = ctx.sMsKey,
    name = sName, culture = 0, hashValue = 0))
}

// Add an AssemblyRef row for an unsigned Lyric package and return its
// 1-based row index.  Lyric-emitted DLLs are unsigned (the Assembly row
// has `publicKey = 0`), so the AssemblyRef must also have
// `publicKeyToken = 0` — otherwise the loader rejects the bind with a
// public-key-token mismatch.  Version threading is tracked in #1364;
// today the major/minor parameters carry through directly.
pub func ctxAddLyricPackageAssemblyRef(ctx: in LoweringCtx, name: in String,
                                       major: in Int, minor: in Int): Int {
  val sName = ctxInternStr(ctx, name)
  addAssemblyRef(ctx.tables, AssemblyRefRow(
    majorVersion = major, minorVersion = minor,
    buildNumber = 0, revisionNumber = 0,
    flags = 0, publicKeyToken = 0,
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

// Build the #Blob encoding for a MethodSpec instantiation signature
// (ECMA-335 §II.23.2.15): GENRICINST (0x0A), compressed generic-argument
// count, then each argument type.  Distinct from the GENERICINST *type*
// signature (0x15) used by TypeSpec — a MethodSpec signature names the
// method's type arguments, not a generic type instantiation.
pub func buildMethodSpecBlob(argTypes: in List[MsilType]): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x0A)  // GENRICINST (method instantiation)
  writeCompressedInt(w, argTypes.count)
  var i = 0
  while i < argTypes.count {
    bufMsilType(w, genericArgType(argTypes[i]))
    i = i + 1
  }
  bufToList(w)
}

// Build the open-generic method signature for `System.Array.Empty<T>(): T[]`
// (ECMA-335 §II.23.2.1).  GENERIC calling convention (0x10), one generic
// parameter, zero formal parameters, return type `SZARRAY MVAR 0` (`!!0[]`).
// The concrete `T` is supplied by the MethodSpec instantiation, not here.
pub func buildArrayEmptyOpenSig(): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x10)             // GENERIC calling convention
  writeCompressedInt(w, 1)   // generic parameter count
  writeCompressedInt(w, 0)   // formal parameter count
  bufU1(w, 0x1D)             // ELEMENT_TYPE_SZARRAY (return is T[])
  bufU1(w, 0x1E)             // ELEMENT_TYPE_MVAR (method generic parameter)
  writeCompressedInt(w, 0)   // method-var index 0
  bufToList(w)
}

// Add a MethodSpec row instantiating a generic method.  `methodCoded` is a
// MethodDefOrRef coded index (use `mdorMemberRef`/`mdorMethodDef`) naming the
// open generic method; `sig` is a `buildMethodSpecBlob` instantiation blob.
// Returns the 1-based row index; the call site uses `0x2B000000 + row`.
pub func ctxAddMethodSpec(ctx: in LoweringCtx, methodCoded: in Int,
                          sigKey: in String, sig: in List[Byte]): Int {
  val bSig = ctxInternBlob(ctx, sigKey, sig)
  addMethodSpec(ctx.tables, MethodSpecRow(
    method = methodCoded,
    instantiation = bSig))
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

// Produce a unique string key for an MsilType, for TypeSpec blob deduplication.
// Must distinguish every concrete encoding produced by bufMsilType.
pub func msilTypeKey(t: in MsilType): String {
  match t {
    case MVoid -> "V"
    case MBool -> "Z"
    case MChar -> "C"
    case MInt -> "I"
    case MLong -> "J"
    case MDouble -> "D"
    case MString -> "S"
    case MObject -> "O"
    case MNativeInt -> "N"
    case MClass(name) -> "L" + name + ";"
    case MTypeVar(idx) -> "T" + toString(idx) + ";"
    case MGenericInst(_, headFqn, typeArgs) -> {
      var key = "G" + headFqn + "<"
      var i = 0
      while i < typeArgs.count {
        key = key + msilTypeKey(typeArgs[i])
        key = key + ","
        i = i + 1
      }
      key + ">"
    }
    case MListOf(e) -> "LIST[" + msilTypeKey(e) + "]"
    case MMapOf(k, v) -> "MAP[" + msilTypeKey(k) + "," + msilTypeKey(v) + "]"
    case MByte -> "B"
    case MArray(e) -> "[" + msilTypeKey(e) + "]"
    case MValueTypeRef(_, clrFqn) -> "VT" + clrFqn + ";"
    case MClassRef(_, clrFqn) -> "CR" + clrFqn + ";"
  }
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
    bufMsilType(w, genericArgType(argTypes[i]))
    i = i + 1
  }
  bufToList(w)
}

// Context-aware variant of bufMsilType.  For MClass types, looks up the
// TypeDef row first (in-bundle) then the TypeRef row (cross-assembly) and
// encodes as ELEMENT_TYPE_CLASS + compressed TypeDefOrRef coded index.
// Falls back to ELEMENT_TYPE_OBJECT (0x1C) when no row is found so the
// output is always valid (matches the context-free path).
func bufMsilTypeWithCtx(w: in ByteWriter, t: in MsilType, ctx: in LoweringCtx): Unit {
  match t {
    case MClass(name) -> {
      val defRow = findTypeDefRowByName(ctx, name)
      if defRow > 0 {
        bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
        writeCompressedInt(w, tdrTypeDef(defRow))
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
          writeCompressedInt(w, tdrTypeRef(refRow))
        } else {
          bufU1(w, 0x1C)  // ELEMENT_TYPE_OBJECT (fallback)
        }
      }
    }
    case MTypeVar(idx) -> {
      bufU1(w, 0x13)
      bufU1(w, idx)
    }
    case MValueTypeRef(typeRefCode, _) -> {
      bufU1(w, 0x11)  // ELEMENT_TYPE_VALUETYPE
      writeCompressedInt(w, typeRefCode)
    }
    case MClassRef(typeRefCode, _) -> {
      bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
      writeCompressedInt(w, typeRefCode)
    }
    case MArray(elem) -> {
      bufU1(w, 0x1D)  // ELEMENT_TYPE_SZARRAY
      bufMsilTypeWithCtx(w, elem, ctx)
    }
    case MGenericInst(typeRefCode, _, typeArgs) -> {
      bufU1(w, 0x15)  // ELEMENT_TYPE_GENERICINST
      bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
      writeCompressedInt(w, typeRefCode)
      bufU1(w, typeArgs.count)
      var gi = 0
      while gi < typeArgs.count {
        bufMsilTypeWithCtx(w, genericArgType(typeArgs[gi]), ctx)
        gi = gi + 1
      }
    }
    case other -> bufU1(w, elementTypeByte(other))
  }
}

// Context-aware version of buildGenericInstBlob.  Uses bufMsilTypeWithCtx
// so that MClass type arguments are encoded as CLASS + TypeDefOrRef rather
// than degrading to ELEMENT_TYPE_OBJECT.  Required for correct isinst /
// castclass TypeSpecs on generic union case classes (e.g. Option_Some<Keyword>).
pub func buildGenericInstBlobWithCtx(ctx: in LoweringCtx,
                                      typeDefOrRef: in Int,
                                      argTypes: in List[MsilType]): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x15)  // ELEMENT_TYPE_GENERICINST
  bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS (reference generic)
  writeCompressedInt(w, typeDefOrRef)
  bufU1(w, argTypes.count)
  var i = 0
  while i < argTypes.count {
    bufMsilTypeWithCtx(w, genericArgType(argTypes[i]), ctx)
    i = i + 1
  }
  bufToList(w)
}

// ── Method body lowering ──────────────────────────────────────────────────────

// Lower one MInsn to opcode bytes in `mb`.
pub func lowerMInsn(ctx: in LoweringCtx, insn: in MInsn, mb: in MethodBody): Unit {
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
    case MLdarga(slot)      -> emitLdarga_S(mb, slot)
    case MLdind(ty)         -> emitLdindForType(mb, ty)
    case MStind(ty)         -> emitStindForType(mb, ty)
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
    case MCastclassByName(name) -> {
      val defRow = findTypeDefRowByName(ctx, name)
      val tok = if defRow > 0 {
        0x02000000 + defRow                     // TypeDef token (local assembly)
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          0x01000000 + refRow                   // TypeRef token (foreign assembly)
        } else {
          0x01000000 + ctx.trObject             // Last resort: System.Object (no-op cast)
        }
      }
      emitCastclass(mb, tok)
    }
    case MIsinst(tok)       -> emitIsinst(mb, tok)
    case MIsinstByName(name) -> {
      val defRow = findTypeDefRowByName(ctx, name)
      val tok = if defRow > 0 {
        0x02000000 + defRow                     // TypeDef token (local assembly)
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          0x01000000 + refRow                   // TypeRef token (foreign assembly)
        } else {
          0x01000000 + ctx.trObject             // Last resort: System.Object
        }
      }
      emitIsinst(mb, tok)
    }
    case MIsinstGeneric(name, typeArgs) -> {
      // Build a closed GENERICINST TypeSpec (e.g. Option_None<Int>) and emit
      // `isinst TypeSpec`.  The open TypeRef of the case class is looked up
      // first in TypeDef (in-bundle cases) then in TypeRef (stdlib cases).
      // The sigKey includes a type-arg fingerprint so that the same case class
      // instantiated at different type arguments (e.g. Option_None<Int> vs
      // Option_None<String>) gets distinct TypeSpec rows rather than sharing
      // the first-registered (possibly wrong) blob.
      var taKey = ""
      var tai = 0
      while tai < typeArgs.count {
        taKey = taKey + msilTypeKey(typeArgs[tai])
        taKey = taKey + ","
        tai = tai + 1
      }
      val defRow = findTypeDefRowByName(ctx, name)
      val tok = if defRow > 0 {
        val codedIdx = tdrTypeDef(defRow)
        val sigKey = "typespec_isinst_def_" + name + "_" + taKey
        val blob   = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
        val specRow = ctxAddTypeSpec(ctx, sigKey, blob)
        0x1B000000 + specRow
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          val codedIdx = tdrTypeRef(refRow)
          val sigKey = "typespec_isinst_ref_" + name + "_" + taKey
          val blob   = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
          val specRow = ctxAddTypeSpec(ctx, sigKey, blob)
          0x1B000000 + specRow
        } else {
          0x01000000 + ctx.trObject             // Last resort: System.Object
        }
      }
      emitIsinst(mb, tok)
    }
    case MCastclassGeneric(name, typeArgs) -> {
      // Build a closed GENERICINST TypeSpec and emit `castclass TypeSpec`.
      // Mirrors MIsinstGeneric but emits castclass instead of isinst.
      // TypeSpec construction is deferred to Phase 5 so all TypeDefs are present.
      var taKey = ""
      var tai = 0
      while tai < typeArgs.count {
        taKey = taKey + msilTypeKey(typeArgs[tai])
        taKey = taKey + ","
        tai = tai + 1
      }
      val defRow = findTypeDefRowByName(ctx, name)
      val tok = if defRow > 0 {
        val codedIdx = tdrTypeDef(defRow)
        val sigKey = "typespec_castclass_def_" + name + "_" + taKey
        val blob   = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
        val specRow = ctxAddTypeSpec(ctx, sigKey, blob)
        0x1B000000 + specRow
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          val codedIdx = tdrTypeRef(refRow)
          val sigKey = "typespec_castclass_ref_" + name + "_" + taKey
          val blob   = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
          val specRow = ctxAddTypeSpec(ctx, sigKey, blob)
          0x1B000000 + specRow
        } else {
          0x01000000 + ctx.trObject
        }
      }
      emitCastclass(mb, tok)
    }
    case MLdfldGeneric(baseName, typeArgs, fieldName, fieldSig) -> {
      // Build a closed GENERICINST TypeSpec and a TypeSpec-parented MemberRef,
      // then emit `ldfld MemberRef`.  Deferred to Phase 5 so all TypeDefs are
      // present and the type arg can be encoded as CLASS TypeDef[N] rather than
      // falling back to ELEMENT_TYPE_OBJECT.
      var taKey = ""
      var tai = 0
      while tai < typeArgs.count {
        taKey = taKey + msilTypeKey(typeArgs[tai])
        taKey = taKey + ","
        tai = tai + 1
      }
      val defRow = findTypeDefRowByName(ctx, baseName)
      val tok = if defRow > 0 {
        val codedIdx = tdrTypeDef(defRow)
        val tsKey  = "typespec_ldfld_def_" + baseName + "_" + taKey
        val blob   = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
        val tsRow  = ctxAddTypeSpec(ctx, tsKey, blob)
        val mrKey  = "mr_ldfld_def_" + baseName + "_" + taKey + "_" + fieldName
        val mrRow  = ctxAddMemberRefForTypeSpec(ctx, tsRow, fieldName, mrKey, fieldSig)
        0x0A000000 + mrRow
      } else {
        val refRow = findTypeRefRowByName(ctx, baseName)
        if refRow > 0 {
          val codedIdx = tdrTypeRef(refRow)
          val tsKey  = "typespec_ldfld_ref_" + baseName + "_" + taKey
          val blob   = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
          val tsRow  = ctxAddTypeSpec(ctx, tsKey, blob)
          val mrKey  = "mr_ldfld_ref_" + baseName + "_" + taKey + "_" + fieldName
          val mrRow  = ctxAddMemberRefForTypeSpec(ctx, tsRow, fieldName, mrKey, fieldSig)
          0x0A000000 + mrRow
        } else {
          0
        }
      }
      if tok > 0 {
        emitLdfld(mb, tok)
      }
    }
    case MNewobjGenericCase(typeRefRow, typeArgs, ctorParams) -> {
      // Build a closed GENERICINST TypeSpec and a TypeSpec-parented .ctor
      // MemberRef at Phase 5, when in-bundle TypeDefs are fully allocated.
      // The case class is always a cross-assembly TypeRef (stdlib), so we use
      // the supplied `typeRefRow` directly — no TypeDef search needed.
      val codedIdx = tdrTypeRef(typeRefRow)
      var taKey = ""
      var tai = 0
      while tai < typeArgs.count {
        taKey = taKey + msilTypeKey(typeArgs[tai]) + ","
        tai = tai + 1
      }
      val tsBlob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
      val tsKey  = "newobj_ts_gcase_" + toString(typeRefRow) + "_" + taKey
      val tsRow  = ctxAddTypeSpec(ctx, tsKey, tsBlob)
      val ctorSig = buildInstanceMethodSig(ctorParams, MVoid)
      var cpKey = ""
      var cpi = 0
      while cpi < ctorParams.count {
        cpKey = cpKey + msilTypeKey(ctorParams[cpi]) + ","
        cpi = cpi + 1
      }
      val mrKey = "newobj_mr_gcase_" + toString(typeRefRow) + "_" + taKey + "_" + cpKey
      val mrRow = ctxAddMemberRefForTypeSpec(ctx, tsRow, ".ctor", mrKey, ctorSig)
      emitNewobj(mb, 0x0A000000 + mrRow)
    }
    case MBox(tok)          -> emitBox(mb, tok)
    case MUnboxAny(tok)     -> emitUnbox_Any(mb, tok)
    case MDup               -> emitDup(mb)
    case MPop               -> emitPop(mb)
    case MThrow             -> emitThrow(mb)
    case MLdlen             -> emitLdlen(mb)
    case MLdelemRef         -> emitLdelem_Ref(mb)
    case MLdelemU1          -> emitLdelem_U1(mb)
    case MLdelemI4          -> emitLdelem_I4(mb)
    case MLdftn(tok)        -> emitLdftn(mb, tok)
    case MLeave(lbl)        -> emitLeave(mb, lbl)
    case MEndfinally        -> emitEndfinally(mb)
    case MEHClause(f, ts, te, hs, he, ct) ->
      mbAddEHClause(mb, EHClause(
        flags        = f,
        tryStart     = ts,
        tryEnd       = te,
        handlerStart = hs,
        handlerEnd   = he,
        catchToken   = ct))
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
    match locals[i] {
      case MClass(_)             -> bufU1(w, 0x1C)   // Object: avoids malformed CLASS+TypeDefOrRef entry
      case MGenericInst(_, _, _) -> bufU1(w, 0x1C)  // same: TypeRef token not valid in LocalVarSig
      // A slice local degrades to Object too: the codegen treats slices as
      // opaque references (a `byte[]` value is still an object), and
      // `elementTypeByte(MArray)` is only the 0x1D SZARRAY *prefix* — writing
      // it alone produces a malformed LocalVarSig (dangling prefix, no element
      // type) that corrupts the evaluation stack at run time (AccessViolation).
      case MArray(_)             -> bufU1(w, 0x1C)
      // A value-typed extern local (e.g. `val u = newUuid()` where Uuid is
      // System.Guid) CANNOT degrade to Object — a struct is not a reference,
      // so an `object` slot would mis-store the unboxed value.  Emit the full
      // VALUETYPE (0x11) + TypeRef token; unlike the MClass case above, the
      // token IS valid here because the struct's TypeRef is already allocated
      // (#1602).
      case MValueTypeRef(typeRefCode, _) -> {
        bufU1(w, 0x11)
        writeCompressedInt(w, typeRefCode)
      }
      // A class-ref local is a reference, so it degrades to Object safely
      // (like MClass above) — an object-typed slot holds any ref correctly.
      case MClassRef(_, _)       -> bufU1(w, 0x1C)
      case other -> bufU1(w, elementTypeByte(other))
    }
    i = i + 1
  }
  bufToList(w)
}

// Build a content-based intern key for a LocalVarSig blob.
// Uses the same element-type encoding as buildLocalVarSig so that two
// local-var lists with identical encoded types share one blob entry.
// Must NOT use the function name as the key: two functions in different
// packages may share the same simple name (e.g. `advance` in Lyric.Lexer
// and Lyric.Parser) but have different local types, causing the second
// function's LocalVarSig to be silently aliased to the first's (#1442).
func buildLvSigKey(locals: in List[MsilType]): String {
  var key = "lv_"
  var i = 0
  while i < locals.count {
    // Value-typed locals encode their TypeRef token, so two distinct structs
    // (System.Guid vs System.DateTime) produce different LocalVarSig blobs and
    // must NOT share an intern key — fold the TypeRef code into the key
    // (#1602).  Reference / primitive locals key on the element-type byte.
    match locals[i] {
      case MValueTypeRef(typeRefCode, _) -> {
        key = key + "vt" + toString(typeRefCode) + "_"
      }
      case _ -> {
        val b = match locals[i] {
          case MClass(_)             -> 0x1C
          case MClassRef(_, _)       -> 0x1C
          case MGenericInst(_, _, _) -> 0x1C
          case other                 -> elementTypeByte(other)
        }
        key = key + toString(b) + "_"
      }
    }
    i = i + 1
  }
  key
}

// Lower an MFunc to a MethodBody and register it in the context.
// Returns the MethodBody (for RVA assignment by the caller).
pub func lowerMFunc(f: in MFunc, ctx: in LoweringCtx): MethodBody {
  val mb = newMethodBody()
  if f.locals.count > 0 {
    val lvSig  = buildLocalVarSig(f.locals)
    val lvBlob = ctxInternBlob(ctx, buildLvSigKey(f.locals), lvSig)
    val lvRow  = addStandAloneSig(ctx.tables, StandAloneSigRow(signature = lvBlob))
    mbSetLocalSig(mb, standaloneToken(lvRow))
  }
  mb.maxStack = f.maxStack
  var i = 0
  while i < f.insns.count {
    lowerMInsn(ctx, f.insns[i], mb)
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
    val fRow  = addField(t, FieldRow(flags = f.flags, name = sF, signature = bSig))
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

  // Build .ctor body: ldarg.0; call <base>::.ctor(); [ldarg.n; stfld field_n]×n; ret
  // The base-class call is required: ECMA-335 §I.8.9.6.6 mandates that every
  // instance constructor initialises `this` by calling a base constructor before
  // returning.  Omitting it produces ilverify error ThisUninitReturn and an
  // InvalidProgramException at JIT time on modern .NET runtimes.
  // For union cases, call the base union class's protected .ctor, not Object's.
  val recBaseCtorTok =
    if r.baseClass.length > 0 and r.baseClass != "System.Object" {
      val recBaseTypeRow = findTypeDefRowByName(ctx, r.baseClass)
      if recBaseTypeRow > 0 {
        val recBaseCtorRow = findMethodDefRowOfType(ctx, recBaseTypeRow, ".ctor")
        if recBaseCtorRow > 0 { 0x06000000 + recBaseCtorRow }
        else { 0x0A000000 + ctx.mrObjectCtor }
      } else { 0x0A000000 + ctx.mrObjectCtor }
    } else { 0x0A000000 + ctx.mrObjectCtor }
  val mbCtor = newMethodBody()
  mbCtor.maxStack = 2
  emitLdarg_0(mbCtor)
  emitCall(mbCtor, recBaseCtorTok)
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
    // Arity-qualify the intern key (#1536) so same-name overloads don't collide in `internBlob`'s dedup.
    val bMSig  = internBlob(bh, "meth_" + r.className + "_" + m.name + "/" + toString(m.params.count), mSig)
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

  // TypeDef row — extends the base class when one is specified (union case
  // classes extend their union base; plain records default to System.Object).
  val recBaseRow = if r.baseClass.length > 0 and r.baseClass != "System.Object" {
    findTypeDefRowByName(ctx, r.baseClass)
  } else { 0 }
  val recExtendsToken = if recBaseRow > 0 { tdrTypeDef(recBaseRow) } else { objectTypeToken(ctx) }
  // ECMA-335 / CLR constraint: SequentialLayout is only valid when the parent
  // is System.Object, System.ValueType, or another SequentialLayout/ExplicitLayout
  // class.  Union case classes extend their abstract AutoLayout base, so they
  // must use AutoLayout (no TDF_SEQUENTIAL_LAYOUT) to pass type loading.
  val recFlags = if recBaseRow > 0 {
    TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT
  } else {
    TDF_PUBLIC + TDF_SEALED + TDF_SEQUENTIAL_LAYOUT + TDF_BEFORE_FIELD_INIT
  }
  addTypeDef(t, TypeDefRow(
    flags         = recFlags,
    typeName      = sName,
    typeNamespace = sNs,
    extends       = recExtendsToken,
    fieldList     = firstField,
    methodList    = firstMethod))
}

// ── Union lowering ────────────────────────────────────────────────────────────

// Lower a nullary union case (no fields) as a sealed class with a static singleton
// `Instance` field and a static constructor (.cctor) that initialises it.
//
// Emits rows in this order (matching addPackageTokens for nullary cases):
//   Field[firstField]   — Instance (public static initonly, type = Object)
//   Method[firstMethod] — .ctor()  (public, HideBySig, SpecialName, RTSpecialName)
//   Method[firstMethod+1] — .cctor() (private static, HideBySig, SpecialName, RTSpecialName)
//   TypeDef — sealed class extending Object, fieldList = firstField, methodList = firstMethod
//
// Construction sites emit `ldsfld Instance` instead of `newobj .ctor()` so that
// reference-equality comparisons (BEq / Object.Equals) succeed across multiple uses
// of the same nullary case.
pub func lowerMNullaryUnionCase(r: in MRecord, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t  = ctx.tables

  val simpleNameRec = if r.namespace.length == 0 { r.className }
                      else { r.className.substring(r.namespace.length + 1, r.className.length - r.namespace.length - 1) }
  val sName = internString(sh, simpleNameRec)
  val sNs   = internString(sh, r.namespace)

  val firstField  = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit Instance static field (public, static, initonly; type = Object).
  val sInstance   = internString(sh, "Instance")
  val instSig     = buildFieldSig(MObject)
  val bInstSig    = internBlob(bh, "inst_" + r.className, instSig)
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_STATIC + FDA_INIT_ONLY,
                       name = sInstance, signature = bInstSig))

  // Emit .ctor() — no parameters; calls the union base's protected .ctor.
  // If the base is a local TypeDef (union case hierarchy), chain through its
  // protected .ctor rather than calling Object::.ctor() directly.
  val baseCtorTok =
    if r.baseClass.length > 0 and r.baseClass != "System.Object" {
      val baseTypeRow = findTypeDefRowByName(ctx, r.baseClass)
      if baseTypeRow > 0 {
        val baseCtorRow = findMethodDefRowOfType(ctx, baseTypeRow, ".ctor")
        if baseCtorRow > 0 { 0x06000000 + baseCtorRow }
        else { 0x0A000000 + ctx.mrObjectCtor }
      } else { 0x0A000000 + ctx.mrObjectCtor }
    } else { 0x0A000000 + ctx.mrObjectCtor }
  val mbCtor    = newMethodBody()
  mbCtor.maxStack = 2
  emitLdarg_0(mbCtor)
  emitCall(mbCtor, baseCtorTok)
  emitRet(mbCtor)
  ctx.bodies.add(mbCtor)
  val rvasCtor  = methodBodyRvas(ctx.bodies)
  val ctorRva   = rvasCtor[ctx.bodies.count - 1]
  val fpCtor    = t.params_.count + 1
  val sCtor     = internString(sh, ".ctor")
  val ctorSig   = buildInstanceMethodSig(newList(), MVoid)
  val bCtorSig  = internBlob(bh, "ctor_" + r.className, ctorSig)
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(t, MethodDefRow(
    rva       = ctorRva,
    implFlags = 0,
    flags     = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
    name      = sCtor,
    signature = bCtorSig,
    paramList = fpCtor))

  // Emit .cctor() — creates the singleton Instance.
  // .ctor MethodDef token = 0x06000000 + firstMethod (already emitted above).
  // Instance FieldDef token = 0x04000000 + firstField (already emitted above).
  val mbCctor   = newMethodBody()
  mbCctor.maxStack = 2
  emitNewobj(mbCctor, 0x06000000 + firstMethod)
  emitStsfld(mbCctor, 0x04000000 + firstField)
  emitRet(mbCctor)
  ctx.bodies.add(mbCctor)
  val rvasCctor = methodBodyRvas(ctx.bodies)
  val cctorRva  = rvasCctor[ctx.bodies.count - 1]
  val fpCctor   = t.params_.count + 1
  val sCctor    = internString(sh, ".cctor")
  val cctorSig  = buildStaticMethodSig(newList(), MVoid)
  val bCctorSig = internBlob(bh, "cctor_" + r.className, cctorSig)
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(t, MethodDefRow(
    rva       = cctorRva,
    implFlags = 0,
    flags     = MDA_PRIVATE + MDA_STATIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
    name      = sCctor,
    signature = bCctorSig,
    paramList = fpCctor))

  // TypeDef row — sealed class extending the union base class (or Object as
  // fallback when the base is not a local TypeDef, e.g. for cross-package use).
  val baseDefRow = if r.baseClass.length > 0 and r.baseClass != "System.Object" {
    findTypeDefRowByName(ctx, r.baseClass)
  } else { 0 }
  val extendsToken = if baseDefRow > 0 { tdrTypeDef(baseDefRow) } else { objectTypeToken(ctx) }
  // ECMA-335 / CLR constraint: SequentialLayout is only valid when the parent
  // is System.Object, System.ValueType, or another SequentialLayout/ExplicitLayout
  // class.  Union case classes extend their abstract AutoLayout base, so they
  // must use AutoLayout (no TDF_SEQUENTIAL_LAYOUT flag) to avoid a
  // TypeLoadException "format is invalid" at assembly load time.
  val caseFlags = if baseDefRow > 0 {
    TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT
  } else {
    TDF_PUBLIC + TDF_SEALED + TDF_SEQUENTIAL_LAYOUT + TDF_BEFORE_FIELD_INIT
  }
  addTypeDef(t, TypeDefRow(
    flags         = caseFlags,
    typeName      = sName,
    typeNamespace = sNs,
    extends       = extendsToken,
    fieldList     = firstField,
    methodList    = firstMethod))
}

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
    // Arity-qualify the intern key (#1536) — see the `meth_` site above.
    val bSig = internBlob(bh, "basemeth_" + u.baseName + "_" + m.name + "/" + toString(m.params.count), mSig)
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

  // Protected no-arg .ctor for the abstract base.  The F# bootstrap emitter
  // defines this constructor so derived case classes can chain through it.
  // Without it, the CLR refuses to load case classes whose TypeDef extends
  // the union base when their own .ctor calls Object::.ctor() directly.
  val sBaseCtor    = internString(sh, ".ctor")
  val baseCtorSig  = buildInstanceMethodSig(newList(), MVoid)
  val bBaseCtorSig = internBlob(bh, "union_base_ctor_" + u.baseName, baseCtorSig)
  val mbBaseCtor   = newMethodBody()
  mbBaseCtor.maxStack = 1
  emitLdarg_0(mbBaseCtor)
  emitCall(mbBaseCtor, 0x0A000000 + ctx.mrObjectCtor)
  emitRet(mbBaseCtor)
  ctx.bodies.add(mbBaseCtor)
  val rvasBaseCtor = methodBodyRvas(ctx.bodies)
  val baseCtorRva  = rvasBaseCtor[ctx.bodies.count - 1]
  val fpBaseCtor   = t.params_.count + 1
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(t, MethodDefRow(
    rva       = baseCtorRva,
    implFlags = 0,
    flags     = MDA_FAMILY + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
    name      = sBaseCtor,
    signature = bBaseCtorSig,
    paramList = fpBaseCtor))

  // Abstract base TypeDef
  val baseRow = addTypeDef(t, TypeDefRow(
    flags         = TDF_PUBLIC + TDF_ABSTRACT + TDF_BEFORE_FIELD_INIT,
    typeName      = sBase,
    typeNamespace = sNs,
    extends       = objectTypeToken(ctx),
    fieldList     = baseFirstField,
    methodList    = baseFirstMethod))

  // Emit case classes extending the base.
  // Nullary cases (no fields) are lowered via lowerMNullaryUnionCase, which emits
  // a static `Instance` singleton field and a .cctor so that reference-equality
  // comparisons work (Object.Equals on different newobj calls would fail).
  var ci = 0
  while ci < u.cases.count {
    val c = u.cases[ci]
    val rec = MRecord(
      className = c.name,
      namespace = u.namespace,
      baseClass = u.baseName,
      fields    = c.fields,
      methods   = newList())
    if c.fields.count == 0 {
      lowerMNullaryUnionCase(rec, ctx)
    } else {
      lowerMRecord(rec, ctx)
    }
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
    // Arity-qualify the intern key (#1536) — see the `meth_` site above.
    val bSig = internBlob(bh, "ifmeth_" + iface.className + "_" + m.name + "/" + toString(m.params.count), mSig)
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

// Find the 1-based TypeRef row whose namespace + name match the given FQN.
// Mirrors `findTypeDefRowByName` but searches the TypeRef table instead of
// TypeDef.  Used by `MIsinstByName` as a fallback when the type is defined in
// a foreign assembly (TypeRef) rather than the current module (TypeDef) — e.g.
// union case classes like `Std.Core.Option$Some` imported from `Lyric.Stdlib.Core`.
// Returns 0 when no matching TypeRef exists.
pub func findTypeRefRowByName(ctx: in LoweringCtx, fqn: in String): Int {
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
  while i < t.typeRefs.count {
    val tr = t.typeRefs[i]
    if tr.typeNamespace == sNs and tr.typeName == sSN {
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

  // The free-function host class is named `<package>.Program`: the
  // *full* package path (e.g. `Lyric.Pkg.Greeter`) is the CLR namespace
  // and `Program` is the type name.  Cross-assembly consumers reach it
  // through `ensureHostClassTypeRefRow`, which builds a TypeRef from the
  // same `(packageName, "Program")` pair — producer and consumer must
  // agree on this convention or the CLR throws "Could not load type" at
  // runtime.  This also matches the F# emitter's convention
  // (`Emitter.fs`: `nsName + ".Program"`), which is critical because the
  // stage-1 stdlib DLLs (`Lyric.Stdlib.*.dll`) are F#-built: a
  // self-hosted-built consumer calling `Std.Testing.assertEqual` emits
  // its TypeRef into the same `(namespace, type)` slot the F# producer
  // emitted.  Single-segment packages (no dot) yield
  // (namespace="<pkg>", name="Program") unchanged.
  val sName    = internString(sh, "Program")
  val sNs      = internString(sh, hostClass)
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
      lowerMInsn(ctx, cctorInsns[ci], mbCctor)
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
    // Arity-qualify the intern key (#1536) so same-name overloads don't collide and inherit the wrong signature blob.
    val bSig = internBlob(bh, "sfunc_" + hostClass + "_" + f.name + "/" + toString(f.params.count), mSig)
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
    typeNamespace = sNs,
    extends       = objectTypeToken(ctx),
    fieldList     = firstField,
    methodList    = firstMethod))
}

// ── Package lowering ───────────────────────────────────────────────────────────

// Lower an MPackage to a complete PE binary.
// `entryMethodToken` is the MethodDef token for the program's entry point (0 for libraries).
// Defaults the Assembly row version to 0.0; the bridge entry points that
// thread `[package].version` (see #1364) use `lowerMPackageWithCtx` with a
// pre-seeded `LoweringCtx`, so the bootstrap-grade caller without a manifest
// retains the legacy default here.
pub func lowerMPackage(pkg: in MPackage, entryMethodToken: in Int): List[Byte] {
  val ctx = newLoweringCtx(pkg.packageName, 0, 0)

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
    guids           = ctx.guids, resourceData = ctx.resourceData)

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}

// Lower an MPackage to a complete PE binary using a pre-seeded LoweringCtx.
// Identical to `lowerMPackage` but skips creating a fresh context, allowing
// the caller to pre-register AssemblyRef / TypeRef / MemberRef rows (for
// external method tokens) before any user-defined types are added.
// Used by `Msil.Codegen` + `Msil.Bridge` so that stdlib call tokens baked
// into `MInsn` values are stable.
// Lower one `MPackageItem` into `ctx`'s metadata tables.  Single dispatch
// point shared by `lowerMPackageWithCtx` and `lowerMPackagesWithCtx` so
// that new `MPackageItem` variants don't silently fall through the
// multi-package walker (#1185).
func lowerMPackageItem(item: in MPackageItem, ctx: in LoweringCtx): Unit {
  match item {
    case MPRecord(rec)                       -> { val _ = lowerMRecord(rec, ctx) }
    case MPFuncs(hostClass, funcs, sfields)  -> { val _ = lowerMFuncsToHostClass(hostClass, funcs, sfields, ctx) }
    case MPUnion(u)                          -> { val _ = lowerMUnion(u, ctx) }
    case MPDistinctType(d)                   -> { val _ = lowerMDistinctType(d, ctx) }
    case MPRangeType(r)                      -> { val _ = lowerMRangeType(r, ctx) }
    case MPEnum(e)                           -> { val _ = lowerMEnum(e, ctx) }
    case MPInterface(iface)                  -> { val _ = lowerMInterface(iface, ctx) }
    case MPImpl(implData)                    -> { val _ = lowerMImpl(implData, ctx) }
    case MPOpaque(op)                        -> { val _ = lowerMOpaque(op, ctx) }
  }
}

pub func lowerMPackageWithCtx(pkg: in MPackage, ctx: in LoweringCtx,
                               entryMethodToken: in Int): List[Byte] {
  var i = 0
  while i < pkg.items.count {
    lowerMPackageItem(pkg.items[i], ctx)
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
    guids           = ctx.guids, resourceData = ctx.resourceData)

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}

// Lower a list of MPackages into ONE complete PE binary against a single
// shared `LoweringCtx` (#1183 — multi-package compilation).  Each package's
// TypeDef / MethodDef / FieldDef rows are appended to the unified metadata
// tables in the order the packages appear in `pkgs`, matching the row
// numbering that the per-package `addPackageTokens` pre-scan reserved.
//
// The PE that comes out has one `Assembly` row (named after the bundle, not
// any individual package) and as many `TypeDef` rows as the union of every
// package's records / unions / enums / interfaces / opaques / impls plus one
// host class per package's functions.  All cross-package call sites that
// resolved to bundle-local `MethodDef` tokens during codegen point at the
// correct row in the unified table.
pub func lowerMPackagesWithCtx(pkgs: in List[MPackage], ctx: in LoweringCtx,
                                entryMethodToken: in Int): List[Byte] {
  var pi = 0
  while pi < pkgs.count {
    val pkg = pkgs[pi]
    var i = 0
    while i < pkg.items.count {
      lowerMPackageItem(pkg.items[i], ctx)
      i = i + 1
    }
    pi = pi + 1
  }

  val inp = AssemblerInput(
    entryPointToken = entryMethodToken,
    methodBodies    = ctx.bodies,
    tables          = ctx.tables,
    strings         = ctx.strings,
    us              = ctx.us,
    blobs           = ctx.blobs,
    guids           = ctx.guids, resourceData = ctx.resourceData)

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}
