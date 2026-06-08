//! jvm/codegen/01_types.l — Jvm.Codegen
//!
//! AST-to-JVM-IR lowering for the Lyric self-hosted compiler.  Walks a parsed
//! `SourceFile` (from Lyric.Parser) and produces an `LPackage` (from
//! Jvm.Lowering) suitable for further lowering to class-file bytes by
//! `Jvm.Lowering.lowerPackage`.
//!
//! The package is split across `lyric-compiler/jvm/codegen/*.l` along
//! function-group boundaries (see docs/44 J0); the files are merged into one
//! `Jvm.Codegen` package by the multi-file builtin loader.  This file holds
//! the per-function context, helpers, type mapping, and load/store/return
//! emit helpers; the remaining sections live in `02_exprs.l` (expressions),
//! `03_match.l` (match), `04_calls.l` (calls), `05_stmts.l` (statements),
//! and `06_items.l` (functions/records/unions and the `codegenPackage` entry).
package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi

// ─────────────────────────────────────────────────────────────────────────────
// §1. Per-function codegen context.
// ─────────────────────────────────────────────────────────────────────────────
// Cross-package function-call resolution entry.  A free-function call
// (`assertEqualInt(...)`) must lower to `invokestatic <owner>.<name><desc>`
// where the owner host class and the exact JVM descriptor (param + return
// types) come from the *callee's* declaration — not the caller's package
// or the pushed argument types.  Without this, a call to an imported or
// void-returning function lowered owner=ctx.className / ret=Object, which
// fails JVM linkage (NoSuchMethodError) at the call site.  The registry is
// built once per compilation from every package's `func` items (the
// caller's own package plus all imported/stdlib packages) and threaded
// read-only through `FuncCtx.funcSigs`.  Keyed by the bare function name
// (last `package` declaring a given name wins; the stdlib's public surface
// has unique names on the call-reachable path).
pub record JvmFuncSig {
  owner: String          // JVM internal host-class name, e.g. "Std/Testing"
  params: List[JvmType]   // declared parameter types, in order
  ret: JvmType         // declared return type (JVoid for Unit)
}

// One field of a union case class, in declaration order.  A match binding
// `case Foo(x) -> …` reads the case object's i-th field; the JVM `getfield`
// descriptor and the bound local's type must be the field's *declared* type,
// not java/lang/Object — otherwise the read mis-resolves (NoSuchFieldError)
// and the bound value verifies as Object (failing any precise-typed use).
// Built once per compilation from every `union` declaration and threaded
// read-only through `FuncCtx.caseFields`, keyed by the case class's JVM name
// (e.g. "Std/Testing/PanicTry$PtPanicked").
pub record JvmCaseField {
  name: String
  ty: JvmType
}

// True when a JVM class name denotes a union case (`Pkg/Union$Case`) rather
// than a record (`Pkg/Point`) — union cases are nested with a `$` separator.
pub func jvmClassIsUnionCase(cls: in String): Bool {
  var i = 0
  while i < cls.length {
    if cls[i] == '$' {
      return true
    }
    i = i + 1
  }
  false
}

// The union's sealed-interface JVM name for a case class (`Pkg/Union$Case` →
// `Pkg/Union`); returns the input unchanged for a record class (no `$`).
pub func jvmUnionBaseClass(cls: in String): String {
  var i = 0
  while i < cls.length {
    if cls[i] == '$' {
      return cls.substring(0, i)
    }
    i = i + 1
  }
  cls
}

