//! msil/lowering.l — High-level MSIL lowering (Stage M84 / Phase R5).
//!
//! Mirrors jvm/lowering.l for the MSIL / .NET PE target.
//!
//! Provides:
//!   MsilType          — typed representation of CLI types.
//!   MInsn             — high-level instruction union; lowerMInsn resolves tokens.
//!   MField / MFunc / MRecord — typed class/method/field descriptors.
//!   MUnion / MEnum / MDistinctType / MRangeType — more IR types.
//!   MPackage          — top-level package descriptor.
//!   lowerMFunc        — lowers an MFunc to a MethodBody.
//!   lowerMRecord      — lowers an MRecord into a LoweringCtx (adds TypeDef/Field/MethodDef rows).
//!   lowerMPackage     — lowers an MPackage to a complete PE byte list.
//!
//! Phase R5 coverage (bootstrap-grade, matching jvm/lowering.l Phase R4):
//!   Primitive types: Int(I4), Long(I8), Double(R8), Bool(Boolean), String, Unit(Void), Char.
//!   Records with primitive or record-typed fields.
//!   Top-level static functions.
//!   Sealed union types (abstract base + derived case classes).
//!   Distinct types and range types (thin newtype wrappers).
//!   Arithmetic, comparison, boolean ops, string ops.
//!   Control flow: if/else, while, match (literal + binding patterns).
//!   Return, function call (static), constructor call (newobj), field access.
//!
//! Not covered in Phase R5 (deferred to R6):
//!   Generics, async, protected types, wire blocks, aspects, FFI (@extern).
//!   Cross-package references beyond the stdlib primitives.
//!   Exception handling (try/catch/finally).
package Msil.Lowering

import Msil.Kernel
import Msil.Opcodes
import Msil.Tables
import Msil.Heaps
import Msil.Assembler
import Std.Core
import Std.Collections
import Std.Math

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
  // Lyric List[T] with a CONCRETE runtime instance — a genuine
  // `List`1<elemTy>` (not the legacy `List<object>` that `MListOf` tracks).
  // Stage 2 of the F#-compatible object model: when the element type
  // is a reference type the instance, its construction tokens, and its method
  // MemberRefs are all the closed generic instantiation, so the signature
  // encodes `GENERICINST List`1<Foo>` (matching the F# emitter) and a returned
  // `List<Foo>` binds against an F#-compiled consumer.  Element access needs no
  // box/unbox (refs stored directly; `get_Item` returns the element typed).
  // Op sites route through `MListOp(op, elemTy)`; legacy `MListOf`/`MObject`
  // keep the `tokListObj*` object path.  In LocalVarSig / slot-compat the
  // instance still degrades to `object` (0x1C) — locals are object slots that
  // `castclass` to the concrete TypeSpec at each op site.
  case MConcreteList(elemTy: MsilType)
  // Lyric Map[K, V] with a CONCRETE runtime instance — a genuine
  // `Dictionary`2<keyTy,valTy>` (not the legacy `Dictionary<object,object>`
  // that `MMapOf` tracks).  The concrete counterpart of `MConcreteList` for
  // maps; op sites route through `MDictOp(op, keyTy, valTy)`.
  case MConcreteMap(keyTy: MsilType, valTy: MsilType)
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
  // GENERICINST VALUETYPE (0x15 0x11) for BCL value-type generic instantiations
  // such as AsyncTaskMethodBuilder<T>.  Like MGenericInst but emits VALUETYPE
  // instead of CLASS after the GENERICINST prefix.  Required for field signatures
  // and call-site method signatures that reference struct generic types.  Encoded
  // by bufMsilType / bufMsilTypeWithCtx; these sites must distinguish it from the
  // CLASS variant (MGenericInst) to avoid a CLR verifier type-mismatch.
  case MValueTypeGenericInst(typeRefCode: Int, headFqn: String, typeArgs: List[MsilType])
  // Lyric async generator — runtime representation is IAsyncEnumerable<object>
  // (the synthesised generator class).  Encoded as ELEMENT_TYPE_OBJECT (0x1C)
  // in method signatures (erased to object like MListOf) so the kickoff
  // function signature is compatible with the existing bootstrap conventions.
  // emitCollectionForMsil detects this type and uses the async-enumerator
  // protocol (GetAsyncEnumerator/MoveNextAsync/Current) instead of the
  // List<object> index-loop protocol.
  case MIAsyncEnumerable(elemTy: MsilType)
  // GENERICINST over an IN-BUNDLE generic TypeDef, resolved BY NAME at lowering
  // time (#2362 / docs/43).  The counterpart of `MGenericInst` for in-bundle
  // generic records/unions: codegen (Phase 3) cannot bake a `tdrTypeDef(row)`
  // because the TypeDef row is only allocated during lowering (Phase 5), so the
  // head's dotted FQN is carried instead and resolved via `resolveSigTypeDefRow`
  // (in-bundle TypeDef first, then TypeRef fallback) when the signature blob is
  // emitted.  Mirrors the proven `MCastclassByName` / `MLdfldByName` deferred-
  // by-name pattern.  Encodes `0x15 0x12 <coded> <argCount> <args…>`.
  case MGenericInstByName(headFqn: String, typeArgs: List[MsilType])
  // Erased-to-object extern type that implements IEnumerable (not IList).
  // emitCollectionForMsil uses the IEnumerator protocol for this type
  // (GetEnumerator/MoveNext/get_Current on non-generic IEnumerable/IEnumerator)
  // so that extern types like DictKeyCollection[K,V] can be iterated with
  // `for x in collection` without requiring the type to implement IList.
  case MExternEnumerable(elemTy: MsilType)
  // Lyric tuple `(A, B, ...)` — runtime representation is List<object>, so this
  // serialises as MObject (0x1C) in all MSIL signatures (like MListOf).  The
  // element types are carried purely for codegen tracking so that PTuple
  // destructuring can `castclass` each `get_Item` result to its declared
  // element type instead of leaving it as `object`, which desynced the verifier
  // ("found object expected List<X>/Option/Result") at tuple binding sites.
  case MTuple(elems: List[MsilType])
}

// Return the ECMA-335 ELEMENT_TYPE byte for the given MsilType.
// For MClass, returns 0x12 (CLASS element type prefix — caller must follow
// with a compressed TypeDefOrRef token; this helper returns the prefix only).
pub func elementTypeByte(t: in MsilType): Int {
  match t {
    case MVoid -> 0x01
    case MBool -> 0x02
    case MChar -> 0x03
    case MInt -> 0x08
    case MLong -> 0x0A
    case MDouble -> 0x0D
    case MString -> 0x0E
    case MObject -> 0x1C
    case MClass(_) -> 0x12
    case MTypeVar(_) -> 0x13  // prefix only; index byte emitted separately by bufMsilType
    case MNativeInt -> 0x18
    case MGenericInst(_, _, _) -> 0x15  // prefix only; full encoding via bufMsilType
    case MListOf(_) -> 0x1C  // same as Object: runtime rep is List<object>
    case MMapOf(_, _) -> 0x1C  // same as Object: runtime rep is Dictionary<object,object>
    case MConcreteList(_) -> 0x15  // GENERICINST prefix; full List`1<elem> via bufMsilType
    case MConcreteMap(_, _) -> 0x15  // GENERICINST prefix; full Dictionary`2<k,v> via bufMsilType
    case MByte -> 0x05  // ELEMENT_TYPE_U1
    case MArray(_) -> 0x1D  // ELEMENT_TYPE_SZARRAY prefix; element follows (bufMsilType)
    case MValueTypeRef(_, _) -> 0x11  // ELEMENT_TYPE_VALUETYPE prefix; TypeRef follows (bufMsilType)
    case MClassRef(_, _) -> 0x12  // ELEMENT_TYPE_CLASS prefix; TypeRef follows (bufMsilType)
    case MByRef(_) -> 0x10  // ELEMENT_TYPE_BYREF prefix; pointee follows (bufMsilType)
    case MValueTypeGenericInst(_, _, _) -> 0x15  // GENERICINST prefix; VALUETYPE byte + args follow
    case MIAsyncEnumerable(_) -> 0x1C  // erased to object in signatures
    case MGenericInstByName(_, _) -> 0x15  // GENERICINST prefix; full encoding via bufMsilTypeWithCtx
    case MExternEnumerable(_) -> 0x1C  // erased to object in signatures
    case MTuple(_) -> 0x1C  // same as Object: runtime rep is List<object>
  }
}

// Emit the `ldind.*` opcode that dereferences a managed pointer whose pointee
// is `ty`.  Used to read an `inout` parameter (whose slot holds a `T&`).  Lyric
// primitives load natively (i4/i8/r8); every reference-shaped type (object,
// string, class, list/map, generic instance, type variable) uses `ldind.ref`.
func emitLdindForType(mb: in MethodBody, ty: in MsilType): Unit {
  match ty {
    case MInt -> emitLdind_I4(mb)
    case MLong -> emitLdind_I8(mb)
    case MDouble -> emitLdind_R8(mb)
    case MBool -> emitLdind_I1(mb)
    case MChar -> emitLdind_U2(mb)
    case MByte -> emitLdind_I1(mb)
    case _ -> emitLdind_Ref(mb)
  }
}

// Emit the `stind.*` opcode that stores through a managed pointer whose pointee
// is `ty`.  Counterpart of `emitLdindForType`; used to write an `out`/`inout`
// parameter.
func emitStindForType(mb: in MethodBody, ty: in MsilType): Unit {
  match ty {
    case MInt -> emitStind_I4(mb)
    case MLong -> emitStind_I8(mb)
    case MDouble -> emitStind_R8(mb)
    case MBool -> emitStind_I1(mb)
    case MChar -> emitStind_I2(mb)
    case MByte -> emitStind_I1(mb)
    case _ -> emitStind_Ref(mb)
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
    case MVoid -> MObject
    // Recurse into array elements so a `slice[Unit]` argument encodes as
    // `object[]` rather than the illegal `void[]` (#1582).
    case MArray(elem) -> MArray(elemTy = genericArgType(elem))
    case _ -> t
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
      writeCompressedInt(w, typeArgs.count)
      var gi = 0
      while gi < typeArgs.count {
        bufMsilType(w, genericArgType(typeArgs[gi]))
        gi = gi + 1
      }
    }
    case MValueTypeGenericInst(typeRefCode, _, typeArgs) -> {
      bufU1(w, 0x15)   // ELEMENT_TYPE_GENERICINST
      bufU1(w, 0x11)   // ELEMENT_TYPE_VALUETYPE (struct generic, e.g. AsyncTaskMethodBuilder<T>)
      writeCompressedInt(w, typeRefCode)
      writeCompressedInt(w, typeArgs.count)
      var gi = 0
      while gi < typeArgs.count {
        bufMsilType(w, genericArgType(typeArgs[gi]))
        gi = gi + 1
      }
    }
    // Concrete collections need the LoweringCtx to resolve the
    // `List`1`/`Dictionary`2` TypeRef row, so the context-free encoder cannot
    // emit a valid GENERICINST.  Degrade to ELEMENT_TYPE_OBJECT (0x1C) here —
    // the same workaround `MClass` uses above.  User signatures go through
    // `bufMsilTypeWithCtx`, which emits the real instantiation; this path is
    // only reached for BCL-extern sigs and context-free generic-arg blobs,
    // where the concrete encoding isn't required.
    case MConcreteList(_) -> bufU1(w, 0x1C)
    case MConcreteMap(_, _) -> bufU1(w, 0x1C)
    // In-bundle generic instantiation needs the LoweringCtx to resolve the
    // TypeDef row, so the context-free encoder degrades to ELEMENT_TYPE_OBJECT
    // (only reached for BCL sigs / context-free generic-arg blobs).
    case MGenericInstByName(_, _) -> bufU1(w, 0x1C)
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
  writeCompressedInt(w, params.count) // param count (ECMA-335 §II.23.2.1: compressed; >127 needs 2 bytes)
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
  writeCompressedInt(w, params.count) // explicit param count (this excluded; compressed per ECMA-335)
  bufMsilType(w, ret)                // return type
  var i = 0
  while i < params.count {
    bufMsilType(w, params[i])
    i = i + 1
  }
  bufToList(w)
}

// Context-aware variant of `buildFieldSig`.  Encodes an `MClass` field type as
// `ELEMENT_TYPE_CLASS + TypeDefOrRef` (resolving the class's TypeDef/TypeRef row
// by name via `bufMsilTypeWithCtx`) instead of degrading to `ELEMENT_TYPE_OBJECT`.
// This produces the same encoding the F# bootstrap emitter does, which is the
// precondition for cross-assembly binding against an F#-compiled producer.
pub func buildFieldSigWithCtx(t: in MsilType, ctx: in LoweringCtx): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x06)          // FIELD
  bufMsilTypeWithCtx(w, t, ctx)
  bufToList(w)
}

// Context-aware variant of `buildStaticMethodSig`.  Encodes `MClass`
// parameters/returns concretely (CLASS + TypeDefOrRef) via `bufMsilTypeWithCtx`.
pub func buildStaticMethodSigWithCtx(params: in List[MsilType], ret: in MsilType, ctx: in LoweringCtx): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x00)                     // DEFAULT call convention (static)
  writeCompressedInt(w, params.count) // param count (compressed per ECMA-335 §II.23.2.1)
  bufMsilTypeWithCtx(w, ret, ctx)    // return type
  var i = 0
  while i < params.count {
    bufMsilTypeWithCtx(w, params[i], ctx)
    i = i + 1
  }
  bufToList(w)
}

// Context-aware variant of `buildInstanceMethodSig` (HASTHIS).  Encodes `MClass`
// parameters/returns concretely (CLASS + TypeDefOrRef) via `bufMsilTypeWithCtx`.
pub func buildInstanceMethodSigWithCtx(params: in List[MsilType], ret: in MsilType, ctx: in LoweringCtx): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x20)                     // HASTHIS
  writeCompressedInt(w, params.count) // explicit param count (this excluded; compressed per ECMA-335)
  bufMsilTypeWithCtx(w, ret, ctx)    // return type
  var i = 0
  while i < params.count {
    bufMsilTypeWithCtx(w, params[i], ctx)
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
  case MConvU1
  case MConvU2

  // Object model
  case MNewobj(ctorToken: Int)         // new T; call .ctor
  case MLdfld(fieldToken: Int)         // load instance field
  case MLdflda(fieldToken: Int)        // ldflda — managed pointer to instance field (for struct mutations)
  case MStfld(fieldToken: Int)         // store instance field
  case MLdsfld(fieldToken: Int)        // load static field
  case MStsfld(fieldToken: Int)        // store static field
  case MCall(methodToken: Int)         // call static or non-virtual method
  case MCallvirt(methodToken: Int)     // callvirt (virtual dispatch)
  case MCastclass(typeToken: Int)      // castclass
  // Concrete generic-collection operations (epic #2359 Stage 2).  The element /
  // key / value MsilType is resolved to a closed `List`1<elemTy>` /
  // `Dictionary`2<k,v>` TypeSpec + member token at lowering time (deferred so
  // in-bundle element types resolve to their TypeDef row).  The operation is a
  // typed `ListOp` / `DictOp` (not a raw int) so the `lowerMInsn` dispatch is
  // exhaustive and an invalid operation is unrepresentable.
  case MListOp(op: ListOp, elemTy: MsilType)
  case MDictOp(op: DictOp, keyTy: MsilType, valTy: MsilType)
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
  // newobj for an IN-BUNDLE generic record/union-case constructor, resolved by
  // name at Phase 5 (#2362 / docs/43).  The in-bundle counterpart of
  // MNewobjGenericCase: the case/record TypeDef row is only allocated during
  // lowering, so `headFqn` (its dotted FQN) is carried and resolved via
  // `resolveSigTypeDefRow` → `tdrTypeDef` (TypeRef fallback) when the closed
  // GENERICINST TypeSpec + TypeSpec-parented `.ctor` MemberRef are built.
  // `ctorParams` are the constructor parameter MSIL types in VAR form (e.g.
  // [MTypeVar(0)] for `Box(value: T)`).
  case MNewobjGenericByName(headFqn: String, typeArgs: List[MsilType], ctorParams: List[MsilType])
  case MBox(typeToken: Int)            // box value type
  case MUnboxAny(typeToken: Int)       // unbox.any
  case MNewarr(typeToken: Int)         // newarr — allocate a 1-D array of the element type token
  case MStelemRef                      // stelem.ref — store into a reference-typed array element
  case MStelem(typeToken: Int)         // stelem <type> — store into an array element of any type (value or ref)

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
    flags: Int,                 //   0=typed catch, 2=finally, 4=fault
    tryStart: Int,                 //   label ID for start of protected region
    tryEnd: Int,                 //   label ID for first insn after protected region
    handlerStart: Int,                 //   label ID for start of handler code
    handlerEnd: Int,                 //   label ID for first insn after handler code
    catchToken: Int,
  )                 //   TypeRef/TypeDef token (0 for finally/fault)

  // Deferred-resolution instructions for async SM synthesis.
  // The SM TypeDef row isn't known during Phase 3 (codegen), so tokens are
  // resolved by name at Phase 5 (lowering) when the table is fully populated.

  // ldfld where ownerFqn+fieldName are used to look up the FieldDef token at
  // Phase 5 via findFieldDefRowOfType(findTypeDefRowByName(ownerFqn)).
  case MLdfldByName(ownerFqn: String, fieldName: String)
  // ldflda variant (load managed pointer to field).
  case MLdfldaByName(ownerFqn: String, fieldName: String)
  // stfld variant.
  case MStfldByName(ownerFqn: String, fieldName: String)
  // newobj resolving the .ctor MemberRef token by class name at Phase 5.
  case MNewobjByName(className: String)
  // Emit `call ATMB[<T>].Start<SM>(ref SM)` — resolves the MethodSpec for
  // `ATMB.Start` instantiated with the SM TypeDef at Phase 5.
  // `smFqn`     — FQN of the SM sealed class.
  // `atmbMrRow` — 1-based MemberRef row of the open-generic `ATMB.Start<!!0>`.
  // `isGeneric` — true when the kickoff returns Task<T> (uses ATMB<T>.Start),
  //               false for void path (uses AsyncTaskMethodBuilder.Start).
  case MCallAtmbStart(smFqn: String, atmbMrRow: Int, isGeneric: Bool)

  // Phase B.1: switch instruction for state dispatch in MoveNext.
  case MSwitch(labels: List[Int])
  // Phase B.1: initobj — zero-initialise a value-type field/local (e.g. clear
  // the awaiter SM field after restoring it at a resume point).
  case MInitobj(typeToken: Int)
  // Phase B.1 deferred: call ATMB[<T>].AwaitUnsafeOnCompleted<TAwaiter,SM>(ref TAwaiter, ref SM).
  // At Phase 5 lowering the SM TypeDef row is looked up from smFqn so the
  // 2-arg MethodSpec [awaiterMsilTy, CLASS SM] can be built and emitted.
  // `atmbMrRow` is the 1-based MemberRef row for the open-generic method.
  case MCallAwaitUnsafeOnCompleted(smFqn: String, atmbMrRow: Int, awaiterMsilTy: MsilType)
  // Non-virtual `call` that resolves the MethodDef token from a TypeDef name
  // and method name at Phase 5 lowering time.  Used by generator kickoffs to
  // call RunBody() on the synthesised generator class before the MethodDef
  // table is fully populated (mirrors the MNewobjByName / MLdfldByName pattern).
  case MCallByName(className: String, methodName: String)
}

// ── MField / MFunc / MRecord ──────────────────────────────────────────────────
pub record MField {
  flags: Int        // FieldAttributes (from Msil.Tables FDA_*)
  name: String
  fieldType: MsilType
}

pub record MFunc {
  flags: Int        // MethodAttributes (from Msil.Tables MDA_*)
  name: String
  params: List[MsilType]
  ret: MsilType
  insns: List[MInsn]
  maxStack: Int
  locals: List[MsilType]   // local variable type list (in order)
}

pub record MRecord {
  className: String          // fully-qualified, e.g. "Hello"
  namespace: String          // e.g. "" (empty = global) or "My.Ns"
  baseClass: String          // fully-qualified, default "System.Object"
  fields: List[MField]
  methods: List[MFunc]
  // When true, lowerMRecord synthesises a public no-arg .ctor (default
  // Object .ctor call) instead of a field-parameterised .ctor.
  // Required for IAsyncStateMachine SM classes (fields set individually
  // by the kickoff after newobj).
  useDefaultCtor: Bool
  // Type-parameter names for an in-bundle generic record (#2362 / docs/43),
  // in declaration order (e.g. ["T"] for `record Box[T]`).  Empty for a
  // non-generic record.  When non-empty, lowerMRecord emits GenericParam rows
  // (table 0x2A) for this TypeDef, lowers `T`-typed fields to `MTypeVar`, and
  // switches the TypeDef to AutoLayout.
  generics: List[String]
}

// ── MUnion — sealed class hierarchy ─────────────────────────────────────────
pub record MUnionCase {
  name: String            // fully-qualified case class name
  fields: List[MField]
  // Type-parameter names this case class re-declares (#2362).  Every case of a
  // generic union carries the union's full parameter list (so `Option_Some` and
  // `Option_None` each declare `[T]`), matching the F# emitter.  Empty for a
  // non-generic union's cases.
  generics: List[String]
}

pub record MUnion {
  baseName: String        // abstract base class name
  namespace: String
  cases: List[MUnionCase]
  methods: List[MFunc]   // methods on the base
  // Type-parameter names for an in-bundle generic union (#2362), in declaration
  // order (e.g. ["T", "E"] for `union Result[T, E]`).  Empty for a non-generic
  // union.  Propagated to every case's `generics` list during lowering.
  generics: List[String]
}

// ── MStaticField — module-level static field (IConst / IVal) ─────────────────
pub record MStaticField {
  flags: Int         // FDA_PUBLIC | FDA_STATIC | optionally FDA_LITERAL | FDA_INIT_ONLY | FDA_HAS_DEFAULT
  name: String
  fieldType: MsilType
  constValue: Int         // literal value when FDA_LITERAL is set (0 otherwise)
  hasLiteral: Bool        // true if constValue is valid (i.e. FDA_LITERAL field)
  initInsns: List[MInsn] // IL to compute initial value for IVal (empty for IConst)
}

// ── MEnum — CLR enum type ─────────────────────────────────────────────────────
pub record MEnum {
  className: String       // fully-qualified, e.g. "Pkg.Direction"
  namespace: String       // e.g. "Pkg"
  cases: List[String] // case names; ordinals = 0..n-1
}

// ── MConfigField / ConfigTokens — config block static fields (D046) ──────────
// BCL tokens threaded through MPConfig so lowerMConfig can emit the .cctor
// without reaching back into CodegenCtx (which lives in a different file).
pub record ConfigTokens {
  tokGetEnvVar: Int      // Environment.GetEnvironmentVariable(string): string
  tokIsNullOrEmpty: Int  // String.IsNullOrEmpty(string): bool
  tokConsoleError: Int   // Console.get_Error(): TextWriter  (static)
  tokTwWriteLine: Int    // TextWriter.WriteLine(string): void  (instance HASTHIS)
  tokEnvExit: Int        // Environment.Exit(int32): void  (static)
  tokInt32Parse: Int     // Int32.Parse(string): int32  (static)
  tokBoolParse: Int      // Boolean.Parse(string): bool  (static)
  tokInt64Parse: Int     // Int64.Parse(string): int64  (static)
  tokDoubleParse: Int    // Double.Parse(string, IFormatProvider): float64  (static)
  tokInvariantCulture: Int  // CultureInfo.get_InvariantCulture(): CultureInfo  (static)
}

// One field inside a config block.  `defaultInsns` is a one-instruction list
// that pushes the literal default (MLdcI4, MLdcI8, MLdcR8, or MLdStr); empty
// for required fields.
pub record MConfigField {
  name: String
  fieldType: MsilType      // MInt, MLong, MDouble, MBool, or MString (G0009-guarded)
  // ldstr token (0x70000000 | US heap offset) for the env var name.
  envVarTok: Int
  hasDefault: Bool
  defaultInsns: List[MInsn]
  // ldstr token for the stderr error message (0 when hasDefault = true).
  requiredMsgTok: Int
}

// ── MInterface / MImplData ───────────────────────────────────────────────────
pub record MInterfaceMethod {
  name: String
  params: List[MsilType]
  ret: MsilType
}

// One slot in an interface definition, in declaration order.
pub union MIfaceItem {
  case MIAbstract(m: MInterfaceMethod)   // abstract slot (IMSig) — RVA = 0
  case MIDim(fn: MFunc)                  // default method body (IMFunc) — concrete MethodDef
}

pub record MInterface {
  className: String       // fully-qualified interface name
  namespace: String
  members: List[MIfaceItem]   // abstract and DIM members in declaration order
}

// Per overridden interface method slot.
//
// Either token may be 0 — in that case `lowerMImpl` resolves the slot by
// looking up the corresponding `*Name` field in the type's MethodDef range.
pub record MImplSlot {
  ifaceMethodToken: Int   // MethodDef or MemberRef token of the interface method (0 = resolve by name)
  implMethodToken: Int   // MethodDef token of the implementing method (0 = resolve by name)
  ifaceMethodName: String  // method name on the interface; used when ifaceMethodToken == 0
  implMethodName: String  // method name on the implementing type; used when implMethodToken == 0
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
  ifaceTypeToken: Int         // TypeDefOrRef coded-index of the interface (0 = resolve by name)
  slots: List[MImplSlot]
  targetTypeName: String      // fully-qualified, e.g. "Pkg.EnglishGreeter"
  ifaceTypeName: String      // fully-qualified, e.g. "Pkg.Greeter"
}

// ── MOpaque — sealed opaque type ─────────────────────────────────────────────
pub record MOpaque {
  className: String    // fully-qualified, e.g. "Pkg.AccountId"
  namespace: String
  fields: List[MField]    // private storage fields
  methods: List[MFunc]     // public methods declared in the package
  isProjectable: Bool           // true if @projectable — emit twin Exposed TypeDef
  // Projectable field metadata (parallel to `fields`; only meaningful when isProjectable=true).
  // visibleFieldMask[i]=true → fields[i] is NOT @hidden (appears in view twin).
  // projBoundaryMask[i]=true → fields[i] IS @projectionBoundary (no recursive toView()).
  visibleFieldMask: List[Bool]
  projBoundaryMask: List[Bool]
}

// ── MDistinctType / MRangeType — thin newtype wrappers ───────────────────────
pub record MDistinctType {
  className: String
  namespace: String
  inner: MsilType    // the wrapped primitive or class type
  // Range-subtype validation (#1501).  When `hasRange` is true the synthesised
  // `from`/`tryFrom` factories bounds-check the incoming value against
  // [minI, maxI] (integer inner) or [minF, maxF] (Double inner) and either throw
  // (`from`) or return `Err` (`tryFrom`).  `upperExclusive` distinguishes
  // `a ..< b` (half-open) from `a ..= b` (closed).  Bounds are folded by the
  // codegen layer from the `rangeClause` literals before lowering.
  hasRange: Bool
  rangeIsFloat: Bool
  minI: Long
  maxI: Long
  minF: Double
  maxF: Double
  upperExclusive: Bool
}

pub record MRangeType {
  className: String
  namespace: String
  inner: MsilType
  minVal: Long
  maxVal: Long
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
  // MPConfig: config block (D046 / docs/25-config-blocks.md).
  // Emits a sealed static class with one public static field per config field,
  // initialised from environment variables by a .cctor at first class access.
  case MPConfig(ns: String, typeName: String, fields: List[MConfigField], configToks: ConfigTokens)
}

pub record MPackage {
  packageName: String
  items: List[MPackageItem]
}

// ── Concrete generic-collection operations (epic #2359 Stage 2) ───────────────
// The operation an `MListOp` / `MDictOp` performs.  A typed union (not a raw
// int) so the `lowerMInsn` dispatch is exhaustive and an invalid operation
// cannot be constructed.
pub union ListOp {
  case LoCtor      // newobj List`1<elemTy>::.ctor()
  case LoAdd       // callvirt Add(!0)
  case LoGetItem   // callvirt get_Item(int32) -> !0
  case LoSetItem   // callvirt set_Item(int32, !0)
  case LoGetCount  // callvirt get_Count() -> int32
  case LoContains  // callvirt Contains(!0) -> bool
  case LoRemoveAt  // callvirt RemoveAt(int32)
  case LoCastclass // castclass List`1<elemTy>
  case LoToArray   // callvirt ToArray() -> !0[]
}

pub union DictOp {
  case DoCtor        // newobj Dictionary`2<k,v>::.ctor()
  case DoAdd         // callvirt Add(!0, !1)
  case DoGetItem     // callvirt get_Item(!0) -> !1
  case DoSetItem     // callvirt set_Item(!0, !1)
  case DoGetCount    // callvirt get_Count() -> int32
  case DoContainsKey // callvirt ContainsKey(!0) -> bool
  case DoRemove      // callvirt Remove(!0) -> bool
  case DoCastclass   // castclass Dictionary`2<k,v>
  case DoTryGetValue // callvirt TryGetValue(!0, !1&) -> bool  (#2474)
  case DoGetKeys     // callvirt get_Keys() -> KeyCollection<k,v>  (#3511)
  case DoGetValues   // callvirt get_Values() -> ValueCollection<k,v>  (#3511)
}

// Operation tokens (0x0A000000 | MemberRef row) for a closed `List`1<elemTy>` /
// `Dictionary`2<k,v>` instantiation, plus the `castclass` TypeSpec token
// (0x1B000000 | TypeSpec row).  Built once per element-type key, cached on the
// LoweringCtx.  Member signatures use the generic type variables `!0` / `!1`, so
// they are byte-identical across instantiations — only the parent TypeSpec row
// differs.
pub record ListTokens {
  typeSpec: Int
  ctor: Int
  add: Int
  getItem: Int
  setItem: Int
  getCount: Int
  contains: Int
  removeAt: Int
  toArray: Int
}

pub record DictTokens {
  typeSpec: Int
  ctor: Int
  add: Int
  getItem: Int
  setItem: Int
  getCount: Int
  containsKey: Int
  remove: Int
  tryGetValue: Int  // TryGetValue(!0, !1&) -> bool  (#2474)
  getKeys: Int      // get_Keys() -> KeyCollection<!0,!1>  (#3511)
  getValues: Int    // get_Values() -> ValueCollection<!0,!1>  (#3511)
}

// ── LoweringCtx — mutable accumulator for a single-assembly lowering ──────────
pub record LoweringCtx {
  strings: StringHeap
  blobs: BlobHeap
  us: UsHeap
  guids: GuidHeap
  tables: MetadataTables
  bodies: List[MethodBody]
  // Pre-interned well-known string indices
  sModule: Int
  sObject: Int
  sSystem: Int
  sMsCorLib: Int
  sMsKey: Int     // blob index of the MS public key token (b03f5f7f11d50a3a)
  // Well-known TypeRef row indices (1-based)
  trObject: Int     // System.Object in System.Runtime
  trEnum: Int     // System.Enum in System.Runtime (for CLR enum types)
  // Well-known AssemblyRef row indices (1-based)
  arRuntime: Int     // System.Runtime
  // Well-known MemberRef row indices (1-based)
  mrObjectCtor: Int    // System.Object::.ctor() — called by synthesised record constructors
  // Resource payload to embed in the PE.  Each resource is encoded as
  // a 4-byte little-endian length prefix followed by the resource
  // bytes; multiple resources are concatenated in `ManifestResource`
  // table row order.  Empty when the bridge doesn't embed any
  // resources (the common case before `Lyric.Contract` embedding
  // shipped).
  resourceData: List[Byte]
  // ── In-bundle type-row registry (epic #2359 Stage 1) ──────────────────────
  // Maps a user-defined type's fully-qualified name to its 1-based TypeDef row.
  // Populated by `recordUserTypeDefRow` as each in-bundle TypeDef is emitted,
  // and PRE-populated (before any signature is built) by a discovery pass over
  // the package items so that `bufMsilTypeWithCtx` can encode a forward
  // reference (a record whose field type is a type declared later in the same
  // bundle) as `ELEMENT_TYPE_CLASS + TypeDef` rather than degrading to
  // `ELEMENT_TYPE_OBJECT`.  TypeDef rows are the only user-controlled rows in
  // the table (BCL / stdlib / restored types are TypeRefs), so a throwaway
  // discovery lowering over the same items assigns identical row numbers — see
  // `discoverTypeDefRowsInto`.  `typeDefRowFqns` is the insertion-ordered key
  // list (maps don't expose key iteration here) used to copy the registry from
  // the discovery context into the real one.
  typeDefRowByFqn: Map[String, Int]
  typeDefRowFqns: List[String]
  // Caches of concrete generic-collection tokens (epic #2359 Stage 2), built
  // lazily by `listTokensForLowering` / `dictTokensForLowering` after the
  // discovery pass has populated `typeDefRowByFqn` (so an in-bundle element type
  // resolves to its TypeDef row).  Keyed by `msilTypeKey(elemTy)` (list) and
  // `msilTypeKey(keyTy)+"|"+msilTypeKey(valTy)` (dict).
  listTokenCache: Map[String, ListTokens]
  dictTokenCache: Map[String, DictTokens]
  // Non-empty (holds one `true`) while a discovery pass is running.  In that
  // mode `lowerMFunc` skips method-body lowering: discovery only needs the
  // TypeDef row layout, and a throwaway context lacks the pre-seeded stdlib /
  // restored token rows that real body lowering resolves against.
  discovering: List[Bool]
  // TypeSpec row cache keyed by the same `sigKey` passed to `ctxAddTypeSpec`.
  // Makes `ctxAddTypeSpec` idempotent: a second call with the same key returns
  // the existing row instead of creating a duplicate TypeSpec row.  Without
  // this, generator synthesis and the consumer for-loop both call
  // `ctxAddTypeSpec("ts_vt_bool", ...)` and create rows N and M (N≠M);
  // the `MoveNextAsync` MemberRef's blob (interned under "iaet_obj_movenext")
  // encodes TypeSpec row N in its return type while the consumer's
  // `MValueTypeRef` local uses row M, causing a token-identity mismatch the
  // CLR JIT rejects as `BadImageFormatException`.
  typeSpecRowByKey: Map[String, Int]
  // MemberRef row cache keyed by the `sigKey` passed to
  // `ctxAddMemberRefForTypeSpec`.  Makes that function idempotent so that
  // generator synthesis (which creates MemberRef rows for GetAsyncEnumerator,
  // MoveNextAsync, etc. to embed in MethodImpl declarations) and the consumer
  // for-loop (which creates MemberRef rows for the same methods to embed in
  // callvirt instructions) end up referencing the same MemberRef row.
  // Without deduplication, the MethodImpl MethodDeclaration points at row M
  // while the callvirt uses row N (M≠N), and the CLR virtual-dispatch resolver
  // fails to match the two as the same slot → MissingMethodException.
  memberRefRowByKey: Map[String, Int]
  // ── Projectable synthesis tracking (@projectable / toView / tryInto) ─────────
  // Maps opaque FQN → MethodDef row for its `toView()` method.  Pre-populated
  // from the discovery pass (same MethodDef order as the real pass) so that
  // `A.toView()` can emit `callvirt B.toView()` when B is lowered after A.
  projectableToViewMDef: Map[String, Int]
  projectableToViewMDefKeys: List[String]
  // Maps opaque FQN → MethodDef row for its `.ctor`.  Used by
  // `<Name>View.tryInto()` to construct the opaque from view fields without
  // a forward-reference problem.
  projectableCtorMDef: Map[String, Int]
  projectableCtorMDefKeys: List[String]
  // Stdlib TypeRef row for `Std.Core.Result_Ok` open generic (the F#-compiled
  // case class name with underscore separator).  Populated by the codegen layer
  // after stdlib registration.  Empty list = stdlib not imported; skip
  // tryInto() generation in that case.
  stdCoreResultOk2Row: List[Int]
  // Stdlib TypeRef row for `Std.Core.Result_Err` open generic, seeded alongside
  // `stdCoreResultOk2Row`.  Required (in addition to Ok) before a range
  // subtype's `tryFrom` factory can be synthesised (#1501).
  stdCoreResultErr2Row: List[Int]
  // Stdlib TypeRef row for the base `Std.Core.Result` union — the declared
  // return type of a synthesised `tryFrom` (which yields either an `Ok` or an
  // `Err`, both subclasses of `Result`).
  stdCoreResultRow: List[Int]
  // Complete set of in-bundle @projectable type FQNs, pre-populated by
  // discoverTypeDefRowsInto before any lowering pass starts.  Used for
  // declaration-order-independent hasNestedProjField checks in lowerMOpaque so
  // the discover and real passes always agree on tryInto() eligibility.
  allProjFqns: Map[String, Bool]
  allProjFqnKeys: List[String]
}

// Build and intern the Microsoft framework public key token blob.
func internMsKeyToken(bh: in BlobHeap): Int {
  val w = bufNew()
  bufU1(w, 0xB0)
  bufU1(w, 0x3F)
  bufU1(w, 0x5F)
  bufU1(w, 0x7F)
  bufU1(w, 0x11)
  bufU1(w, 0xD5)
  bufU1(w, 0x0A)
  bufU1(w, 0x3A)
  internBlob(bh, "__mskey__", bufToList(w))
}

// Create a fresh LoweringCtx pre-populated with the mandatory rows every
// CLI assembly needs (Module, System.Object TypeRef, System.Runtime AssemblyRef).
// `major` / `minor` populate the Assembly row's version (`addAssembly`
// at the bottom of this function); pass `(0, 0)` for the bootstrap-
// compatible default.  Consumers thread the manifest's `[package].version`
// through `Msil.Bridge` (see #1364).
pub func newLoweringCtx(packageName: in String, major: in Int, minor: in Int): LoweringCtx {
  val sh = newStringHeap()
  val bh = newBlobHeap()
  val uh = newUsHeap()
  val gh = newGuidHeap()
  val t = newMetadataTables()

  // Intern well-known strings
  val sModule = internString(sh, "<Module>")
  val sObject = internString(sh, "Object")
  val sSystem = internString(sh, "System")
  val sRuntime = internString(sh, "System.Runtime")
  val sMsCorLib = internString(sh, "mscorlib")
  val msKey = internMsKeyToken(bh)

  // Module row
  val guidW = bufNew()
  var gi = 0
  while gi < 16 {
    bufU1(guidW, 0)
    gi = gi + 1
  }
  val mvid = appendGuid(gh, bufToList(guidW))
  addModule(t, ModuleRow(generation = 0, name = sModule, mvid = mvid, encId = 0, encBaseId = 0))

  // <Module> TypeDef (always TypeDef[1] per CLI spec)
  addTypeDef(
    t,
    TypeDefRow(flags = 0, typeName = sModule, typeNamespace = 0, extends = 0, fieldList = 1, methodList = 1)
  )

  // AssemblyRef[1]: System.Runtime
  val arRuntime = addAssemblyRef(
    t,
    AssemblyRefRow(
      majorVersion = 10,
      minorVersion = 0,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = msKey,
      name = sRuntime,
      culture = 0,
      hashValue = 0
    )
  )

  // TypeRef[1]: System.Object in System.Runtime
  val trObject = addTypeRef(
    t,
    TypeRefRow(resolutionScope = rsAssemblyRef(arRuntime), typeName = sObject, typeNamespace = sSystem)
  )

  // TypeRef[2]: System.Enum in System.Runtime (needed for CLR enum types)
  val sEnum = internString(sh, "Enum")
  val trEnum = addTypeRef(
    t,
    TypeRefRow(resolutionScope = rsAssemblyRef(arRuntime), typeName = sEnum, typeNamespace = sSystem)
  )

  // MemberRef[1]: System.Object::.ctor() — called from synthesised record constructors
  // to satisfy the CLR verifier rule that every .ctor must call a base constructor
  // before returning (ECMA-335 §I.8.9.6.6; ilverify error ThisUninitReturn).
  val sCtorName = internString(sh, ".ctor")
  val objCtorSig = buildInstanceMethodSig(newList(), MVoid)
  val bObjCtorSig = internBlob(bh, "__object_ctor_sig__", objCtorSig)
  val mrObjectCtor = addMemberRef(
    t,
    MemberRefRow(class = mrpTypeRef(trObject), name = sCtorName, signature = bObjCtorSig)
  )

  // Assembly row
  val sPackage = internString(sh, packageName)
  addAssembly(
    t,
    AssemblyRow(
      hashAlgId = HASH_ALG_SHA1,
      majorVersion = major,
      minorVersion = minor,
      buildNumber = 0,
      revisionNumber = 0,
      flags = ASF_NONE,
      publicKey = 0,
      name = sPackage,
      culture = 0
    )
  )

  LoweringCtx(
    strings = sh,
    blobs = bh,
    us = uh,
    guids = gh,
    tables = t,
    bodies = newList(),
    sModule = sModule,
    sObject = sObject,
    sSystem = sSystem,
    sMsCorLib = sMsCorLib,
    sMsKey = msKey,
    trObject = trObject,
    trEnum = trEnum,
    arRuntime = arRuntime,
    mrObjectCtor = mrObjectCtor,
    resourceData = newList(),
    typeDefRowByFqn = newMap(),
    typeDefRowFqns = newList(),
    listTokenCache = newMap(),
    dictTokenCache = newMap(),
    discovering = newList(),
    typeSpecRowByKey = newMap(),
    memberRefRowByKey = newMap(),
    projectableToViewMDef = newMap(),
    projectableToViewMDefKeys = newList(),
    projectableCtorMDef = newMap(),
    projectableCtorMDefKeys = newList(),
    stdCoreResultOk2Row = newList(),
    stdCoreResultErr2Row = newList(),
    stdCoreResultRow = newList(),
    allProjFqns = newMap(),
    allProjFqnKeys = newList()
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
  val rest = version.substring(firstDot + 1, version.length - firstDot - 1)
  val secondDot = rest.indexOf(".")
  val minStr = if secondDot < 0 { rest } else { rest.substring(0, secondDot) }
  parts.add(parseIntOr0(majStr))
  parts.add(parseIntOr0(minStr))
  parts
}

// Parse an ASCII decimal int, returning 0 on any non-digit / overflow.
// Local helper to avoid an `Std.Parse` dependency from the lowering layer.
func parseIntOr0(s: in String): Int {
  if s.length == 0 {
    return 0
  }
  var i = 0
  var n = 0
  while i < s.length {
    val ch = s.substring(i, 1)
    if ch < "0" or ch > "9" {
      return 0
    }
    n = n * 10 + semverParseDigit(ch)
    i = i + 1
  }
  n
}

func semverParseDigit(ch: in String): Int {
  if ch == "0" {
    0
  } else if ch == "1" {
    1
  } else if ch == "2" {
    2
  } else if ch == "3" {
    3
  } else if ch == "4" {
    4
  } else if ch == "5" {
    5
  } else if ch == "6" {
    6
  } else if ch == "7" {
    7
  } else if ch == "8" {
    8
  } else if ch == "9" {
    9
  } else {
    0
  }
}

// Add a new AssemblyRef row for a BCL / framework assembly and return
// its 1-based row index.  Uses the Microsoft framework public key
// token (`b03f5f7f11d50a3a`) so the loader binds against the
// strong-named host runtime assemblies.  Lyric package refs use
// `ctxAddLyricPackageAssemblyRef` below (no public key token).
pub func ctxAddAssemblyRef(ctx: in LoweringCtx, name: in String, major: in Int, minor: in Int): Int {
  val sName = ctxInternStr(ctx, name)
  addAssemblyRef(
    ctx.tables,
    AssemblyRefRow(
      majorVersion = major,
      minorVersion = minor,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = ctx.sMsKey,
      name = sName,
      culture = 0,
      hashValue = 0
    )
  )
}

// Add an AssemblyRef row for an unsigned Lyric package and return its
// 1-based row index.  Lyric-emitted DLLs are unsigned (the Assembly row
// has `publicKey = 0`), so the AssemblyRef must also have
// `publicKeyToken = 0` — otherwise the loader rejects the bind with a
// public-key-token mismatch.  Version threading is tracked in #1364;
// today the major/minor parameters carry through directly.
pub func ctxAddLyricPackageAssemblyRef(ctx: in LoweringCtx, name: in String, major: in Int, minor: in Int): Int {
  val sName = ctxInternStr(ctx, name)
  addAssemblyRef(
    ctx.tables,
    AssemblyRefRow(
      majorVersion = major,
      minorVersion = minor,
      buildNumber = 0,
      revisionNumber = 0,
      flags = 0,
      publicKeyToken = 0,
      name = sName,
      culture = 0,
      hashValue = 0
    )
  )
}

// Add a TypeRef row and return its 1-based row index.
pub func ctxAddTypeRef(ctx: in LoweringCtx, namespaceName: in String, typeName: in String, assemblyRefRow: in Int): Int {
  val sNs = ctxInternStr(ctx, namespaceName)
  val sName = ctxInternStr(ctx, typeName)
  addTypeRef(
    ctx.tables,
    TypeRefRow(resolutionScope = rsAssemblyRef(assemblyRefRow), typeName = sName, typeNamespace = sNs)
  )
}

// Add a nested TypeRef whose ResolutionScope points to an enclosing TypeRef row.
// ECMA-335 §22.38: ResolutionScope can reference another TypeRef (tag 0x01) to
// describe nested types (e.g. Dictionary`2+KeyCollection).
pub func ctxAddNestedTypeRef(ctx: in LoweringCtx, outerTypeRefRow: in Int, nestedTypeName: in String): Int {
  val sName = ctxInternStr(ctx, nestedTypeName)
  val sEmpty = ctxInternStr(ctx, "")
  addTypeRef(
    ctx.tables,
    TypeRefRow(resolutionScope = rsTypeRef(outerTypeRefRow), typeName = sName, typeNamespace = sEmpty)
  )
}

// Add a MemberRef row (external method reference) and return its 1-based row index.
pub func ctxAddMemberRef(
  ctx: in LoweringCtx,
  parentTypeRefRow: in Int,
  methodName: in String,
  sigKey: in String,
  sig: in List[Byte],
): Int {
  val sName = ctxInternStr(ctx, methodName)
  val bSig = ctxInternBlob(ctx, sigKey, sig)
  addMemberRef(ctx.tables, MemberRefRow(class = mrpTypeRef(parentTypeRefRow), name = sName, signature = bSig))
}

// Add a TypeSpec row and return its 1-based row index.
// sigBytes is a type-signature blob (e.g. GENERICINST encoding).
pub func ctxAddTypeSpec(ctx: in LoweringCtx, sigKey: in String, sigBytes: in List[Byte]): Int {
  match mapGet(ctx.typeSpecRowByKey, sigKey) {
    case Some(row) -> row
    case None -> {
      val bSig = ctxInternBlob(ctx, sigKey, sigBytes)
      val row = addTypeSpec(ctx.tables, TypeSpecRow(signature = bSig))
      ctx.typeSpecRowByKey.add(sigKey, row)
      row
    }
  }
}

// Build the #Blob encoding for a MethodSpec instantiation signature
// (ECMA-335 §II.23.2.15): GENERICINST (0x0A), compressed generic-argument
// count, then each argument type.  Distinct from the GENERICINST *type*
// signature (0x15) used by TypeSpec — a MethodSpec signature names the
// method's type arguments, not a generic type instantiation.
pub func buildMethodSpecBlob(argTypes: in List[MsilType]): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x0A)  // GENERICINST (method instantiation)
  writeCompressedInt(w, argTypes.count)
  var i = 0
  while i < argTypes.count {
    bufMsilType(w, genericArgType(argTypes[i]))
    i = i + 1
  }
  bufToList(w)
}