// FuncCtx threads mutable state through expression and statement lowering.
// `slotTicker` and `labelTicker` are singleton lists whose `.count` is the
// current next-slot / next-label integer; `.add` advances them.
pub record FuncCtx {
  pkgName: String            // JVM path, e.g. "com/example/Hello"
  className: String            // host class for static methods
  slots: Map[String, Int]  // variable name → local slot
  types: Map[String, JvmType]  // variable name → JVM type
  slotTicker: List[Int]         // length = next slot index
  labelTicker: List[Int]         // length = next label index
  loopBreak: List[String]      // stack of loop exit labels (innermost last)
  loopCont: List[String]      // stack of loop continue labels (innermost last)
  // Generator body context: when Some, EYield emits LYield; when None, EYield panics.
  genClass: Option[String]
  // Cross-package free-function call resolution (see JvmFuncSig).  Keyed by
  // bare function name.  Empty for hand-built / generator-internal contexts.
  funcSigs: Map[String, JvmFuncSig]
  // Union case field types for precise match-binding (see JvmCaseField).
  // Keyed by case class JVM name, e.g. "Pkg/Union$Case".  Record types are
  // registered here too (keyed by their plain class name, e.g. "Pkg/Point")
  // so record-field access and record-pattern binding resolve field types.
  caseFields: Map[String, List[JvmCaseField]]
  // Constructible nominal types (records + union cases): short name → JVM class
  // name (`Point` → `Pkg/Point`, `Circle` → `Pkg/Shape$Circle`).  Drives
  // construction-call lowering and record/union pattern class resolution; field
  // lists come from `caseFields` keyed by the resolved class name.  (A plain
  // `Map[String, String]` rather than a record-valued map — the F# stage-0
  // bootstrap emitter mis-resolves field access through a `Map[String, <record>]`
  // in the whole-compiler bundle compile.)
  ctors: Map[String, String]
  // Extern-type alias → Java FQN, e.g. "Math" → "java.lang.Math".
  externTypes: Map[String, String]
  // Auto-FFI resolution context for JDK class loading.
  autoFfi: AutoFfiCtx
  // Declared JVM return type of the function being lowered.  An explicit
  // `return e` coerces `e` to this type so the return value matches the
  // method descriptor (e.g. a plain Double literal narrows to Float).  JVoid
  // for void functions and hand-built / generator-internal contexts.
  retTy: JvmType
  // Pending `defer { … }` blocks for the current lexical scope chain, innermost
  // last.  A `defer` pushes its block here; the enclosing `lowerBlock` replays
  // (and pops) the blocks it pushed on the normal fall-off path, and
  // `return` / `break` / `continue` replay the still-pending blocks before
  // transferring control so the deferred code runs on every non-exception
  // exit.  The exception-unwind path is covered by a catch-all handler emitted
  // around the deferred region (#1833, mirrors MSIL #1477).
  deferStack: List[Block]
  // `deferStack.count` captured at each enclosing loop's entry, innermost last.
  // `break` / `continue` replay the defers pushed inside the loop body (indices
  // >= this depth) before jumping, so a `defer` declared in a loop body runs on
  // loop-exit and loop-continue as well as on fall-off.
  loopDeferDepth: List[Int]
  // When `Some(cls)`, the function is an instance method whose receiver is at
  // local slot 0 (a protected-type entry / helper).  `self` and bare field
  // references (`tokens`, not `self.tokens`) resolve to `getfield`/`putfield`
  // on `cls` when the name is one of `cls`'s fields (registered in `caseFields`).
  // None for static functions, where bare unknown names fall back as before.
  selfClass: Option[String]
  // Module-level `val NAME` declarations of the host package: name → JVM type.
  // A bare reference to such a name lowers to `getstatic <hostClass>.<name>`
  // (the `public static final` field emitted by `lowerFuncsToClass`).  The
  // owning class is the package host class (`pkgName`).  Empty for hand-built
  // / generator-internal contexts (m-2).
  moduleVals: Map[String, JvmType]
  // JVM class names (e.g. "Pkg/Counter") of `opaque type` declarations in scope.
  // An opaque type stores its fields privately as `$<name>` and exposes them via
  // `$<name>()` accessor methods, so a field read on an opaque receiver lowers
  // to `invokevirtual $<name>()` rather than a direct `getfield` (J3 M-3).
  opaqueTypes: Map[String, Bool]
  // J2b closures (#2665): the package-shared accumulator of synthesised closure
  // classes.  An `ELambda` lowers to a `new <pkg>$Lambda$<n>` inner class that
  // implements the shared `<pkg>/Lyric$Lambda` functional interface
  // (`invoke([Ljava/lang/Object;)Ljava/lang/Object;`).  Each lowered closure is
  // appended here; `codegenPackageWithSigs` drains the list into `LPClosureClass`
  // package items (plus the one shared interface) after all functions are lowered.
  // The same list object is threaded through every `FuncCtx` of the package so
  // lambda-class names stay globally unique and no closure is lost.
  closureAcc: List[LClosure]
  // Shared monotonic counter for unique `<pkg>$Lambda$<n>` class names; `.count`
  // is the next index, `.add` advances it.  Shared across the package like
  // `closureAcc`.
  closureCounter: List[Int]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Helper utilities.
// ─────────────────────────────────────────────────────────────────────────────
// Convert a dotted Lyric package name to a JVM internal binary name.
pub func lyricNameToJvm(name: in String): String {
  name.replace(".", "/")
}

// Allocate a fresh label like "L0", "L1", …
pub func freshLabel(ctx: in FuncCtx): String {
  val n = ctx.labelTicker.count
  ctx.labelTicker.add(0)
  "L" + toString(n)
}

// Assign the next JVM local slot to `name` with type `ty`.
// Long and Double occupy two consecutive slots; all others occupy one.
// Returns the assigned slot.
//
// Re-binding a name (a shadowed local, or a catch binding reused across
// sequential `try`/`catch` blocks in one function — e.g. the `__lyric_e`
// the test-runner synthesises for every `test` block) allocates a *fresh*
// slot and overwrites the mapping rather than crashing the underlying
// dictionary with a duplicate-key insert.  When the rebound type has the
// same width as the original (1 slot for refs/int/float/etc., 2 slots
// for `JLong`/`JDouble`) the existing slot is reused so `max_locals`
// doesn't grow per re-bind — keeping the StackMapTable frame-locals
// list lean (#1682).
pub func allocSlot(ctx: in FuncCtx, name: in String, ty: in JvmType): Int {
  val width = jvmTypeSlotWidth(ty)
  match mapGet(ctx.slots, name) {
    case Some(existing) -> {
      val prevTy = match mapGet(ctx.types, name) { case Some(t) -> t; case None -> ty }
      if jvmTypeSlotWidth(prevTy) == width {
        ctx.types.remove(name)
        ctx.types.add(name, ty)
        return existing
      }
      ctx.slots.remove(name)
    }
    case None -> {
    }
  }
  val slot = ctx.slotTicker.count
  ctx.slots.add(name, slot)
  if ctx.types.containsKey(name) {
    ctx.types.remove(name)
  }
  ctx.types.add(name, ty)
  // Advance the ticker.
  ctx.slotTicker.add(0)
  if width == 2 {
    ctx.slotTicker.add(0)
  }
  slot
}

// Slot width in JVM local-variable units: 2 for `JLong`/`JDouble`, 1 for
// everything else.  Mirrors ECMA JVMS §2.6.1.
func jvmTypeSlotWidth(ty: in JvmType): Int {
  match ty {
    case JLong -> 2
    case JDouble -> 2
    case _ -> 1
  }
}

// Look up the slot assigned to `name`.
pub func lookupSlot(ctx: in FuncCtx, name: in String): Option[Int] {
  mapGet(ctx.slots, name)
}

// Look up the JVM type of a named local.
pub func lookupType(ctx: in FuncCtx, name: in String): Option[JvmType] {
  mapGet(ctx.types, name)
}

// Resolve the declared JVM type of field `fieldName` on the record/union-case
// JVM class `cls`, via the type registry.  `None` when the class or field is
// unknown (e.g. an erased Object receiver, or a BCL/extern type).
pub func recordFieldType(ctx: in FuncCtx, cls: in String, fieldName: in String): Option[JvmType] {
  val fldsOpt: Option[List[JvmCaseField]] = mapGet(ctx.caseFields, cls)
  match fldsOpt {
    case Some(flds) -> {
      var i = 0
      while i < flds.count {
        if flds[i].name == fieldName {
          return Some(value = flds[i].ty)
        }
        i = i + 1
      }
      None
    }
    case None -> None
  }
}

// When the current function is an instance method (`ctx.selfClass` is set),
// resolve the JVM type of a field named `name` on the receiver class — used to
// lower a bare field reference / assignment inside a protected-type entry to a
// `getfield`/`putfield` on `this`.  `None` for static functions or non-fields.
pub func selfFieldType(ctx: in FuncCtx, name: in String): Option[JvmType] {
  match ctx.selfClass {
    case Some(cls) -> recordFieldType(ctx, cls, name)
    case None -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Type mapping.
// ─────────────────────────────────────────────────────────────────────────────
// Return the last segment of a ModulePath.
func lastSegment(path: in ModulePath): String {
  val n = path.segments.count
  if n == 0 {
    return ""
  }
  path.segments[n - 1]
}

// Join path segments with a separator.
func joinSegments(segs: in List[String], sep: in String): String {
  var result = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      result = result + sep
    }
    result = result + segs[i]
    i = i + 1
  }
  result
}

// Collect the type-parameter names from an optional `GenericParams` list, so a
// declaration's generic params (e.g. `T`, `E` of `Result[T, E]`) can be erased
// to `java/lang/Object` rather than mis-resolved to a non-existent class.
pub func genericParamNames(g: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match g {
    case Some(gp) -> {
      var i = 0
      while i < gp.params.count {
        match gp.params[i] {
          case GPType(name, _) -> names.add(name)
          case GPValue(name, _, _) -> names.add(name)
        }
        i = i + 1
      }
    }
    case None -> ()
  }
  names
}

func listContainsStr(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

// Like `typeExprToJvm`, but a bare `TRef` whose name is one of `typeParams`
// erases to `java/lang/Object` (the JVM has no reified generics — see docs/44
// M-1 / Q-J001).  Used when lowering a generic record/union's field types so a
// `T`-typed payload is declared `Ljava/lang/Object;` instead of resolving to a
// non-existent `pkg/T` class.
pub func typeExprToJvmErased(te: in TypeExpr, pkgName: in String, typeParams: in List[String]): JvmType {
  match te.kind {
    case TRef(path) -> {
      val seg = lastSegment(path)
      if listContainsStr(typeParams, seg) {
        JRef(className = "java/lang/Object")
      } else {
        typeExprToJvm(te, pkgName)
      }
    }
    case TParen(inner) -> typeExprToJvmErased(inner, pkgName, typeParams)
    case _ -> typeExprToJvm(te, pkgName)
  }
}

// Map a Lyric TypeExpr to a JvmType.
pub func typeExprToJvm(te: in TypeExpr, pkgName: in String): JvmType {
  match te.kind {
    case TUnit -> JVoid
    case TNever -> JVoid
    case TRef(path) -> {
      val seg = lastSegment(path)
      if seg == "Int" {
        JInt
      } else if seg == "Long" {
        JLong
      } else if seg == "Double" {
        JDouble
      } else if seg == "Float" {
        JFloat
      } else if seg == "Bool" {
        JBoolean
      } else if seg == "String" {
        JRef(className = "java/lang/String")
      } else if seg == "Char" {
        JChar
      } else if seg == "Byte" {
        JByte
      } else if seg == "Unit" {
        JVoid
      } else {
        // User-defined type in the same package.
        JRef(className = pkgName + "/" + seg)
      }
    }
    case TSlice(_) -> JArray(elem = JRef(className = "java/lang/Object"))
    case TGenericApp(_, _) -> JRef(className = "java/lang/Object")
    case TNullable(_) -> JRef(className = "java/lang/Object")
    case TTuple(_) -> JRef(className = "java/lang/Object")
    case TFunction(_, _) -> JRef(className = "java/lang/Object")
    case TArray(_, _) -> JRef(className = "java/lang/Object")
    case TRefined(_, _) -> JInt
    case TParen(inner) -> typeExprToJvm(inner, pkgName)
    case TSelf -> JRef(className = "java/lang/Object")
    case TError -> JRef(className = "java/lang/Object")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Load / store / return helpers.
// ─────────────────────────────────────────────────────────────────────────────
pub func emitLoad(insns: in List[LInsn], slot: in Int, ty: in JvmType): Unit {
  match ty {
    case JLong -> insns.add(LLload(slot = slot))
    case JDouble -> insns.add(LDload(slot = slot))
    case JBoolean -> insns.add(LIload(slot = slot))
    case JByte -> insns.add(LIload(slot = slot))
    case JChar -> insns.add(LIload(slot = slot))
    case JShort -> insns.add(LIload(slot = slot))
    case JInt -> insns.add(LIload(slot = slot))
    case JFloat -> insns.add(LFload(slot = slot))
    case JVoid -> insns.add(LNop)
    case JRef(_) -> insns.add(LAload(slot = slot))
    case JArray(_) -> insns.add(LAload(slot = slot))
  }
}

// Load an if/match/try result local, narrowing a reference value back to its
// precise class.  Result locals are tracked as java/lang/Object in the
// StackMapTable (object locals lose their class through a plain astore), so a
// downstream `areturn` / member access requiring the precise type would
// otherwise fail verification ("Type 'java/lang/Object' is not assignable…").
// A checkcast restores the static type; for primitives it is a no-op load.
pub func emitResultLoad(insns: in List[LInsn], slot: in Int, ty: in JvmType): Unit {
  emitLoad(insns, slot, ty)
  match ty {
    case JRef(cls) -> {
      if cls != "java/lang/Object" {
        insns.add(LCheckcast(className = cls))
      }
    }
    case _ -> ()
  }
}

pub func emitStore(insns: in List[LInsn], slot: in Int, ty: in JvmType): Unit {
  match ty {
    case JLong -> insns.add(LLstore(slot = slot))
    case JDouble -> insns.add(LDstore(slot = slot))
    case JBoolean -> insns.add(LIstore(slot = slot))
    case JByte -> insns.add(LIstore(slot = slot))
    case JChar -> insns.add(LIstore(slot = slot))
    case JShort -> insns.add(LIstore(slot = slot))
    case JInt -> insns.add(LIstore(slot = slot))
    case JFloat -> insns.add(LFstore(slot = slot))
    case JVoid -> insns.add(LNop)
    case JRef(_) -> insns.add(LAstore(slot = slot))
    case JArray(_) -> insns.add(LAstore(slot = slot))
  }
}

pub func emitReturn(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JLong -> insns.add(LLreturn)
    case JDouble -> insns.add(LDreturn)
    case JBoolean -> insns.add(LIreturn)
    case JByte -> insns.add(LIreturn)
    case JChar -> insns.add(LIreturn)
    case JShort -> insns.add(LIreturn)
    case JInt -> insns.add(LIreturn)
    case JFloat -> insns.add(LFreturn)
    case JVoid -> insns.add(LReturn)
    case JRef(_) -> insns.add(LAreturn)
    case JArray(_) -> insns.add(LAreturn)
  }
}