// Open-generic method signature for `ATMB[<T>].Start<TStateMachine>(ref TStateMachine): void`
// (ECMA-335 §II.23.2.1).
// Calling convention: HASTHIS(0x20) | GENERIC(0x10) = 0x30.
// 1 generic type parameter (TStateMachine = !!0), 1 formal parameter, void return.
// The single formal param is `byref !!0` = BYREF(0x10) MVAR(0x1E) 0.
pub func buildAtmbStartOpenSig(): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x30)             // HASTHIS | GENERIC
  writeCompressedInt(w, 1)   // 1 generic parameter (TStateMachine)
  writeCompressedInt(w, 1)   // 1 formal parameter
  bufU1(w, 0x01)             // ELEMENT_TYPE_VOID (return)
  bufU1(w, 0x10)             // ELEMENT_TYPE_BYREF (param: ref TStateMachine)
  bufU1(w, 0x1E)             // ELEMENT_TYPE_MVAR (method generic param)
  writeCompressedInt(w, 0)   // index 0 (!!0 = TStateMachine)
  bufToList(w)
}

// Context-aware MethodSpec blob for `ATMB.Start<SM>(ref SM)` where the SM
// TypeDef row is not known at Phase 3 build time.  At Phase 5 lowering the
// SM TypeDef row has been allocated, so we can look it up by name and encode
// the concrete TypeDef token (0x02000000 + row) as the GENERICINST argument.
pub func buildMethodSpecBlobWithCtx(ctx: in LoweringCtx, smFqn: in String): List[Byte] {
  val smRow = findTypeDefRowByName(ctx, smFqn)
  val smCoded = tdrTypeDef(smRow)  // TypeDefOrRef coded-index: row*4+0
  val w = bufNew()
  bufU1(w, 0x0A)                 // GENERICINST (method instantiation)
  writeCompressedInt(w, 1)       // 1 generic argument
  bufU1(w, 0x12)                 // ELEMENT_TYPE_CLASS (SM is a sealed class)
  writeCompressedInt(w, smCoded)
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
pub func ctxAddMethodSpec(ctx: in LoweringCtx, methodCoded: in Int, sigKey: in String, sig: in List[Byte]): Int {
  val bSig = ctxInternBlob(ctx, sigKey, sig)
  addMethodSpec(ctx.tables, MethodSpecRow(method = methodCoded, instantiation = bSig))
}

// Add a MemberRef row whose parent is a TypeSpec row (for generic instantiations).
// Idempotent: a second call with the same `sigKey` returns the cached row index
// instead of emitting a duplicate row.  This guarantees that MethodImpl
// MethodDeclaration rows and consumer callvirt instructions reference the exact
// same MemberRef table entry, which the CLR requires for virtual dispatch to
// resolve correctly.  Returns the 1-based row index.
pub func ctxAddMemberRefForTypeSpec(
  ctx: in LoweringCtx,
  typeSpecRow: in Int,
  methodName: in String,
  sigKey: in String,
  sig: in List[Byte],
): Int {
  match mapGet(ctx.memberRefRowByKey, sigKey) {
    case Some(row) -> row
    case None -> {
      val sName = ctxInternStr(ctx, methodName)
      val bSig = ctxInternBlob(ctx, sigKey, sig)
      val row = addMemberRef(ctx.tables, MemberRefRow(class = mrpTypeSpec(typeSpecRow), name = sName, signature = bSig))
      ctx.memberRefRowByKey.add(sigKey, row)
      row
    }
  }
}

// Extract the simple name from a "Namespace.SimpleName" FQN string.
// When namespace is empty the whole string is the simple name.
// Equivalent to the last dot-segment: substring(ns.length + 1, …).
// Used consistently everywhere a struct/class className needs to be split
// (#2978: replaces ad-hoc manual substring arithmetic).
pub func simpleNameFromFqn(namespace: in String, className: in String): String {
  if namespace.length == 0 {
    className
  } else {
    // start = namespace.length + 1 (skip "Namespace.")
    // length = className.length - namespace.length - 1
    className.substring(namespace.length + 1, className.length - namespace.length - 1)
  }
}

// Produce a unique string key for an MsilType, for TypeSpec blob deduplication.
// Must distinguish every concrete encoding produced by bufMsilType.
// INVARIANT: the output must never contain `|` — `dictTokensForLowering` joins
// the key/value keys with `|` to form a collision-free composite cache key, so a
// new variant that emitted a pipe would silently corrupt that cache (#2475).
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
    case MConcreteList(e) -> "CLIST[" + msilTypeKey(e) + "]"
    case MConcreteMap(k, v) -> "CMAP[" + msilTypeKey(k) + "," + msilTypeKey(v) + "]"
    case MByte -> "B"
    case MArray(e) -> "[" + msilTypeKey(e) + "]"
    case MValueTypeRef(_, clrFqn) -> "VT" + clrFqn + ";"
    case MClassRef(_, clrFqn) -> "CR" + clrFqn + ";"
    case MValueTypeGenericInst(_, headFqn, typeArgs) -> {
      var key = "VG" + headFqn + "<"
      var i = 0
      while i < typeArgs.count {
        key = key + msilTypeKey(typeArgs[i])
        key = key + ","
        i = i + 1
      }
      key + ">"
    }
    case MByRef(inner) -> "BY" + msilTypeKey(inner) + ";"
    case MIAsyncEnumerable(e) -> "IAE[" + msilTypeKey(e) + "]"
    case MExternEnumerable(e) -> "EE[" + msilTypeKey(e) + "]"
    case MGenericInstByName(headFqn, typeArgs) -> {
      var key = "GN" + headFqn + "<"
      var i = 0
      while i < typeArgs.count {
        key = key + msilTypeKey(typeArgs[i])
        key = key + ","
        i = i + 1
      }
      key + ">"
    }
    case MTuple(elems) -> {
      var key = "TUP("
      var i = 0
      while i < elems.count {
        key = key + msilTypeKey(elems[i])
        key = key + ","
        i = i + 1
      }
      key + ")"
    }
  }
}

// Build the #Blob encoding for a GENERICINST type (ECMA-335 §II.23.2.14).
// typeDefOrRef is the compressed TypeDefOrRef coded-index for the open generic.
// argTypes is the list of concrete type arguments.
// Returns: 0x15 CLASS typeDefOrRef argCount argType...
pub func buildGenericInstBlob(typeDefOrRef: in Int, argTypes: in List[MsilType]): List[Byte] {
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
// Falls back to ELEMENT_TYPE_OBJECT (0x1C) when no row is found; a W0005 comment marks the fallback
// for MConcreteList/MConcreteDict (per-package builds omit those TypeRefs legitimately) and MGenericInstByName (#2494).
func bufMsilTypeWithCtx(w: in ByteWriter, t: in MsilType, ctx: in LoweringCtx): Unit {
  match t {
    case MClass(name) -> {
      val defRow = resolveSigTypeDefRow(ctx, name)
      if defRow > 0 {
        bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
        writeCompressedInt(w, tdrTypeDef(defRow))
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
          writeCompressedInt(w, tdrTypeRef(refRow))
        } else {
          bufU1(w, 0x1C)  // ELEMENT_TYPE_OBJECT (fallback; expected for unregistered type params)
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
    case MByRef(inner) -> {
      // ELEMENT_TYPE_BYREF (out/inout parameter): the 0x10 prefix MUST be
      // followed by the pointee type.  The context-free `bufMsilType` handles
      // this; without an explicit arm here it would fall through to the `other`
      // case and emit a bare, dangling 0x10 prefix — a malformed signature
      // ("The signature is incorrect" at type load).  See #2360.
      bufU1(w, 0x10)
      bufMsilTypeWithCtx(w, inner, ctx)
    }
    case MGenericInst(typeRefCode, _, typeArgs) -> {
      bufU1(w, 0x15)  // ELEMENT_TYPE_GENERICINST
      bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
      writeCompressedInt(w, typeRefCode)
      writeCompressedInt(w, typeArgs.count)
      var gi = 0
      while gi < typeArgs.count {
        bufMsilTypeWithCtx(w, genericArgType(typeArgs[gi]), ctx)
        gi = gi + 1
      }
    }
    case MValueTypeGenericInst(typeRefCode, _, typeArgs) -> {
      bufU1(w, 0x15)  // ELEMENT_TYPE_GENERICINST
      bufU1(w, 0x11)  // ELEMENT_TYPE_VALUETYPE
      writeCompressedInt(w, typeRefCode)
      writeCompressedInt(w, typeArgs.count)
      var gi = 0
      while gi < typeArgs.count {
        bufMsilTypeWithCtx(w, genericArgType(typeArgs[gi]), ctx)
        gi = gi + 1
      }
    }
    // Concrete collections: encode the closed `List`1<elem>` /
    // `Dictionary`2<k,v>` instantiation as GENERICINST CLASS + TypeRef so a
    // self-hosted-compiled signature matches the F# emitter's byte-for-byte
    // and a returned `List<Foo>` binds against an F#-compiled consumer.  The
    // open generic TypeRef is seeded for every assembly; W0005 if missing (#2494).
    case MConcreteList(elem) -> {
      val trList1 = findTypeRefRowByName(ctx, "System.Collections.Generic.List`1")
      if trList1 > 0 {
        bufU1(w, 0x15)  // GENERICINST
        bufU1(w, 0x12)  // CLASS
        writeCompressedInt(w, tdrTypeRef(trList1))
        bufU1(w, 1)
        bufMsilTypeWithCtx(w, genericArgType(elem), ctx)
      } else {
        // W0005: List`1 TypeRef absent — seeding bug; per-package builds legitimately omit it (#2494).
        bufU1(w, 0x1C)
      }
    }
    case MConcreteMap(keyT, valT) -> {
      val trDict2 = findTypeRefRowByName(ctx, "System.Collections.Generic.Dictionary`2")
      if trDict2 > 0 {
        bufU1(w, 0x15)  // GENERICINST
        bufU1(w, 0x12)  // CLASS
        writeCompressedInt(w, tdrTypeRef(trDict2))
        bufU1(w, 2)
        bufMsilTypeWithCtx(w, genericArgType(keyT), ctx)
        bufMsilTypeWithCtx(w, genericArgType(valT), ctx)
      } else {
        // W0005: Dictionary`2 TypeRef absent — seeding bug; per-package builds legitimately omit it (#2494).
        bufU1(w, 0x1C)
      }
    }
    // In-bundle generic instantiation (#2362).  Resolve the head's TypeDef row
    // first (in-bundle generic record/union), then a TypeRef fallback (the head
    // came from another assembly after all), and encode the closed GENERICINST.
    // W0005 if neither resolves — missing TypeRef seeding bug (#2494).
    case MGenericInstByName(headFqn, typeArgs) -> {
      val defRow = resolveSigTypeDefRow(ctx, headFqn)
      val coded = if defRow > 0 {
        tdrTypeDef(defRow)
      } else {
        val refRow = findTypeRefRowByName(ctx, headFqn)
        if refRow > 0 {
          tdrTypeRef(refRow)
        } else {
          0
        }
      }
      if coded > 0 {
        bufU1(w, 0x15)  // GENERICINST
        bufU1(w, 0x12)  // CLASS
        writeCompressedInt(w, coded)
        bufU1(w, typeArgs.count)
        var gi = 0
        while gi < typeArgs.count {
          bufMsilTypeWithCtx(w, genericArgType(typeArgs[gi]), ctx)
          gi = gi + 1
        }
      } else {
        // The throwaway discovery context (discoverTypeDefRowsInto) only learns
        // in-bundle TypeDef rows — it lacks the seeded external TypeRefs, so a
        // closed external generic legitimately degrades there; the real pass
        // resolves it.  Suppress the warning during discovery to avoid noise.
        if ctx.discovering.count == 0 {
          println(
            "W0005: bufMsilTypeWithCtx: TypeRef/TypeDef not found for MGenericInstByName '" + headFqn +
              "' — signature degraded to System.Object (#2494)"
          )
        }
        bufU1(w, 0x1C)
      }
    }
    case other -> bufU1(w, elementTypeByte(other))
  }
}

// Context-aware version of buildGenericInstBlob.  Uses bufMsilTypeWithCtx
// so that MClass type arguments are encoded as CLASS + TypeDefOrRef rather
// than degrading to ELEMENT_TYPE_OBJECT.  Required for correct isinst /
// castclass TypeSpecs on generic union case classes (e.g. Option_Some<Keyword>).
pub func buildGenericInstBlobWithCtx(ctx: in LoweringCtx, typeDefOrRef: in Int, argTypes: in List[MsilType]): List[Byte] {
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

// Context-aware GENERICINST blob for value-type generics (ELEMENT_TYPE_VALUETYPE = 0x11).
// Required for AsyncTaskMethodBuilder<T> and other BCL structs — buildGenericInstBlobWithCtx
// incorrectly emits ELEMENT_TYPE_CLASS (0x12) for those, causing a CLR value-type mismatch.
pub func buildValueTypeGenericInstBlobWithCtx(
  ctx: in LoweringCtx, typeDefOrRef: in Int, argTypes: in List[MsilType]
): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x15)  // ELEMENT_TYPE_GENERICINST
  bufU1(w, 0x11)  // ELEMENT_TYPE_VALUETYPE (struct generic, e.g. AsyncTaskMethodBuilder<T>)
  writeCompressedInt(w, typeDefOrRef)
  bufU1(w, argTypes.count)
  var i = 0
  while i < argTypes.count {
    bufMsilTypeWithCtx(w, genericArgType(argTypes[i]), ctx)
    i = i + 1
  }
  bufToList(w)
}

// Open-generic method signature for
// `ATMB[<T>].AwaitUnsafeOnCompleted<TAwaiter,TStateMachine>(ref TAwaiter, ref TStateMachine): void`
// (ECMA-335 §II.23.2.1).
// Calling convention: HASTHIS(0x20) | GENERIC(0x10) = 0x30.
// 2 generic type parameters (TAwaiter = !!0, TStateMachine = !!1).
// 2 formal parameters, void return.
// Param 0: BYREF MVAR 0   (ref TAwaiter)
// Param 1: BYREF MVAR 1   (ref TStateMachine)
pub func buildAwaitUnsafeOnCompletedOpenSig(): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x30)            // HASTHIS | GENERIC
  writeCompressedInt(w, 2)  // 2 generic type parameters
  writeCompressedInt(w, 2)  // 2 formal parameters
  bufU1(w, 0x01)            // ELEMENT_TYPE_VOID (return)
  bufU1(w, 0x10)            // ELEMENT_TYPE_BYREF (ref TAwaiter)
  bufU1(w, 0x1E)            // ELEMENT_TYPE_MVAR
  writeCompressedInt(w, 0)  // index 0 (!!0 = TAwaiter)
  bufU1(w, 0x10)            // ELEMENT_TYPE_BYREF (ref TStateMachine)
  bufU1(w, 0x1E)            // ELEMENT_TYPE_MVAR
  writeCompressedInt(w, 1)  // index 1 (!!1 = TStateMachine)
  bufToList(w)
}

// Build a 2-arg GENERICINST MethodSpec blob for
// `AwaitUnsafeOnCompleted<arg0, SM>`.
// arg0 is the concrete awaiter type (e.g. TaskAwaiter<Int>).
// SM is the in-bundle state machine sealed class identified by smFqn; its
// TypeDef token is resolved at Phase 5 lowering time.
func buildMethodSpec2ArgBlobWithCtx(ctx: in LoweringCtx, arg0: in MsilType, smFqn: in String): List[Byte] {
  val smRow = findTypeDefRowByName(ctx, smFqn)
  val smCoded = tdrTypeDef(smRow)
  val w = bufNew()
  bufU1(w, 0x0A)              // GENERICINST (method instantiation)
  writeCompressedInt(w, 2)    // 2 generic arguments
  bufMsilTypeWithCtx(w, arg0, ctx)  // arg 0: TAwaiter
  bufU1(w, 0x12)              // ELEMENT_TYPE_CLASS (SM is a sealed class)
  writeCompressedInt(w, smCoded)    // arg 1: SM TypeDef
  bufToList(w)
}

// ── Method body lowering ──────────────────────────────────────────────────────
// Lower one MInsn to opcode bytes in `mb`.
pub func lowerMInsn(ctx: in LoweringCtx, insn: in MInsn, mb: in MethodBody): Unit {
  match insn {
    case MLabel(id) -> mbMarkLabel(mb, id)
    case MBr(lbl) -> emitBr(mb, lbl)
    case MBrTrue(lbl) -> emitBrtrue(mb, lbl)
    case MBrFalse(lbl) -> emitBrfalse(mb, lbl)
    case MBrEq(lbl) -> emitBeq(mb, lbl)
    case MBrNe(lbl) -> emitBne_Un(mb, lbl)
    case MBrLt(lbl) -> emitBlt(mb, lbl)
    case MBrGt(lbl) -> emitBgt(mb, lbl)
    case MBrLe(lbl) -> emitBle(mb, lbl)
    case MBrGe(lbl) -> emitBge(mb, lbl)
    case MNop -> emitNop(mb)
    case MRet -> emitRet(mb)
    case MLdNull -> emitLdnull(mb)
    case MLdcI4(v) -> emitLdc_I4(mb, v)
    case MLdcI8(v) -> emitLdc_I8(mb, v)
    case MLdcR8(v) -> emitLdc_R8(mb, v)
    case MLdStr(token) -> emitLdstr(mb, token)
    case MLdarg(slot) -> emitLdarg(mb, slot)
    case MStarg(slot) -> emitStarg_S(mb, slot)
    case MLdloc(slot) -> emitLdloc(mb, slot)
    case MStloc(slot) -> emitStloc(mb, slot)
    case MLdloca(slot) -> emitLdloca_S(mb, slot)
    case MLdarga(slot) -> emitLdarga_S(mb, slot)
    case MLdind(ty) -> emitLdindForType(mb, ty)
    case MStind(ty) -> emitStindForType(mb, ty)
    case MAdd -> emitAdd(mb)
    case MSub -> emitSub(mb)
    case MMul -> emitMul(mb)
    case MDiv -> emitDiv(mb)
    case MRem -> emitRem(mb)
    case MAnd -> emitAnd(mb)
    case MOr -> emitOr(mb)
    case MXor -> emitXor(mb)
    case MNeg -> emitNeg(mb)
    case MNot -> emitNot(mb)
    case MShl -> emitShl(mb)
    case MShr -> emitShr(mb)
    case MShrUn -> emitShrUn(mb)
    case MCeq -> emitCeq(mb)
    case MClt -> emitClt(mb)
    case MCgt -> emitCgt(mb)
    case MConvI4 -> emitConv_I4(mb)
    case MConvI8 -> emitConv_I8(mb)
    case MConvR8 -> emitConv_R8(mb)
    case MConvU1 -> emitConv_U1(mb)
    case MConvU2 -> emitConv_U2(mb)
    case MNewobj(tok) -> emitNewobj(mb, tok)
    case MLdfld(tok) -> emitLdfld(mb, tok)
    case MLdflda(tok) -> emitLdflda(mb, tok)
    case MStfld(tok) -> emitStfld(mb, tok)
    case MLdsfld(tok) -> emitLdsfld(mb, tok)
    case MStsfld(tok) -> emitStsfld(mb, tok)
    case MCall(tok) -> emitCall(mb, tok)
    case MCallvirt(tok) -> emitCallvirt(mb, tok)
    case MCastclass(tok) -> emitCastclass(mb, tok)
    case MListOp(op, elemTy) -> {
      val lt = listTokensForLowering(ctx, elemTy)
      match op {
        case LoCtor -> emitNewobj(mb, lt.ctor)
        case LoAdd -> emitCallvirt(mb, lt.add)
        case LoGetItem -> emitCallvirt(mb, lt.getItem)
        case LoSetItem -> emitCallvirt(mb, lt.setItem)
        case LoGetCount -> emitCallvirt(mb, lt.getCount)
        case LoContains -> emitCallvirt(mb, lt.contains)
        case LoRemoveAt -> emitCallvirt(mb, lt.removeAt)
        case LoCastclass -> emitCastclass(mb, lt.typeSpec)
        case LoToArray -> emitCallvirt(mb, lt.toArray)
      }
    }
    case MDictOp(op, keyTy, valTy) -> {
      val dt = dictTokensForLowering(ctx, keyTy, valTy)
      match op {
        case DoCtor -> emitNewobj(mb, dt.ctor)
        case DoAdd -> emitCallvirt(mb, dt.add)
        case DoGetItem -> emitCallvirt(mb, dt.getItem)
        case DoSetItem -> emitCallvirt(mb, dt.setItem)
        case DoGetCount -> emitCallvirt(mb, dt.getCount)
        case DoContainsKey -> emitCallvirt(mb, dt.containsKey)
        case DoRemove -> emitCallvirt(mb, dt.remove)
        case DoCastclass -> emitCastclass(mb, dt.typeSpec)
        case DoTryGetValue -> emitCallvirt(mb, dt.tryGetValue)
        case DoGetKeys -> emitCallvirt(mb, dt.getKeys)
        case DoGetValues -> emitCallvirt(mb, dt.getValues)
      }
    }
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
    case MIsinst(tok) -> emitIsinst(mb, tok)
    case MIsinstByName(name) -> {
      val defRow = findTypeDefRowByName(ctx, name)
      val tok = if defRow > 0 {
        0x02000000 + defRow                     // TypeDef token (local assembly)
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          0x01000000 + refRow                   // TypeRef token (foreign assembly)
        } else {
          // W0003: type name could not be resolved — falling back to System.Object
          // makes `isinst` always return non-null (every reference type is an Object),
          // so any pattern arm guarded by this isinst unconditionally matches.  Likely
          // cause: cross-bundle union case whose TypeRef was not registered via
          // registerRestoredArtifactTokens, or a misspelled case name.
          println(
            "W0003: MIsinstByName: could not resolve type '" + name +
              "' — falling back to System.Object (isinst will always succeed; check for a misspelled case name or a missing restored-package registration)"
          )
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
        val blob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
        val specRow = ctxAddTypeSpec(ctx, sigKey, blob)
        0x1B000000 + specRow
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          val codedIdx = tdrTypeRef(refRow)
          val sigKey = "typespec_isinst_ref_" + name + "_" + taKey
          val blob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
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
        val blob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
        val specRow = ctxAddTypeSpec(ctx, sigKey, blob)
        0x1B000000 + specRow
      } else {
        val refRow = findTypeRefRowByName(ctx, name)
        if refRow > 0 {
          val codedIdx = tdrTypeRef(refRow)
          val sigKey = "typespec_castclass_ref_" + name + "_" + taKey
          val blob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
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
        val tsKey = "typespec_ldfld_def_" + baseName + "_" + taKey
        val blob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
        val tsRow = ctxAddTypeSpec(ctx, tsKey, blob)
        val mrKey = "mr_ldfld_def_" + baseName + "_" + taKey + "_" + fieldName
        val mrRow = ctxAddMemberRefForTypeSpec(ctx, tsRow, fieldName, mrKey, fieldSig)
        0x0A000000 + mrRow
      } else {
        val refRow = findTypeRefRowByName(ctx, baseName)
        if refRow > 0 {
          val codedIdx = tdrTypeRef(refRow)
          val tsKey = "typespec_ldfld_ref_" + baseName + "_" + taKey
          val blob = buildGenericInstBlobWithCtx(ctx, codedIdx, typeArgs)
          val tsRow = ctxAddTypeSpec(ctx, tsKey, blob)
          val mrKey = "mr_ldfld_ref_" + baseName + "_" + taKey + "_" + fieldName
          val mrRow = ctxAddMemberRefForTypeSpec(ctx, tsRow, fieldName, mrKey, fieldSig)
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
      val tsKey = "newobj_ts_gcase_" + toString(typeRefRow) + "_" + taKey
      val tsRow = ctxAddTypeSpec(ctx, tsKey, tsBlob)
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
    case MNewobjGenericByName(headFqn, typeArgs, ctorParams) -> {
      // In-bundle generic construction (#2362).  Resolve the record/case TypeDef
      // row (TypeRef fallback) so the closed GENERICINST TypeSpec references the
      // in-bundle TypeDef, then build a TypeSpec-parented `.ctor` MemberRef whose
      // signature uses the VAR-form ctorParams.  Mirrors MNewobjGenericCase but
      // by-name (the TypeDef row is only known at this lowering phase).
      val defRow = resolveSigTypeDefRow(ctx, headFqn)
      val coded = if defRow > 0 {
        tdrTypeDef(defRow)
      } else {
        val refRow = findTypeRefRowByName(ctx, headFqn)
        if refRow > 0 {
          tdrTypeRef(refRow)
        } else {
          0
        }
      }
      if coded > 0 {
        var taKey = ""
        var tai = 0
        while tai < typeArgs.count {
          taKey = taKey + msilTypeKey(typeArgs[tai]) + ","
          tai = tai + 1
        }
        val tsBlob = buildGenericInstBlobWithCtx(ctx, coded, typeArgs)
        val tsKey = "newobj_ts_gname_" + headFqn + "_" + taKey
        val tsRow = ctxAddTypeSpec(ctx, tsKey, tsBlob)
        // Ctx-aware so a concrete CLASS-typed ctor parameter encodes CLASS +
        // TypeDef (matching the TypeDef `.ctor` sig lowerMRecord emits) rather
        // than degrading to object — VAR params encode 0x13 idx either way.
        val ctorSig = buildInstanceMethodSigWithCtx(ctorParams, MVoid, ctx)
        var cpKey = ""
        var cpi = 0
        while cpi < ctorParams.count {
          cpKey = cpKey + msilTypeKey(ctorParams[cpi]) + ","
          cpi = cpi + 1
        }
        val mrKey = "newobj_mr_gname_" + headFqn + "_" + taKey + "_" + cpKey
        val mrRow = ctxAddMemberRefForTypeSpec(ctx, tsRow, ".ctor", mrKey, ctorSig)
        emitNewobj(mb, 0x0A000000 + mrRow)
      } else {
        panic("Msil.Lowering: MNewobjGenericByName could not resolve TypeDef/TypeRef for '" + headFqn + "'")
      }
    }
    case MBox(tok) -> emitBox(mb, tok)
    case MUnboxAny(tok) -> emitUnbox_Any(mb, tok)
    case MNewarr(tok) -> emitNewarr(mb, tok)
    case MStelemRef -> emitStelem_Ref(mb)
    case MStelem(tok) -> emitStelem(mb, tok)
    case MDup -> emitDup(mb)
    case MPop -> emitPop(mb)
    case MThrow -> emitThrow(mb)
    case MLdlen -> emitLdlen(mb)
    case MLdelemRef -> emitLdelem_Ref(mb)
    case MLdelemU1 -> emitLdelem_U1(mb)
    case MLdelemI4 -> emitLdelem_I4(mb)
    case MLdftn(tok) -> emitLdftn(mb, tok)
    case MLeave(lbl) -> emitLeave(mb, lbl)
    case MEndfinally -> emitEndfinally(mb)
    case MEHClause(f, ts, te, hs, he, ct) -> mbAddEHClause(mb, EHClause(flags = f, tryStart = ts, tryEnd = te, handlerStart = hs, handlerEnd = he, catchToken = ct))

    // ── Deferred-resolution instructions (async SM synthesis) ──────────────

    case MLdfldByName(ownerFqn, fieldName) -> {
      val tdRow = findTypeDefRowByName(ctx, ownerFqn)
      val fdRow = findFieldDefRowOfType(ctx, tdRow, fieldName)
      if fdRow > 0 {
        emitLdfld(mb, 0x04000000 + fdRow)
      } else {
        panic("Msil.Lowering: MLdfldByName could not resolve field '" + fieldName + "' on type '" + ownerFqn + "'")
      }
    }
    case MLdfldaByName(ownerFqn, fieldName) -> {
      val tdRow = findTypeDefRowByName(ctx, ownerFqn)
      val fdRow = findFieldDefRowOfType(ctx, tdRow, fieldName)
      if fdRow > 0 {
        emitLdflda(mb, 0x04000000 + fdRow)
      } else {
        panic("Msil.Lowering: MLdfldaByName could not resolve field '" + fieldName + "' on type '" + ownerFqn + "'")
      }
    }
    case MStfldByName(ownerFqn, fieldName) -> {
      val tdRow = findTypeDefRowByName(ctx, ownerFqn)
      val fdRow = findFieldDefRowOfType(ctx, tdRow, fieldName)
      if fdRow > 0 {
        emitStfld(mb, 0x04000000 + fdRow)
      } else {
        panic("Msil.Lowering: MStfldByName could not resolve field '" + fieldName + "' on type '" + ownerFqn + "'")
      }
    }
    case MNewobjByName(className) -> {
      // Find (or build) a no-arg .ctor MemberRef for the SM class.
      // The SM TypeDef is in-bundle, so resolve to a MethodDef token directly.
      val tdRow = findTypeDefRowByName(ctx, className)
      val ctorRow = findMethodDefRowOfType(ctx, tdRow, ".ctor")
      if ctorRow > 0 {
        emitNewobj(mb, 0x06000000 + ctorRow)
      } else {
        panic("Msil.Lowering: MNewobjByName could not resolve .ctor for type '" + className + "'")
      }
    }
    case MCallByName(className, methodName) -> {
      val tdRow = findTypeDefRowByName(ctx, className)
      val mdRow = findMethodDefRowOfType(ctx, tdRow, methodName)
      if mdRow > 0 {
        emitCall(mb, 0x06000000 + mdRow)
      } else {
        panic("Msil.Lowering: MCallByName could not resolve '" + methodName + "' on type '" + className + "'")
      }
    }
    case MCallAtmbStart(smFqn, atmbMrRow, isGeneric) -> {
      // Resolve MethodSpec for `ATMB[<T>].Start<SM>(ref SM)` at Phase 5.
      // The MemberRef for `ATMB.Start<!!0>` is atmbMrRow; we instantiate it
      // with the SM TypeDef (resolved by smFqn) to produce a MethodSpec row.
      val specSig = buildMethodSpecBlobWithCtx(ctx, smFqn)
      val specKey = "ms_atmb_start_" + smFqn + "_" + toString(isGeneric)
      val specRow = ctxAddMethodSpec(ctx, mdorMemberRef(atmbMrRow), specKey, specSig)
      emitCall(mb, 0x2B000000 + specRow)
    }

    // ── Phase B.1 instructions ────────────────────────────────────────────────

    case MSwitch(labels) -> emitSwitch(mb, labels)

    case MInitobj(typeToken) -> emitInitobj(mb, typeToken)

    case MCallAwaitUnsafeOnCompleted(smFqn, atmbMrRow, awaiterMsilTy) -> {
      // Build a 2-arg MethodSpec for `ATMB[<T>].AwaitUnsafeOnCompleted<TAwaiter, SM>`.
      // arg0 = concrete awaiter type; arg1 = SM class (TypeDef row looked up from smFqn).
      val specBlob = buildMethodSpec2ArgBlobWithCtx(ctx, awaiterMsilTy, smFqn)
      val specKey = "ms_atmbawunafe_" + smFqn + "_" + msilTypeKey(awaiterMsilTy)
      val specRow = ctxAddMethodSpec(ctx, mdorMemberRef(atmbMrRow), specKey, specBlob)
      emitCall(mb, 0x2B000000 + specRow)
    }
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
      case MClass(_) -> bufU1(w, 0x1C)   // Object: avoids malformed CLASS+TypeDefOrRef entry
      case MGenericInst(_, _, _) -> bufU1(w, 0x1C)  // same: TypeRef token not valid in LocalVarSig
      case MValueTypeGenericInst(_, _, _) -> bufU1(w, 0x1C)  // struct generics also degrade (rare as locals)
      // A slice/array local is encoded concretely as SZARRAY + element type
      // (e.g. `byte[]` = 0x1D 0x05) — NOT degraded to Object.  Codegen tracks
      // slice locals as `MArray`, so an object-typed slot desynced the verifier:
      // `ldloc` yielded `object` where a `T[]` was expected (StackUnexpected,
      // e.g. the metadata reader's `val b = img.bytes` → `rdU8(b, ...)`, #3943).
      // `bufMsilType` writes the SZARRAY prefix *with* its element type, so the
      // signature is well-formed (the earlier bare-0x1D worry doesn't apply).
      case MArray(_) -> bufMsilType(w, locals[i])
      // Concrete collections degrade to Object in LocalVarSig like MGenericInst:
      // the local slot is an object reference that op sites `castclass` to the
      // concrete TypeSpec; the open GENERICINST token is not valid in a
      // LocalVarSig.
      case MConcreteList(_) -> bufU1(w, 0x1C)
      case MConcreteMap(_, _) -> bufU1(w, 0x1C)
      // In-bundle generic instantiation locals degrade to Object like
      // MGenericInst: the slot is an object reference that op sites `castclass`
      // to the concrete TypeSpec; the GENERICINST token is not valid in a
      // LocalVarSig (#2362).
      case MGenericInstByName(_, _) -> bufU1(w, 0x1C)
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
      // An extern class-ref local (e.g. `ProcessStartInfo`) is tracked
      // concretely by codegen, so encode CLASS + its TypeRef rather than erasing
      // to Object — an object slot desynced the verifier (`ldloc` yielded
      // `object` where the concrete class was expected, #3943).  `bufMsilType`
      // writes ELEMENT_TYPE_CLASS + the carried TypeRef token.
      case MClassRef(_, _) -> bufMsilType(w, locals[i])
      case other -> bufU1(w, elementTypeByte(other))
    }
    i = i + 1
  }
  bufToList(w)
}

// Context-aware variant of buildLocalVarSig.  Unlike the base function:
// - MClass(fqn) locals are encoded with their real CLASS + TypeDef token so
//   that `ldloca` on such a local pushes `byref SM` rather than `byref Object`.
//   Required for the async SM kickoff: ATMB.Start<SM>(ref SM) needs `byref SM`.
// - MValueTypeGenericInst locals (e.g. TaskAwaiter<Int>) are encoded with the
//   full GENERICINST VALUETYPE signature so that `stloc` to an awaiter local
//   does not cause a struct-to-object store type mismatch ("invalid program").
//   Struct generics cannot degrade to Object in LocalVarSig because the JIT
//   cannot store an unboxed struct value into an object-typed slot.
func buildLocalVarSigWithCtx(locals: in List[MsilType], ctx: in LoweringCtx): List[Byte] {
  val w = bufNew()
  bufU1(w, 0x07)  // LOCAL_SIG
  writeCompressedInt(w, locals.count)
  var i = 0
  while i < locals.count {
    match locals[i] {
      case MClass(name) -> {
        val defRow = resolveSigTypeDefRow(ctx, name)
        if defRow > 0 {
          bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
          writeCompressedInt(w, tdrTypeDef(defRow))
        } else {
          // Not an in-bundle TypeDef — try a cross-assembly TypeRef before
          // erasing to Object.  A cross-package record-typed local (e.g. a
          // `val w = bufNew()` of type `Msil.Kernel.ByteWriter` in Msil.Lowering)
          // is tracked concretely by codegen, so erasing only the LocalVarSig to
          // Object desynced the verifier: the unchecked `ldloc`/store passed an
          // `object` where the concrete type was expected (StackUnexpected →
          // InvalidProgramException).  Encode `ELEMENT_TYPE_CLASS + TypeRef`,
          // mirroring `bufMsilTypeWithCtx`, so the local is genuinely typed
          // (#3920).
          val refRow = findTypeRefRowByName(ctx, name)
          if refRow > 0 {
            bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
            writeCompressedInt(w, tdrTypeRef(refRow))
          } else {
            bufU1(w, 0x1C)  // fallback to Object (neither TypeDef nor TypeRef found)
          }
        }
      }
      // Closed generic-instantiation locals (e.g. `Option_Some`1<int32>` from a
      // `case Some(x) ->` cast-slot) are tracked concretely by codegen, so encode
      // the closed GENERICINST inline via `bufMsilTypeWithCtx` rather than erasing
      // to Object — otherwise `ldloc` yields `object` where the concrete generic
      // type is expected (StackUnexpected → InvalidProgramException) (#3920).
      case MGenericInst(_, _, _) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      case MGenericInstByName(_, _) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      case MValueTypeGenericInst(_, _, _) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      // Slice/array locals encode concretely as SZARRAY + element (#3943); see
      // the base `buildLocalVarSig`.  `bufMsilTypeWithCtx` types reference
      // element types via their TypeRef/TypeDef token where available.
      case MArray(_) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      // A concrete-collection local holds a genuine `List`1<elem>` /
      // `Dictionary`2<k,v>` at run time (`MListOp(LoCtor)` emits
      // `newobj List`1<elem>`), and codegen tracks the slot concretely, so
      // erasing only the LocalVarSig to Object desynced the verifier (the
      // `MListOp` / call sites operate on the concrete type while `ldloc`
      // yielded `object`) → StackUnexpected / InvalidProgramException.  Encode
      // the full closed GENERICINST via `bufMsilTypeWithCtx` (which itself
      // falls back to Object if `List`1` / `Dictionary`2` TypeRefs are absent),
      // matching the runtime value (#3920).
      case MConcreteList(_) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      case MConcreteMap(_, _) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      // Extern class-ref local: encode CLASS + TypeRef concretely (#3943); see
      // the base `buildLocalVarSig`.
      case MClassRef(_, _) -> bufMsilTypeWithCtx(w, locals[i], ctx)
      case MValueTypeRef(typeRefCode, _) -> {
        bufU1(w, 0x11)
        writeCompressedInt(w, typeRefCode)
      }
      case other -> bufU1(w, elementTypeByte(other))
    }
    i = i + 1
  }
  bufToList(w)
}

// Build a content-based intern key for a LocalVarSig blob.
// Must produce a DISTINCT key for every distinct `buildLocalVarSigWithCtx`
// blob: `internBlob` dedups purely by this key and discards the second
// blob's bytes on a collision, so two local-var lists that encode to
// different blobs but share a key alias to the first's blob — giving the
// second function a LocalVarSig with the wrong slot types (StackUnexpected /
// InvalidProgramException) (#1442, #3943).
//
// `msilTypeKey` is the canonical per-type discriminator — documented to
// distinguish every concrete encoding produced by `bufMsilType` (and hence by
// `bufMsilTypeWithCtx`, which `buildLocalVarSigWithCtx` uses for
// MConcreteList / MConcreteMap / MGenericInst / MGenericInstByName /
// MValueTypeGenericInst).  Keying every local on it keeps the intern key in
// lock-step with the encoder: identical MsilType sequences share one blob
// (correct), and any difference the encoder represents concretely (a list's
// element type, a generic's args, a class FQN) yields a different key.  Two
// types that the encoder erases to the same byte (e.g. MClassRef vs MArray,
// both Object in LocalVarSig) get distinct keys and hence redundant — but
// byte-identical — blobs, which is harmless.
//
// This previously mirrored the *old* erase-to-Object `buildLocalVarSig`, but
// #3920 switched `lowerMFunc` to the concrete-encoding `buildLocalVarSigWithCtx`
// without updating this key, reintroducing exactly the aliasing #1442 fixed.
func buildLvSigKey(locals: in List[MsilType]): String {
  var key = "lv_"
  var i = 0
  while i < locals.count {
    key = key + msilTypeKey(locals[i]) + "_"
    i = i + 1
  }
  key
}

// Lower an MFunc to a MethodBody and register it in the context.
// Returns the MethodBody (for RVA assignment by the caller).
pub func lowerMFunc(f: in MFunc, ctx: in LoweringCtx): MethodBody {
  val mb = newMethodBody()
  // Discovery pass (epic #2359 Stage 1): only the TypeDef/MethodDef row layout
  // matters, so skip body lowering — a throwaway context has none of the
  // pre-seeded stdlib / restored token rows that `lowerMInsn` resolves against.
  if ctx.discovering.count > 0 {
    return mb
  }
  if f.locals.count > 0 {
    val lvSig = buildLocalVarSigWithCtx(f.locals, ctx)
    val lvBlob = ctxInternBlob(ctx, buildLvSigKey(f.locals), lvSig)
    val lvRow = addStandAloneSig(ctx.tables, StandAloneSigRow(signature = lvBlob))
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
// Emit one GenericParam row (table 0x2A) per type-parameter name owned by the
// generic TypeDef at `ownerTypeDefRow` (#2362 / docs/43).  Each row records the
// parameter's 0-based ordinal (`number`), invariant/no-constraint flags (0), the
// owning TypeDef as a TypeOrMethodDef coded index, and the #Strings index of the
// parameter name.  The serializer sorts the table by (owner, number) before
// emission, so rows may be added here in declaration order.  No-op when
// `generics` is empty (the non-generic case).
func emitGenericParamRows(ctx: in LoweringCtx, ownerTypeDefRow: in Int, generics: in List[String]): Unit {
  val sh = ctx.strings
  val t = ctx.tables
  var gi = 0
  while gi < generics.count {
    addGenericParam(
      t,
      GenericParamRow(number = gi, flags = 0, owner = mtdTypeDef(ownerTypeDefRow), name = internString(sh, generics[gi]))
    )
    gi = gi + 1
  }
}

// Lower an MRecord into the context, adding the TypeDef, Field, and MethodDef rows.
// Returns the 1-based TypeDef row index of the emitted class.
pub func lowerMRecord(r: in MRecord, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables

  // TypeDef must store simple name (no namespace); CLR loader resolves by (namespace, simpleName).
  val simpleBaseRec = simpleNameFromFqn(r.namespace, r.className)
  // Generic TypeDef name carries arity suffix (Box`1) — without it multi-field value-type layouts break silently (#2362; D-progress-471).
  val simpleNameRec = if r.generics.count > 0 {
    simpleBaseRec + "`" + toString(r.generics.count)
  } else {
    simpleBaseRec
  }
  val sName = internString(sh, simpleNameRec)
  val sNs = internString(sh, r.namespace)

  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // TypeDef row registered before fields so MLdfldByName in MoveNext can resolve tokens; ECMA-335 §II.22.37 only requires fieldList to be non-decreasing (#2827; D-progress-471).
  val recBaseRow = if r.baseClass.length > 0 and r.baseClass != "System.Object" {
    findTypeDefRowByName(ctx, r.baseClass)
  } else {
    0
  }
  // A generic union *case* extends the open instantiation of its generic base
  // (`Maybe_Just`1` extends `Maybe`1<!0>`), encoded as a TypeSpec — NOT a bare
  // TypeDef ref to the open base (#2362).  Build that base-open TypeSpec once;
  // it parents both the `extends` token and the base-`.ctor` MemberRef below.
  val baseOpenTsRow = if recBaseRow > 0 and r.generics.count > 0 {
    val baseArgs: List[MsilType] = newList()
    var bj = 0
    while bj < r.generics.count {
      baseArgs.add(MTypeVar(index = bj))
      bj = bj + 1
    }
    val baseBlob = buildGenericInstBlobWithCtx(ctx, tdrTypeDef(recBaseRow), baseArgs)
    ctxAddTypeSpec(ctx, "base_open_ts_" + r.className, baseBlob)
  } else {
    0
  }
  val recExtendsToken = if baseOpenTsRow > 0 {
    tdrTypeSpec(baseOpenTsRow)
  } else if recBaseRow > 0 {
    tdrTypeDef(recBaseRow)
  } else {
    objectTypeToken(ctx)
  }
  // ECMA-335 / CLR constraint: SequentialLayout is only valid when the parent
  // is System.Object, System.ValueType, or another SequentialLayout/ExplicitLayout
  // class.  Union case classes extend their abstract AutoLayout base, so they
  // must use AutoLayout (no TDF_SEQUENTIAL_LAYOUT) to pass type loading.
  // A generic TypeDef with a type-variable field (`value: T` → VAR(0)) cannot
  // use SequentialLayout — the CLR rejects it at load with a TypeLoadException —
  // so a generic record (non-empty `r.generics`) uses AutoLayout too (#2362).
  val recFlags = if recBaseRow > 0 or r.generics.count > 0 {
    TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT
  } else {
    TDF_PUBLIC + TDF_SEALED + TDF_SEQUENTIAL_LAYOUT + TDF_BEFORE_FIELD_INIT
  }
  addTypeDef(
    t,
    TypeDefRow(
      flags = recFlags,
      typeName = sName,
      typeNamespace = sNs,
      extends = recExtendsToken,
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  val selfTypeDefRow = t.typeDefs.count
  recordUserTypeDefRow(ctx, r.namespace, simpleNameRec, selfTypeDefRow)
  // Emit GenericParam rows for an in-bundle generic record (#2362).
  emitGenericParamRows(ctx, selfTypeDefRow, r.generics)
  // For a generic record, field access from WITHIN the type's own methods (the
  // ctor's `stfld`) must go through a Field MemberRef parented to the *open*
  // self-instantiation TypeSpec (`Box`1<!0>`), NOT a bare FieldDef token.  A
  // bare FieldDef makes the JIT use the canonical (reference-sized) layout, so
  // for a value-type instantiation (`Pair<Int,Int>`) the ctor writes the wrong
  // field offset (the second field silently lands in the wrong slot) — #2362.
  // Build the open self-TypeSpec once here; the ctor below references its fields.
  val selfTsRow = if r.generics.count > 0 {
    val openArgs: List[MsilType] = newList()
    var gj = 0
    while gj < r.generics.count {
      openArgs.add(MTypeVar(index = gj))
      gj = gj + 1
    }
    val selfBlob = buildGenericInstBlobWithCtx(ctx, tdrTypeDef(selfTypeDefRow), openArgs)
    ctxAddTypeSpec(ctx, "self_open_ts_" + r.className, selfBlob)
  } else {
    0
  }

  // Emit Field rows (must come after TypeDef so findFieldDefRowOfType sees this
  // type's firstField as the starting point when lowerMFunc is called below).
  var fi = 0
  while fi < r.fields.count {
    val f = r.fields[fi]
    val sF = internString(sh, f.name)
    val fSig = buildFieldSigWithCtx(f.fieldType, ctx)
    val bSig = internBlob(bh, "field_" + r.className + "_" + f.name, fSig)
    val fRow = addField(t, FieldRow(flags = f.flags, name = sF, signature = bSig))
    fi = fi + 1
  }

  // Synthesise a constructor.
  // When useDefaultCtor=true (async SM classes), emit a no-arg .ctor() that
  // only calls the base-class constructor — SM fields are set individually
  // by the kickoff function via stfld after `newobj`.
  // Otherwise emit the standard .ctor(field1, field2, ...) that takes all
  // fields as parameters (the existing record constructor pattern).
  val sCtor = internString(sh, ".ctor")
  val recBaseCtorTok2 = if baseOpenTsRow > 0 {
    // Generic case: chain through `Maybe`1<!0>::.ctor()` via a TypeSpec MemberRef.
    val mrRow = ctxAddMemberRefForTypeSpec(
      ctx,
      baseOpenTsRow,
      ".ctor",
      "base_open_ctor_" + r.className,
      buildInstanceMethodSig(newList(), MVoid)
    )
    0x0A000000 + mrRow
  } else if r.baseClass.length > 0 and r.baseClass != "System.Object" {
    val recBaseTypeRow2 = findTypeDefRowByName(ctx, r.baseClass)
    if recBaseTypeRow2 > 0 {
      val recBaseCtorRow2 = findMethodDefRowOfType(ctx, recBaseTypeRow2, ".ctor")
      if recBaseCtorRow2 > 0 {
        0x06000000 + recBaseCtorRow2
      } else {
        0x0A000000 + ctx.mrObjectCtor
      }
    } else {
      0x0A000000 + ctx.mrObjectCtor
    }
  } else {
    0x0A000000 + ctx.mrObjectCtor
  }

  if r.useDefaultCtor {
    // No-arg constructor: ldarg.0; call Object::.ctor(); ret
    val noArgSig = buildInstanceMethodSig(newList(), MVoid)
    val noArgKey = "ctor_noarg_" + r.className
    val bNoArgSig = internBlob(bh, noArgKey, noArgSig)
    val mbCtor2 = newMethodBody()
    mbCtor2.maxStack = 1
    emitLdarg_0(mbCtor2)
    emitCall(mbCtor2, recBaseCtorTok2)
    emitRet(mbCtor2)
    ctx.bodies.add(mbCtor2)
    val rvasC2 = methodBodyRvas(ctx.bodies)
    val ctorRva2 = rvasC2[ctx.bodies.count - 1]
    val firstPrm2 = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = ctorRva2,
        implFlags = 0,
        flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sCtor,
        signature = bNoArgSig,
        paramList = firstPrm2
      )
    )
  } else {
    // Field-parameterised constructor: .ctor(field1, field2, ...)
    val ctorParams: List[MsilType] = newList()
    var ci = 0
    while ci < r.fields.count {
      ctorParams.add(r.fields[ci].fieldType)
      ci = ci + 1
    }
    val ctorSig = buildInstanceMethodSigWithCtx(ctorParams, MVoid, ctx)
    val ctorKey = "ctor_" + r.className
    val bCtorSig = internBlob(bh, ctorKey, ctorSig)

    // Build .ctor body: ldarg.0; call <base>::.ctor(); [ldarg.n; stfld field_n]×n; ret
    // ECMA-335 §I.8.9.6.6: every ctor must call a base ctor before returning.
    val mbCtor = newMethodBody()
    mbCtor.maxStack = 2
    emitLdarg_0(mbCtor)
    emitCall(mbCtor, recBaseCtorTok2)
    var ai = 0
    while ai < r.fields.count {
      emitLdarg_0(mbCtor)
      emitLdarg(mbCtor, ai + 1)
      if selfTsRow > 0 {
        // Generic record: stfld through a Field MemberRef on the open
        // self-instantiation TypeSpec so the JIT uses the correct per-
        // instantiation field layout (#2362).
        val f = r.fields[ai]
        val fSigC = buildFieldSigWithCtx(f.fieldType, ctx)
        val mrRow = ctxAddMemberRefForTypeSpec(ctx, selfTsRow, f.name, "self_open_fld_" + r.className + "_" + f.name, fSigC)
        emitStfld(mbCtor, 0x0A000000 + mrRow)
      } else {
        emitStfld(mbCtor, 0x04000000 + firstField + ai)
      }
      ai = ai + 1
    }
    emitRet(mbCtor)
    ctx.bodies.add(mbCtor)

    val rvas = methodBodyRvas(ctx.bodies)
    val ctorRva = rvas[ctx.bodies.count - 1]
    val firstParam = t.params_.count + 1

    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))

    addMethodDef(
      t,
      MethodDefRow(
        rva = ctorRva,
        implFlags = 0,
        flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sCtor,
        signature = bCtorSig,
        paramList = firstParam
      )
    )
  }

  // Emit explicit instance methods — TypeDef and FieldDefs are already registered
  // above, so MLdfldByName/MStfldByName inside lowerMFunc resolve correctly.
  var mi = 0
  while mi < r.methods.count {
    val m = r.methods[mi]
    val mbM = lowerMFunc(m, ctx)
    ctx.bodies.add(mbM)
    val rvasM = methodBodyRvas(ctx.bodies)
    val mRva = rvasM[ctx.bodies.count - 1]
    val sName2 = internString(sh, m.name)
    val mSig = buildInstanceMethodSigWithCtx(m.params, m.ret, ctx)
    // Arity-qualify the intern key (#1536) so same-name overloads don't collide in `internBlob`'s dedup.
    val bMSig = internBlob(bh, "meth_" + r.className + "_" + m.name + "/" + toString(m.params.count), mSig)
    val fp = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(rva = mRva, implFlags = 0, flags = m.flags, name = sName2, signature = bMSig, paramList = fp)
    )
    mi = mi + 1
  }
  selfTypeDefRow
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
  val t = ctx.tables

  val simpleNameRec = simpleNameFromFqn(r.namespace, r.className)
  val sName = internString(sh, simpleNameRec)
  val sNs = internString(sh, r.namespace)

  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit Instance static field (public, static, initonly; type = Object).
  val sInstance = internString(sh, "Instance")
  val instSig = buildFieldSig(MObject)
  val bInstSig = internBlob(bh, "inst_" + r.className, instSig)
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_STATIC + FDA_INIT_ONLY, name = sInstance, signature = bInstSig))

  // Emit .ctor() — no parameters; calls the union base's protected .ctor.
  // If the base is a local TypeDef (union case hierarchy), chain through its
  // protected .ctor rather than calling Object::.ctor() directly.
  val baseCtorTok = if r.baseClass.length > 0 and r.baseClass != "System.Object" {
    val baseTypeRow = findTypeDefRowByName(ctx, r.baseClass)
    if baseTypeRow > 0 {
      val baseCtorRow = findMethodDefRowOfType(ctx, baseTypeRow, ".ctor")
      if baseCtorRow > 0 {
        0x06000000 + baseCtorRow
      } else {
        0x0A000000 + ctx.mrObjectCtor
      }
    } else {
      0x0A000000 + ctx.mrObjectCtor
    }
  } else {
    0x0A000000 + ctx.mrObjectCtor
  }
  val mbCtor = newMethodBody()
  mbCtor.maxStack = 2
  emitLdarg_0(mbCtor)
  emitCall(mbCtor, baseCtorTok)
  emitRet(mbCtor)
  ctx.bodies.add(mbCtor)
  val rvasCtor = methodBodyRvas(ctx.bodies)
  val ctorRva = rvasCtor[ctx.bodies.count - 1]
  val fpCtor = t.params_.count + 1
  val sCtor = internString(sh, ".ctor")
  val ctorSig = buildInstanceMethodSig(newList(), MVoid)
  val bCtorSig = internBlob(bh, "ctor_" + r.className, ctorSig)
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(
    t,
    MethodDefRow(
      rva = ctorRva,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name = sCtor,
      signature = bCtorSig,
      paramList = fpCtor
    )
  )

  // Emit .cctor() — creates the singleton Instance.
  // .ctor MethodDef token = 0x06000000 + firstMethod (already emitted above).
  // Instance FieldDef token = 0x04000000 + firstField (already emitted above).
  val mbCctor = newMethodBody()
  mbCctor.maxStack = 2
  emitNewobj(mbCctor, 0x06000000 + firstMethod)
  emitStsfld(mbCctor, 0x04000000 + firstField)
  emitRet(mbCctor)
  ctx.bodies.add(mbCctor)
  val rvasCctor = methodBodyRvas(ctx.bodies)
  val cctorRva = rvasCctor[ctx.bodies.count - 1]
  val fpCctor = t.params_.count + 1
  val sCctor = internString(sh, ".cctor")
  val cctorSig = buildStaticMethodSig(newList(), MVoid)
  val bCctorSig = internBlob(bh, "cctor_" + r.className, cctorSig)
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(
    t,
    MethodDefRow(
      rva = cctorRva,
      implFlags = 0,
      flags = MDA_PRIVATE + MDA_STATIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name = sCctor,
      signature = bCctorSig,
      paramList = fpCctor
    )
  )

  // TypeDef row — sealed class extending the union base class (or Object as
  // fallback when the base is not a local TypeDef, e.g. for cross-package use).
  val baseDefRow = if r.baseClass.length > 0 and r.baseClass != "System.Object" {
    findTypeDefRowByName(ctx, r.baseClass)
  } else {
    0
  }
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
  addTypeDef(
    t,
    TypeDefRow(
      flags = caseFlags,
      typeName = sName,
      typeNamespace = sNs,
      extends = extendsToken,
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  val caseTypeDefRow = t.typeDefs.count
  recordUserTypeDefRow(ctx, r.namespace, simpleNameRec, caseTypeDefRow)
  // A nullary case of a generic union re-declares the union's type parameters
  // (e.g. `Option_None` carries `[T]`), matching the F# emitter (#2362).
  emitGenericParamRows(ctx, caseTypeDefRow, r.generics)
  caseTypeDefRow
}

// Lower an MUnion as an abstract base class + one sealed case class per variant.
// Returns the 1-based TypeDef row of the abstract base class.
pub func lowerMUnion(u: in MUnion, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables

  val simpleBaseUnion = if u.namespace.length == 0 {
    u.baseName
  } else {
    u.baseName.substring(u.namespace.length + 1, u.baseName.length - u.namespace.length - 1)
  }
  // A generic union's base + case TypeDefs carry the CLR arity suffix
  // (`Maybe`1`, `Maybe_Just`1`) — same convention as generic records (#2362).
  val arity = u.generics.count
  val simpleNameUnion = if arity > 0 { simpleBaseUnion + "`" + toString(arity) } else { simpleBaseUnion }
  // The arity-suffixed base FQN the case classes must name as their base so
  // findTypeDefRowByName resolves it (the TypeDef is stored under the suffix).
  val baseClassFqn = if arity > 0 { u.baseName + "`" + toString(arity) } else { u.baseName }
  val sBase = internString(sh, simpleNameUnion)
  val sNs = internString(sh, u.namespace)

  val baseFirstField = t.fields.count + 1
  val baseFirstMethod = t.methodDefs.count + 1

  // Emit base methods (abstract / virtual)
  var mi = 0
  while mi < u.methods.count {
    val m = u.methods[mi]
    val mb = lowerMFunc(m, ctx)
    ctx.bodies.add(mb)
    val rvas = methodBodyRvas(ctx.bodies)
    val mRva = rvas[ctx.bodies.count - 1]
    val sN = internString(sh, m.name)
    val mSig = buildStaticMethodSigWithCtx(m.params, m.ret, ctx)
    // Arity-qualify the intern key (#1536) — see the `meth_` site above.
    val bSig = internBlob(bh, "basemeth_" + u.baseName + "_" + m.name + "/" + toString(m.params.count), mSig)
    val fp = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(rva = mRva, implFlags = 0, flags = m.flags, name = sN, signature = bSig, paramList = fp))
    mi = mi + 1
  }

  // Protected no-arg .ctor for the abstract base.  The F# bootstrap emitter
  // defines this constructor so derived case classes can chain through it.
  // Without it, the CLR refuses to load case classes whose TypeDef extends
  // the union base when their own .ctor calls Object::.ctor() directly.
  val sBaseCtor = internString(sh, ".ctor")
  val baseCtorSig = buildInstanceMethodSig(newList(), MVoid)
  val bBaseCtorSig = internBlob(bh, "union_base_ctor_" + u.baseName, baseCtorSig)
  val mbBaseCtor = newMethodBody()
  mbBaseCtor.maxStack = 1
  emitLdarg_0(mbBaseCtor)
  emitCall(mbBaseCtor, 0x0A000000 + ctx.mrObjectCtor)
  emitRet(mbBaseCtor)
  ctx.bodies.add(mbBaseCtor)
  val rvasBaseCtor = methodBodyRvas(ctx.bodies)
  val baseCtorRva = rvasBaseCtor[ctx.bodies.count - 1]
  val fpBaseCtor = t.params_.count + 1
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(
    t,
    MethodDefRow(
      rva = baseCtorRva,
      implFlags = 0,
      flags = MDA_FAMILY + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name = sBaseCtor,
      signature = bBaseCtorSig,
      paramList = fpBaseCtor
    )
  )

  // Abstract base TypeDef
  val baseRow = addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_ABSTRACT + TDF_BEFORE_FIELD_INIT,
      typeName = sBase,
      typeNamespace = sNs,
      extends = objectTypeToken(ctx),
      fieldList = baseFirstField,
      methodList = baseFirstMethod
    )
  )
  recordUserTypeDefRow(ctx, u.namespace, simpleNameUnion, baseRow)
  // GenericParam rows for the abstract base of a generic union (#2362).
  emitGenericParamRows(ctx, baseRow, u.generics)

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
      baseClass = baseClassFqn,
      fields = c.fields,
      methods = newList(),
      useDefaultCtor = false,
      generics = c.generics
    )
    // A *generic* nullary case routes through lowerMRecord (a zero-field generic
    // record): lowerMRecord emits exactly the F# shape — a plain `.ctor()`
    // chaining the base via a TypeSpec MemberRef, AutoLayout, the arity-suffixed
    // name, GenericParam rows, and NO singleton.  The singleton scheme
    // (`lowerMNullaryUnionCase`) cannot apply to a generic case because a generic
    // type's static `Instance` field is per-instantiation — F# constructs the
    // nullary generic case via `newobj` each time instead (Q-GEN-001).  A
    // non-generic nullary case keeps the singleton (reference equality).
    if c.fields.count == 0 and c.generics.count == 0 {
      lowerMNullaryUnionCase(rec, ctx)
    } else {
      lowerMRecord(rec, ctx)
    }
    ci = ci + 1
  }

  baseRow
}

// ── Distinct / Range type lowering ────────────────────────────────────────────
// Inherent conversion method name for a distinct type's underlying primitive
// (`type UserId = Int` ⇒ `toInt(): Int`).  Empty when the underlying type has
// no canonical projection (e.g. a class-typed newtype).
pub func distinctConvName(inner: in MsilType): String {
  match inner {
    case MInt -> "toInt"
    case MLong -> "toLong"
    case MDouble -> "toDouble"
    case MByte -> "toByte"
    case _ -> ""
  }
}

// Add one synthesised method (body + a placeholder Param row + MethodDef row).
// Mirrors the per-method emission the union/record lowerers use.
func addSynthMethodDef(ctx: in LoweringCtx, mb: in MethodBody, name: in String, sigBlob: in Int, flags: in Int): Unit {
  ctx.bodies.add(mb)
  val rvas = methodBodyRvas(ctx.bodies)
  val rva = rvas[ctx.bodies.count - 1]
  val fp = ctx.tables.params_.count + 1
  addParam(ctx.tables, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  val _ = addMethodDef(
    ctx.tables,
    MethodDefRow(
      rva = rva,
      implFlags = 0,
      flags = flags,
      name = internString(ctx.strings, name),
      signature = sigBlob,
      paramList = fp
    )
  )
}

// Emit the range bounds test for a distinct type into `mb`, branching to
// `failLabel` on any violation (value below min, or above/at max).  Operates on
// the value in arg 0 (the static `from`/`tryFrom` factories take the underlying
// value as their sole argument).  No-op when the type carries no range (#1501).
func emitDistinctBoundsToFail(mb: in MethodBody, d: in MDistinctType, failLabel: in Int): Unit {
  if not d.hasRange {
    return
  }
  // min check: fail if value < min.
  emitLdarg_0(mb)
  if d.rangeIsFloat {
    emitLdc_R8(mb, d.minF)
  } else {
    match d.inner {
      case MInt -> emitLdc_I4(mb, longToInt(d.minI))
      case _ -> emitLdc_I8(mb, d.minI)
    }
  }
  emitClt(mb)
  emitBrtrue(mb, failLabel)
  // max check: closed (`..=`) fails if value > max; half-open (`..<`) fails if
  // value >= max ⟺ not(value < max).
  emitLdarg_0(mb)
  if d.rangeIsFloat {
    emitLdc_R8(mb, d.maxF)
  } else {
    match d.inner {
      case MInt -> emitLdc_I4(mb, longToInt(d.maxI))
      case _ -> emitLdc_I8(mb, d.maxI)
    }
  }
  if d.upperExclusive {
    emitClt(mb)
    emitBrfalse(mb, failLabel)
  } else {
    emitCgt(mb)
    emitBrtrue(mb, failLabel)
  }
}

// Human-readable range description for the bounds-violation message.
func distinctRangeDesc(d: in MDistinctType): String {
  val lo = if d.rangeIsFloat { d.minF.toString() } else { d.minI.toString() }
  val hi = if d.rangeIsFloat { d.maxF.toString() } else { d.maxI.toString() }
  val close = if d.upperExclusive { ")" } else { "]" }
  "[" + lo + ", " + hi + close
}

// Lower an MDistinctType as a sealed reference type wrapping one `value` field,
// with the construction API the language reference defines for distinct and
// range subtypes (#1501): a `.ctor(value)`, a static `from(x)` factory (which
// throws `System.ArgumentOutOfRangeException` on a range violation), a static
// `tryFrom(x): Result[Self, String]` (which returns `Err(message)` instead of
// throwing — emitted only when `Std.Core.Result` is imported), and an inherent
// `toInt`/`toLong`/… projection back to the underlying primitive.
//
// Method emission order is fixed — `.ctor`, `from`, `tryFrom`, `toX` — and the
// codegen pass-1 token budget (`addPackageTokens`, IDistinctType arm) reserves
// MethodDef rows in exactly this order so call sites resolve to the right token.
pub func lowerMDistinctType(d: in MDistinctType, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables
  val isDiscover = ctx.discovering.count > 0

  val simpleName = simpleNameFromFqn(d.namespace, d.className)
  val sName = internString(sh, simpleName)
  val sNs = internString(sh, d.namespace)

  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // ── value field ──
  val fSig = buildFieldSigWithCtx(d.inner, ctx)
  val bFSig = internBlob(bh, "dval_" + d.className, fSig)
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_INIT_ONLY, name = internString(sh, "value"), signature = bFSig))
  val valueFieldTok = 0x04000000 + firstField

  val hasTryFrom = ctx.stdCoreResultOk2Row.count > 0 and ctx.stdCoreResultErr2Row.count > 0 and
    ctx.stdCoreResultRow.count > 0
  val convName = distinctConvName(d.inner)
  val rangeMsg = simpleName + ".from: value out of range " + (if d.hasRange { distinctRangeDesc(d) } else { "" })
  val tryFromMsg = simpleName + ".tryFrom: value out of range " + (if d.hasRange { distinctRangeDesc(d) } else { "" })

  val singleParam: List[MsilType] = newList()
  singleParam.add(d.inner)

  // ── Method 0: .ctor(value) ──
  val ctorSig = buildInstanceMethodSigWithCtx(singleParam, MVoid, ctx)
  val bCtorSig = internBlob(bh, "dctor_" + d.className, ctorSig)
  val mbCtor = newMethodBody()
  if not isDiscover {
    mbCtor.maxStack = 2
    emitLdarg_0(mbCtor)
    emitCall(mbCtor, 0x0A000000 + ctx.mrObjectCtor)
    emitLdarg_0(mbCtor)
    emitLdarg(mbCtor, 1)
    emitStfld(mbCtor, valueFieldTok)
    emitRet(mbCtor)
  }
  addSynthMethodDef(
    ctx,
    mbCtor,
    ".ctor",
    bCtorSig,
    MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME
  )
  val ctorTok = 0x06000000 + firstMethod

  // ── Method 1: static from(x): Self ──
  val fromSig = buildStaticMethodSigWithCtx(singleParam, MClass(className = d.className), ctx)
  val bFromSig = internBlob(bh, "dfrom_" + d.className, fromSig)
  val mbFrom = newMethodBody()
  if not isDiscover {
    mbFrom.maxStack = 4
    if d.hasRange {
      val failL = mbNewLabel(mbFrom)
      emitDistinctBoundsToFail(mbFrom, d, failL)
      emitLdarg_0(mbFrom)
      emitNewobj(mbFrom, ctorTok)
      emitRet(mbFrom)
      mbMarkLabel(mbFrom, failL)
      val trExc = ctxAddTypeRef(ctx, "System", "ArgumentOutOfRangeException", ctx.arRuntime)
      val mrExcCtor = 0x0A000000 +
        ctxAddMemberRef(
          ctx,
          trExc,
          ".ctor",
          "dexc_ctor",
          buildInstanceMethodSig(singleStringParam(), MVoid)
        )
      emitLdstr(mbFrom, ctxInternUs(ctx, rangeMsg))
      emitNewobj(mbFrom, mrExcCtor)
      emitThrow(mbFrom)
    } else {
      emitLdarg_0(mbFrom)
      emitNewobj(mbFrom, ctorTok)
      emitRet(mbFrom)
    }
  }
  addSynthMethodDef(ctx, mbFrom, "from", bFromSig, MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG)

  // ── Method 2: static tryFrom(x): Result[Self, String] (Result imported only) ──
  if hasTryFrom {
    val resTyArgs: List[MsilType] = newList()
    resTyArgs.add(MClass(className = d.className))
    resTyArgs.add(MString)
    val resRetTy = MGenericInst(
      typeRefCode = tdrTypeRef(ctx.stdCoreResultRow[0]),
      headFqn = "Std.Core.Result",
      typeArgs = resTyArgs
    )
    val tryFromSig = buildStaticMethodSigWithCtx(singleParam, resRetTy, ctx)
    val bTryFromSig = internBlob(bh, "dtryfrom_" + d.className, tryFromSig)
    val mbTry = newMethodBody()
    if not isDiscover {
      mbTry.maxStack = 4
      // Ok ctor MemberRef on closed Result_Ok<Self, String>.
      val okBlob = buildGenericInstBlobWithCtx(ctx, tdrTypeRef(ctx.stdCoreResultOk2Row[0]), resTyArgs)
      val tsOk = ctxAddTypeSpec(ctx, "ts_dtryfrom_ok_" + d.className, okBlob)
      val okCtorPs: List[MsilType] = newList()
      okCtorPs.add(MTypeVar(index = 0))
      val mrOk = 0x0A000000 +
        ctxAddMemberRefForTypeSpec(
          ctx,
          tsOk,
          ".ctor",
          "mr_dtryfrom_ok_" + d.className,
          buildInstanceMethodSig(okCtorPs, MVoid)
        )
      if d.hasRange {
        val failL = mbNewLabel(mbTry)
        emitDistinctBoundsToFail(mbTry, d, failL)
        emitLdarg_0(mbTry)
        emitNewobj(mbTry, ctorTok)
        emitNewobj(mbTry, mrOk)
        emitRet(mbTry)
        mbMarkLabel(mbTry, failL)
        // Err ctor MemberRef on closed Result_Err<Self, String>.
        val errBlob = buildGenericInstBlobWithCtx(ctx, tdrTypeRef(ctx.stdCoreResultErr2Row[0]), resTyArgs)
        val tsErr = ctxAddTypeSpec(ctx, "ts_dtryfrom_err_" + d.className, errBlob)
        val errCtorPs: List[MsilType] = newList()
        errCtorPs.add(MTypeVar(index = 1))
        val mrErr = 0x0A000000 +
          ctxAddMemberRefForTypeSpec(
            ctx,
            tsErr,
            ".ctor",
            "mr_dtryfrom_err_" + d.className,
            buildInstanceMethodSig(errCtorPs, MVoid)
          )
        emitLdstr(mbTry, ctxInternUs(ctx, tryFromMsg))
        emitNewobj(mbTry, mrErr)
        emitRet(mbTry)
      } else {
        emitLdarg_0(mbTry)
        emitNewobj(mbTry, ctorTok)
        emitNewobj(mbTry, mrOk)
        emitRet(mbTry)
      }
    }
    addSynthMethodDef(ctx, mbTry, "tryFrom", bTryFromSig, MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG)
  }

  // ── Method 3: instance toX(): Underlying ──
  if convName.length > 0 {
    val convSig = buildInstanceMethodSigWithCtx(newList(), d.inner, ctx)
    val bConvSig = internBlob(bh, "dconv_" + d.className, convSig)
    val mbConv = newMethodBody()
    if not isDiscover {
      mbConv.maxStack = 1
      emitLdarg_0(mbConv)
      emitLdfld(mbConv, valueFieldTok)
      emitRet(mbConv)
    }
    addSynthMethodDef(ctx, mbConv, convName, bConvSig, MDA_PUBLIC + MDA_HIDE_BY_SIG)
  }

  val typeRow = addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
      typeName = sName,
      typeNamespace = sNs,
      extends = objectTypeToken(ctx),
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  recordUserTypeDefRow(ctx, d.namespace, simpleName, typeRow)
  typeRow
}

// One-element `[String]` param list (for the ArgumentOutOfRangeException ctor).
func singleStringParam(): List[MsilType] {
  val ps: List[MsilType] = newList()
  ps.add(MString)
  ps
}

// Lower an MRangeType as a distinct type with range validation in .ctor.
// The constructor checks `minVal <= value <= maxVal` at runtime and throws a
// System.ArgumentOutOfRangeException when violated (Phase R5 runtime check;
// SMT proof is Phase R6).
pub func lowerMRangeType(r: in MRangeType, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables

  val simpleName = simpleNameFromFqn(r.namespace, r.className)
  val sName = internString(sh, simpleName)
  val sNs = internString(sh, r.namespace)

  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Single public initonly field named `value`.
  val fSig = buildFieldSigWithCtx(r.inner, ctx)
  val bFSig = internBlob(bh, "range_val_" + r.className, fSig)
  addField(t, FieldRow(flags = FDA_PUBLIC + FDA_INIT_ONLY, name = internString(sh, "value"), signature = bFSig))

  // Exception and ArgumentOutOfRangeException TypeRefs for bounds-check throws.
  val trExc = ctxAddTypeRef(ctx, "System", "ArgumentOutOfRangeException", ctx.arRuntime)
  val excCtorPs: List[MsilType] = newList()
  excCtorPs.add(MString)
  val excCtorSig = buildInstanceMethodSig(excCtorPs, MVoid)
  val mrExcCtor = 0x0A000000 + ctxAddMemberRef(ctx, trExc, ".ctor", "range_exc_ctor", excCtorSig)

  // Build .ctor(value: inner) body:
  //   ldarg.0; call Object..ctor()
  //   ldarg.1; ldc <minVal>; clt; brfalse skip_min
  //   ldstr msg; newobj Exc..ctor; throw
  //   skip_min: ldarg.1; ldc <maxVal>; cgt; brfalse skip_max
  //   ldstr msg; newobj Exc..ctor; throw
  //   skip_max: ldarg.0; ldarg.1; stfld value; ret
  val ctorParams: List[MsilType] = newList()
  ctorParams.add(r.inner)
  val ctorSig = buildInstanceMethodSigWithCtx(ctorParams, MVoid, ctx)
  val bCtorSig = internBlob(bh, "range_ctor_" + r.className, ctorSig)

  val mbCtor = newMethodBody()
  mbCtor.maxStack = 3
  emitLdarg_0(mbCtor)
  emitCall(mbCtor, 0x0A000000 + ctx.mrObjectCtor)

  // minVal check: if value < minVal → throw
  val skipMinL = mbNewLabel(mbCtor)
  emitLdarg(mbCtor, 1)
  match r.inner {
    case MInt -> emitLdc_I4(mbCtor, longToInt(r.minVal))
    case _ -> emitLdc_I8(mbCtor, r.minVal)
  }
  emitClt(mbCtor)
  emitBrfalse(mbCtor, skipMinL)
  val minMsg = ctxInternUs(ctx, "Value is below minimum " + r.minVal.toString() + " for type " + r.className)
  emitLdstr(mbCtor, minMsg)
  emitNewobj(mbCtor, mrExcCtor)
  emitThrow(mbCtor)
  mbMarkLabel(mbCtor, skipMinL)

  // maxVal check: if value > maxVal → throw
  val skipMaxL = mbNewLabel(mbCtor)
  emitLdarg(mbCtor, 1)
  match r.inner {
    case MInt -> emitLdc_I4(mbCtor, longToInt(r.maxVal))
    case _ -> emitLdc_I8(mbCtor, r.maxVal)
  }
  emitCgt(mbCtor)
  emitBrfalse(mbCtor, skipMaxL)
  val maxMsg = ctxInternUs(ctx, "Value is above maximum " + r.maxVal.toString() + " for type " + r.className)
  emitLdstr(mbCtor, maxMsg)
  emitNewobj(mbCtor, mrExcCtor)
  emitThrow(mbCtor)
  mbMarkLabel(mbCtor, skipMaxL)

  // Store value into field and return.
  emitLdarg_0(mbCtor)
  emitLdarg(mbCtor, 1)
  emitStfld(mbCtor, 0x04000000 + firstField)
  emitRet(mbCtor)
  ctx.bodies.add(mbCtor)

  val rvas = methodBodyRvas(ctx.bodies)
  val ctorRva = rvas[ctx.bodies.count - 1]
  val sCtor = internString(sh, ".ctor")
  val firstParam = t.params_.count + 1
  addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
  addMethodDef(
    t,
    MethodDefRow(
      rva = ctorRva,
      implFlags = 0,
      flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
      name = sCtor,
      signature = bCtorSig,
      paramList = firstParam
    )
  )

  val typeRow = addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_SEALED + TDF_SEQUENTIAL_LAYOUT + TDF_BEFORE_FIELD_INIT,
      typeName = sName,
      typeNamespace = sNs,
      extends = objectTypeToken(ctx),
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  recordUserTypeDefRow(ctx, r.namespace, simpleName, typeRow)
  typeRow
}

// ── Enum lowering ─────────────────────────────────────────────────────────────
// Lower an MEnum to a CLR enum TypeDef.
// Produces: TypeDef extends System.Enum, one `value__` field (I4), one static literal
// field per case, and one Constant row per case in the Constant table.
pub func lowerMEnum(e: in MEnum, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables

  // TypeDef stores the simple name; the CLR loader resolves by
  // (namespace, simpleName).  Interning the full FQN here produced a
  // doubled display name (`Std.Log` + `Std.Log.LogLevel`) that no
  // consumer TypeRef could resolve (#3196).
  val sName = internString(sh, simpleNameFromFqn(e.namespace, e.className))
  val sNs = internString(sh, e.namespace)

  // Allocate TypeDef row first (field list starts right after current fields).
  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit `value__` special field (I4, Private, SpecialName, RTSpecialName).
  val sValueDunder = internString(sh, "value__")
  val i4Sig = buildFieldSig(MInt)
  val bI4Sig = internBlob(bh, "field_i4_sig", i4Sig)
  addField(
    t,
    FieldRow(flags = FDA_PRIVATE + FDA_SPECIAL_NAME + FDA_RT_SPECIAL_NAME, name = sValueDunder, signature = bI4Sig)
  )

  // Emit one static literal field per case + a Constant row for its ordinal value.
  // The enum's own TypeDef is appended at the end of this function via
  // `addTypeDef`, so its row number will be `t.typeDefs.count + 1`
  // (1-based row indices, current count snapshot taken before append).
  val enumTypeDefRow = t.typeDefs.count + 1

  var ci = 0
  while ci < e.cases.count {
    val sCase = internString(sh, e.cases[ci])
    // Case field type = VALUETYPE <this enum TypeDef>.
    // TypeDefOrRef coded-index for a TypeDef: tdrTypeDef(row) = row * 4.
    val enumTdr = tdrTypeDef(enumTypeDefRow)
    val caseSig = buildValueTypeFieldSig(enumTdr)
    val bCaseSig = internBlob(bh, "enum_case_" + e.className + "_" + e.cases[ci], caseSig)
    val caseFieldRow = addField(
      t,
      FieldRow(
        flags = FDA_PUBLIC + FDA_STATIC + FDA_LITERAL + FDA_HAS_DEFAULT,
        name = sCase,
        signature = bCaseSig
      )
    )
    // Constant row: ELEMENT_TYPE_I4 (0x08), parent = hconstField(caseFieldRow).
    val constBlob = buildI4ConstantBlob(ci)
    val bConst = internBlob(bh, "const_" + e.className + "_" + e.cases[ci], constBlob)
    addConstant(
      t,
      ConstantRow(
        type_ = 0x08,
        // ELEMENT_TYPE_I4
        parent = hconstField(caseFieldRow),
        value = bConst
      )
    )
    ci = ci + 1
  }

  // Emit the TypeDef itself — must extend System.Enum.
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_SEALED,
      typeName = sName,
      typeNamespace = sNs,
      extends = enumTypeToken(ctx),
      fieldList = firstField,
      methodList = firstMethod
    )
  )
}

// ── Interface lowering ────────────────────────────────────────────────────────
// Lower an MInterface to a CLR interface TypeDef with abstract method headers.
pub func lowerMInterface(iface: in MInterface, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables

  val simpleNameIface = simpleNameFromFqn(iface.namespace, iface.className)
  val sName = internString(sh, simpleNameIface)
  val sNs = internString(sh, iface.namespace)

  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Pass 1 (#2962): lower and accumulate every DIM body first, recording each
  // member's body index.  `methodBodyRvas` re-serializes ALL accumulated
  // bodies per call, so calling it inside the member loop was O(n·k); one
  // call after the loop is O(n+k).  Earlier bodies' RVAs are stable across
  // later additions (sequential layout from a fixed base), so the single
  // post-loop call yields the same RVAs the per-member calls did.
  val dimBodyIdx: List[Int] = newList()
  var hasDim = false
  var mi = 0
  while mi < iface.members.count {
    match iface.members[mi] {
      case MIAbstract(_) -> dimBodyIdx.add(-1)
      case MIDim(dm) -> {
        ctx.bodies.add(lowerMFunc(dm, ctx))
        dimBodyIdx.add(ctx.bodies.count - 1)
        hasDim = true
      }
    }
    mi = mi + 1
  }
  val dimRvas: List[Int] = if hasDim { methodBodyRvas(ctx.bodies) } else { newList() }

  // Pass 2: emit one MethodDef per member in declaration order so token
  // numbers agree with the addPackageTokens pre-pass (which also walks
  // members in order).  Abstract slots (MIAbstract) get RVA=0 and the
  // Abstract flag; DIM slots (MIDim) get their pass-1 body's RVA and no
  // Abstract flag.
  mi = 0
  while mi < iface.members.count {
    match iface.members[mi] {
      case MIAbstract(m) -> {
        val sN = internString(sh, m.name)
        val mSig = buildInstanceMethodSigWithCtx(m.params, m.ret, ctx)
        // Arity-qualify the intern key (#1536) — see the `meth_` site above.
        val bSig = internBlob(bh, "ifmeth_" + iface.className + "_" + m.name + "/" + toString(m.params.count), mSig)
        val fp = t.params_.count + 1
        addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
        addMethodDef(
          t,
          MethodDefRow(
            rva = 0,
            implFlags = 0,
            flags = MDA_PUBLIC + MDA_ABSTRACT + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_NEW_SLOT,
            name = sN,
            signature = bSig,
            paramList = fp
          )
        )
      }
      case MIDim(dm) -> {
        val dmRva = dimRvas[dimBodyIdx[mi]]
        val sNDm = internString(sh, dm.name)
        val dmSig = buildInstanceMethodSigWithCtx(dm.params, dm.ret, ctx)
        val bDmSig = internBlob(bh, "ifdmeth_" + iface.className + "_" + dm.name + "/" + toString(dm.params.count), dmSig)
        val fpDm = t.params_.count + 1
        addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
        addMethodDef(
          t,
          MethodDefRow(
            rva = dmRva,
            implFlags = 0,
            flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_NEW_SLOT,
            name = sNDm,
            signature = bDmSig,
            paramList = fpDm
          )
        )
      }
    }
    mi = mi + 1
  }

  // TypeDef flags for a CLR interface: Interface | Abstract | Public.
  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_INTERFACE + TDF_ABSTRACT + TDF_PUBLIC,
      typeName = sName,
      typeNamespace = sNs,
      extends = 0,
      // interfaces have no extends
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  val ifaceTypeDefRow = t.typeDefs.count
  recordUserTypeDefRow(ctx, iface.namespace, simpleNameIface, ifaceTypeDefRow)
  ifaceTypeDefRow
}

// ── Impl lowering ─────────────────────────────────────────────────────────────
// Find the 1-based TypeDef row whose (namespace, name) matches the given
// fully-qualified type name.  Returns 0 if no such TypeDef exists.
// Uses #Strings heap interning — both `internString` calls are idempotent so
// they do not pollute the heap.
pub func findTypeDefRowByName(ctx: in LoweringCtx, fqn: in String): Int {
  // lowerMRecord stores the SIMPLE name in typeName and the namespace in
  // typeNamespace (e.g. "EnglishGreeter"/"ShMIface" for "ShMIface.EnglishGreeter").
  // It derives the simple name by stripping the namespace prefix, so a
  // compiler-generated simple name may itself contain dots inside angle
  // brackets — e.g. an async state machine for a *type-method*:
  // `Std.Http.<HttpResponse.bodyText>__SM_3` (simple name
  // `<HttpResponse.bodyText>__SM_3`, namespace `Std.Http`).  A naive
  // last-dot split would land inside the brackets and never match.
  // Namespaces never contain `<`, so only consider dots BEFORE the first
  // `<` when locating the namespace/simple-name boundary.
  val boundary = nsBoundaryLimit(fqn)
  var lastDot = -1
  var di = 0
  while di < boundary {
    if fqn[di] == '.' {
      lastDot = di
    }
    di = di + 1
  }
  val ns = if lastDot < 0 { "" } else { fqn.substring(0, lastDot) }
  val simpleName = if lastDot < 0 { fqn } else { fqn.substring(lastDot + 1, fqn.length - lastDot - 1) }
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
  // Arity-suffix fallback: a generic type's TypeDef carries a `` `N `` suffix
  // (`Option`1`), but callers pass the plain dotted name (codegen maps are keyed
  // plainly via `stripGenericArity`).  Probe the suffixed forms so a plain-name
  // lookup still resolves the generic TypeDef.  Read-only `mapGet`.
  var defArity = 1
  while defArity <= 9 {
    match mapGet(ctx.strings.entries, simpleName + "`" + toString(defArity)) {
      case Some(suffOff) -> {
        var dj = 0
        while dj < t.typeDefs.count {
          val td2 = t.typeDefs[dj]
          if td2.typeNamespace == sNs and td2.typeName == suffOff {
            return dj + 1
          }
          dj = dj + 1
        }
      }
      case None -> ()
    }
    defArity = defArity + 1
  }
  0
}

// The index of the first `<` in `fqn`, or its length when none is present.
// Dots at or after this index belong to a bracketed (compiler-generated)
// simple name, not the namespace, so namespace/simple-name splitting must
// ignore them.  See `findTypeDefRowByName`.
func nsBoundaryLimit(fqn: in String): Int {
  var i = 0
  while i < fqn.length {
    if fqn[i] == '<' {
      return i
    }
    i = i + 1
  }
  fqn.length
}

// Find the 1-based TypeRef row whose namespace + name match the given FQN.
// Mirrors `findTypeDefRowByName` but searches the TypeRef table instead of
// TypeDef.  Used by `MIsinstByName` as a fallback when the type is defined in
// a foreign assembly (TypeRef) rather than the current module (TypeDef) — e.g.
// union case classes like `Std.Core.Option$Some` imported from `Lyric.Stdlib.Core`.
// Returns 0 when no matching TypeRef exists.
pub func findTypeRefRowByName(ctx: in LoweringCtx, fqn: in String): Int {
  // Same bracketed-simple-name handling as `findTypeDefRowByName`: only
  // dots before the first `<` delimit the namespace.
  val boundary = nsBoundaryLimit(fqn)
  var lastDot = -1
  var di = 0
  while di < boundary {
    if fqn[di] == '.' {
      lastDot = di
    }
    di = di + 1
  }
  val ns = if lastDot < 0 { "" } else { fqn.substring(0, lastDot) }
  val simpleName = if lastDot < 0 { fqn } else { fqn.substring(lastDot + 1, fqn.length - lastDot - 1) }
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
  // Arity-suffix fallback (see `findTypeDefRowByName`): a cross-package generic
  // type's TypeRef carries a `` `N `` suffix (`Option_Some`1`), but
  // `MIsinstByName` / `MCastclassByName` / `MIsinstGeneric` pass the plain
  // dotted case name.  Without this the lookup misses, the caller degrades to
  // System.Object, and `isinst` unconditionally succeeds — breaking match
  // dispatch on cross-package generic unions.  Read-only `mapGet`.
  var refArity = 1
  while refArity <= 9 {
    match mapGet(ctx.strings.entries, simpleName + "`" + toString(refArity)) {
      case Some(suffOff) -> {
        var rj = 0
        while rj < t.typeRefs.count {
          val tr2 = t.typeRefs[rj]
          if tr2.typeNamespace == sNs and tr2.typeName == suffOff {
            return rj + 1
          }
          rj = rj + 1
        }
      }
      case None -> ()
    }
    refArity = refArity + 1
  }
  0
}

// Reconstruct a TypeDef's fully-qualified name from its (namespace, simpleName)
// the same way `findTypeDefRowByName` splits one — so a name recorded here is
// looked up by the identical key.
func joinTypeFqn(namespace: in String, simpleName: in String): String {
  if namespace.length == 0 {
    simpleName
  } else {
    namespace + "." + simpleName
  }
}

// Register an in-bundle TypeDef's FQN → row mapping (epic #2359 Stage 1).
// Idempotent: a second registration of the same FQN (e.g. the real pass after
// the discovery pass already seeded it) is ignored.  `simpleName` is the
// unqualified type name as stored in the TypeDef row; `namespace` its namespace.
pub func recordUserTypeDefRow(ctx: in LoweringCtx, namespace: in String, simpleName: in String, row: in Int): Unit {
  val fqn = joinTypeFqn(namespace, simpleName)
  if not ctx.typeDefRowByFqn.containsKey(fqn) {
    ctx.typeDefRowByFqn.add(fqn, row)
    ctx.typeDefRowFqns.add(fqn)
  }
}

// Resolve an in-bundle type's TypeDef row for SIGNATURE encoding.  Consults the
// pre-populated registry first (so a forward reference resolves) and falls back
// to scanning the table (covers any TypeDef added without registration).
// Returns 0 when the name is not an in-bundle TypeDef.  Interface types resolve
// to their TypeDef like any other reference type — `ELEMENT_TYPE_CLASS` over an
// interface is valid ECMA-335 (interfaces are reference types); the F# emitter
// is being updated to match this (epic #2359 Stage 1).
pub func resolveSigTypeDefRow(ctx: in LoweringCtx, fqn: in String): Int {
  match mapGet(ctx.typeDefRowByFqn, fqn) {
    case Some(row) -> row
    case None -> findTypeDefRowByName(ctx, fqn)
  }
}

// Discovery pass (epic #2359 Stage 1): lower every item of every package into a
// throwaway context purely to learn each in-bundle type's TypeDef row, then
// copy that registry into the real context `dst` BEFORE the real lowering runs.
// Because user TypeDefs are the only TypeDef rows besides `<Module>` (row 1) —
// BCL / stdlib / restored types are TypeRefs — the throwaway pass assigns
// identical row numbers regardless of the real context's pre-seeded
// TypeRef / MemberRef / AssemblyRef rows.
pub func discoverTypeDefRowsInto(dst: in LoweringCtx, pkgs: in List[MPackage], hasResultOk: Bool): Unit {
  val dctx = newLoweringCtx("__lyric_typedef_discovery__", 0, 0)
  dctx.discovering.add(true)
  // Pre-scan: collect ALL @projectable type FQNs from all packages before processing
  // any items.  This makes hasNestedProjField in lowerMOpaque declaration-order-
  // independent: both the discover and the real pass see the same complete set.
  var psi = 0
  while psi < pkgs.count {
    val pspkg = pkgs[psi]
    var psj = 0
    while psj < pspkg.items.count {
      match pspkg.items[psj] {
        case MPOpaque(op) -> {
          if op.isProjectable and not dctx.allProjFqns.containsKey(op.className) {
            dctx.allProjFqns.add(op.className, true)
            dctx.allProjFqnKeys.add(op.className)
          }
        }
        case _ -> ()
      }
      psj = psj + 1
    }
    psi = psi + 1
  }
  // Mirror the real context's stdCoreResultOk2Row so canEmitTryInto agrees
  // between discover and real passes: if the caller's context has Result_Ok seeded,
  // so should the discover context.
  if hasResultOk and dctx.stdCoreResultOk2Row.count == 0 {
    dctx.stdCoreResultOk2Row.add(1)
  }
  // Mirror Result_Err too so a range subtype's `tryFrom` row budget (#1501)
  // agrees between the discover and real passes.  Ok and Err are registered
  // together (both Result cases), so `hasResultOk` gates both.
  if hasResultOk and dctx.stdCoreResultErr2Row.count == 0 {
    dctx.stdCoreResultErr2Row.add(1)
  }
  if hasResultOk and dctx.stdCoreResultRow.count == 0 {
    dctx.stdCoreResultRow.add(1)
  }
  var pi = 0
  while pi < pkgs.count {
    val pkg = pkgs[pi]
    var i = 0
    while i < pkg.items.count {
      match pkg.items[i] {
        // MPImpl adds no TypeDef rows (only InterfaceImpl / MethodImpl rows and
        // method bodies), and `lowerMImpl` resolves the impl's interface type —
        // which for a BCL interface (e.g. async state machines implementing
        // `System.Runtime.CompilerServices.IAsyncStateMachine`) lives only in
        // the pre-seeded real context, not this fresh discovery context, so
        // processing it here would panic.  Skipping it is safe: it cannot shift
        // any TypeDef row number that the real pass will assign.
        case MPImpl(_) -> {
        }
        case other -> lowerMPackageItem(other, dctx)
      }
      i = i + 1
    }
    pi = pi + 1
  }
  var k = 0
  while k < dctx.typeDefRowFqns.count {
    val fqn = dctx.typeDefRowFqns[k]
    match mapGet(dctx.typeDefRowByFqn, fqn) {
      case Some(row) -> {
        if not dst.typeDefRowByFqn.containsKey(fqn) {
          dst.typeDefRowByFqn.add(fqn, row)
          dst.typeDefRowFqns.add(fqn)
        }
      }
      case None -> {
      }
    }
    k = k + 1
  }
  // Copy projectable MethodDef rows so the real pass can use them as
  // forward references (A.toView() may call B.toView() even when B's
  // TypeDef is emitted after A's — the pre-computed row is valid because
  // the discovery and real passes process items in the same order).
  var pk = 0
  while pk < dctx.projectableToViewMDefKeys.count {
    val fqn2 = dctx.projectableToViewMDefKeys[pk]
    match mapGet(dctx.projectableToViewMDef, fqn2) {
      case Some(row) -> {
        if not dst.projectableToViewMDef.containsKey(fqn2) {
          dst.projectableToViewMDef.add(fqn2, row)
          dst.projectableToViewMDefKeys.add(fqn2)
        }
      }
      case None -> ()
    }
    pk = pk + 1
  }
  var ck = 0
  while ck < dctx.projectableCtorMDefKeys.count {
    val fqn3 = dctx.projectableCtorMDefKeys[ck]
    match mapGet(dctx.projectableCtorMDef, fqn3) {
      case Some(row) -> {
        if not dst.projectableCtorMDef.containsKey(fqn3) {
          dst.projectableCtorMDef.add(fqn3, row)
          dst.projectableCtorMDefKeys.add(fqn3)
        }
      }
      case None -> ()
    }
    ck = ck + 1
  }
  // Copy the declaration-order-independent allProjFqns set to the real context.
  var apk = 0
  while apk < dctx.allProjFqnKeys.count {
    val apfqn = dctx.allProjFqnKeys[apk]
    if not dst.allProjFqns.containsKey(apfqn) {
      dst.allProjFqns.add(apfqn, true)
      dst.allProjFqnKeys.add(apfqn)
    }
    apk = apk + 1
  }
}

// Build (and cache) the concrete `List`1<elemTy>` operation tokens (epic #2359
// Stage 2).  Deferred to lowering time so an in-bundle `MClass` element type
// resolves to its TypeDef row via `buildGenericInstBlobWithCtx`.  Member sigs
// use `!0` (`MTypeVar(0)`), identical across instantiations.
pub func listTokensForLowering(ctx: in LoweringCtx, elemTy: in MsilType): ListTokens {
  val key = msilTypeKey(elemTy)
  match mapGet(ctx.listTokenCache, key) {
    case Some(t) -> return t
    case None -> ()
  }
  val trList1 = findTypeRefRowByName(ctx, "System.Collections.Generic.List`1")
  if trList1 <= 0 {
    // The open `List`1` TypeRef is seeded for every assembly; a missing row
    // here would produce a malformed TypeSpec blob the CLR rejects at load.
    panic("Msil.Lowering.listTokensForLowering: System.Collections.Generic.List`1 TypeRef not seeded")
  }
  val argTys: List[MsilType] = newList()
  argTys.add(elemTy)
  val tsRow = ctxAddTypeSpec(ctx, "ts_list_" + key, buildGenericInstBlobWithCtx(ctx, tdrTypeRef(trList1), argTys))
  val ctorP: List[MsilType] = newList()
  val ctorTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      ".ctor",
      "list_ctor_" + key,
      buildInstanceMethodSig(ctorP, MVoid)
    )
  val addP: List[MsilType] = newList()
  addP.add(MTypeVar(0))
  val addTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(ctx, tsRow, "Add", "list_add_" + key, buildInstanceMethodSig(addP, MVoid))
  val getP: List[MsilType] = newList()
  getP.add(MInt)
  val getTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "get_Item",
      "list_get_" + key,
      buildInstanceMethodSig(getP, MTypeVar(0))
    )
  val setP: List[MsilType] = newList()
  setP.add(MInt)
  setP.add(MTypeVar(0))
  val setTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "set_Item",
      "list_set_" + key,
      buildInstanceMethodSig(setP, MVoid)
    )
  val cntP: List[MsilType] = newList()
  val cntTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "get_Count",
      "list_cnt_" + key,
      buildInstanceMethodSig(cntP, MInt)
    )
  val cnsP: List[MsilType] = newList()
  cnsP.add(MTypeVar(0))
  val cnsTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "Contains",
      "list_cns_" + key,
      buildInstanceMethodSig(cnsP, MBool)
    )
  val rmP: List[MsilType] = newList()
  rmP.add(MInt)
  val rmTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(ctx, tsRow, "RemoveAt", "list_rm_" + key, buildInstanceMethodSig(rmP, MVoid))
  // `instance !0[] ToArray()` — materialises a genuine CLR array from the list,
  // used to bridge a List-backed value into an array-typed boundary (#2592).
  val taP: List[MsilType] = newList()
  val taTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "ToArray",
      "list_toarr_" + key,
      buildInstanceMethodSig(taP, MArray(elemTy = MTypeVar(index = 0)))
    )
  val t = ListTokens(
    typeSpec = 0x1B000000 + tsRow,
    ctor = ctorTok,
    add = addTok,
    getItem = getTok,
    setItem = setTok,
    getCount = cntTok,
    contains = cnsTok,
    removeAt = rmTok,
    toArray = taTok
  )
  ctx.listTokenCache.add(key, t)
  t
}

// Build (and cache) the concrete `Dictionary`2<keyTy,valTy>` operation tokens.
pub func dictTokensForLowering(ctx: in LoweringCtx, keyTy: in MsilType, valTy: in MsilType): DictTokens {
  // `|` separates key/value: `msilTypeKey` emits commas (generics, maps) but
  // never a pipe, and CLR FQNs contain no pipe — so this cannot collide.
  val key = msilTypeKey(keyTy) + "|" + msilTypeKey(valTy)
  match mapGet(ctx.dictTokenCache, key) {
    case Some(t) -> return t
    case None -> ()
  }
  val trDict2 = findTypeRefRowByName(ctx, "System.Collections.Generic.Dictionary`2")
  if trDict2 <= 0 {
    panic("Msil.Lowering.dictTokensForLowering: System.Collections.Generic.Dictionary`2 TypeRef not seeded")
  }
  val argTys: List[MsilType] = newList()
  argTys.add(keyTy)
  argTys.add(valTy)
  val tsRow = ctxAddTypeSpec(ctx, "ts_dict_" + key, buildGenericInstBlobWithCtx(ctx, tdrTypeRef(trDict2), argTys))
  val ctorP: List[MsilType] = newList()
  val ctorTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      ".ctor",
      "dict_ctor_" + key,
      buildInstanceMethodSig(ctorP, MVoid)
    )
  val addP: List[MsilType] = newList()
  addP.add(MTypeVar(0))
  addP.add(MTypeVar(1))
  val addTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(ctx, tsRow, "Add", "dict_add_" + key, buildInstanceMethodSig(addP, MVoid))
  val getP: List[MsilType] = newList()
  getP.add(MTypeVar(0))
  val getTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "get_Item",
      "dict_get_" + key,
      buildInstanceMethodSig(getP, MTypeVar(1))
    )
  val setP: List[MsilType] = newList()
  setP.add(MTypeVar(0))
  setP.add(MTypeVar(1))
  val setTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "set_Item",
      "dict_set_" + key,
      buildInstanceMethodSig(setP, MVoid)
    )
  val cntP: List[MsilType] = newList()
  val cntTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "get_Count",
      "dict_cnt_" + key,
      buildInstanceMethodSig(cntP, MInt)
    )
  val ckP: List[MsilType] = newList()
  ckP.add(MTypeVar(0))
  val ckTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "ContainsKey",
      "dict_ck_" + key,
      buildInstanceMethodSig(ckP, MBool)
    )
  val rmP: List[MsilType] = newList()
  rmP.add(MTypeVar(0))
  val rmTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(ctx, tsRow, "Remove", "dict_rm_" + key, buildInstanceMethodSig(rmP, MBool))
  // TryGetValue(!0, !1&) -> bool: out-param is ByRef so one hash lookup atomically returns presence + value (#2474).
  val tgvP: List[MsilType] = newList()
  tgvP.add(MTypeVar(0))
  tgvP.add(MByRef(inner = MTypeVar(1)))
  val tgvTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "TryGetValue",
      "dict_tgv_" + key,
      buildInstanceMethodSig(tgvP, MBool)
    )
  // Add nested TypeRefs for Dictionary`2+KeyCollection and Dictionary`2+ValueCollection.
  // ResolutionScope points to the enclosing Dictionary`2 TypeRef (ECMA-335 §22.38).
  val trKeyCol = ctxAddNestedTypeRef(ctx, trDict2, "KeyCollection")
  val trValCol = ctxAddNestedTypeRef(ctx, trDict2, "ValueCollection")
  // get_Keys() -> Dictionary`2+KeyCollection<!0,!1>
  val gkRetArgs: List[MsilType] = newList()
  gkRetArgs.add(MTypeVar(0))
  gkRetArgs.add(MTypeVar(1))
  val gkRetTy = MGenericInst(typeRefCode = tdrTypeRef(trKeyCol), headFqn = "KeyCollection", typeArgs = gkRetArgs)
  val gkP: List[MsilType] = newList()
  val gkTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "get_Keys",
      "dict_gk_" + key,
      buildInstanceMethodSig(gkP, gkRetTy)
    )
  // get_Values() -> Dictionary`2+ValueCollection<!0,!1>
  val gvRetArgs: List[MsilType] = newList()
  gvRetArgs.add(MTypeVar(0))
  gvRetArgs.add(MTypeVar(1))
  val gvRetTy = MGenericInst(typeRefCode = tdrTypeRef(trValCol), headFqn = "ValueCollection", typeArgs = gvRetArgs)
  val gvP: List[MsilType] = newList()
  val gvTok = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      ctx,
      tsRow,
      "get_Values",
      "dict_gv_" + key,
      buildInstanceMethodSig(gvP, gvRetTy)
    )
  val t = DictTokens(
    typeSpec = 0x1B000000 + tsRow,
    ctor = ctorTok,
    add = addTok,
    getItem = getTok,
    setItem = setTok,
    getCount = cntTok,
    containsKey = ckTok,
    remove = rmTok,
    tryGetValue = tgvTok,
    getKeys = gkTok,
    getValues = gvTok
  )
  ctx.dictTokenCache.add(key, t)
  t
}

// Find the 1-based MethodDef row owned by typeDefRow with the given method
// name.  The methods owned by a TypeDef are the contiguous range
// [td.methodList, nextTd.methodList) in the MethodDef table — the last
// TypeDef owns through the end of the table.  Returns 0 if not found.
pub func findMethodDefRowOfType(ctx: in LoweringCtx, typeDefRow: in Int, methodName: in String): Int {
  val t = ctx.tables
  if typeDefRow < 1 or typeDefRow > t.typeDefs.count {
    return 0
  }
  val sName = internString(ctx.strings, methodName)
  val td = t.typeDefs[typeDefRow - 1]
  val first = td.methodList
  val last = if typeDefRow == t.typeDefs.count { t.methodDefs.count + 1 } else { t.typeDefs[typeDefRow].methodList }
  var i = first
  while i < last {
    if t.methodDefs[i - 1].name == sName {
      return i
    }
    i = i + 1
  }
  0
}

// Find the 1-based FieldDef row owned by typeDefRow with the given field name.
// Fields owned by a TypeDef are the contiguous range
// [td.fieldList, nextTd.fieldList) — the last TypeDef owns through the end.
// Returns 0 if not found.
pub func findFieldDefRowOfType(ctx: in LoweringCtx, typeDefRow: in Int, fieldName: in String): Int {
  val t = ctx.tables
  if typeDefRow < 1 or typeDefRow > t.typeDefs.count {
    return 0
  }
  val sName = internString(ctx.strings, fieldName)
  val td = t.typeDefs[typeDefRow - 1]
  val first = td.fieldList
  val last = if typeDefRow == t.typeDefs.count { t.fields.count + 1 } else { t.typeDefs[typeDefRow].fieldList }
  var i = first
  while i < last {
    if t.fields[i - 1].name == sName {
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
  val targetRow = if d.targetTypeDefRow > 0 { d.targetTypeDefRow } else { findTypeDefRowByName(ctx, d.targetTypeName) }
  if targetRow == 0 {
    panic("Msil.Lowering: MPImpl target type '" + d.targetTypeName + "' has no TypeDef row")
  }
  val ifaceToken = if d.ifaceTypeToken > 0 {
    d.ifaceTypeToken
  } else {
    val ifaceDefRow = findTypeDefRowByName(ctx, d.ifaceTypeName)
    if ifaceDefRow > 0 {
      tdrTypeDef(ifaceDefRow)
    } else {
      val ifaceRefRow = findTypeRefRowByName(ctx, d.ifaceTypeName)
      if ifaceRefRow == 0 {
        panic("Msil.Lowering: MPImpl interface type '" + d.ifaceTypeName + "' has no TypeDef or TypeRef row")
      }
      tdrTypeRef(ifaceRefRow)
    }
  }
  // InterfaceImpl row: records that targetRow implements ifaceToken.
  addInterfaceImpl(t, InterfaceImplRow(class_ = targetRow, interface_ = ifaceToken))
  // For TypeSpec-instantiated generic interfaces (tag = 2), the CLR cannot
  // resolve implementations via name matching alone — explicit MethodImpl rows
  // are required.  When a slot carries a pre-resolved ifaceMethodToken (the raw
  // MemberRef row of the interface method), emit a MethodImpl row that wires
  // the implementation MethodDef to the interface slot's MemberRef.
  if (ifaceToken % 4) == 2 {
    var si = 0
    while si < d.slots.count {
      val slot = d.slots[si]
      if slot.ifaceMethodToken > 0 {
        val implRow = findMethodDefRowOfType(ctx, targetRow, slot.implMethodName)
        if implRow > 0 {
          addMethodImpl(
            t,
            MethodImplRow(
              class_ = targetRow,
              methodBody = mdorMethodDef(implRow),
              methodDeclaration = mdorMemberRef(slot.ifaceMethodToken)
            )
          )
        }
      }
      si = si + 1
    }
  }
  0
}

// ── Opaque type lowering ──────────────────────────────────────────────────────
// Lower an MOpaque to a sealed TypeDef with private storage fields.
// When isProjectable=true, also emits a sibling `<Name>View` TypeDef with
// public fields, a `.ctor`, an optional `tryInto()` method, and a `toView()`
// instance method on the opaque itself — mirroring the F# emitter M2.0–M2.2
// four-pass approach (Pass A: view stub, Pass B: view fields/ctor, Pass C:
// toView IL, Pass D: tryInto).
//
// Multi-pass ordering: the view TypeDef is emitted BEFORE the opaque TypeDef
// so that `toView()` on the opaque can reference the view's `.ctor` MethodDef
// (forward references into later TypeDefs are valid in ECMA-335 metadata).
// The `toView()` method may call a sibling projectable's `toView()` even when
// that sibling is lowered later; the MethodDef row is pre-computed from the
// discovery pass and copied by `discoverTypeDefRowsInto`.
// SYNC-POINT: addPackageTokens in codegen.l (IOpaque handler, ~line 2048) pre-allocates
// MethodDef row numbers by mirroring this function's emission order exactly.  Any change
// to the Phase 1 / Phase 2 method sequence here MUST be mirrored there (#3046).
pub func lowerMOpaque(op: in MOpaque, ctx: in LoweringCtx): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables
  val isDiscover = ctx.discovering.count > 0

  val simpleNameOpaque = simpleNameFromFqn(op.namespace, op.className)
  val sName = internString(sh, simpleNameOpaque)
  val sNs = internString(sh, op.namespace)

  if op.isProjectable {
    // ── Phase 1: emit <Name>View TypeDef (view twin) ─────────────────────────
    val viewSimpleName = simpleNameOpaque + "View"
    val viewFqn = op.className + "View"
    val sViewName = internString(sh, viewSimpleName)

    // Build the list of visible (non-@hidden) field indices and their view types.
    // A view field's type substitutes the source type with the sibling view type
    // when the source is also projectable — unless @projectionBoundary blocks it.
    val viewFieldIdxs: List[Int] = newList()
    val viewFieldTypes: List[MsilType] = newList()
    var fvi = 0
    while fvi < op.fields.count {
      if op.visibleFieldMask[fvi] {
        viewFieldIdxs.add(fvi)
        val srcTy = op.fields[fvi].fieldType
        val vTy = if op.projBoundaryMask[fvi] {
          srcTy
        } else {
          match srcTy {
            case MClass(srcFqn) -> {
              if ctx.projectableToViewMDef.containsKey(srcFqn) {
                MClass(className = srcFqn + "View")
              } else {
                srcTy
              }
            }
            case _ -> srcTy
          }
        }
        viewFieldTypes.add(vTy)
      }
      fvi = fvi + 1
    }

    // Whether tryInto() can be emitted:
    //   - stdlib Result_Ok TypeRef must be available
    //   - no visible field is of a nested projectable type (those need monadic bind)
    //   - no fields are @hidden (suppresses round-trip reconstruction)
    // hasNestedProjField uses ctx.allProjFqns (pre-populated before any lowering
    // starts) so both the discover and real passes see the same complete set,
    // regardless of declaration order.
    val hasHiddenFields = viewFieldIdxs.count < op.fields.count
    var hasNestedProjField = false
    var vfti = 0
    while vfti < viewFieldIdxs.count {
      val origIdx = viewFieldIdxs[vfti]
      if not op.projBoundaryMask[origIdx] {
        match op.fields[origIdx].fieldType {
          case MClass(srcFqn) -> {
            if ctx.allProjFqns.containsKey(srcFqn) {
              hasNestedProjField = true
            }
          }
          case _ -> ()
        }
      }
      vfti = vfti + 1
    }
    // Both discover and real passes use the same condition: stdCoreResultOk2Row
    // is seeded in the discover context by discoverTypeDefRowsInto when the real
    // context already has it (hasResultOk=true), so no isDiscover shortcut needed.
    val canEmitTryInto = ctx.stdCoreResultOk2Row.count > 0 and not hasNestedProjField and not hasHiddenFields

    // View TypeDef: field and method ranges.
    val firstViewField = t.fields.count + 1
    val firstViewMethod = t.methodDefs.count + 1

    // Emit public view fields.
    var vfi2 = 0
    while vfi2 < viewFieldIdxs.count {
      val origIdx2 = viewFieldIdxs[vfi2]
      val sF = internString(sh, op.fields[origIdx2].name)
      val fSig = buildFieldSigWithCtx(viewFieldTypes[vfi2], ctx)
      val bSig = internBlob(bh, "vfield_" + viewFqn + "_" + op.fields[origIdx2].name, fSig)
      addField(t, FieldRow(flags = FDA_PUBLIC, name = sF, signature = bSig))
      vfi2 = vfi2 + 1
    }

    // Emit view .ctor(fields...).
    val viewCtorPs: List[MsilType] = newList()
    var vci = 0
    while vci < viewFieldTypes.count {
      viewCtorPs.add(viewFieldTypes[vci])
      vci = vci + 1
    }
    val viewCtorSig = buildInstanceMethodSigWithCtx(viewCtorPs, MVoid, ctx)
    val bViewCtorSig = internBlob(bh, "vctor_" + viewFqn, viewCtorSig)
    val sViewCtor = internString(sh, ".ctor")

    val mbViewCtor = newMethodBody()
    if not isDiscover {
      mbViewCtor.maxStack = 2
      emitLdarg_0(mbViewCtor)
      emitCall(mbViewCtor, 0x0A000000 + ctx.mrObjectCtor)
      var vca = 0
      while vca < viewFieldIdxs.count {
        emitLdarg_0(mbViewCtor)
        emitLdarg(mbViewCtor, vca + 1)
        emitStfld(mbViewCtor, 0x04000000 + firstViewField + vca)
        vca = vca + 1
      }
      emitRet(mbViewCtor)
    }
    ctx.bodies.add(mbViewCtor)
    val rvasVCtor = methodBodyRvas(ctx.bodies)
    val viewCtorRva = rvasVCtor[ctx.bodies.count - 1]
    val fpvc = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = viewCtorRva,
        implFlags = 0,
        flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sViewCtor,
        signature = bViewCtorSig,
        paramList = fpvc
      )
    )
    val viewCtorMDefRow = t.methodDefs.count

    // Emit tryInto(): Result[OpaqueType, String] on the view (Pass D).
    // Uses the pre-computed opaque .ctor MethodDef row from the discovery pass.
    if canEmitTryInto {
      if isDiscover {
        // Discover-pass stub: emit an empty body to reserve the MethodDef row so
        // the discover and real passes assign identical row numbers to every
        // subsequent method.  Must not access stdCoreResultOk2Row[0] — the fresh
        // discover ctx has that list empty.
        val mbStub = newMethodBody()
        ctx.bodies.add(mbStub)
        val rvasStub = methodBodyRvas(ctx.bodies)
        val stubRva = rvasStub[ctx.bodies.count - 1]
        val sTryIntoD = internString(sh, "tryInto")
        val dSig = buildInstanceMethodSig(newList(), MObject)
        val bTryIntoSigD = internBlob(bh, "vtryinto_disc_" + viewFqn, dSig)
        val fptiD = t.params_.count + 1
        addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
        addMethodDef(
          t,
          MethodDefRow(
            rva = stubRva,
            implFlags = 0,
            flags = MDA_PUBLIC + MDA_HIDE_BY_SIG,
            name = sTryIntoD,
            signature = bTryIntoSigD,
            paramList = fptiD
          )
        )
      } else {
        val trResultOk2 = ctx.stdCoreResultOk2Row[0]
        match mapGet(ctx.projectableCtorMDef, op.className) {
          case Some(opaqueCtorRow) -> {
            // Build type args once — shared by signature return type and body TypeSpec.
            val tiTypeArgs: List[MsilType] = newList()
            tiTypeArgs.add(MClass(className = op.className))
            tiTypeArgs.add(MString)
            // Return type is Result_Ok<OpaqueType, String> as a GENERICINST, not MObject.
            // bufMsilTypeWithCtx encodes as 0x15 0x12 <coded-TypeRef> 2 <CLASS:OpaqueType> <STRING>.
            val tryIntoRetType = MGenericInst(
              typeRefCode = tdrTypeRef(trResultOk2),
              headFqn = "Std.Core.Result_Ok",
              typeArgs = tiTypeArgs
            )
            val tryIntoPsNone: List[MsilType] = newList()
            val tryIntoSig = buildInstanceMethodSigWithCtx(tryIntoPsNone, tryIntoRetType, ctx)
            val bTryIntoSig = internBlob(bh, "vtryinto_" + viewFqn, tryIntoSig)
            val sTryInto = internString(sh, "tryInto")

            val mbTryInto = newMethodBody()
            // Push each opaque field in .ctor order from the view's matching field.
            // All opaque fields are visible (hasHiddenFields = false at this point).
            mbTryInto.maxStack = op.fields.count + 2
            var tifi = 0
            while tifi < viewFieldIdxs.count {
              emitLdarg_0(mbTryInto)
              emitLdfld(mbTryInto, 0x04000000 + firstViewField + tifi)
              tifi = tifi + 1
            }
            // newobj the opaque using its pre-computed MethodDef (forward reference valid).
            emitNewobj(mbTryInto, 0x06000000 + opaqueCtorRow)
            // Wrap in Result_Ok<OpaqueType, String> via closed GENERICINST TypeSpec.
            val okBlob = buildGenericInstBlobWithCtx(ctx, tdrTypeRef(trResultOk2), tiTypeArgs)
            val tsOkKey = "ts_tryinto_ok_" + op.className
            val tsOkRow = ctxAddTypeSpec(ctx, tsOkKey, okBlob)
            // ctor param: MTypeVar(0) = T (the value field of Ok<T,E>)
            val tiCtorPs: List[MsilType] = newList()
            tiCtorPs.add(MTypeVar(index = 0))
            val tiCtorSig = buildInstanceMethodSig(tiCtorPs, MVoid)
            val tiMrKey = "mr_tryinto_ok_" + op.className
            val tiMrRow = ctxAddMemberRefForTypeSpec(ctx, tsOkRow, ".ctor", tiMrKey, tiCtorSig)
            emitNewobj(mbTryInto, 0x0A000000 + tiMrRow)
            emitRet(mbTryInto)

            ctx.bodies.add(mbTryInto)
            val rvasTryInto = methodBodyRvas(ctx.bodies)
            val tryIntoRva = rvasTryInto[ctx.bodies.count - 1]
            val fpti = t.params_.count + 1
            addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
            val _ = addMethodDef(
              t,
              MethodDefRow(
                rva = tryIntoRva,
                implFlags = 0,
                flags = MDA_PUBLIC + MDA_HIDE_BY_SIG,
                name = sTryInto,
                signature = bTryIntoSig,
                paramList = fpti
              )
            )
          }
          case None -> ()
        }
      }
    }

    // Emit view TypeDef row.
    val viewTypeDefRow = addTypeDef(
      t,
      TypeDefRow(
        flags = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
        typeName = sViewName,
        typeNamespace = sNs,
        extends = objectTypeToken(ctx),
        fieldList = firstViewField,
        methodList = firstViewMethod
      )
    )
    recordUserTypeDefRow(ctx, op.namespace, viewSimpleName, viewTypeDefRow)

    // ── Phase 2: emit opaque TypeDef with toView() (Passes B/C) ─────────────
    val firstOpaqueField = t.fields.count + 1
    val firstOpaqueMethod = t.methodDefs.count + 1

    // Emit private storage fields.
    var ofi = 0
    while ofi < op.fields.count {
      val f = op.fields[ofi]
      val sF2 = internString(sh, f.name)
      val fSig2 = buildFieldSigWithCtx(f.fieldType, ctx)
      val bSig2 = internBlob(bh, "ofield_" + op.className + "_" + f.name, fSig2)
      // FDA_ASSEMBLY (internal) allows same-assembly access so that same-package
      // code (e.g. `addrv.country.iso` via a @projectionBoundary view field) can
      // read the field.  The Lyric type checker enforces the stricter package-
      // level visibility at the source level; the MSIL flag mirrors the
      // assembly boundary, which corresponds to the package/compilation-unit
      // boundary in the single-assembly output model.
      addField(t, FieldRow(flags = FDA_ASSEMBLY, name = sF2, signature = bSig2))
      ofi = ofi + 1
    }

    // Register the .ctor MethodDef row BEFORE addMethodDef so that sibling
    // view's tryInto() (emitted earlier) can reference it as a forward ref.
    val predictedCtorRow = t.methodDefs.count + 1
    if not ctx.projectableCtorMDef.containsKey(op.className) {
      ctx.projectableCtorMDef.add(op.className, predictedCtorRow)
      ctx.projectableCtorMDefKeys.add(op.className)
    }

    // Emit opaque .ctor.
    val ctorPs2: List[MsilType] = newList()
    var ci2 = 0
    while ci2 < op.fields.count {
      ctorPs2.add(op.fields[ci2].fieldType)
      ci2 = ci2 + 1
    }
    val ctorSig2 = buildInstanceMethodSigWithCtx(ctorPs2, MVoid, ctx)
    val bCtorSig2 = internBlob(bh, "octor_" + op.className, ctorSig2)
    val sCtor2 = internString(sh, ".ctor")

    val mbCtor2 = newMethodBody()
    if not isDiscover {
      mbCtor2.maxStack = 2
      emitLdarg_0(mbCtor2)
      emitCall(mbCtor2, 0x0A000000 + ctx.mrObjectCtor)
      var ai2 = 0
      while ai2 < op.fields.count {
        emitLdarg_0(mbCtor2)
        emitLdarg(mbCtor2, ai2 + 1)
        emitStfld(mbCtor2, 0x04000000 + firstOpaqueField + ai2)
        ai2 = ai2 + 1
      }
      emitRet(mbCtor2)
    }
    ctx.bodies.add(mbCtor2)
    val rvasCtor2 = methodBodyRvas(ctx.bodies)
    val ctorRva2 = rvasCtor2[ctx.bodies.count - 1]
    val fp2 = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = ctorRva2,
        implFlags = 0,
        flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sCtor2,
        signature = bCtorSig2,
        paramList = fp2
      )
    )

    // Emit explicit instance methods declared in the opaque body.
    var mi2 = 0
    while mi2 < op.methods.count {
      val m2 = op.methods[mi2]
      val mbM2 = lowerMFunc(m2, ctx)
      ctx.bodies.add(mbM2)
      val rvasM2 = methodBodyRvas(ctx.bodies)
      val mRva2 = rvasM2[ctx.bodies.count - 1]
      val sN2 = internString(sh, m2.name)
      val mSig2 = buildInstanceMethodSigWithCtx(m2.params, m2.ret, ctx)
      val bMSig2 = internBlob(bh, "ometh_" + op.className + "_" + m2.name, mSig2)
      val fpm2 = t.params_.count + 1
      addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
      addMethodDef(
        t,
        MethodDefRow(rva = mRva2, implFlags = 0, flags = m2.flags, name = sN2, signature = bMSig2, paramList = fpm2)
      )
      mi2 = mi2 + 1
    }

    // Emit toView(): <Name>View instance method (Pass C).
    // Register BEFORE addMethodDef so sibling A.toView() sees B.toView()'s row.
    val predictedToViewRow = t.methodDefs.count + 1
    if not ctx.projectableToViewMDef.containsKey(op.className) {
      ctx.projectableToViewMDef.add(op.className, predictedToViewRow)
      ctx.projectableToViewMDefKeys.add(op.className)
    }

    val toViewRetTy = MClass(className = viewFqn)
    val toViewPsNone: List[MsilType] = newList()
    val toViewSig = buildInstanceMethodSigWithCtx(toViewPsNone, toViewRetTy, ctx)
    val bToViewSig = internBlob(bh, "otoview_" + op.className, toViewSig)
    val sToView = internString(sh, "toView")

    val mbToView = newMethodBody()
    if not isDiscover {
      mbToView.maxStack = viewFieldIdxs.count + 2
      // For each visible field, load from opaque and optionally project to view type.
      var tvfi2 = 0
      while tvfi2 < viewFieldIdxs.count {
        val origIdx3 = viewFieldIdxs[tvfi2]
        emitLdarg_0(mbToView)
        emitLdfld(mbToView, 0x04000000 + firstOpaqueField + origIdx3)
        // Call toView() on the field if it is a projectable opaque and not @projectionBoundary.
        if not op.projBoundaryMask[origIdx3] {
          match op.fields[origIdx3].fieldType {
            case MClass(srcFqn2) -> {
              match mapGet(ctx.projectableToViewMDef, srcFqn2) {
                case Some(nestedToViewRow) -> {
                  // callvirt on the nested projectable's toView() MethodDef.
                  emitCallvirt(mbToView, 0x06000000 + nestedToViewRow)
                }
                case None -> ()
              }
            }
            case _ -> ()
          }
        }
        tvfi2 = tvfi2 + 1
      }
      // newobj the view using the view's .ctor MethodDef (same assembly forward ref).
      emitNewobj(mbToView, 0x06000000 + viewCtorMDefRow)
      emitRet(mbToView)
    }
    ctx.bodies.add(mbToView)
    val rvasToView = methodBodyRvas(ctx.bodies)
    val toViewRva = rvasToView[ctx.bodies.count - 1]
    val fptvw = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = toViewRva,
        implFlags = 0,
        flags = MDA_PUBLIC + MDA_HIDE_BY_SIG,
        name = sToView,
        signature = bToViewSig,
        paramList = fptvw
      )
    )

    // Emit opaque TypeDef row.
    val opaqueRowP = addTypeDef(
      t,
      TypeDefRow(
        flags = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
        typeName = sName,
        typeNamespace = sNs,
        extends = objectTypeToken(ctx),
        fieldList = firstOpaqueField,
        methodList = firstOpaqueMethod
      )
    )
    recordUserTypeDefRow(ctx, op.namespace, simpleNameOpaque, opaqueRowP)

    opaqueRowP
  } else {
    // Non-projectable opaque: emit a sealed TypeDef with private fields and
    // a synthesised .ctor (the original behaviour, unchanged).
    val firstField = t.fields.count + 1
    val firstMethod = t.methodDefs.count + 1

    // Emit private storage fields (no public field access outside the package).
    var fi = 0
    while fi < op.fields.count {
      val f = op.fields[fi]
      val sF = internString(sh, f.name)
      val fSig = buildFieldSigWithCtx(f.fieldType, ctx)
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
    val ctorSig = buildInstanceMethodSigWithCtx(ctorPs, MVoid, ctx)
    val bCtorSig = internBlob(bh, "octor_" + op.className, ctorSig)
    val sCtor = internString(sh, ".ctor")

    val mbCtor = newMethodBody()
    if not isDiscover {
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
    }
    ctx.bodies.add(mbCtor)

    val rvas = methodBodyRvas(ctx.bodies)
    val ctorRva = rvas[ctx.bodies.count - 1]
    val fp = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = ctorRva,
        implFlags = 0,
        flags = MDA_PUBLIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sCtor,
        signature = bCtorSig,
        paramList = fp
      )
    )

    // Emit explicit instance methods.
    var mi = 0
    while mi < op.methods.count {
      val m = op.methods[mi]
      val mbM = lowerMFunc(m, ctx)
      ctx.bodies.add(mbM)
      val rvasM = methodBodyRvas(ctx.bodies)
      val mRva = rvasM[ctx.bodies.count - 1]
      val sN = internString(sh, m.name)
      val mSig = buildInstanceMethodSigWithCtx(m.params, m.ret, ctx)
      val bMSig = internBlob(bh, "ometh_" + op.className + "_" + m.name, mSig)
      val fpm = t.params_.count + 1
      addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
      addMethodDef(
        t,
        MethodDefRow(rva = mRva, implFlags = 0, flags = m.flags, name = sN, signature = bMSig, paramList = fpm)
      )
      mi = mi + 1
    }

    val opaqueRow = addTypeDef(
      t,
      TypeDefRow(
        flags = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
        typeName = sName,
        typeNamespace = sNs,
        extends = objectTypeToken(ctx),
        fieldList = firstField,
        methodList = firstMethod
      )
    )
    recordUserTypeDefRow(ctx, op.namespace, simpleNameOpaque, opaqueRow)

    opaqueRow
  }
}

// ── Top-level static functions lowering ───────────────────────────────────────
// Lower a list of top-level static MFuncs (and optional static fields) into a
// single host class named `hostClass`. staticFields holds IConst/IVal items.
pub func lowerMFuncsToHostClass(
  hostClass: in String,
  funcs: in List[MFunc],
  staticFields: in List[MStaticField],
  ctx: in LoweringCtx,
): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables

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
  val sName = internString(sh, "Program")
  val sNs = internString(sh, hostClass)
  val firstField = t.fields.count + 1

  // Emit static fields (IConst → literal; IVal → init-only).
  val cctorInsns: List[MInsn] = newList()
  val hasCctor: List[Bool] = newList()  // singleton used as mutable bool flag
  var sfi = 0
  while sfi < staticFields.count {
    val sf = staticFields[sfi]
    val sN = internString(sh, sf.name)
    val fSig = buildFieldSigWithCtx(sf.fieldType, ctx)
    val bSig = internBlob(bh, "stfld_" + hostClass + "_" + sf.name, fSig)
    val fRow = addField(t, FieldRow(flags = sf.flags, name = sN, signature = bSig))
    if sf.hasLiteral {
      // IConst: emit a Constant table row with the literal value.
      val constBlob = buildI4ConstantBlob(sf.constValue)
      val bConst = internBlob(bh, "const_" + hostClass + "_" + sf.name, constBlob)
      addConstant(
        t,
        ConstantRow(
          type_ = 0x08,
          // ELEMENT_TYPE_I4
          parent = hconstField(fRow),
          value = bConst
        )
      )
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
    val cRva = rvasC[ctx.bodies.count - 1]
    val sCctor = internString(sh, ".cctor")
    val cctorSig = buildStaticMethodSig(newList(), MVoid)
    val bCctorSig = internBlob(bh, "cctor_" + hostClass, cctorSig)
    val fpc = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = cRva,
        implFlags = 0,
        flags = MDA_PRIVATE + MDA_STATIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sCctor,
        signature = bCctorSig,
        paramList = fpc
      )
    )
  }

  // Emit static methods.
  var fi = 0
  while fi < funcs.count {
    val f = funcs[fi]
    val mb = lowerMFunc(f, ctx)
    ctx.bodies.add(mb)
    val rvas = methodBodyRvas(ctx.bodies)
    val fRva = rvas[ctx.bodies.count - 1]
    val sN = internString(sh, f.name)
    val mSig = buildStaticMethodSigWithCtx(f.params, f.ret, ctx)
    // Arity-qualify the intern key (#1536) so same-name overloads don't collide and inherit the wrong signature blob.
    val bSig = internBlob(bh, "sfunc_" + hostClass + "_" + f.name + "/" + toString(f.params.count), mSig)
    val fp = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(t, MethodDefRow(rva = fRva, implFlags = 0, flags = f.flags, name = sN, signature = bSig, paramList = fp))
    fi = fi + 1
  }

  addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
      typeName = sName,
      typeNamespace = sNs,
      extends = objectTypeToken(ctx),
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  val programTypeDefRow = t.typeDefs.count
  recordUserTypeDefRow(ctx, hostClass, "Program", programTypeDefRow)
  programTypeDefRow
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

  val discPkgs: List[MPackage] = newList()
  discPkgs.add(pkg)
  discoverTypeDefRowsInto(ctx, discPkgs, ctx.stdCoreResultOk2Row.count > 0)

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
      case MPConfig(ns, typeName, fields, configToks) -> {
        lowerMConfig(ns, typeName, fields, configToks, ctx)
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
    methodBodies = ctx.bodies,
    tables = ctx.tables,
    strings = ctx.strings,
    us = ctx.us,
    blobs = ctx.blobs,
    guids = ctx.guids,
    resourceData = ctx.resourceData
  )

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}

// Lower an MPackage to a complete PE binary using a pre-seeded LoweringCtx.
// Identical to `lowerMPackage` but skips creating a fresh context, allowing
// the caller to pre-register AssemblyRef / TypeRef / MemberRef rows (for
// external method tokens) before any user-defined types are added.
// Used by `Msil.Codegen` + `Msil.Bridge` so that stdlib call tokens baked
// into `MInsn` values are stable.
// Lower a `config { }` block (D046 / docs/25-config-blocks.md) into a sealed
// static CLR class whose fields are initialised from environment variables by a
// .cctor.  The field order, flag, and method-def numbering exactly mirror
// `lowerMFuncsToHostClass` so the pre-allocated token budget in
// `addPackageTokens` remains consistent.
//
// Emitted structure:
//   TypeDef  (ns = pkgName, name = blockName, TDF_PUBLIC|TDF_SEALED|TDF_BFI)
//     FieldDef  per field  (FDA_PUBLIC | FDA_STATIC)
//     MethodDef .cctor      (MDA_PRIVATE | MDA_STATIC | special-name + rts-special)
//
// .cctor body for each field i:
//   ldstr envVarName
//   call  Environment.GetEnvironmentVariable(string): string
//   call  String.IsNullOrEmpty(string): bool
//   brfalse parseLabel_i   ; env var is set → go parse
//   ; absent path
//   <defaultInsns or Console.Error + Exit(78)>
//   br doneLabel_i
//   parseLabel_i:
//   ldstr envVarName
//   call  Environment.GetEnvironmentVariable(string): string
//   [call Int32.Parse / Int64.Parse / Boolean.Parse, or
//    call CultureInfo.get_InvariantCulture + Double.Parse(string, IFormatProvider)
//    for Float/Double fields — omitted for String fields]
//   stsfld fieldToken_i
//   doneLabel_i:
func lowerMConfig(
  ns: in String,
  typeName: in String,
  fields: in List[MConfigField],
  configToks: in ConfigTokens,
  ctx: in LoweringCtx,
): Int {
  val sh = ctx.strings
  val bh = ctx.blobs
  val t = ctx.tables
  val firstField = t.fields.count + 1
  val firstMethod = t.methodDefs.count + 1

  // Emit one FieldDef per config field.
  var fi = 0
  while fi < fields.count {
    val f = fields[fi]
    val sN = internString(sh, f.name)
    val fSig = buildFieldSig(f.fieldType)
    val bSig = internBlob(bh, "cfgfld_" + ns + "_" + typeName + "_" + f.name, fSig)
    val _ = addField(t, FieldRow(flags = FDA_PUBLIC + FDA_STATIC, name = sN, signature = bSig))
    fi = fi + 1
  }

  // Emit the .cctor.  Label IDs: field i → parseLabel = 2*i, doneLabel = 2*i+1.
  if fields.count > 0 {
    val cctorInsns: List[MInsn] = newList()
    var ci = 0
    while ci < fields.count {
      val f = fields[ci]
      val fieldTok = 0x04000000 + firstField + ci
      val parseLabel = 2 * ci
      val doneLabel = 2 * ci + 1

      // Check whether the env var is set.
      cctorInsns.add(MLdStr(token = f.envVarTok))
      cctorInsns.add(MCall(methodToken = configToks.tokGetEnvVar))
      cctorInsns.add(MCall(methodToken = configToks.tokIsNullOrEmpty))
      // brfalse to parseLabel when IsNullOrEmpty returns false (env var is set).
      cctorInsns.add(MBrFalse(label = parseLabel))

      // Absent path.
      if f.hasDefault {
        var di = 0
        while di < f.defaultInsns.count {
          cctorInsns.add(f.defaultInsns[di])
          di = di + 1
        }
        cctorInsns.add(MStsfld(fieldToken = fieldTok))
      } else {
        // Required field: print error to stderr and exit with code 78 (POSIX EX_CONFIG).
        cctorInsns.add(MCall(methodToken = configToks.tokConsoleError))
        cctorInsns.add(MLdStr(token = f.requiredMsgTok))
        cctorInsns.add(MCallvirt(methodToken = configToks.tokTwWriteLine))
        cctorInsns.add(MLdcI4(v = 78))
        cctorInsns.add(MCall(methodToken = configToks.tokEnvExit))
      }
      // Unconditional branch to done (dead after Exit for required fields;
      // needed for verifier structural correctness).
      cctorInsns.add(MBr(label = doneLabel))

      // Present path: re-load env var and parse.  The `case _` arm is
      // unreachable for type-checked input — the front-end rejects config
      // fields outside Bool/Int/Long/Float/Double/String with G0009.  A
      // silent fall-through there would stsfld a raw string into a
      // non-string field — invalid IL at runtime (#2993).
      cctorInsns.add(MLabel(id = parseLabel))
      cctorInsns.add(MLdStr(token = f.envVarTok))
      cctorInsns.add(MCall(methodToken = configToks.tokGetEnvVar))
      match f.fieldType {
        case MInt -> cctorInsns.add(MCall(methodToken = configToks.tokInt32Parse))
        case MLong -> cctorInsns.add(MCall(methodToken = configToks.tokInt64Parse))
        case MDouble -> {
          // Pin InvariantCulture so the accepted numeric format does not vary
          // with the host locale (the single-arg overload reads "1,5" as 15
          // under e.g. de-DE).
          cctorInsns.add(MCall(methodToken = configToks.tokInvariantCulture))
          cctorInsns.add(MCall(methodToken = configToks.tokDoubleParse))
        }
        case MBool -> cctorInsns.add(MCall(methodToken = configToks.tokBoolParse))
        case MString -> {
        }  // raw env-var string is already on the stack
        case _ -> panic("Msil.Lowering ICE: config field '" + f.name + "' has an unsupported MsilType — the type checker (G0009) should have rejected this")
      }
      cctorInsns.add(MStsfld(fieldToken = fieldTok))
      cctorInsns.add(MLabel(id = doneLabel))

      ci = ci + 1
    }
    cctorInsns.add(MRet)

    val mbCctor = newMethodBody()
    mbCctor.maxStack = 8
    var insnIdx = 0
    while insnIdx < cctorInsns.count {
      lowerMInsn(ctx, cctorInsns[insnIdx], mbCctor)
      insnIdx = insnIdx + 1
    }
    ctx.bodies.add(mbCctor)
    val cctorRvas = methodBodyRvas(ctx.bodies)
    val cctorRva = cctorRvas[ctx.bodies.count - 1]

    val sCctor = internString(sh, ".cctor")
    val cctorSig = buildStaticMethodSig(newList(), MVoid)
    val bCctorSig = internBlob(bh, "cfg_cctor_" + ns + "_" + typeName, cctorSig)
    val fpc = t.params_.count + 1
    addParam(t, ParamRow(flags = PRA_NONE, sequence = 0, name = 0))
    addMethodDef(
      t,
      MethodDefRow(
        rva = cctorRva,
        implFlags = 0,
        flags = MDA_PRIVATE + MDA_STATIC + MDA_HIDE_BY_SIG + MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME,
        name = sCctor,
        signature = bCctorSig,
        paramList = fpc
      )
    )
  }

  val sName = internString(sh, typeName)
  val sNs = internString(sh, ns)
  val _ = addTypeDef(
    t,
    TypeDefRow(
      flags = TDF_PUBLIC + TDF_SEALED + TDF_BEFORE_FIELD_INIT,
      typeName = sName,
      typeNamespace = sNs,
      extends = objectTypeToken(ctx),
      fieldList = firstField,
      methodList = firstMethod
    )
  )
  t.typeDefs.count
}

// Lower one `MPackageItem` into `ctx`'s metadata tables.  Single dispatch
// point shared by `lowerMPackageWithCtx` and `lowerMPackagesWithCtx` so
// that new `MPackageItem` variants don't silently fall through the
// multi-package walker (#1185).
func lowerMPackageItem(item: in MPackageItem, ctx: in LoweringCtx): Unit {
  match item {
    case MPRecord(rec) -> {
      val _ = lowerMRecord(rec, ctx)
    }
    case MPFuncs(hostClass, funcs, sfields) -> {
      val _ = lowerMFuncsToHostClass(hostClass, funcs, sfields, ctx)
    }
    case MPUnion(u) -> {
      val _ = lowerMUnion(u, ctx)
    }
    case MPDistinctType(d) -> {
      val _ = lowerMDistinctType(d, ctx)
    }
    case MPRangeType(r) -> {
      val _ = lowerMRangeType(r, ctx)
    }
    case MPEnum(e) -> {
      val _ = lowerMEnum(e, ctx)
    }
    case MPInterface(iface) -> {
      val _ = lowerMInterface(iface, ctx)
    }
    case MPImpl(implData) -> {
      val _ = lowerMImpl(implData, ctx)
    }
    case MPOpaque(op) -> {
      val _ = lowerMOpaque(op, ctx)
    }
    case MPConfig(ns, typeName, fields, configToks) -> {
      val _ = lowerMConfig(ns, typeName, fields, configToks, ctx)
    }
  }
}

pub func lowerMPackageWithCtx(pkg: in MPackage, ctx: in LoweringCtx, entryMethodToken: in Int): List[Byte] {
  val discPkgs: List[MPackage] = newList()
  discPkgs.add(pkg)
  discoverTypeDefRowsInto(ctx, discPkgs, ctx.stdCoreResultOk2Row.count > 0)

  var i = 0
  while i < pkg.items.count {
    lowerMPackageItem(pkg.items[i], ctx)
    i = i + 1
  }

  // RVAs are set inline by each lowerM* call; no post-pass needed.
  // (See the same comment in lowerMPackage above.)

  val inp = AssemblerInput(
    entryPointToken = entryMethodToken,
    methodBodies = ctx.bodies,
    tables = ctx.tables,
    strings = ctx.strings,
    us = ctx.us,
    blobs = ctx.blobs,
    guids = ctx.guids,
    resourceData = ctx.resourceData
  )

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
pub func lowerMPackagesWithCtx(pkgs: in List[MPackage], ctx: in LoweringCtx, entryMethodToken: in Int): List[Byte] {
  discoverTypeDefRowsInto(ctx, pkgs, ctx.stdCoreResultOk2Row.count > 0)

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
    methodBodies = ctx.bodies,
    tables = ctx.tables,
    strings = ctx.strings,
    us = ctx.us,
    blobs = ctx.blobs,
    guids = ctx.guids,
    resourceData = ctx.resourceData
  )

  val peBuf = assemblePe(inp)
  bufToList(peBuf)
}
