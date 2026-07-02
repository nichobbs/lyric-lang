//! llvm/codegen.l — Lyric.LlvmCodegen: AST → LLVM IR lowering (Phase N1).
//!
//! Walks parsed + middle-ended `SourceFile`s and produces an `NPackage`
//! for `Lyric.LlvmLowering.lowerPackage`.  Phase N1 scope (scalar codegen,
//! native/plan/08-work-items.md):
//!
//!   * Int/Long/Float/Bool/Char/Byte scalars, String references.
//!   * Arithmetic, comparison, short-circuit `and`/`or`, `not`,
//!     bitwise `.and/.or/.xor/.shl/.shr`, checked integer division.
//!   * `val`/`var` locals (alloca-based; LLVM's mem2reg promotes),
//!     assignment (plain + compound), if/else (statement and
//!     expression), `while`, `break`/`continue`, blocks, `return`.
//!   * Function definitions and cross-package static calls (positional
//!     and named arguments; overloads disambiguated by arity).
//!   * String literals (static `LyricString` globals), concatenation,
//!     equality/ordering, `.length`, `.substring`, interpolation, and
//!     `.toString()` on every scalar.
//!   * `extern func` C-ABI declarations and calls (D-N-007).
//!   * `panic(msg)` / `assert(cond)` via `lyric_panic_msg`.
//!   * `func main(): Int | Unit` entry-point synthesis (C `main`).
//!
//! Style constraint: value-position if/else whose other branch panics is
//! written in return style throughout this file — the self-hosted MSIL
//! emitter miscompiles that shape (ilverify ReturnMissing/StackUnderflow,
//! #4625); `typeExprToNType`, `lowerExpr`'s EPath arm, and
//! `assignTargetName` hit it before the rewrite.
//!
//! Phase N2 (records, unions, enums, distinct types, pattern matching,
//! ARC insertion) lowers here too:
//!
//!   * Records: `{ i32 rc, i8* dtor, fields... }` heap structs with
//!     synthesised destructors (Rule 7) and inline construction
//!     (Rules 1/2).  Methods in record bodies lower as package
//!     functions with the explicit `self` receiver (D037), resolved
//!     via UFCS.
//!   * Unions: `{ header, i32 disc, i32 pad, [W x i64] payload }` with
//!     per-case payload structs; `match` lowers to discriminant tests
//!     with payload-field bindings, literal/range/string tests,
//!     guards, and a non-exhaustive panic backstop.
//!   * ARC: value-provenance bookkeeping — constructors and
//!     ref-returning calls yield OWNED temps (Rule 6) released at
//!     region end unless transferred to a binding (Rule 4), a heap
//!     store (Rules 2/3), or a return; borrows retain on binding;
//!     scope stacks release locals on block exit, `return`, `break`,
//!     and `continue`.  `in` params are borrows (Rule 5).
//!
//! Not yet lowered (each panics with a construct-naming message, per
//! the MSIL/JVM backend convention for backend gaps): closures/lambdas
//! and `NativeWeak[T]` (rest of N2), generics-after-mono leftovers,
//! tuples/interfaces/protected types (N3), `for`, module-level `val`,
//! collections (N5), async (Phase 2).
package Lyric.LlvmCodegen

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Encoding as Encoding
import Lyric.Lexer
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr

// ─────────────────────────────────────────────────────────────────────────────
// §1. Codegen inputs and cross-package call registry.
// ─────────────────────────────────────────────────────────────────────────────
/// One package's contribution to the native module.  `fns` are the
/// function bodies to lower (the bridge pre-filters to the reachable
/// set for bundled stdlib packages); `externs` are the reachable
/// `extern func` declarations.
pub record CodegenUnit {
  pkgName: String
  fns: List[FunctionDecl]
  externs: List[ExternFuncDecl]
  // Type declarations register unfiltered (layouts are cheap and other
  // packages' signatures may reference them); generic declarations are
  // skipped at registration and panic only when actually used.
  records: List[RecordDecl]
  unions: List[UnionDecl]
  enums: List[EnumDecl]
  distincts: List[DistinctTypeDecl]
}

/// Call-registry entry: how a resolvable callee lowers.  `isExternSym`
/// selects between a Lyric function (`irName` = `Pkg.name`, possibly
/// arity-suffixed) and a C symbol from an `extern func`.
record NFuncSig {
  irName: String
  pkg: String
  paramNames: List[String]
  paramTys: List[TypeExpr]
  retTy: Option[TypeExpr]
  isExternSym: Bool
}

/// The result of lowering one expression: its LLVM type and operand.
record NVal {
  ty: NType
  value: NValue
}

/// Registered (non-generic) record type: IR struct name plus the field
/// layout in declaration order.
record NRecInfo {
  irName: String
  fieldNames: List[String]
  fieldTys: List[NType]
  fieldDefaults: List[Option[Expr]]
}

record NUnionCaseInfo {
  name: String
  fieldNames: List[String]
  fieldTys: List[NType]
}

/// Registered (non-generic) union type: cases plus the payload area
/// size in 8-byte words (max over the cases' payload struct layouts).
record NUnionInfo {
  irName: String
  cases: List[NUnionCaseInfo]
  payloadWords: Int
}

/// Resolves a case name to its union and discriminant index.
record NCaseRef {
  unionKey: String
  caseIdx: Int
}

/// Registered distinct type: the underlying representation plus the
/// optional literal range bounds (range subtypes check on construction).
record NDistinctInfo {
  underlying: NType
  hasRange: Bool
  lo: Long
  hi: Long
}

/// A ref-typed local owned by a lexical scope (released on scope exit).
record NOwnedLocal {
  slot: String
  ty: NType
}

/// An owned ref-typed temporary (rc transferred by a constructor or a
/// call); released at the end of its evaluation region unless
/// transferred to a binding, a heap store, or a return.
record NOwnedTemp {
  value: NValue
  ty: NType
}

/// Per-module mutable codegen state, threaded through all lowering.
/// Tickers use the singleton-list idiom (`.count` is the next index)
/// shared with `Jvm.Codegen.FuncCtx`.
record Ctx {
  mainPkg: String
  tmpTicker: List[Int]
  labelTicker: List[Int]
  strTicker: List[Int]
  // Current function state.
  varSlots: Map[String, String]
  varTypes: Map[String, NType]
  allocas: List[NInsn]
  loopBreak: List[String]
  loopCont: List[String]
  // Module accumulators.
  globals: List[NGlobalDef]
  sigs: Map[String, NFuncSig]
  // Package the function being lowered belongs to (self-package call
  // resolution).
  curPkg: List[String]
  // Return type of the function being lowered (singleton list).
  curRet: List[NType]
  // Heap-type registries (module-wide, shared across functions).
  recordDefs: Map[String, NRecInfo]
  unionDefs: Map[String, NUnionInfo]
  caseRefs: Map[String, NCaseRef]
  enumDefs: Map[String, Int]
  distinctDefs: Map[String, NDistinctInfo]
  // ARC state (per function).  `scopeRefs` stacks the ref-typed locals
  // each lexical scope owns; `tempScopes` stacks the owned temporaries
  // of each evaluation region; the depth lists snapshot both stacks at
  // loop entry so break/continue release exactly the loop-inner scopes.
  scopeRefs: List[List[NOwnedLocal]]
  tempScopes: List[List[NOwnedTemp]]
  loopVarDepth: List[Int]
  loopTempDepth: List[Int]
}

func freshTmp(ctx: in Ctx): String {
  val n = ctx.tmpTicker.count
  ctx.tmpTicker.add(0)
  "t" + n.toString()
}

func freshLabel(ctx: in Ctx, stem: in String): String {
  val n = ctx.labelTicker.count
  ctx.labelTicker.add(0)
  stem + "." + n.toString()
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Type mapping (03-type-mapping.md).
// ─────────────────────────────────────────────────────────────────────────────
pub func lyricStringNType(): NType {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NI64)
  fields.add(NI64)
  NPtr(pointee = NStruct(name = "LyricString", fields = fields))
}

func isStringNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> match pointee { case NStruct(name, _) -> name == "LyricString"; case _ -> false }
    case _ -> false
  }
}

func lastSeg(path: in ModulePath): String {
  if path.segments.count == 0 {
    ""
  } else {
    path.segments[path.segments.count - 1]
  }
}

/// Map a surface type to its LLVM lowering.  Panics (naming the type)
/// for constructs outside the N1 scalar scope.
pub func typeExprToNType(te: in TypeExpr): NType {
  match te.kind {
    case TRef(path) -> {
      val n = lastSeg(path)
      if n == "Int" {
        return NI32
      }
      if n == "Long" {
        return NI64
      }
      if n == "Float" or n == "Double" {
        return NDouble
      }
      if n == "Bool" {
        return NI1
      }
      if n == "Unit" {
        return NVoid
      }
      if n == "Byte" {
        return NI8
      }
      if n == "Char" {
        return NI32
      }
      if n == "String" {
        return lyricStringNType()
      }
      panic(
        "Lyric.LlvmCodegen: type '" + n +
          "' is not yet supported for --target native (Phase N1 lowers scalars and String only)"
      )
    }
    case TGenericApp(head, args) -> {
      val n = lastSeg(head)
      if n == "NativePtr" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> return NPtr(pointee = typeExprToNType(inner))
          case TAValue(_) -> panic("Lyric.LlvmCodegen: NativePtr takes a type argument")
        }
      }
      panic("Lyric.LlvmCodegen: generic type '" + n + "' is not yet supported for --target native (Phase N1)")
    }
    case TUnit -> NVoid
    case TParen(inner) -> typeExprToNType(inner)
    case _ -> panic("Lyric.LlvmCodegen: this type form is not yet supported for --target native (Phase N1)")
  }
}

func retTypeToNType(ret: in Option[TypeExpr]): NType {
  match ret {
    case Some(te) -> typeExprToNType(te)
    case None -> NVoid
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.5. Heap types: registries, layout, and ARC bookkeeping (Phase N2).
// ─────────────────────────────────────────────────────────────────────────────
/// Registry-aware type resolution: scalars first, then records, unions,
/// enums (i32), and distinct types (their underlying representation).
func typeToN(ctx: in Ctx, te: in TypeExpr): NType {
  match te.kind {
    case TRef(path) -> {
      val joined = modulePathJoin(path.segments)
      val n = lastSeg(path)
      match lookupHeapType(ctx, joined, n) {
        case Some(t) -> return t
        case None -> {
        }
      }
      typeExprToNType(te)
    }
    case TParen(inner) -> typeToN(ctx, inner)
    case _ -> typeExprToNType(te)
  }
}

/// Non-panicking variant of `typeToN`, used when registering bundled
/// (stdlib) type declarations: a bundled record whose field types the
/// native backend cannot lower yet must not break unrelated programs —
/// it stays unregistered, so a *use* panics with the resolution
/// message while non-users compile fine.
func typeToNOpt(ctx: in Ctx, te: in TypeExpr): Option[NType] {
  match te.kind {
    case TRef(path) -> {
      val joined = modulePathJoin(path.segments)
      val n = lastSeg(path)
      match lookupHeapType(ctx, joined, n) {
        case Some(t) -> return Some(value = t)
        case None -> {
        }
      }
      if n == "Int" or n == "Char" {
        return Some(value = NI32)
      }
      if n == "Long" {
        return Some(value = NI64)
      }
      if n == "Float" or n == "Double" {
        return Some(value = NDouble)
      }
      if n == "Bool" {
        return Some(value = NI1)
      }
      if n == "Unit" {
        return Some(value = NVoid)
      }
      if n == "Byte" {
        return Some(value = NI8)
      }
      if n == "String" {
        return Some(value = lyricStringNType())
      }
      None
    }
    case TGenericApp(head, args) -> {
      if lastSeg(head) == "NativePtr" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> {
            match typeToNOpt(ctx, inner) {
              case Some(t) -> return Some(value = NPtr(pointee = t))
              case None -> return None
            }
          }
          case TAValue(_) -> return None
        }
      }
      None
    }
    case TUnit -> Some(value = NVoid)
    case TParen(inner) -> typeToNOpt(ctx, inner)
    case _ -> None
  }
}

func lookupHeapType(ctx: in Ctx, joined: in String, bare: in String): Option[NType] {
  match mapGet(ctx.recordDefs, joined) {
    case Some(ri) -> return Some(value = recPtrType(ri))
    case None -> {
    }
  }
  match mapGet(ctx.recordDefs, bare) {
    case Some(ri) -> return Some(value = recPtrType(ri))
    case None -> {
    }
  }
  match mapGet(ctx.unionDefs, joined) {
    case Some(ui) -> return Some(value = unionPtrType(ui))
    case None -> {
    }
  }
  match mapGet(ctx.unionDefs, bare) {
    case Some(ui) -> return Some(value = unionPtrType(ui))
    case None -> {
    }
  }
  if ctx.enumDefs.containsKey(joined + ".__enum") or ctx.enumDefs.containsKey(bare + ".__enum") {
    return Some(value = NI32)
  }
  // Field access goes through a helper: the stage-0 seed mis-infers
  // the `Some(di)` binding against this function's Option[NType]
  // return type and rejects `di.underlying` (#4631 family).
  match mapGet(ctx.distinctDefs, joined) {
    case Some(di) -> return Some(value = distinctUnderlying(di))
    case None -> {
    }
  }
  match mapGet(ctx.distinctDefs, bare) {
    case Some(di) -> return Some(value = distinctUnderlying(di))
    case None -> {
    }
  }
  None
}

func distinctUnderlying(di: in NDistinctInfo): NType {
  di.underlying
}

func retTypeToN(ctx: in Ctx, ret: in Option[TypeExpr]): NType {
  match ret {
    case Some(te) -> typeToN(ctx, te)
    case None -> NVoid
  }
}

/// The pointer type for a registered record.  The struct body carries
/// the ARC header (rc, dtor) followed by the fields, so GEP field
/// indices are `2 + declIndex`.
func recPtrType(ri: in NRecInfo): NType {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  var i = 0
  while i < ri.fieldTys.count {
    fields.add(ri.fieldTys[i])
    i = i + 1
  }
  NPtr(pointee = NStruct(name = ri.irName, fields = fields))
}

/// The pointer type for a registered union: header, i32 discriminant,
/// i32 pad (so the payload is 8-aligned), then the payload words.
func unionPtrType(ui: in NUnionInfo): NType {
  NPtr(pointee = NStruct(name = ui.irName, fields = unionBodyFields(ui.payloadWords)))
}

func unionBodyFields(payloadWords: in Int): List[NType] {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NI32)
  fields.add(NI32)
  fields.add(NArray(elem = NI64, size = payloadWords))
  fields
}

/// x86-64 / AArch64 System V sizes for the types that can appear in
/// heap-struct fields (aggregates are always behind pointers).
func sizeOfN(t: in NType): Int {
  match t {
    case NI1 -> 1
    case NI8 -> 1
    case NI32 -> 4
    case NI64 -> 8
    case NDouble -> 8
    case NPtr(_) -> 8
    case NArray(elem, size) -> sizeOfN(elem) * size
    case _ -> panic("Lyric.LlvmCodegen: by-value aggregate fields are not supported in native heap layouts")
  }
}

func alignOfN(t: in NType): Int {
  match t {
    case NArray(elem, _) -> alignOfN(elem)
    case _ -> sizeOfN(t)
  }
}

func roundUpTo(off: in Int, a: in Int): Int {
  if a <= 1 {
    return off
  }
  // Binds first: a trailing line starting with '(' would parse as a
  // call continuing the if statement.
  val rounded = ((off + a - 1) / a) * a
  rounded
}

/// Struct layout size (C rules): field offsets aligned per field, total
/// rounded up to the max field alignment.
func structSize(fields: in List[NType]): Int {
  var off = 0
  var maxA = 1
  var i = 0
  while i < fields.count {
    val a = alignOfN(fields[i])
    if a > maxA {
      maxA = a
    }
    off = roundUpTo(off, a)
    off = off + sizeOfN(fields[i])
    i = i + 1
  }
  roundUpTo(off, maxA)
}

/// Allocation size of a record: ARC header + fields.
func recAllocSize(ri: in NRecInfo): Int {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  var i = 0
  while i < ri.fieldTys.count {
    fields.add(ri.fieldTys[i])
    i = i + 1
  }
  structSize(fields)
}

func unionAllocSize(ui: in NUnionInfo): Int {
  structSize(unionBodyFields(ui.payloadWords))
}

/// ARC-managed values are pointers to named structs (LyricString,
/// records, unions).  Raw c-strings (`i8*`) and `NativePtr[T]` are not.
func isRefNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> match pointee { case NStruct(_, _) -> true; case _ -> false }
    case _ -> false
  }
}

func asI8Ptr(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NValue {
  match v.ty {
    case NPtr(pointee) -> {
      match pointee {
        case NI8 -> return v.value
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
  NLocal(name = dest)
}

func emitRetain(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  val p = asI8Ptr(ctx, insns, v)
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_retain"), args = arg1(NPtr(pointee = NI8), p)))
}

func emitRelease(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  val p = asI8Ptr(ctx, insns, v)
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), p)))
}

// ── Ownership bookkeeping ────────────────────────────────────────────────────
func pushTempScope(ctx: in Ctx): Unit {
  val fresh: List[NOwnedTemp] = newList()
  ctx.tempScopes.add(fresh)
}

/// Release every still-owned temp of the top scope and pop it.
func popTempScope(ctx: in Ctx, insns: in List[NInsn]): Unit {
  val top = ctx.tempScopes[ctx.tempScopes.count - 1]
  var i = top.count - 1
  while i >= 0 {
    emitRelease(ctx, insns, NVal(ty = top[i].ty, value = top[i].value))
    i = i - 1
  }
  ctx.tempScopes.removeAt(ctx.tempScopes.count - 1)
}

/// Register an owned ref-typed value in the current temp scope.  No-op
/// for scalars and when no temp scope is active (module-level paths).
func registerTemp(ctx: in Ctx, v: in NVal): Unit {
  if not isRefNType(v.ty) {
    return
  }
  if ctx.tempScopes.count == 0 {
    return
  }
  ctx.tempScopes[ctx.tempScopes.count - 1].add(NOwnedTemp(value = v.value, ty = v.ty))
}

func nValueEq(a: in NValue, b: in NValue): Bool {
  match a {
    case NLocal(an) -> match b { case NLocal(bn) -> an == bn; case _ -> false }
    case NGlobal(an) -> match b { case NGlobal(bn) -> an == bn; case _ -> false }
    case _ -> false
  }
}

/// Remove `v` from any temp scope (ownership is being transferred to a
/// binding, a heap store, or the caller).  Returns true when found —
/// i.e. `v` was an owned temp; false means `v` is a borrow.
func unregisterTemp(ctx: in Ctx, v: in NVal): Bool {
  var si = ctx.tempScopes.count - 1
  while si >= 0 {
    val scp = ctx.tempScopes[si]
    var i = scp.count - 1
    while i >= 0 {
      if nValueEq(scp[i].value, v.value) {
        scp.removeAt(i)
        return true
      }
      i = i - 1
    }
    si = si - 1
  }
  false
}

/// Make `v` owned by the current consumer: owned temps transfer
/// (unregister); borrows get a retain.  Scalars pass through.
func ensureOwned(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  if not isRefNType(v.ty) {
    return
  }
  if unregisterTemp(ctx, v) {
    return
  }
  emitRetain(ctx, insns, v)
}

func pushVarScope(ctx: in Ctx): Unit {
  val fresh: List[NOwnedLocal] = newList()
  ctx.scopeRefs.add(fresh)
}

/// Release the ref-typed locals of the top var scope (reverse bind
/// order) and pop it.
func popVarScope(ctx: in Ctx, insns: in List[NInsn]): Unit {
  releaseVarScopeAt(ctx, insns, ctx.scopeRefs.count - 1)
  ctx.scopeRefs.removeAt(ctx.scopeRefs.count - 1)
}

func releaseVarScopeAt(ctx: in Ctx, insns: in List[NInsn], idx: in Int): Unit {
  val scp = ctx.scopeRefs[idx]
  var i = scp.count - 1
  while i >= 0 {
    val dest = freshTmp(ctx)
    insns.add(NLoad(dest = dest, ty = scp[i].ty, ptr = NLocal(name = scp[i].slot)))
    emitRelease(ctx, insns, NVal(ty = scp[i].ty, value = NLocal(name = dest)))
    i = i - 1
  }
}

/// Emit the releases a `return` needs: every var scope in the stack and
/// every remaining owned temp (the return value itself must already be
/// unregistered/retained by the caller of this helper).
func releaseAllForReturn(ctx: in Ctx, insns: in List[NInsn]): Unit {
  var ti = ctx.tempScopes.count - 1
  while ti >= 0 {
    val scp = ctx.tempScopes[ti]
    var i = scp.count - 1
    while i >= 0 {
      emitRelease(ctx, insns, NVal(ty = scp[i].ty, value = scp[i].value))
      i = i - 1
    }
    ti = ti - 1
  }
  var si = ctx.scopeRefs.count - 1
  while si >= 0 {
    releaseVarScopeAt(ctx, insns, si)
    si = si - 1
  }
}

/// Emit the releases `break`/`continue` need: var scopes and temp
/// scopes opened inside the innermost loop (not the loop-outer ones).
func releaseForLoopExit(ctx: in Ctx, insns: in List[NInsn]): Unit {
  val varFloor = ctx.loopVarDepth[ctx.loopVarDepth.count - 1]
  val tempFloor = ctx.loopTempDepth[ctx.loopTempDepth.count - 1]
  var ti = ctx.tempScopes.count - 1
  while ti >= tempFloor {
    val scp = ctx.tempScopes[ti]
    var i = scp.count - 1
    while i >= 0 {
      emitRelease(ctx, insns, NVal(ty = scp[i].ty, value = scp[i].value))
      i = i - 1
    }
    ti = ti - 1
  }
  var si = ctx.scopeRefs.count - 1
  while si >= varFloor {
    releaseVarScopeAt(ctx, insns, si)
    si = si - 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Registry construction.
// ─────────────────────────────────────────────────────────────────────────────
func paramNamesOf(params: in List[Param]): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < params.count {
    names.add(params[i].name)
    i = i + 1
  }
  names
}

func paramTysOf(params: in List[Param]): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  var i = 0
  while i < params.count {
    tys.add(params[i].ty)
    i = i + 1
  }
  tys
}

func addSig(sigs: in Map[String, NFuncSig], key: in String, sig: in NFuncSig): Unit {
  if not sigs.containsKey(key) {
    sigs.add(key, sig)
  }
}

/// The IR symbol for a Lyric function.  A name that is overloaded by
/// arity within its package gets a stable `.<arity>` suffix so each
/// overload owns a distinct symbol.
func irNameFor(pkg: in String, name: in String, arity: in Int, overloaded: in Bool): String {
  if overloaded {
    pkg + "." + name + "." + arity.toString()
  } else {
    pkg + "." + name
  }
}

/// Build the cross-package call registry over every unit's functions
/// and extern funcs.  Keys: `<name>/<arity>` (bare) and
/// `<Pkg>.<name>/<arity>` (qualified); first registration wins, and the
/// main package registers first so its names shadow stdlib bare names,
/// matching source scoping.
func buildSigs(units: in List[CodegenUnit]): Map[String, NFuncSig] {
  val sigs: Map[String, NFuncSig] = newMap()
  // Pass 1: count same-package name+arity groups to detect overloads.
  val nameCount: Map[String, Int] = newMap()
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var fi = 0
    while fi < u.fns.count {
      val key = u.pkgName + "." + u.fns[fi].name
      val prior = match mapGet(nameCount, key) { case Some(c) -> c; case None -> 0 }
      if nameCount.containsKey(key) {
        nameCount.remove(key)
      }
      nameCount.add(key, prior + 1)
      fi = fi + 1
    }
    ui = ui + 1
  }
  var ui2 = 0
  while ui2 < units.count {
    val u = units[ui2]
    var fi = 0
    while fi < u.fns.count {
      val fn = u.fns[fi]
      val groupKey = u.pkgName + "." + fn.name
      val overloaded = match mapGet(nameCount, groupKey) { case Some(c) -> c > 1; case None -> false }
      val arity = fn.params.count
      val sig = NFuncSig(
        irName = irNameFor(u.pkgName, fn.name, arity, overloaded),
        pkg = u.pkgName,
        paramNames = paramNamesOf(fn.params),
        paramTys = paramTysOf(fn.params),
        retTy = fn.ret,
        isExternSym = false
      )
      addSig(sigs, u.pkgName + "." + fn.name + "/" + arity.toString(), sig)
      addSig(sigs, fn.name + "/" + arity.toString(), sig)
      fi = fi + 1
    }
    var ei = 0
    while ei < u.externs.count {
      val ef = u.externs[ei]
      val arity = ef.params.count
      val sig = NFuncSig(
        irName = ef.symbol,
        pkg = u.pkgName,
        paramNames = paramNamesOf(ef.params),
        paramTys = paramTysOf(ef.params),
        retTy = ef.ret,
        isExternSym = true
      )
      addSig(sigs, u.pkgName + "." + ef.name + "/" + arity.toString(), sig)
      addSig(sigs, ef.name + "/" + arity.toString(), sig)
      ei = ei + 1
    }
    ui2 = ui2 + 1
  }
  sigs
}

/// The registry key for a call target, or "" when the callee shape is
/// not a static function reference.  Exported so the bridge's
/// reachability walk resolves call sites identically to the codegen.
pub func callKeyOf(fnExpr: in Expr, argc: in Int): String {
  val inner = match fnExpr.kind { case ETypeApp(f, _) -> f; case _ -> fnExpr }
  match inner.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        ""
      } else {
        modulePathJoin(path.segments) + "/" + argc.toString()
      }
    }
    case EMember(recv, memberName) -> {
      match recv.kind {
        case EPath(rpath) -> modulePathJoin(rpath.segments) + "." + memberName + "/" + argc.toString()
        case _ -> ""
      }
    }
    case _ -> ""
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. String literal globals and runtime helpers.
// ─────────────────────────────────────────────────────────────────────────────
/// Emit (once) the static `LyricString` global for `text` and return an
/// NVal of String type referencing it via bitcast.
func emitStringLiteral(ctx: in Ctx, insns: in List[NInsn], text: in String): NVal {
  val bytes = Encoding.encodeUtf8(text)
  val n = bytes.length
  val idx = ctx.strTicker.count
  ctx.strTicker.add(0)
  val gname = ".strobj." + idx.toString()
  // Data carries a trailing NUL (len excludes it) so debuggers and
  // lyric_string_to_cstring fast paths see C-friendly bytes.
  val tyStr = "{ i32, i8*, i64, i64, [" + (n + 1).toString() + " x i8] }"
  val initStr = "{ i32 2147483647, i8* null, i64 " + n.toString() + ", i64 " + (n + 1).toString() + ", [" +
    (n + 1).toString() +
    " x i8] c\"" +
    escapeIrBytes(bytes) +
    "\\00\" }"
  ctx.globals.add(
    NGlobalDef(name = gname, linkage = "private unnamed_addr constant", tyStr = tyStr, initStr = initStr, align = 8)
  )
  val dest = freshTmp(ctx)
  // The global's own type is the anonymous literal struct (header +
  // inline data array); bitcast to %LyricString* for uniform call sites.
  val litFields: List[NType] = newList()
  litFields.add(NI32)
  litFields.add(NPtr(pointee = NI8))
  litFields.add(NI64)
  litFields.add(NI64)
  litFields.add(NArray(elem = NI8, size = n + 1))
  insns.add(
    NBitcast(
      dest = dest,
      fromTy = NPtr(pointee = NLitStruct(fields = litFields)),
      value = NGlobal(name = gname),
      toTy = lyricStringNType()
    )
  )
  NVal(ty = lyricStringNType(), value = NLocal(name = dest))
}

/// Emit a raw NUL-terminated `[N x i8]` c-string global (no LyricString
/// header) and return an i8* to its first byte.  Used for panic
/// file/message operands.
func emitRawCString(ctx: in Ctx, insns: in List[NInsn], text: in String): NVal {
  val bytes = Encoding.encodeUtf8(text)
  val n = bytes.length
  val idx = ctx.strTicker.count
  ctx.strTicker.add(0)
  val gname = ".cstr." + idx.toString()
  val tyStr = "[" + (n + 1).toString() + " x i8]"
  val initStr = "c\"" + escapeIrBytes(bytes) + "\\00\""
  ctx.globals.add(
    NGlobalDef(name = gname, linkage = "private unnamed_addr constant", tyStr = tyStr, initStr = initStr, align = 1)
  )
  val dest = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = dest,
      fromTy = NPtr(pointee = NArray(elem = NI8, size = n + 1)),
      value = NGlobal(name = gname),
      toTy = NPtr(pointee = NI8)
    )
  )
  NVal(ty = NPtr(pointee = NI8), value = NLocal(name = dest))
}

/// Emit `lyric_panic_msg(msg, file, line)` + `unreachable`, then open a
/// fresh dead block so the current block stays well-formed.
func emitPanicRaw(ctx: in Ctx, insns: in List[NInsn], msg: in String, line: in Int): Unit {
  val msgPtr = emitRawCString(ctx, insns, msg)
  val filePtr = emitRawCString(ctx, insns, ctx.mainPkg)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NPtr(pointee = NI8), value = msgPtr.value))
  args.add(NArg(ty = NPtr(pointee = NI8), value = filePtr.value))
  args.add(NArg(ty = NI32, value = NLitInt(v = intToLong(line), ty = NI32)))
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = args))
  insns.add(NUnreachable)
  insns.add(NLabel(name = freshLabel(ctx, "dead")))
}

func intToLong(v: in Int): Long {
  v.toLong()
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Locals.
// ─────────────────────────────────────────────────────────────────────────────
/// Create a hoisted alloca slot for `name` and store `v` into it.
func bindLocal(ctx: in Ctx, insns: in List[NInsn], name: in String, v: in NVal): Unit {
  match v.ty {
    case NVoid -> {
      // A Unit binding owns no storage; record the type so reads of the
      // name yield Unit.
      if ctx.varTypes.containsKey(name) {
        ctx.varTypes.remove(name)
      }
      ctx.varTypes.add(name, NVoid)
    }
    case _ -> {
      // ARC Rule 4: the binding takes ownership — owned temps transfer,
      // borrows are retained; the owning scope releases on exit.
      if isRefNType(v.ty) {
        ensureOwned(ctx, insns, v)
      }
      val slot = name + ".slot." + freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = slot, ty = v.ty))
      insns.add(NStore(ty = v.ty, value = v.value, ptr = NLocal(name = slot)))
      if ctx.varSlots.containsKey(name) {
        ctx.varSlots.remove(name)
      }
      ctx.varSlots.add(name, slot)
      if ctx.varTypes.containsKey(name) {
        ctx.varTypes.remove(name)
      }
      ctx.varTypes.add(name, v.ty)
      if isRefNType(v.ty) and ctx.scopeRefs.count > 0 {
        ctx.scopeRefs[ctx.scopeRefs.count - 1].add(NOwnedLocal(slot = slot, ty = v.ty))
      }
    }
  }
}

func loadLocal(ctx: in Ctx, insns: in List[NInsn], name: in String): NVal {
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: unknown name '" + name + "' (module-level constants and non-local references are not yet supported for --target native)")
  }
  match ty {
    case NVoid -> NVal(ty = NVoid, value = NUndef(ty = NVoid))
    case _ -> {
      val slot = match mapGet(ctx.varSlots, name) {
        case Some(s) -> s
        case None -> panic("Lyric.LlvmCodegen: no storage slot for '" + name + "'")
      }
      val dest = freshTmp(ctx)
      insns.add(NLoad(dest = dest, ty = ty, ptr = NLocal(name = slot)))
      NVal(ty = ty, value = NLocal(name = dest))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Numeric helpers.
// ─────────────────────────────────────────────────────────────────────────────
func isIntNType(t: in NType): Bool {
  match t {
    case NI32 -> true
    case NI64 -> true
    case NI8 -> true
    case NI1 -> true
    case _ -> false
  }
}

/// Unify the operand types of a binary op: identical types pass; a
/// literal adapts to the other side's width.  Anything else is a
/// codegen error (the type checker rejects it upstream).
func unifyOperands(a: in NVal, b: in NVal): NType {
  val sameKind = nTypeToIrString(a.ty) == nTypeToIrString(b.ty)
  if sameKind {
    return a.ty
  }
  match a.value {
    case NLitInt(_, _) -> {
      if isIntNType(b.ty) {
        return b.ty
      }
    }
    case _ -> {
    }
  }
  match b.value {
    case NLitInt(_, _) -> {
      if isIntNType(a.ty) {
        return a.ty
      }
    }
    case _ -> {
    }
  }
  panic(
    "Lyric.LlvmCodegen: mixed operand types '" + nTypeToIrString(a.ty) + "' and '" + nTypeToIrString(b.ty) +
      "' (insert an explicit conversion such as .toLong()/.toFloat())"
  )
}

/// Emit the checked-division guard: panics at runtime on division by
/// zero and on the two's-complement MIN/-1 overflow, matching the
/// managed targets' exception semantics (LLVM sdiv would be UB).
func emitDivGuard(ctx: in Ctx, insns: in List[NInsn], ty: in NType, a: in NValue, b: in NValue, line: in Int): Unit {
  val minLit = match ty {
    case NI64 -> NLitInt(v = -9223372036854775807i64 - 1i64, ty = NI64)
    case _ -> NLitInt(v = -2147483648i64, ty = NI32)
  }
  val zeroCmp = freshTmp(ctx)
  insns.add(NICmp(dest = zeroCmp, pred = IEq, ty = ty, a = b, b = NLitInt(v = 0i64, ty = ty)))
  val minCmp = freshTmp(ctx)
  insns.add(NICmp(dest = minCmp, pred = IEq, ty = ty, a = a, b = minLit))
  val negOneCmp = freshTmp(ctx)
  insns.add(NICmp(dest = negOneCmp, pred = IEq, ty = ty, a = b, b = NLitInt(v = -1i64, ty = ty)))
  val ovf = freshTmp(ctx)
  insns.add(NAnd(dest = ovf, ty = NI1, a = NLocal(name = minCmp), b = NLocal(name = negOneCmp)))
  val bad = freshTmp(ctx)
  insns.add(NOr(dest = bad, ty = NI1, a = NLocal(name = zeroCmp), b = NLocal(name = ovf)))
  val trapL = freshLabel(ctx, "div.trap")
  val okL = freshLabel(ctx, "div.ok")
  insns.add(NCondBr(cond = NLocal(name = bad), thenLabel = trapL, elseLabel = okL))
  insns.add(NLabel(name = trapL))
  emitPanicRaw(ctx, insns, "integer division by zero or overflow", line)
  insns.add(NBr(label = okL))
  insns.add(NLabel(name = okL))
}

/// Division guard for unsigned widths (Byte): only division by zero can
/// trap — there is no MIN / -1 overflow case (#4628).
func emitDivZeroGuard(ctx: in Ctx, insns: in List[NInsn], ty: in NType, b: in NValue, line: in Int): Unit {
  val zeroCmp = freshTmp(ctx)
  insns.add(NICmp(dest = zeroCmp, pred = IEq, ty = ty, a = b, b = NLitInt(v = 0i64, ty = ty)))
  val trapL = freshLabel(ctx, "div.trap")
  val okL = freshLabel(ctx, "div.ok")
  insns.add(NCondBr(cond = NLocal(name = zeroCmp), thenLabel = trapL, elseLabel = okL))
  insns.add(NLabel(name = trapL))
  emitPanicRaw(ctx, insns, "integer division by zero", line)
  insns.add(NBr(label = okL))
  insns.add(NLabel(name = okL))
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Runtime call helper.
// ─────────────────────────────────────────────────────────────────────────────
func callRuntime(ctx: in Ctx, insns: in List[NInsn], sym: in String, retTy: in NType, args: in List[NArg]): NVal {
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NGlobal(name = sym), args = args))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sym), args = args))
      val outV = NVal(ty = retTy, value = NLocal(name = dest))
      // ARC Rule 6: a ref-returning call transfers ownership here.
      registerTemp(ctx, outV)
      outV
    }
  }
}

func arg1(ty: in NType, v: in NValue): List[NArg] {
  val args: List[NArg] = newList()
  args.add(NArg(ty = ty, value = v))
  args
}

func arg2(ty1: in NType, v1: in NValue, ty2: in NType, v2: in NValue): List[NArg] {
  val args: List[NArg] = newList()
  args.add(NArg(ty = ty1, value = v1))
  args.add(NArg(ty = ty2, value = v2))
  args
}

/// `.toString()` lowering for every scalar (and identity on String).
func emitToString(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  match v.ty {
    case NI32 -> {
      val wide = freshTmp(ctx)
      insns.add(NSExt(dest = wide, fromTy = NI32, value = v.value, toTy = NI64))
      callRuntime(ctx, insns, "lyric_string_from_int", lyricStringNType(), arg1(NI64, NLocal(name = wide)))
    }
    case NI64 -> callRuntime(ctx, insns, "lyric_string_from_int", lyricStringNType(), arg1(NI64, v.value))
    case NI8 -> {
      val wide = freshTmp(ctx)
      insns.add(NZExt(dest = wide, fromTy = NI8, value = v.value, toTy = NI64))
      callRuntime(ctx, insns, "lyric_string_from_int", lyricStringNType(), arg1(NI64, NLocal(name = wide)))
    }
    case NI1 -> callRuntime(ctx, insns, "lyric_string_from_bool", lyricStringNType(), arg1(NI32, widenBoolToI32(ctx, insns, v.value)))
    case NDouble -> callRuntime(ctx, insns, "lyric_string_from_float", lyricStringNType(), arg1(NDouble, v.value))
    case _ -> {
      if isStringNType(v.ty) {
        return v
      }
      panic("Lyric.LlvmCodegen: .toString() on this type is not yet supported for --target native (Phase N1)")
    }
  }
}

func widenBoolToI32(ctx: in Ctx, insns: in List[NInsn], v: in NValue): NValue {
  val dest = freshTmp(ctx)
  insns.add(NZExt(dest = dest, fromTy = NI1, value = v, toTy = NI32))
  NLocal(name = dest)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerExpr(ctx: in Ctx, insns: in List[NInsn], expr: in Expr): NVal {
  match expr.kind {
    case ELiteral(lit) -> lowerLiteral(ctx, insns, lit)
    case EInterpolated(segments) -> lowerInterpolated(ctx, insns, segments)
    case EPath(path) -> {
      val joined = modulePathJoin(path.segments)
      if path.segments.count == 1 {
        if ctx.varTypes.containsKey(path.segments[0]) {
          return loadLocal(ctx, insns, path.segments[0])
        }
      }
      // Nullary union case (`None`, `Option.None`) constructs an
      // instance; enum case paths (`Color.Red`) are i32 discriminants.
      match mapGet(ctx.caseRefs, joined) {
        case Some(cref) -> {
          val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
            case Some(u) -> u
            case None -> panic("Lyric.LlvmCodegen: internal — case '" + joined + "' references unregistered union")
          }
          if ui.cases[cref.caseIdx].fieldNames.count > 0 {
            panic("Lyric.LlvmCodegen: union case '" + joined + "' requires arguments")
          }
          val noArgs: List[CallArg] = newList()
          return lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, noArgs)
        }
        case None -> {
        }
      }
      match mapGet(ctx.enumDefs, joined) {
        case Some(idx) -> {
          if not Str.endsWith(joined, ".__enum") {
            return NVal(ty = NI32, value = NLitInt(v = intToLong(idx), ty = NI32))
          }
        }
        case None -> {
        }
      }
      if path.segments.count == 1 {
        return loadLocal(ctx, insns, path.segments[0])
      }
      panic(
        "Lyric.LlvmCodegen: qualified value reference '" + joined +
          "' is not yet supported for --target native (module-level constants are Phase N2+)"
      )
    }
    case EParen(inner) -> lowerExpr(ctx, insns, inner)
    case EIf(cond, thenBranch, elseBranch, _) -> lowerIf(ctx, insns, cond, thenBranch, elseBranch)
    case ECall(fn, args) -> lowerCall(ctx, insns, fn, args, expr.span.startPos.line)
    case EMember(receiver, memberName) -> lowerMember(ctx, insns, receiver, memberName)
    case EPrefix(op, operand) -> lowerPrefix(ctx, insns, op, operand)
    case EBinop(op, lhs, rhs) -> lowerBinop(ctx, insns, op, lhs, rhs, expr.span.startPos.line)
    case EBlock(block) -> lowerBlockValue(ctx, insns, block)
    case EAssign(target, op, value) -> {
      lowerAssign(ctx, insns, target, op, value, expr.span.startPos.line)
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case EMatch(scrutinee, arms) -> lowerMatch(ctx, insns, scrutinee, arms, expr.span.startPos.line)
    // `self` in a record-method body is the desugared receiver param.
    case ESelf -> loadLocal(ctx, insns, "self")
    case ELambda(_, _) -> panic("Lyric.LlvmCodegen: lambdas are not yet supported for --target native (closures are Phase N2)")
    case ETuple(_) -> panic("Lyric.LlvmCodegen: tuples are not yet supported for --target native (Phase N3)")
    case EList(_) -> panic("Lyric.LlvmCodegen: list literals are not yet supported for --target native (collections are Phase N2/N5)")
    case EIndex(_, _) -> panic("Lyric.LlvmCodegen: indexing is not yet supported for --target native (Phase N2)")
    case _ -> panic("Lyric.LlvmCodegen: this expression form is not yet supported for --target native (Phase N1)")
  }
}

func lowerLiteral(ctx: in Ctx, insns: in List[NInsn], lit: in Literal): NVal {
  match lit {
    case LInt(v, suffix, _) -> {
      val isLong = match suffix { case I64 -> true; case U64 -> true; case _ -> v < -2147483648i64 or v > 2147483647i64 }
      if isLong {
        NVal(ty = NI64, value = NLitInt(v = v, ty = NI64))
      } else {
        NVal(ty = NI32, value = NLitInt(v = v, ty = NI32))
      }
    }
    case LFloat(v, _, _) -> NVal(ty = NDouble, value = NLitFloat(v = v))
    case LChar(codepoint) -> NVal(ty = NI32, value = NLitInt(v = codepoint.toLong(), ty = NI32))
    case LString(text) -> emitStringLiteral(ctx, insns, text)
    case LTripleString(text) -> emitStringLiteral(ctx, insns, text)
    case LRawString(text) -> emitStringLiteral(ctx, insns, text)
    case LBool(value) -> {
      if value {
        NVal(ty = NI1, value = NLitInt(v = 1i64, ty = NI1))
      } else {
        NVal(ty = NI1, value = NLitInt(v = 0i64, ty = NI1))
      }
    }
    case LUnit -> NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
}

func lowerInterpolated(ctx: in Ctx, insns: in List[NInsn], segments: in List[InterpolatedSegment]): NVal {
  var acc = emitStringLiteral(ctx, insns, "")
  var first = true
  var i = 0
  while i < segments.count {
    val seg = segments[i]
    val piece = match seg {
      case ISText(text, _) -> emitStringLiteral(ctx, insns, text)
      case ISExpr(ex) -> emitToString(ctx, insns, lowerExpr(ctx, insns, ex))
    }
    if first {
      acc = piece
      first = false
    } else {
      acc = callRuntime(
        ctx,
        insns,
        "lyric_string_concat",
        lyricStringNType(),
        arg2(lyricStringNType(), acc.value, lyricStringNType(), piece.value)
      )
    }
    i = i + 1
  }
  acc
}

func lowerPrefix(ctx: in Ctx, insns: in List[NInsn], op: in PrefixOp, operand: in Expr): NVal {
  val v = lowerExpr(ctx, insns, operand)
  match op {
    case PreNeg -> {
      match v.ty {
        case NDouble -> {
          val dest = freshTmp(ctx)
          insns.add(NFNeg(dest = dest, a = v.value))
          NVal(ty = NDouble, value = NLocal(name = dest))
        }
        case _ -> {
          val dest = freshTmp(ctx)
          insns.add(NSub(dest = dest, ty = v.ty, a = NLitInt(v = 0i64, ty = v.ty), b = v.value))
          NVal(ty = v.ty, value = NLocal(name = dest))
        }
      }
    }
    case PreNot -> {
      val dest = freshTmp(ctx)
      insns.add(NXor(dest = dest, ty = NI1, a = v.value, b = NLitInt(v = 1i64, ty = NI1)))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case PreRef -> panic("Lyric.LlvmCodegen: function references (&f) are not yet supported for --target native (closures are Phase N2)")
  }
}

func binIntOp(
  ctx: in Ctx, insns: in List[NInsn], op: in BinOp, ty: in NType, a: in NValue, b: in NValue, line: in Int
): NVal {
  val dest = freshTmp(ctx)
  match op {
    case BAdd -> insns.add(NAdd(dest = dest, ty = ty, a = a, b = b))
    case BSub -> insns.add(NSub(dest = dest, ty = ty, a = a, b = b))
    case BMul -> insns.add(NMul(dest = dest, ty = ty, a = a, b = b))
    case BDiv -> {
      // Byte is unsigned: udiv, and only the zero check applies (#4628).
      match ty {
        case NI8 -> {
          emitDivZeroGuard(ctx, insns, ty, b, line)
          insns.add(NUDiv(dest = dest, ty = ty, a = a, b = b))
        }
        case _ -> {
          emitDivGuard(ctx, insns, ty, a, b, line)
          insns.add(NSDiv(dest = dest, ty = ty, a = a, b = b))
        }
      }
    }
    case BMod -> {
      match ty {
        case NI8 -> {
          emitDivZeroGuard(ctx, insns, ty, b, line)
          insns.add(NURem(dest = dest, ty = ty, a = a, b = b))
        }
        case _ -> {
          emitDivGuard(ctx, insns, ty, a, b, line)
          insns.add(NSRem(dest = dest, ty = ty, a = a, b = b))
        }
      }
    }
    case _ -> panic("Lyric.LlvmCodegen: unexpected integer binop")
  }
  NVal(ty = ty, value = NLocal(name = dest))
}

func binFloatOp(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, a: in NValue, b: in NValue): NVal {
  val dest = freshTmp(ctx)
  match op {
    case BAdd -> insns.add(NFAdd(dest = dest, a = a, b = b))
    case BSub -> insns.add(NFSub(dest = dest, a = a, b = b))
    case BMul -> insns.add(NFMul(dest = dest, a = a, b = b))
    case BDiv -> insns.add(NFDiv(dest = dest, a = a, b = b))
    case BMod -> insns.add(NFRem(dest = dest, a = a, b = b))
    case _ -> panic("Lyric.LlvmCodegen: unexpected float binop")
  }
  NVal(ty = NDouble, value = NLocal(name = dest))
}

func icmpPredFor(op: in BinOp): ICmpPred {
  match op {
    case BEq -> IEq
    case BNeq -> INe
    case BLt -> ISlt
    case BLte -> ISle
    case BGt -> ISgt
    case BGte -> ISge
    case _ -> panic("Lyric.LlvmCodegen: unexpected comparison op")
  }
}

/// Byte comparisons use the unsigned predicates (#4628).
func icmpPredForUnsigned(op: in BinOp): ICmpPred {
  match op {
    case BEq -> IEq
    case BNeq -> INe
    case BLt -> IUlt
    case BLte -> IUle
    case BGt -> IUgt
    case BGte -> IUge
    case _ -> panic("Lyric.LlvmCodegen: unexpected comparison op")
  }
}

func fcmpPredFor(op: in BinOp): FCmpPred {
  match op {
    case BEq -> FOeq
    case BNeq -> FUne
    case BLt -> FOlt
    case BLte -> FOle
    case BGt -> FOgt
    case BGte -> FOge
    case _ -> panic("Lyric.LlvmCodegen: unexpected float comparison op")
  }
}

func isComparisonOp(op: in BinOp): Bool {
  match op {
    case BEq -> true
    case BNeq -> true
    case BLt -> true
    case BLte -> true
    case BGt -> true
    case BGte -> true
    case _ -> false
  }
}

func lowerBinop(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, lhs: in Expr, rhs: in Expr, line: in Int): NVal {
  // Short-circuit boolean forms first (rhs must not evaluate eagerly).
  match op {
    case BAnd -> return lowerShortCircuit(ctx, insns, lhs, rhs, true)
    case BOr -> return lowerShortCircuit(ctx, insns, lhs, rhs, false)
    case _ -> {
    }
  }
  val a = lowerExpr(ctx, insns, lhs)
  val b = lowerExpr(ctx, insns, rhs)
  if isStringNType(a.ty) or isStringNType(b.ty) {
    return lowerStringBinop(ctx, insns, op, a, b)
  }
  if isComparisonOp(op) {
    match unifyOperands(a, b) {
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFCmp(dest = dest, pred = fcmpPredFor(op), a = a.value, b = b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NICmp(dest = dest, pred = icmpPredForUnsigned(op), ty = NI8, a = a.value, b = b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
      case ty -> {
        val dest = freshTmp(ctx)
        insns.add(NICmp(dest = dest, pred = icmpPredFor(op), ty = ty, a = a.value, b = b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
    }
  }
  match op {
    case BXor -> {
      val ty = unifyOperands(a, b)
      val dest = freshTmp(ctx)
      insns.add(NXor(dest = dest, ty = ty, a = a.value, b = b.value))
      return NVal(ty = ty, value = NLocal(name = dest))
    }
    case _ -> {
    }
  }
  match unifyOperands(a, b) {
    case NDouble -> binFloatOp(ctx, insns, op, a.value, b.value)
    case ty -> binIntOp(ctx, insns, op, ty, a.value, b.value, line)
  }
}

func lowerStringBinop(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, a: in NVal, b: in NVal): NVal {
  if not (isStringNType(a.ty) and isStringNType(b.ty)) {
    panic("Lyric.LlvmCodegen: mixed String/non-String operands (call .toString() explicitly)")
  }
  val sTy = lyricStringNType()
  match op {
    case BAdd -> callRuntime(ctx, insns, "lyric_string_concat", sTy, arg2(sTy, a.value, sTy, b.value))
    case BEq -> {
      val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sTy, a.value, sTy, b.value))
      val dest = freshTmp(ctx)
      insns.add(NICmp(dest = dest, pred = INe, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case BNeq -> {
      val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sTy, a.value, sTy, b.value))
      val dest = freshTmp(ctx)
      insns.add(NICmp(dest = dest, pred = IEq, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case BLt -> stringCmpTo(ctx, insns, a, b, ISlt)
    case BLte -> stringCmpTo(ctx, insns, a, b, ISle)
    case BGt -> stringCmpTo(ctx, insns, a, b, ISgt)
    case BGte -> stringCmpTo(ctx, insns, a, b, ISge)
    case _ -> panic("Lyric.LlvmCodegen: this String operator is not yet supported for --target native")
  }
}

func stringCmpTo(ctx: in Ctx, insns: in List[NInsn], a: in NVal, b: in NVal, pred: in ICmpPred): NVal {
  val sTy = lyricStringNType()
  val c = callRuntime(ctx, insns, "lyric_string_cmp", NI32, arg2(sTy, a.value, sTy, b.value))
  val dest = freshTmp(ctx)
  insns.add(NICmp(dest = dest, pred = pred, ty = NI32, a = c.value, b = NLitInt(v = 0i64, ty = NI32)))
  NVal(ty = NI1, value = NLocal(name = dest))
}

/// Short-circuit `and`/`or` through a temp slot: the right operand only
/// evaluates when the left one does not decide the result.
func lowerShortCircuit(ctx: in Ctx, insns: in List[NInsn], lhs: in Expr, rhs: in Expr, isAnd: in Bool): NVal {
  val slot = "sc.slot." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = slot, ty = NI1))
  val a = lowerExpr(ctx, insns, lhs)
  insns.add(NStore(ty = NI1, value = a.value, ptr = NLocal(name = slot)))
  val evalL = freshLabel(ctx, "sc.rhs")
  val doneL = freshLabel(ctx, "sc.done")
  if isAnd {
    insns.add(NCondBr(cond = a.value, thenLabel = evalL, elseLabel = doneL))
  } else {
    insns.add(NCondBr(cond = a.value, thenLabel = doneL, elseLabel = evalL))
  }
  insns.add(NLabel(name = evalL))
  val b = lowerExpr(ctx, insns, rhs)
  insns.add(NStore(ty = NI1, value = b.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = doneL))
  insns.add(NLabel(name = doneL))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = NI1, ptr = NLocal(name = slot)))
  NVal(ty = NI1, value = NLocal(name = dest))
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Member access and scalar methods.
// ─────────────────────────────────────────────────────────────────────────────
func lowerMember(ctx: in Ctx, insns: in List[NInsn], receiver: in Expr, memberName: in String): NVal {
  // `Color.Red` / `MaybeStr.Nothing` parse as member access on a type
  // path, not a multi-segment EPath: resolve enum cases and nullary
  // union cases before treating the receiver as a value.
  if isPackagePathExpr(ctx, receiver) {
    match receiver.kind {
      case EPath(rpath) -> {
        val joined = modulePathJoin(rpath.segments) + "." + memberName
        match mapGet(ctx.enumDefs, joined) {
          case Some(idx) -> return NVal(ty = NI32, value = NLitInt(v = intToLong(idx), ty = NI32))
          case None -> {
          }
        }
        match mapGet(ctx.caseRefs, joined) {
          case Some(cref) -> {
            val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
              case Some(u) -> u
              case None -> panic("Lyric.LlvmCodegen: internal — case '" + joined + "' references unregistered union")
            }
            if ui.cases[cref.caseIdx].fieldNames.count > 0 {
              panic("Lyric.LlvmCodegen: union case '" + joined + "' requires arguments")
            }
            val noArgs: List[CallArg] = newList()
            return lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, noArgs)
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
  }
  val v = lowerExpr(ctx, insns, receiver)
  if isStringNType(v.ty) {
    if memberName == "length" {
      val n = callRuntime(ctx, insns, "lyric_string_len", NI64, arg1(lyricStringNType(), v.value))
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
      return NVal(ty = NI32, value = NLocal(name = dest))
    }
    panic("Lyric.LlvmCodegen: String member '." + memberName + "' is not yet supported for --target native (Phase N1)")
  }
  // Record field access: GEP + load (a borrow — the record keeps
  // ownership of the field value).
  match recInfoOfType(ctx, v.ty) {
    case Some(ri) -> return lowerRecordFieldLoad(ctx, insns, ri, v, memberName)
    case None -> {
    }
  }
  // Distinct types share their underlying representation, so `.value`
  // is the identity.  Record fields shadow this (checked above).
  if memberName == "value" {
    return v
  }
  panic(
    "Lyric.LlvmCodegen: member access '." + memberName +
      "' is not yet supported for --target native (this receiver has no such field)"
  )
}

func recFieldIndex(ri: in NRecInfo, fieldName: in String): Int {
  var i = 0
  while i < ri.fieldNames.count {
    if ri.fieldNames[i] == fieldName {
      return i
    }
    i = i + 1
  }
  0 - 1
}

func lowerRecordFieldLoad(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, v: in NVal, fieldName: in String): NVal {
  val idx = recFieldIndex(ri, fieldName)
  if idx < 0 {
    panic("Lyric.LlvmCodegen: record '" + ri.irName + "' has no field '" + fieldName + "'")
  }
  val structTy = match v.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + idx), ty = NI32)))
  insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = v.value, indices = fArgs))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = ri.fieldTys[idx], ptr = NLocal(name = fieldPtr)))
  NVal(ty = ri.fieldTys[idx], value = NLocal(name = dest))
}

/// Scalar method-call receivers: `.and/.or/.xor/.shl/.shr`, the
/// conversion family, `.toString()`, and String's `.substring`.
/// Returns None when `name` is not a scalar method (the caller then
/// resolves it as a UFCS function call).
func lowerScalarMethodCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  v: in NVal,
  name: in String,
  args: in List[CallArg],
  line: in Int,
): Option[NVal] {
  if isStringNType(v.ty) {
    if name == "toString" and args.count == 0 {
      return Some(value = v)
    }
    if name == "substring" and args.count == 2 {
      val a0 = lowerPositionalArg(ctx, insns, args, 0)
      val a1 = lowerPositionalArg(ctx, insns, args, 1)
      val startW = freshTmp(ctx)
      insns.add(NSExt(dest = startW, fromTy = NI32, value = a0.value, toTy = NI64))
      val lenW = freshTmp(ctx)
      insns.add(NSExt(dest = lenW, fromTy = NI32, value = a1.value, toTy = NI64))
      val callArgs: List[NArg] = newList()
      callArgs.add(NArg(ty = lyricStringNType(), value = v.value))
      callArgs.add(NArg(ty = NI64, value = NLocal(name = startW)))
      callArgs.add(NArg(ty = NI64, value = NLocal(name = lenW)))
      return Some(value = callRuntime(ctx, insns, "lyric_string_substring", lyricStringNType(), callArgs))
    }
    return None
  }
  if name == "toString" and args.count == 0 {
    return Some(value = emitToString(ctx, insns, v))
  }
  if name == "toLong" and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NSExt(dest = dest, fromTy = NI32, value = v.value, toTy = NI64))
        return Some(value = NVal(ty = NI64, value = NLocal(name = dest)))
      }
      case NI64 -> return Some(value = v)
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI64))
        return Some(value = NVal(ty = NI64, value = NLocal(name = dest)))
      }
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFPToSI(dest = dest, fromTy = NDouble, value = v.value, toTy = NI64))
        return Some(value = NVal(ty = NI64, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if name == "toInt" and args.count == 0 {
    match v.ty {
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case NI32 -> return Some(value = v)
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFPToSI(dest = dest, fromTy = NDouble, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if (name == "toFloat" or name == "toDouble") and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI32, value = v.value, toTy = NDouble))
        return Some(value = NVal(ty = NDouble, value = NLocal(name = dest)))
      }
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI64, value = v.value, toTy = NDouble))
        return Some(value = NVal(ty = NDouble, value = NLocal(name = dest)))
      }
      case NDouble -> return Some(value = v)
      case _ -> {
      }
    }
  }
  if name == "toByte" and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI32, value = v.value, toTy = NI8))
        return Some(value = NVal(ty = NI8, value = NLocal(name = dest)))
      }
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = v.value, toTy = NI8))
        return Some(value = NVal(ty = NI8, value = NLocal(name = dest)))
      }
      case NI8 -> return Some(value = v)
      case _ -> {
      }
    }
  }
  if name == "toChar" and args.count == 0 {
    match v.ty {
      case NI32 -> return Some(value = v)
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if args.count == 1 and (name == "and" or name == "or" or name == "xor" or name == "shl" or name == "shr") {
    val b = lowerPositionalArg(ctx, insns, args, 0)
    val ty = v.ty
    val bv = if name == "shl" or name == "shr" {
      // Shift amounts are Int in the surface language; widen/narrow to
      // the operand width (LLVM requires matching shift types).
      coerceShiftAmount(ctx, insns, ty, b)
    } else {
      b.value
    }
    val dest = freshTmp(ctx)
    if name == "and" {
      insns.add(NAnd(dest = dest, ty = ty, a = v.value, b = bv))
    } else if name == "or" {
      insns.add(NOr(dest = dest, ty = ty, a = v.value, b = bv))
    } else if name == "xor" {
      insns.add(NXor(dest = dest, ty = ty, a = v.value, b = bv))
    } else if name == "shl" {
      insns.add(NShl(dest = dest, ty = ty, a = v.value, b = bv))
    } else {
      // Byte is unsigned (its widenings zero-extend), so its right shift
      // is logical; the signed widths shift arithmetically (#4628).
      match ty {
        case NI8 -> insns.add(NLShr(dest = dest, ty = ty, a = v.value, b = bv))
        case _ -> insns.add(NAShr(dest = dest, ty = ty, a = v.value, b = bv))
      }
    }
    return Some(value = NVal(ty = ty, value = NLocal(name = dest)))
  }
  None
}

func coerceShiftAmount(ctx: in Ctx, insns: in List[NInsn], ty: in NType, amt: in NVal): NValue {
  val sameKind = nTypeToIrString(ty) == nTypeToIrString(amt.ty)
  if sameKind {
    return amt.value
  }
  match amt.value {
    case NLitInt(v, _) -> return NLitInt(v = v, ty = ty)
    case _ -> {
    }
  }
  match ty {
    case NI64 -> {
      val dest = freshTmp(ctx)
      insns.add(NSExt(dest = dest, fromTy = NI32, value = amt.value, toTy = NI64))
      NLocal(name = dest)
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = amt.value, toTy = ty))
      NLocal(name = dest)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Calls.
// ─────────────────────────────────────────────────────────────────────────────
func lowerPositionalArg(ctx: in Ctx, insns: in List[NInsn], args: in List[CallArg], idx: in Int): NVal {
  match args[idx] {
    case CAPositional(ex) -> lowerExpr(ctx, insns, ex)
    case CANamed(_, value, _) -> lowerExpr(ctx, insns, value)
  }
}

func isPackagePathExpr(ctx: in Ctx, e: in Expr): Bool {
  // A member receiver is a package path (not a value) when it is a path
  // whose head is not a local variable.
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        return false
      }
      not ctx.varTypes.containsKey(path.segments[0])
    }
    case _ -> false
  }
}

/// Reorder call arguments to the callee's declared parameter order and
/// lower each.  Positional args bind left-to-right; named args bind by
/// declared name.
func lowerCallArgs(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig, args: in List[CallArg]): List[NArg] {
  if args.count != sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: call to '" + sig.irName + "' passes " + args.count.toString() +
        " argument(s) but the declaration has " +
        sig.paramTys.count.toString() +
        " (default arguments are not yet supported for --target native)"
    )
  }
  // Evaluate in source order first (Lyric's evaluation order), keeping
  // the destination parameter index of each.
  val vals: List[NVal] = newList()
  val slots: List[Int] = newList()
  var i = 0
  var nextPositional = 0
  while i < args.count {
    match args[i] {
      case CAPositional(ex) -> {
        vals.add(lowerExpr(ctx, insns, ex))
        slots.add(nextPositional)
        nextPositional = nextPositional + 1
      }
      case CANamed(argName, value, _) -> {
        var slot = -1
        var pi = 0
        while pi < sig.paramNames.count {
          if sig.paramNames[pi] == argName {
            slot = pi
          }
          pi = pi + 1
        }
        if slot < 0 {
          panic("Lyric.LlvmCodegen: named argument '" + argName + "' does not match a parameter of '" + sig.irName + "'")
        }
        vals.add(lowerExpr(ctx, insns, value))
        slots.add(slot)
      }
    }
    i = i + 1
  }
  val ordered: List[NArg] = newList()
  var pi2 = 0
  while pi2 < sig.paramTys.count {
    var found = -1
    var vi = 0
    while vi < slots.count {
      if slots[vi] == pi2 {
        found = vi
      }
      vi = vi + 1
    }
    if found < 0 {
      panic("Lyric.LlvmCodegen: no argument bound for parameter " + pi2.toString() + " of '" + sig.irName + "'")
    }
    val declTy = typeToN(ctx, sig.paramTys[pi2])
    val v = coerceTo(ctx, insns, vals[found], declTy)
    ordered.add(NArg(ty = declTy, value = v.value))
    pi2 = pi2 + 1
  }
  ordered
}

/// UFCS call-argument lowering: the pre-lowered receiver binds
/// parameter 0; `args` bind the remaining parameters.
func lowerCallArgsWithReceiver(
  ctx: in Ctx,
  insns: in List[NInsn],
  sig: in NFuncSig,
  recv: in NVal,
  args: in List[CallArg],
): List[NArg] {
  if args.count + 1 != sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: method call to '" + sig.irName + "' passes " + (args.count + 1).toString() +
        " argument(s) (incl. receiver) but the declaration has " +
        sig.paramTys.count.toString()
    )
  }
  val ordered: List[NArg] = newList()
  val recvTy = typeToN(ctx, sig.paramTys[0])
  val rv = coerceTo(ctx, insns, recv, recvTy)
  ordered.add(NArg(ty = recvTy, value = rv.value))
  var i = 0
  var nextPositional = 1
  val vals: List[NVal] = newList()
  val slots: List[Int] = newList()
  while i < args.count {
    match args[i] {
      case CAPositional(ex) -> {
        vals.add(lowerExpr(ctx, insns, ex))
        slots.add(nextPositional)
        nextPositional = nextPositional + 1
      }
      case CANamed(argName, value, _) -> {
        var slot = -1
        var pi = 1
        while pi < sig.paramNames.count {
          if sig.paramNames[pi] == argName {
            slot = pi
          }
          pi = pi + 1
        }
        if slot < 0 {
          panic("Lyric.LlvmCodegen: named argument '" + argName + "' does not match a parameter of '" + sig.irName + "'")
        }
        vals.add(lowerExpr(ctx, insns, value))
        slots.add(slot)
      }
    }
    i = i + 1
  }
  var pi2 = 1
  while pi2 < sig.paramTys.count {
    var found = -1
    var vi = 0
    while vi < slots.count {
      if slots[vi] == pi2 {
        found = vi
      }
      vi = vi + 1
    }
    if found < 0 {
      panic("Lyric.LlvmCodegen: no argument bound for parameter " + pi2.toString() + " of '" + sig.irName + "'")
    }
    val declTy = typeToN(ctx, sig.paramTys[pi2])
    val v = coerceTo(ctx, insns, vals[found], declTy)
    ordered.add(NArg(ty = declTy, value = v.value))
    pi2 = pi2 + 1
  }
  ordered
}

/// Adapt a value to the declared type: integer literals retype freely;
/// Int widens to Long implicitly at a declared-Long boundary (matching
/// the managed backends' literal-friendly call sites).  Anything else
/// must already match.
func coerceTo(ctx: in Ctx, insns: in List[NInsn], v: in NVal, want: in NType): NVal {
  val sameKind = nTypeToIrString(v.ty) == nTypeToIrString(want)
  if sameKind {
    return v
  }
  match v.value {
    case NLitInt(litV, _) -> {
      if isIntNType(want) {
        return NVal(ty = want, value = NLitInt(v = litV, ty = want))
      }
      match want {
        case NDouble -> return NVal(ty = NDouble, value = NLitFloat(v = longToDouble(litV)))
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  val fromStr = nTypeToIrString(v.ty)
  val wantStr = nTypeToIrString(want)
  if fromStr == "i32" and wantStr == "i64" {
    val dest = freshTmp(ctx)
    insns.add(NSExt(dest = dest, fromTy = NI32, value = v.value, toTy = NI64))
    return NVal(ty = NI64, value = NLocal(name = dest))
  }
  panic(
    "Lyric.LlvmCodegen: cannot pass a '" + fromStr + "' where '" + wantStr +
      "' is expected (insert an explicit conversion)"
  )
}

func longToDouble(v: in Long): Double {
  v.toDouble()
}

func lowerCall(ctx: in Ctx, insns: in List[NInsn], fnExpr: in Expr, args: in List[CallArg], line: in Int): NVal {
  // Builtins first.
  match fnExpr.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val n = path.segments[0]
        if n == "panic" and args.count == 1 {
          val msg = lowerPositionalArg(ctx, insns, args, 0)
          val cs = callRuntime(ctx, insns, "lyric_string_to_cstring", NPtr(pointee = NI8), arg1(lyricStringNType(), msg.value))
          val filePtr = emitRawCString(ctx, insns, ctx.mainPkg)
          val pArgs: List[NArg] = newList()
          pArgs.add(NArg(ty = NPtr(pointee = NI8), value = cs.value))
          pArgs.add(NArg(ty = NPtr(pointee = NI8), value = filePtr.value))
          pArgs.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
          insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = pArgs))
          insns.add(NUnreachable)
          insns.add(NLabel(name = freshLabel(ctx, "dead")))
          return NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
        if n == "assert" and args.count >= 1 {
          val cond = lowerPositionalArg(ctx, insns, args, 0)
          val okL = freshLabel(ctx, "assert.ok")
          val failL = freshLabel(ctx, "assert.fail")
          insns.add(NCondBr(cond = cond.value, thenLabel = okL, elseLabel = failL))
          insns.add(NLabel(name = failL))
          emitPanicRaw(ctx, insns, "assertion failed", line)
          insns.add(NBr(label = okL))
          insns.add(NLabel(name = okL))
          return NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
      }
    }
    case EMember(receiver, memberName) -> {
      if not isPackagePathExpr(ctx, receiver) {
        val recvVal = lowerExpr(ctx, insns, receiver)
        match lowerScalarMethodCall(ctx, insns, recvVal, memberName, args, line) {
          case Some(v) -> return v
          case None -> return lowerUfcsCall(ctx, insns, recvVal, memberName, args, line)
        }
      }
    }
    case _ -> {
    }
  }
  // Static function call through the registry.
  val key = callKeyOf(fnExpr, args.count)
  if key.length == 0 {
    panic("Lyric.LlvmCodegen: indirect calls are not yet supported for --target native (closures are Phase N2)")
  }
  // Resolution order: self-package qualified, then the key as written,
  // then heap-type constructors (records, union cases, distinct types).
  val selfKey = ctx.curPkg[0] + "." + key
  // var-mutation shape (#4631).
  var sigOpt: Option[NFuncSig] = None
  match mapGet(ctx.sigs, selfKey) {
    case Some(s) -> {
      sigOpt = Some(value = s)
    }
    case None -> {
      sigOpt = mapGet(ctx.sigs, key)
    }
  }
  match sigOpt {
    case Some(sig) -> {
      val callArgs = lowerCallArgs(ctx, insns, sig, args)
      val retTy = retTypeToN(ctx, sig.retTy)
      match retTy {
        case NVoid -> {
          insns.add(NCallVoid(fn = NGlobal(name = sig.irName), args = callArgs))
          NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
        case _ -> {
          val dest = freshTmp(ctx)
          insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sig.irName), args = callArgs))
          val outV = NVal(ty = retTy, value = NLocal(name = dest))
          registerTemp(ctx, outV)
          outV
        }
      }
    }
    case None -> lowerConstructCall(ctx, insns, fnExpr, args, key, line)
  }
}

/// Constructor-call fallback for `lowerCall`: record construction,
/// union-case construction, and distinct-type conversion.
func lowerConstructCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  fnExpr: in Expr,
  args: in List[CallArg],
  key: in String,
  line: in Int,
): NVal {
  val inner = match fnExpr.kind { case ETypeApp(f, _) -> f; case _ -> fnExpr }
  val name = match inner.kind {
    case EPath(path) -> modulePathJoin(path.segments)
    case EMember(recv, memberName) -> {
      match recv.kind {
        case EPath(rpath) -> modulePathJoin(rpath.segments) + "." + memberName
        case _ -> ""
      }
    }
    case _ -> ""
  }
  if name.length > 0 {
    match mapGet(ctx.recordDefs, name) {
      case Some(ri) -> return lowerRecordConstructArgs(ctx, insns, ri, args)
      case None -> {
      }
    }
    match mapGet(ctx.caseRefs, name) {
      case Some(cref) -> {
        val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
          case Some(u) -> u
          case None -> panic("Lyric.LlvmCodegen: internal — case '" + name + "' references unregistered union")
        }
        return lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, args)
      }
      case None -> {
      }
    }
    match mapGet(ctx.distinctDefs, name) {
      case Some(di) -> return lowerDistinctConstruct(ctx, insns, name, di, args, line)
      case None -> {
      }
    }
    // `X.From(v)` distinct-conversion spelling.
    if Str.endsWith(name, ".From") {
      val baseName = Str.substring(name, 0, name.length - 5)
      match mapGet(ctx.distinctDefs, baseName) {
        case Some(di) -> return lowerDistinctConstruct(ctx, insns, baseName, di, args, line)
        case None -> {
        }
      }
    }
  }
  panic(
    "Lyric.LlvmCodegen: cannot resolve call target '" + key +
      "' for --target native (the callee may be outside the bundled import closure)"
  )
}

/// UFCS method-call resolution: `recv.name(args)` calls the function
/// `name` with the receiver as its first argument.  Resolution tries
/// the current package, the receiver type's defining package (methods
/// in type bodies desugar to package functions, D037), then bare names.
func lowerUfcsCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in NVal,
  name: in String,
  args: in List[CallArg],
  line: in Int,
): NVal {
  val arity = (args.count + 1).toString()
  var sigOpt = mapGet(ctx.sigs, ctx.curPkg[0] + "." + name + "/" + arity)
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      match recv.ty {
        case NPtr(pointee) -> {
          match pointee {
            case NStruct(tyName, _) -> {
              val dotIdx = lastDotIndex(tyName)
              if dotIdx > 0 {
                sigOpt = mapGet(ctx.sigs, Str.substring(tyName, 0, dotIdx) + "." + name + "/" + arity)
              }
            }
            case _ -> {
            }
          }
        }
        case _ -> {
        }
      }
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      sigOpt = mapGet(ctx.sigs, name + "/" + arity)
    }
  }
  val sig = match sigOpt {
    case Some(s) -> s
    case None -> panic("Lyric.LlvmCodegen: method '." + name + "' on this receiver is not yet supported for --target native (no matching function '" + name + "/" + arity + "' in the bundled import closure)")
  }
  val callArgs = lowerCallArgsWithReceiver(ctx, insns, sig, recv, args)
  val retTy = retTypeToN(ctx, sig.retTy)
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NGlobal(name = sig.irName), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sig.irName), args = callArgs))
      val outV = NVal(ty = retTy, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
  }
}

func lastDotIndex(s: in String): Int {
  var i = s.length - 1
  while i >= 0 {
    if Str.substring(s, i, 1) == "." {
      return i
    }
    i = i - 1
  }
  0 - 1
}

// ─────────────────────────────────────────────────────────────────────────────
// §10.5. Heap-type registration, destructors, and construction (Phase N2).
// ─────────────────────────────────────────────────────────────────────────────
func addRecKey(ctx: in Ctx, key: in String, ri: in NRecInfo): Unit {
  if not ctx.recordDefs.containsKey(key) {
    ctx.recordDefs.add(key, ri)
  }
}

func replaceRecKey(ctx: in Ctx, key: in String, ri: in NRecInfo): Unit {
  if ctx.recordDefs.containsKey(key) {
    match mapGet(ctx.recordDefs, key) {
      case Some(prior) -> {
        // Only replace the stub for the same declaration (first-wins
        // shadowing across packages must hold for bare names).
        if prior.irName != ri.irName {
          return
        }
      }
      case None -> {
      }
    }
    ctx.recordDefs.remove(key)
  }
  ctx.recordDefs.add(key, ri)
}

func addUnionKey(ctx: in Ctx, key: in String, ui: in NUnionInfo): Unit {
  if not ctx.unionDefs.containsKey(key) {
    ctx.unionDefs.add(key, ui)
  }
}

func replaceUnionKey(ctx: in Ctx, key: in String, ui: in NUnionInfo): Unit {
  if ctx.unionDefs.containsKey(key) {
    match mapGet(ctx.unionDefs, key) {
      case Some(prior) -> {
        if prior.irName != ui.irName {
          return
        }
      }
      case None -> {
      }
    }
    ctx.unionDefs.remove(key)
  }
  ctx.unionDefs.add(key, ui)
}

func recFieldsOf(decl: in RecordDecl): List[FieldDecl] {
  val fields: List[FieldDecl] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> fields.add(f)
      case RMInvariant(_) -> {
      }
      case RMFunc(_) -> {
        // Methods in type bodies desugar to package functions (D037);
        // native lowering of record methods lands with the stdlib port.
      }
    }
    i = i + 1
  }
  fields
}

func unionFieldName(f: in UnionField, idx: in Int): String {
  match f {
    case UFNamed(name, _, _) -> name
    case UFPos(_, _) -> "_" + idx.toString()
  }
}

func unionFieldTy(f: in UnionField): TypeExpr {
  match f {
    case UFNamed(_, ty, _) -> ty
    case UFPos(ty, _) -> ty
  }
}

/// Literal Long value of a range bound expression, or None when the
/// bound is not an integer literal.
func rangeBoundLit(e: in Expr): Option[Long] {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _, _) -> Some(value = v)
        case _ -> None
      }
    }
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          match rangeBoundLit(operand) {
            case Some(v) -> Some(value = 0i64 - v)
            case None -> None
          }
        }
        case _ -> None
      }
    }
    case EParen(inner) -> rangeBoundLit(inner)
    case _ -> None
  }
}

/// Register every non-generic record/union/enum/distinct declaration in
/// the bundle.  Two phases: names first (so pointer-typed fields can
/// reference any registered type, including cyclically), then field
/// layouts, IR type definitions, and synthesised destructors.
func registerHeapTypes(
  ctx: in Ctx, units: in List[CodegenUnit], typeDefs: in List[NTypeDefn], fns: in List[NFunc]
): Unit {
  // Phase A: allocate names.
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var ri = 0
    while ri < u.records.count {
      val rd = u.records[ri]
      match rd.generics {
        case Some(_) -> {
        }
        case None -> {
          val emptyNames: List[String] = newList()
          val emptyTys: List[NType] = newList()
          val emptyDflts: List[Option[Expr]] = newList()
          val stub = NRecInfo(
            irName = u.pkgName + "." + rd.name,
            fieldNames = emptyNames,
            fieldTys = emptyTys,
            fieldDefaults = emptyDflts
          )
          addRecKey(ctx, u.pkgName + "." + rd.name, stub)
          addRecKey(ctx, rd.name, stub)
        }
      }
      ri = ri + 1
    }
    var ci = 0
    while ci < u.unions.count {
      val ud = u.unions[ci]
      match ud.generics {
        case Some(_) -> {
        }
        case None -> {
          val emptyCases: List[NUnionCaseInfo] = newList()
          val stub = NUnionInfo(irName = u.pkgName + "." + ud.name, cases = emptyCases, payloadWords = 0)
          addUnionKey(ctx, u.pkgName + "." + ud.name, stub)
          addUnionKey(ctx, ud.name, stub)
        }
      }
      ci = ci + 1
    }
    var ei = 0
    while ei < u.enums.count {
      val ed = u.enums[ei]
      if not ctx.enumDefs.containsKey(ed.name + ".__enum") {
        ctx.enumDefs.add(ed.name + ".__enum", 0)
      }
      if not ctx.enumDefs.containsKey(u.pkgName + "." + ed.name + ".__enum") {
        ctx.enumDefs.add(u.pkgName + "." + ed.name + ".__enum", 0)
      }
      var eci = 0
      while eci < ed.cases.count {
        val caseKey = ed.name + "." + ed.cases[eci].name
        if not ctx.enumDefs.containsKey(caseKey) {
          ctx.enumDefs.add(caseKey, eci)
        }
        val qKey = u.pkgName + "." + caseKey
        if not ctx.enumDefs.containsKey(qKey) {
          ctx.enumDefs.add(qKey, eci)
        }
        eci = eci + 1
      }
      ei = ei + 1
    }
    ui = ui + 1
  }
  // Phase B: field layouts, case tables, type definitions, destructors.
  // The user package (units[0]) registers strictly (unresolvable field
  // types panic with the precise message); bundled stdlib declarations
  // register tolerantly (skipped so a use, not the bundle, fails).
  var ui2 = 0
  while ui2 < units.count {
    val u = units[ui2]
    val strict = ui2 == 0
    var di = 0
    while di < u.distincts.count {
      val dd = u.distincts[di]
      match dd.generics {
        case Some(_) -> {
        }
        case None -> registerDistinct(ctx, u.pkgName, dd, strict)
      }
      di = di + 1
    }
    var ri = 0
    while ri < u.records.count {
      val rd = u.records[ri]
      match rd.generics {
        case Some(_) -> {
        }
        case None -> registerRecordLayout(ctx, u.pkgName, rd, typeDefs, fns, strict)
      }
      ri = ri + 1
    }
    var ci = 0
    while ci < u.unions.count {
      val ud = u.unions[ci]
      match ud.generics {
        case Some(_) -> {
        }
        case None -> registerUnionLayout(ctx, u.pkgName, ud, typeDefs, fns, strict)
      }
      ci = ci + 1
    }
    ui2 = ui2 + 1
  }
}

func registerDistinct(ctx: in Ctx, pkg: in String, dd: in DistinctTypeDecl, strict: in Bool): Unit {
  var under = NVoid
  var underOk = false
  match typeToNOpt(ctx, dd.underlying) {
    case Some(t) -> {
      under = t
      underOk = true
    }
    case None -> {
    }
  }
  if not underOk {
    if strict {
      // Re-run through the panicking path for the precise message.
      val _ = typeToN(ctx, dd.underlying)
    }
    return
  }
  var hasRange = false
  var lo = 0i64
  var hi = 0i64
  match dd.rangeClause {
    case Some(rb) -> {
      var loExprOpt: Option[Expr] = None
      var hiExprOpt: Option[Expr] = None
      var hiInclusive = true
      var openEnded = false
      match rb {
        case RBClosed(l, h) -> {
          loExprOpt = Some(value = l)
          hiExprOpt = Some(value = h)
        }
        case RBHalfOpen(l, h) -> {
          loExprOpt = Some(value = l)
          hiExprOpt = Some(value = h)
          hiInclusive = false
        }
        case RBLowerOpen(_) -> {
          openEnded = true
        }
        case RBUpperOpen(_) -> {
          openEnded = true
        }
      }
      if openEnded {
        if strict {
          panic("Lyric.LlvmCodegen: range subtype '" + dd.name + "' needs closed literal bounds for --target native")
        }
        return
      }
      // var-mutation shape (#4631: value-position match over Option
      // mis-lowers in the stage-0 seed).
      var loOpt: Option[Long] = None
      match loExprOpt {
        case Some(e) -> {
          loOpt = rangeBoundLit(e)
        }
        case None -> {
        }
      }
      var hiOpt: Option[Long] = None
      match hiExprOpt {
        case Some(e) -> {
          hiOpt = rangeBoundLit(e)
        }
        case None -> {
        }
      }
      var boundsOk = false
      match loOpt {
        case Some(l) -> {
          match hiOpt {
            case Some(h) -> {
              hasRange = true
              boundsOk = true
              lo = l
              hi = if hiInclusive { h } else { h - 1i64 }
            }
            case None -> {
            }
          }
        }
        case None -> {
        }
      }
      if not boundsOk {
        if strict {
          panic("Lyric.LlvmCodegen: range subtype '" + dd.name + "' needs literal bounds for --target native")
        }
        return
      }
    }
    case None -> {
    }
  }
  val info = NDistinctInfo(underlying = under, hasRange = hasRange, lo = lo, hi = hi)
  if not ctx.distinctDefs.containsKey(pkg + "." + dd.name) {
    ctx.distinctDefs.add(pkg + "." + dd.name, info)
  }
  if not ctx.distinctDefs.containsKey(dd.name) {
    ctx.distinctDefs.add(dd.name, info)
  }
}

func recDtorName(ri: in NRecInfo): String {
  ri.irName + ".dtor"
}

func recHasRefFields(ri: in NRecInfo): Bool {
  var i = 0
  while i < ri.fieldTys.count {
    if isRefNType(ri.fieldTys[i]) {
      return true
    }
    i = i + 1
  }
  false
}

/// Drop a stub registration (tolerant mode) so uses of the type fail
/// with the type-resolution message rather than a bad layout.
func unregisterRecStub(ctx: in Ctx, key: in String, irName: in String): Unit {
  match mapGet(ctx.recordDefs, key) {
    case Some(prior) -> {
      if prior.irName == irName {
        ctx.recordDefs.remove(key)
      }
    }
    case None -> {
    }
  }
}

func unregisterUnionStub(ctx: in Ctx, key: in String, irName: in String): Unit {
  match mapGet(ctx.unionDefs, key) {
    case Some(prior) -> {
      if prior.irName == irName {
        ctx.unionDefs.remove(key)
      }
    }
    case None -> {
    }
  }
}

func registerRecordLayout(
  ctx: in Ctx,
  pkg: in String,
  rd: in RecordDecl,
  typeDefs: in List[NTypeDefn],
  fns: in List[NFunc],
  strict: in Bool,
): Unit {
  val fields = recFieldsOf(rd)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
  val irName = pkg + "." + rd.name
  var i = 0
  while i < fields.count {
    names.add(fields[i].name)
    match typeToNOpt(ctx, fields[i].ty) {
      case Some(t) -> tys.add(t)
      case None -> {
        if strict {
          // Panicking path for the precise field-type message.
          tys.add(typeToN(ctx, fields[i].ty))
        } else {
          unregisterRecStub(ctx, irName, irName)
          unregisterRecStub(ctx, rd.name, irName)
          return
        }
      }
    }
    dflts.add(fields[i].dflt)
    i = i + 1
  }
  val ri = NRecInfo(irName = irName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts)
  replaceRecKey(ctx, pkg + "." + rd.name, ri)
  replaceRecKey(ctx, rd.name, ri)
  val defnFields: List[NType] = newList()
  defnFields.add(NI32)
  defnFields.add(NPtr(pointee = NI8))
  var fi = 0
  while fi < tys.count {
    defnFields.add(tys[fi])
    fi = fi + 1
  }
  typeDefs.add(NTypeDefn(name = ri.irName, fields = defnFields))
  if recHasRefFields(ri) {
    fns.add(synthRecordDtor(ctx, ri))
  }
}

func unionDtorName(ui: in NUnionInfo): String {
  ui.irName + ".dtor"
}

func unionHasRefFields(ui: in NUnionInfo): Bool {
  var ci = 0
  while ci < ui.cases.count {
    var fi = 0
    while fi < ui.cases[ci].fieldTys.count {
      if isRefNType(ui.cases[ci].fieldTys[fi]) {
        return true
      }
      fi = fi + 1
    }
    ci = ci + 1
  }
  false
}

func casePayloadStructName(ui: in NUnionInfo, caseName: in String): String {
  ui.irName + "." + caseName
}

func casePayloadStructType(ui: in NUnionInfo, ci: in NUnionCaseInfo): NType {
  NStruct(name = casePayloadStructName(ui, ci.name), fields = ci.fieldTys)
}

func registerUnionLayout(
  ctx: in Ctx,
  pkg: in String,
  ud: in UnionDecl,
  typeDefs: in List[NTypeDefn],
  fns: in List[NFunc],
  strict: in Bool,
): Unit {
  val cases: List[NUnionCaseInfo] = newList()
  val irName = pkg + "." + ud.name
  var maxBytes = 0
  var ci = 0
  while ci < ud.cases.count {
    val cd = ud.cases[ci]
    val names: List[String] = newList()
    val tys: List[NType] = newList()
    var fi = 0
    while fi < cd.fields.count {
      names.add(unionFieldName(cd.fields[fi], fi))
      match typeToNOpt(ctx, unionFieldTy(cd.fields[fi])) {
        case Some(t) -> tys.add(t)
        case None -> {
          if strict {
            tys.add(typeToN(ctx, unionFieldTy(cd.fields[fi])))
          } else {
            unregisterUnionStub(ctx, irName, irName)
            unregisterUnionStub(ctx, ud.name, irName)
            return
          }
        }
      }
      fi = fi + 1
    }
    val sz = structSize(tys)
    if sz > maxBytes {
      maxBytes = sz
    }
    cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    ci = ci + 1
  }
  val words = (maxBytes + 7) / 8
  val ui = NUnionInfo(irName = irName, cases = cases, payloadWords = words)
  replaceUnionKey(ctx, pkg + "." + ud.name, ui)
  replaceUnionKey(ctx, ud.name, ui)
  typeDefs.add(NTypeDefn(name = ui.irName, fields = unionBodyFields(words)))
  var ci2 = 0
  while ci2 < cases.count {
    if cases[ci2].fieldTys.count > 0 {
      typeDefs.add(NTypeDefn(name = casePayloadStructName(ui, cases[ci2].name), fields = cases[ci2].fieldTys))
    }
    // Case-name entries resolve constructor calls and patterns.  The
    // unqualified name mirrors source scoping (first-wins).
    val cref = NCaseRef(unionKey = ui.irName, caseIdx = ci2)
    val bare = cases[ci2].name
    if not ctx.caseRefs.containsKey(bare) {
      ctx.caseRefs.add(bare, cref)
    }
    if not ctx.caseRefs.containsKey(ud.name + "." + bare) {
      ctx.caseRefs.add(ud.name + "." + bare, cref)
    }
    if not ctx.caseRefs.containsKey(pkg + "." + ud.name + "." + bare) {
      ctx.caseRefs.add(pkg + "." + ud.name + "." + bare, cref)
    }
    ci2 = ci2 + 1
  }
  if unionHasRefFields(ui) {
    fns.add(synthUnionDtor(ctx, ui))
  }
}

/// `define internal void @<T>.dtor(i8*)`: release each ref-typed field
/// (ARC Rule 7).  `lyric_release` frees the object afterwards.
func synthRecordDtor(ctx: in Ctx, ri: in NRecInfo): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  body.add(NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = objTy))
  var i = 0
  while i < ri.fieldTys.count {
    if isRefNType(ri.fieldTys[i]) {
      val fieldPtr = freshTmp(ctx)
      val idxArgs: List[NArg] = newList()
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + i), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = idxArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = ri.fieldTys[i], ptr = NLocal(name = fieldPtr)))
      val cast = freshTmp(ctx)
      body.add(NBitcast(dest = cast, fromTy = ri.fieldTys[i], value = NLocal(name = fieldVal), toTy = NPtr(pointee = NI8)))
      body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = cast))))
    }
    i = i + 1
  }
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  NFunc(
    name = recDtorName(ri),
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

/// Union destructor: switch on the discriminant; each ref-carrying case
/// releases its ref fields through the case payload view.
func synthUnionDtor(ctx: in Ctx, ui: in NUnionInfo): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val objTy = unionPtrType(ui)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  body.add(NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = objTy))
  val discPtr = freshTmp(ctx)
  val discArgs: List[NArg] = newList()
  discArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  discArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  body.add(NGEP(dest = discPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = discArgs))
  val disc = freshTmp(ctx)
  body.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  val endL = "dtor.end"
  val switchCases: List[NSwitchCase] = newList()
  val caseLabels: List[String] = newList()
  var ci = 0
  while ci < ui.cases.count {
    var hasRef = false
    var fi = 0
    while fi < ui.cases[ci].fieldTys.count {
      if isRefNType(ui.cases[ci].fieldTys[fi]) {
        hasRef = true
      }
      fi = fi + 1
    }
    if hasRef {
      val label = "dtor.case." + ci.toString()
      caseLabels.add(label)
      switchCases.add(NSwitchCase(matchVal = intToLong(ci), label = label))
    } else {
      caseLabels.add("")
    }
    ci = ci + 1
  }
  body.add(NSwitch(ty = NI32, scrutinee = NLocal(name = disc), defaultLabel = endL, cases = switchCases))
  var ci2 = 0
  while ci2 < ui.cases.count {
    if caseLabels[ci2].length > 0 {
      body.add(NLabel(name = caseLabels[ci2]))
      val payloadPtr = freshTmp(ctx)
      val pArgs: List[NArg] = newList()
      pArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      pArgs.add(NArg(ty = NI32, value = NLitInt(v = 4i64, ty = NI32)))
      body.add(NGEP(dest = payloadPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = pArgs))
      val caseTy = casePayloadStructType(ui, ui.cases[ci2])
      val casePtr = freshTmp(ctx)
      body.add(
        NBitcast(
          dest = casePtr,
          fromTy = NPtr(pointee = NArray(elem = NI64, size = ui.payloadWords)),
          value = NLocal(name = payloadPtr),
          toTy = NPtr(pointee = caseTy)
        )
      )
      var fi = 0
      while fi < ui.cases[ci2].fieldTys.count {
        if isRefNType(ui.cases[ci2].fieldTys[fi]) {
          val fieldPtr = freshTmp(ctx)
          val fArgs: List[NArg] = newList()
          fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
          fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(fi), ty = NI32)))
          body.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
          val fieldVal = freshTmp(ctx)
          body.add(NLoad(dest = fieldVal, ty = ui.cases[ci2].fieldTys[fi], ptr = NLocal(name = fieldPtr)))
          val cast = freshTmp(ctx)
          body.add(
            NBitcast(
              dest = cast,
              fromTy = ui.cases[ci2].fieldTys[fi],
              value = NLocal(name = fieldVal),
              toTy = NPtr(pointee = NI8)
            )
          )
          body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = cast))))
        }
        fi = fi + 1
      }
      body.add(NBr(label = endL))
    }
    ci2 = ci2 + 1
  }
  body.add(NLabel(name = endL))
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  NFunc(
    name = unionDtorName(ui),
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

// ── Construction ─────────────────────────────────────────────────────────────
/// Allocate a heap object and initialise its ARC header (rc = 1 per
/// Rule 1; dtor null when the type owns no refs).
func emitHeapAlloc(ctx: in Ctx, insns: in List[NInsn], objTy: in NType, size: in Int, dtorName: in String): String {
  val raw = freshTmp(ctx)
  insns.add(
    NCall(
      dest = raw,
      retTy = NPtr(pointee = NI8),
      fn = NGlobal(name = "lyric_alloc"),
      args = arg1(NI64, NLitInt(v = intToLong(size), ty = NI64))
    )
  )
  val obj = freshTmp(ctx)
  insns.add(NBitcast(dest = obj, fromTy = NPtr(pointee = NI8), value = NLocal(name = raw), toTy = objTy))
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val rcPtr = freshTmp(ctx)
  val rcArgs: List[NArg] = newList()
  rcArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  rcArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  insns.add(NGEP(dest = rcPtr, ty = structTy, ptr = NLocal(name = obj), indices = rcArgs))
  insns.add(NStore(ty = NI32, value = NLitInt(v = 1i64, ty = NI32), ptr = NLocal(name = rcPtr)))
  val dtorPtr = freshTmp(ctx)
  val dtorArgs: List[NArg] = newList()
  dtorArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dtorArgs.add(NArg(ty = NI32, value = NLitInt(v = 1i64, ty = NI32)))
  insns.add(NGEP(dest = dtorPtr, ty = structTy, ptr = NLocal(name = obj), indices = dtorArgs))
  if dtorName.length == 0 {
    insns.add(NStore(ty = NPtr(pointee = NI8), value = NLitNull(ty = NPtr(pointee = NI8)), ptr = NLocal(name = dtorPtr)))
  } else {
    val fnParams: List[NType] = newList()
    fnParams.add(NPtr(pointee = NI8))
    val cast = freshTmp(ctx)
    insns.add(
      NBitcast(
        dest = cast,
        fromTy = NPtr(pointee = NFnPtr(params = fnParams, ret = NVoid)),
        value = NGlobal(name = dtorName),
        toTy = NPtr(pointee = NI8)
      )
    )
    insns.add(NStore(ty = NPtr(pointee = NI8), value = NLocal(name = cast), ptr = NLocal(name = dtorPtr)))
  }
  obj
}

/// Resolve construction args (named/positional/defaults) to the field
/// declaration order and lower each.
func resolveFieldArgs(
  ctx: in Ctx,
  insns: in List[NInsn],
  what: in String,
  fieldNames: in List[String],
  fieldTys: in List[NType],
  fieldDefaults: in List[Option[Expr]],
  args: in List[CallArg],
): List[NVal] {
  val provided: Map[String, Expr] = newMap()
  var positionalIdx = 0
  var ai = 0
  while ai < args.count {
    match args[ai] {
      case CANamed(name, value, _) -> {
        if not provided.containsKey(name) {
          provided.add(name, value)
        }
      }
      case CAPositional(ex) -> {
        if positionalIdx >= fieldNames.count {
          panic("Lyric.LlvmCodegen: too many arguments constructing " + what)
        }
        if not provided.containsKey(fieldNames[positionalIdx]) {
          provided.add(fieldNames[positionalIdx], ex)
        }
        positionalIdx = positionalIdx + 1
      }
    }
    ai = ai + 1
  }
  val outV: List[NVal] = newList()
  var fi = 0
  while fi < fieldNames.count {
    // var-mutation shape (stage-0 value-position-match lowering gap,
    // #4631: the rewrapped Option falls through as None).
    var ex: Option[Expr] = None
    match mapGet(provided, fieldNames[fi]) {
      case Some(e) -> {
        ex = Some(value = e)
      }
      case None -> {
        ex = fieldDefaults[fi]
      }
    }
    match ex {
      case Some(e) -> {
        val v = lowerExpr(ctx, insns, e)
        outV.add(coerceTo(ctx, insns, v, fieldTys[fi]))
      }
      case None -> panic("Lyric.LlvmCodegen: missing field '" + fieldNames[fi] + "' constructing " + what)
    }
    fi = fi + 1
  }
  outV
}

func lowerRecordConstructArgs(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, args: in List[CallArg]): NVal {
  val noDflts: List[Option[Expr]] = ri.fieldDefaults
  val vals = resolveFieldArgs(ctx, insns, "record '" + ri.irName + "'", ri.fieldNames, ri.fieldTys, noDflts, args)
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val dtorName = if recHasRefFields(ri) { recDtorName(ri) } else { "" }
  val obj = emitHeapAlloc(ctx, insns, objTy, recAllocSize(ri), dtorName)
  var fi = 0
  while fi < vals.count {
    // Rule 2: the object owns its ref fields — retain before storing.
    if isRefNType(ri.fieldTys[fi]) {
      emitRetain(ctx, insns, vals[fi])
    }
    val fieldPtr = freshTmp(ctx)
    val fArgs: List[NArg] = newList()
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + fi), ty = NI32)))
    insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = obj), indices = fArgs))
    insns.add(NStore(ty = ri.fieldTys[fi], value = vals[fi].value, ptr = NLocal(name = fieldPtr)))
    fi = fi + 1
  }
  val outV = NVal(ty = objTy, value = NLocal(name = obj))
  registerTemp(ctx, outV)
  outV
}

func lowerUnionConstruct(
  ctx: in Ctx, insns: in List[NInsn], ui: in NUnionInfo, caseIdx: in Int, args: in List[CallArg]
): NVal {
  val ci = ui.cases[caseIdx]
  val noDflts: List[Option[Expr]] = newList()
  var di = 0
  while di < ci.fieldNames.count {
    val noD: Option[Expr] = None
    noDflts.add(noD)
    di = di + 1
  }
  val vals = resolveFieldArgs(
    ctx,
    insns,
    "union case '" + ui.irName + "." + ci.name + "'",
    ci.fieldNames,
    ci.fieldTys,
    noDflts,
    args
  )
  val objTy = unionPtrType(ui)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val dtorName = if unionHasRefFields(ui) { unionDtorName(ui) } else { "" }
  val obj = emitHeapAlloc(ctx, insns, objTy, unionAllocSize(ui), dtorName)
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = NLocal(name = obj), indices = dArgs))
  insns.add(NStore(ty = NI32, value = NLitInt(v = intToLong(caseIdx), ty = NI32), ptr = NLocal(name = discPtr)))
  if vals.count > 0 {
    val casePtr = emitCasePayloadPtr(ctx, insns, ui, structTy, obj, caseIdx)
    val caseTy = casePayloadStructType(ui, ci)
    var fi = 0
    while fi < vals.count {
      if isRefNType(ci.fieldTys[fi]) {
        emitRetain(ctx, insns, vals[fi])
      }
      val fieldPtr = freshTmp(ctx)
      val fArgs: List[NArg] = newList()
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(fi), ty = NI32)))
      insns.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
      insns.add(NStore(ty = ci.fieldTys[fi], value = vals[fi].value, ptr = NLocal(name = fieldPtr)))
      fi = fi + 1
    }
  }
  val outV = NVal(ty = objTy, value = NLocal(name = obj))
  registerTemp(ctx, outV)
  outV
}

/// GEP to the union payload area and bitcast it to the case's payload
/// struct pointer.
func emitCasePayloadPtr(
  ctx: in Ctx,
  insns: in List[NInsn],
  ui: in NUnionInfo,
  structTy: in NType,
  obj: in String,
  caseIdx: in Int,
): String {
  val payloadPtr = freshTmp(ctx)
  val pArgs: List[NArg] = newList()
  pArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  pArgs.add(NArg(ty = NI32, value = NLitInt(v = 4i64, ty = NI32)))
  insns.add(NGEP(dest = payloadPtr, ty = structTy, ptr = NLocal(name = obj), indices = pArgs))
  val caseTy = casePayloadStructType(ui, ui.cases[caseIdx])
  val casePtr = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = casePtr,
      fromTy = NPtr(pointee = NArray(elem = NI64, size = ui.payloadWords)),
      value = NLocal(name = payloadPtr),
      toTy = NPtr(pointee = caseTy)
    )
  )
  casePtr
}

func lowerDistinctConstruct(
  ctx: in Ctx,
  insns: in List[NInsn],
  name: in String,
  di: in NDistinctInfo,
  args: in List[CallArg],
  line: in Int,
): NVal {
  if args.count != 1 {
    panic("Lyric.LlvmCodegen: distinct type '" + name + "' takes exactly one construction argument")
  }
  val v = coerceTo(ctx, insns, lowerPositionalArg(ctx, insns, args, 0), di.underlying)
  if di.hasRange {
    val loCmp = freshTmp(ctx)
    insns.add(
      NICmp(dest = loCmp, pred = ISlt, ty = di.underlying, a = v.value, b = NLitInt(v = di.lo, ty = di.underlying))
    )
    val hiCmp = freshTmp(ctx)
    insns.add(
      NICmp(dest = hiCmp, pred = ISgt, ty = di.underlying, a = v.value, b = NLitInt(v = di.hi, ty = di.underlying))
    )
    val bad = freshTmp(ctx)
    insns.add(NOr(dest = bad, ty = NI1, a = NLocal(name = loCmp), b = NLocal(name = hiCmp)))
    val trapL = freshLabel(ctx, "range.trap")
    val okL = freshLabel(ctx, "range.ok")
    insns.add(NCondBr(cond = NLocal(name = bad), thenLabel = trapL, elseLabel = okL))
    insns.add(NLabel(name = trapL))
    emitPanicRaw(ctx, insns, "value out of range for type " + name, line)
    insns.add(NBr(label = okL))
    insns.add(NLabel(name = okL))
  }
  v
}

// ── Pattern matching (N2.4) ──────────────────────────────────────────────────
/// Union info for a scrutinee type, when it is a registered union.
func unionInfoOfType(ctx: in Ctx, t: in NType): Option[NUnionInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.unionDefs, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

func recInfoOfType(ctx: in Ctx, t: in NType): Option[NRecInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.recordDefs, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

func stripPattern(p: in Pattern): Pattern {
  match p.kind {
    case PParen(inner) -> stripPattern(inner)
    case _ -> p
  }
}

/// Emit the test for `arm`'s pattern against `sv`, branching to
/// `okLabel` on match and `failLabel` otherwise, and record the
/// case-field/whole-value bindings to apply in the arm body.  Bindings
/// are (name, NVal) pairs appended to `bindNames`/`bindVals`.
func emitPatternTest(
  ctx: in Ctx,
  insns: in List[NInsn],
  sv: in NVal,
  pat: in Pattern,
  okLabel: in String,
  failLabel: in String,
  bindNames: in List[String],
  bindVals: in List[NVal],
): Unit {
  val p = stripPattern(pat)
  match p.kind {
    case PWildcard -> insns.add(NBr(label = okLabel))
    case PBinding(name, inner) -> {
      match inner {
        case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns (name @ pattern) are not yet supported for --target native")
        case None -> {
          bindNames.add(name)
          bindVals.add(sv)
          insns.add(NBr(label = okLabel))
        }
      }
    }
    case PLiteral(lit) -> {
      val lv = lowerLiteral(ctx, insns, lit)
      if isStringNType(sv.ty) {
        val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sv.ty, sv.value, lv.ty, lv.value))
        val isEq = freshTmp(ctx)
        insns.add(NICmp(dest = isEq, pred = INe, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
        insns.add(NCondBr(cond = NLocal(name = isEq), thenLabel = okLabel, elseLabel = failLabel))
      } else {
        match sv.ty {
          case NDouble -> {
            val cmp = freshTmp(ctx)
            insns.add(NFCmp(dest = cmp, pred = FOeq, a = sv.value, b = lv.value))
            insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
          }
          case sty -> {
            val lc = coerceTo(ctx, insns, lv, sty)
            val cmp = freshTmp(ctx)
            insns.add(NICmp(dest = cmp, pred = IEq, ty = sty, a = sv.value, b = lc.value))
            insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
          }
        }
      }
    }
    case PRange(lo, inclusive, hi) -> {
      val loV = coerceTo(ctx, insns, lowerExpr(ctx, insns, lo), sv.ty)
      val hiV = coerceTo(ctx, insns, lowerExpr(ctx, insns, hi), sv.ty)
      val geLo = freshTmp(ctx)
      insns.add(NICmp(dest = geLo, pred = ISge, ty = sv.ty, a = sv.value, b = loV.value))
      val leHi = freshTmp(ctx)
      val hiPred = if inclusive { ISle } else { ISlt }
      insns.add(NICmp(dest = leHi, pred = hiPred, ty = sv.ty, a = sv.value, b = hiV.value))
      val both = freshTmp(ctx)
      insns.add(NAnd(dest = both, ty = NI1, a = NLocal(name = geLo), b = NLocal(name = leHi)))
      insns.add(NCondBr(cond = NLocal(name = both), thenLabel = okLabel, elseLabel = failLabel))
    }
    case PConstructor(head, subpats) -> emitConstructorTest(ctx, insns, sv, head, subpats, okLabel, failLabel, bindNames, bindVals)
    case _ -> panic("Lyric.LlvmCodegen: this pattern form is not yet supported for --target native (Phase N2 lowers wildcard, binding, literal, range, and constructor patterns)")
  }
}

func emitConstructorTest(
  ctx: in Ctx,
  insns: in List[NInsn],
  sv: in NVal,
  head: in ModulePath,
  subpats: in List[Pattern],
  okLabel: in String,
  failLabel: in String,
  bindNames: in List[String],
  bindVals: in List[NVal],
): Unit {
  val joined = modulePathJoin(head.segments)
  // Enum case pattern: scrutinee is the i32 discriminant itself.
  match mapGet(ctx.enumDefs, joined) {
    case Some(idx) -> {
      val cmp = freshTmp(ctx)
      insns.add(NICmp(dest = cmp, pred = IEq, ty = NI32, a = sv.value, b = NLitInt(v = intToLong(idx), ty = NI32)))
      insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
      return
    }
    case None -> {
    }
  }
  val cref = match mapGet(ctx.caseRefs, joined) {
    case Some(c) -> c
    case None -> panic("Lyric.LlvmCodegen: unknown constructor pattern '" + joined + "' for --target native")
  }
  val ui = match unionInfoOfType(ctx, sv.ty) {
    case Some(u) -> u
    case None -> panic("Lyric.LlvmCodegen: constructor pattern '" + joined + "' matched against a non-union value")
  }
  if ui.irName != cref.unionKey {
    panic("Lyric.LlvmCodegen: constructor pattern '" + joined + "' does not belong to union '" + ui.irName + "'")
  }
  val structTy = match unionPtrType(ui) { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = sv.value, indices = dArgs))
  val disc = freshTmp(ctx)
  insns.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  val cmp = freshTmp(ctx)
  insns.add(
    NICmp(
      dest = cmp,
      pred = IEq,
      ty = NI32,
      a = NLocal(name = disc),
      b = NLitInt(v = intToLong(cref.caseIdx), ty = NI32)
    )
  )
  val ci = ui.cases[cref.caseIdx]
  if subpats.count == 0 {
    insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
    return
  }
  if subpats.count != ci.fieldNames.count {
    panic(
      "Lyric.LlvmCodegen: constructor pattern '" + joined + "' has " + subpats.count.toString() +
        " sub-patterns but the case declares " +
        ci.fieldNames.count.toString() +
        " fields"
    )
  }
  // Field loads live in a dedicated block so they only run when the
  // discriminant matched.
  val fieldsL = freshLabel(ctx, "match.fields")
  insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = fieldsL, elseLabel = failLabel))
  insns.add(NLabel(name = fieldsL))
  val objName = match sv.value {
    case NLocal(n) -> n
    case _ -> panic("Lyric.LlvmCodegen: union scrutinee must be a local value")
  }
  val casePtr = emitCasePayloadPtr(ctx, insns, ui, structTy, objName, cref.caseIdx)
  val caseTy = casePayloadStructType(ui, ci)
  var fi = 0
  // Sub-patterns test in order; scalar/binding sub-patterns chain
  // within this block against the loaded field values.
  val fieldVals: List[NVal] = newList()
  while fi < ci.fieldNames.count {
    val fieldPtr = freshTmp(ctx)
    val fArgs: List[NArg] = newList()
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(fi), ty = NI32)))
    insns.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
    val fieldVal = freshTmp(ctx)
    insns.add(NLoad(dest = fieldVal, ty = ci.fieldTys[fi], ptr = NLocal(name = fieldPtr)))
    fieldVals.add(NVal(ty = ci.fieldTys[fi], value = NLocal(name = fieldVal)))
    fi = fi + 1
  }
  var pi = 0
  while pi < subpats.count {
    val sub = stripPattern(subpats[pi])
    val isLast = pi == subpats.count - 1
    val nextL = if isLast { okLabel } else { freshLabel(ctx, "match.sub") }
    match sub.kind {
      case PWildcard -> {
        if isLast {
          insns.add(NBr(label = okLabel))
        }
      }
      case PBinding(name, inner) -> {
        match inner {
          case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns are not yet supported for --target native")
          case None -> {
            bindNames.add(name)
            bindVals.add(fieldVals[pi])
            if isLast {
              insns.add(NBr(label = okLabel))
            }
          }
        }
      }
      case _ -> {
        emitPatternTest(ctx, insns, fieldVals[pi], sub, nextL, failLabel, bindNames, bindVals)
        if not isLast {
          insns.add(NLabel(name = nextL))
        }
      }
    }
    pi = pi + 1
  }
}

/// Lower a `match` expression (value or statement position).  Arms test
/// sequentially; a fall-through past every arm panics (the type checker
/// enforces exhaustiveness, so this is a compiled backstop, not a
/// user-facing path).
func lowerMatch(ctx: in Ctx, insns: in List[NInsn], scrutinee: in Expr, arms: in List[MatchArm], line: in Int): NVal {
  if arms.count == 0 {
    panic("Lyric.LlvmCodegen: match with no arms")
  }
  val sv0 = lowerExpr(ctx, insns, scrutinee)
  // Pin the scrutinee into a named local so every arm block can address
  // it (also keeps it alive across arms via the enclosing temp scope).
  val sv = sv0
  val mergeL = freshLabel(ctx, "match.merge")
  var slotName = ""
  var slotTy = NVoid
  var ai = 0
  while ai < arms.count {
    val arm = arms[ai]
    val armBodyL = freshLabel(ctx, "match.body")
    val isLastArm = ai == arms.count - 1
    val nextL = if isLastArm { freshLabel(ctx, "match.nomatch") } else { freshLabel(ctx, "match.next") }
    val bindNames: List[String] = newList()
    val bindVals: List[NVal] = newList()
    // Guarded arms re-test into the guard block first.
    match arm.guard {
      case Some(g) -> {
        val guardL = freshLabel(ctx, "match.guard")
        emitPatternTest(ctx, insns, sv, arm.pattern, guardL, nextL, bindNames, bindVals)
        insns.add(NLabel(name = guardL))
        pushVarScope(ctx)
        applyPatternBinds(ctx, insns, bindNames, bindVals)
        pushTempScope(ctx)
        val gv = lowerExpr(ctx, insns, g)
        popTempScope(ctx, insns)
        // Guard bindings stay live for the body; release scope only on
        // the fail path.
        val failReleaseL = freshLabel(ctx, "match.guardfail")
        insns.add(NCondBr(cond = gv.value, thenLabel = armBodyL, elseLabel = failReleaseL))
        insns.add(NLabel(name = failReleaseL))
        releaseVarScopeAt(ctx, insns, ctx.scopeRefs.count - 1)
        insns.add(NBr(label = nextL))
        insns.add(NLabel(name = armBodyL))
        val armV = lowerArmBody(ctx, insns, arm)
        // Arm value protocol mirrors lowerIf's slot scheme.
        match armV.ty {
          case NVoid -> {
          }
          case vty -> {
            if slotName.length == 0 {
              slotName = "match.slot." + freshTmp(ctx)
              slotTy = vty
              ctx.allocas.add(NAlloca(dest = slotName, ty = vty))
            }
            val cv = coerceTo(ctx, insns, armV, slotTy)
            insns.add(NStore(ty = slotTy, value = cv.value, ptr = NLocal(name = slotName)))
          }
        }
        popVarScope(ctx, insns)
        insns.add(NBr(label = mergeL))
      }
      case None -> {
        emitPatternTest(ctx, insns, sv, arm.pattern, armBodyL, nextL, bindNames, bindVals)
        insns.add(NLabel(name = armBodyL))
        pushVarScope(ctx)
        applyPatternBinds(ctx, insns, bindNames, bindVals)
        val armV = lowerArmBody(ctx, insns, arm)
        match armV.ty {
          case NVoid -> {
          }
          case vty -> {
            if slotName.length == 0 {
              slotName = "match.slot." + freshTmp(ctx)
              slotTy = vty
              ctx.allocas.add(NAlloca(dest = slotName, ty = vty))
            }
            val cv = coerceTo(ctx, insns, armV, slotTy)
            insns.add(NStore(ty = slotTy, value = cv.value, ptr = NLocal(name = slotName)))
          }
        }
        popVarScope(ctx, insns)
        insns.add(NBr(label = mergeL))
      }
    }
    insns.add(NLabel(name = nextL))
    if isLastArm {
      emitPanicRaw(ctx, insns, "non-exhaustive match", line)
      insns.add(NBr(label = mergeL))
    }
    ai = ai + 1
  }
  insns.add(NLabel(name = mergeL))
  if slotName.length == 0 {
    return NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = slotTy, ptr = NLocal(name = slotName)))
  val outV = NVal(ty = slotTy, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

/// Bind pattern names as arm-scoped locals.  Bindings borrow from the
/// scrutinee (alive for the whole match), so `bindLocal`'s
/// retain-borrow rule keeps ownership sound if the arm rebinds or the
/// body escapes the value.
func applyPatternBinds(ctx: in Ctx, insns: in List[NInsn], bindNames: in List[String], bindVals: in List[NVal]): Unit {
  var i = 0
  while i < bindNames.count {
    bindLocal(ctx, insns, bindNames[i], bindVals[i])
    i = i + 1
  }
}

/// Lower an arm body producing an OWNED value (ref results retained or
/// transferred before the arm's scopes unwind).
func lowerArmBody(ctx: in Ctx, insns: in List[NInsn], arm: in MatchArm): NVal {
  pushTempScope(ctx)
  val v = lowerExprOrBlock(ctx, insns, arm.body)
  if isRefNType(v.ty) {
    ensureOwned(ctx, insns, v)
  }
  popTempScope(ctx, insns)
  v
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Control flow.
// ─────────────────────────────────────────────────────────────────────────────
func lowerExprOrBlock(ctx: in Ctx, insns: in List[NInsn], eob: in ExprOrBlock): NVal {
  match eob {
    case EOBExpr(ex) -> lowerExpr(ctx, insns, ex)
    case EOBBlock(b) -> lowerBlockValue(ctx, insns, b)
  }
}

func lowerIf(
  ctx: in Ctx,
  insns: in List[NInsn],
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranch: in Option[ExprOrBlock],
): NVal {
  val c = lowerExpr(ctx, insns, cond)
  val thenL = freshLabel(ctx, "if.then")
  val elseL = freshLabel(ctx, "if.else")
  val mergeL = freshLabel(ctx, "if.merge")
  // Value-producing if: both branches store into a shared temp slot;
  // the slot is typed after lowering the then-branch.  Ref-typed
  // results follow the value-region ARC protocol: each branch stores
  // an OWNED value (its temps released within the branch), and the
  // merged load re-registers as a single owned temp.
  match elseBranch {
    case Some(eb) -> {
      insns.add(NCondBr(cond = c.value, thenLabel = thenL, elseLabel = elseL))
      insns.add(NLabel(name = thenL))
      val thenInsns: List[NInsn] = newList()
      pushTempScope(ctx)
      val tv = lowerExprOrBlock(ctx, thenInsns, thenBranch)
      match tv.ty {
        case NVoid -> {
          popTempScope(ctx, thenInsns)
          appendInsns(insns, thenInsns)
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = elseL))
          pushTempScope(ctx)
          val ev = lowerExprOrBlock(ctx, insns, eb)
          val _ = ev
          popTempScope(ctx, insns)
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = mergeL))
          NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
        case vty -> {
          if isRefNType(vty) {
            ensureOwned(ctx, thenInsns, tv)
          }
          popTempScope(ctx, thenInsns)
          appendInsns(insns, thenInsns)
          val slot = "if.slot." + freshTmp(ctx)
          ctx.allocas.add(NAlloca(dest = slot, ty = vty))
          insns.add(NStore(ty = vty, value = tv.value, ptr = NLocal(name = slot)))
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = elseL))
          pushTempScope(ctx)
          val ev = lowerExprOrBlock(ctx, insns, eb)
          val evc = coerceTo(ctx, insns, ev, vty)
          if isRefNType(vty) {
            ensureOwned(ctx, insns, evc)
          }
          popTempScope(ctx, insns)
          insns.add(NStore(ty = vty, value = evc.value, ptr = NLocal(name = slot)))
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = mergeL))
          val dest = freshTmp(ctx)
          insns.add(NLoad(dest = dest, ty = vty, ptr = NLocal(name = slot)))
          val outV = NVal(ty = vty, value = NLocal(name = dest))
          registerTemp(ctx, outV)
          outV
        }
      }
    }
    case None -> {
      insns.add(NCondBr(cond = c.value, thenLabel = thenL, elseLabel = mergeL))
      insns.add(NLabel(name = thenL))
      pushTempScope(ctx)
      val tv = lowerExprOrBlock(ctx, insns, thenBranch)
      val _ = tv
      popTempScope(ctx, insns)
      insns.add(NBr(label = mergeL))
      insns.add(NLabel(name = mergeL))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
  }
}

func appendInsns(dest: in List[NInsn], src: in List[NInsn]): Unit {
  var i = 0
  while i < src.count {
    dest.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Statements and blocks.
// ─────────────────────────────────────────────────────────────────────────────
func lowerStmt(ctx: in Ctx, insns: in List[NInsn], stmt: in Statement): Unit {
  match stmt.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val v0 = lowerExpr(ctx, insns, init)
          val v = match tyOpt { case Some(te) -> coerceTo(ctx, insns, v0, typeToN(ctx, te)); case None -> v0 }
          match pat.kind {
            case PBinding(name, inner) -> {
              match inner {
                case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns are not yet supported for --target native")
                case None -> bindLocal(ctx, insns, name, v)
              }
            }
            case PWildcard -> {
            }
            case _ -> panic("Lyric.LlvmCodegen: destructuring val patterns are not yet supported for --target native (Phase N2)")
          }
        }
        case LBLet(name, tyOpt, init) -> {
          val v0 = lowerExpr(ctx, insns, init)
          val v = match tyOpt { case Some(te) -> coerceTo(ctx, insns, v0, typeToN(ctx, te)); case None -> v0 }
          bindLocal(ctx, insns, name, v)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              val v0 = lowerExpr(ctx, insns, init)
              val v = match tyOpt { case Some(te) -> coerceTo(ctx, insns, v0, typeToN(ctx, te)); case None -> v0 }
              bindLocal(ctx, insns, name, v)
            }
            case None -> {
              match tyOpt {
                case Some(te) -> {
                  val ty = typeToN(ctx, te)
                  val zero = zeroValueOf(ty)
                  bindLocal(ctx, insns, name, NVal(ty = ty, value = zero))
                }
                case None -> panic("Lyric.LlvmCodegen: 'var' without initializer needs a type annotation")
              }
            }
          }
        }
      }
    }
    case SAssign(target, op, value) -> lowerAssign(ctx, insns, target, op, value, stmt.span.startPos.line)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(v) -> {
          val nv = lowerExpr(ctx, insns, v)
          match ctx.curRet[0] {
            case NVoid -> {
              releaseAllForReturn(ctx, insns)
              insns.add(NRetVoid)
            }
            case rt -> {
              val cv = coerceTo(ctx, insns, nv, rt)
              // Rule 6: return transfers ownership — owned temps move
              // out unregistered; borrows retain before the scope
              // releases below.
              if isRefNType(rt) {
                ensureOwned(ctx, insns, cv)
              }
              releaseAllForReturn(ctx, insns)
              insns.add(NRet(ty = rt, value = cv.value))
            }
          }
        }
        case None -> {
          releaseAllForReturn(ctx, insns)
          insns.add(NRetVoid)
        }
      }
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SBreak(label) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled break is not yet supported for --target native")
        case None -> {
        }
      }
      if ctx.loopBreak.count == 0 {
        panic("Lyric.LlvmCodegen: 'break' outside a loop")
      }
      releaseForLoopExit(ctx, insns)
      insns.add(NBr(label = ctx.loopBreak[ctx.loopBreak.count - 1]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SContinue(label) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled continue is not yet supported for --target native")
        case None -> {
        }
      }
      if ctx.loopCont.count == 0 {
        panic("Lyric.LlvmCodegen: 'continue' outside a loop")
      }
      releaseForLoopExit(ctx, insns)
      insns.add(NBr(label = ctx.loopCont[ctx.loopCont.count - 1]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SWhile(label, cond, body) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled while is not yet supported for --target native")
        case None -> {
        }
      }
      val condL = freshLabel(ctx, "while.cond")
      val bodyL = freshLabel(ctx, "while.body")
      val exitL = freshLabel(ctx, "while.exit")
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = condL))
      // Cond temps release before the branch (the cond value is scalar).
      pushTempScope(ctx)
      val c = lowerExpr(ctx, insns, cond)
      popTempScope(ctx, insns)
      insns.add(NCondBr(cond = c.value, thenLabel = bodyL, elseLabel = exitL))
      insns.add(NLabel(name = bodyL))
      ctx.loopBreak.add(exitL)
      ctx.loopCont.add(condL)
      ctx.loopVarDepth.add(ctx.scopeRefs.count)
      ctx.loopTempDepth.add(ctx.tempScopes.count)
      lowerBlockStmts(ctx, insns, body)
      ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
      ctx.loopCont.removeAt(ctx.loopCont.count - 1)
      ctx.loopVarDepth.removeAt(ctx.loopVarDepth.count - 1)
      ctx.loopTempDepth.removeAt(ctx.loopTempDepth.count - 1)
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = exitL))
    }
    case SExpr(ex) -> {
      val _ = lowerExpr(ctx, insns, ex)
    }
    case SFor(_, _, _, _) -> panic("Lyric.LlvmCodegen: 'for' loops are not yet supported for --target native (Phase N2; use 'while')")
    case SLoop(_, _) -> panic("Lyric.LlvmCodegen: 'loop' is not yet supported for --target native (use 'while true')")
    case SThrow(_) -> panic("Lyric.LlvmCodegen: 'throw' is not supported for --target native (D-N-003: panics abort)")
    case STry(_, _, _) -> panic("Lyric.LlvmCodegen: try/catch is not supported for --target native (D-N-003: no unwinding)")
    case SDefer(_) -> panic("Lyric.LlvmCodegen: 'defer' is not yet supported for --target native (Phase 2, D-N-003)")
    case SInvariant(_) -> {
      // Loop invariants are proof obligations (lyric prove); they carry
      // no runtime lowering here.
    }
    case _ -> panic("Lyric.LlvmCodegen: this statement form is not yet supported for --target native (Phase N1)")
  }
}

func zeroValueOf(ty: in NType): NValue {
  match ty {
    case NDouble -> NLitFloat(v = 0.0)
    case NPtr(pointee) -> NLitNull(ty = NPtr(pointee = pointee))
    case _ -> NLitInt(v = 0i64, ty = ty)
  }
}

// The assignable local behind an assignment target (split out of
// `lowerAssign` in return style: the self-hosted MSIL emitter
// miscompiles a value-position if/else whose other branch panics,
// #4625).
func assignTargetName(target: in Expr): String {
  match target.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        return path.segments[0]
      }
      panic("Lyric.LlvmCodegen: assignment to a qualified path is not yet supported for --target native")
    }
    case _ -> panic("Lyric.LlvmCodegen: assignment to this target form is not yet supported for --target native (fields are Phase N2)")
  }
}

func lowerAssign(
  ctx: in Ctx, insns: in List[NInsn], target: in Expr, op: in AssignOp, value: in Expr, line: in Int
): Unit {
  match target.kind {
    case EMember(recv, fieldName) -> {
      lowerFieldAssign(ctx, insns, recv, fieldName, op, value, line)
      return
    }
    case _ -> {
    }
  }
  val name = assignTargetName(target)
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: assignment to unknown variable '" + name + "'")
  }
  val slot = match mapGet(ctx.varSlots, name) {
    case Some(s) -> s
    case None -> panic("Lyric.LlvmCodegen: no storage slot for '" + name + "'")
  }
  val rhs = lowerExpr(ctx, insns, value)
  val newVal = match op {
    case AssEq -> coerceTo(ctx, insns, rhs, ty)
    case _ -> {
      val curDest = freshTmp(ctx)
      insns.add(NLoad(dest = curDest, ty = ty, ptr = NLocal(name = slot)))
      val cur = NVal(ty = ty, value = NLocal(name = curDest))
      val binOp = match op {
        case AssPlus -> BAdd
        case AssMinus -> BSub
        case AssStar -> BMul
        case AssSlash -> BDiv
        case AssPercent -> BMod
        case AssEq -> BAdd
      }
      if isStringNType(ty) {
        lowerStringBinop(ctx, insns, binOp, cur, coerceTo(ctx, insns, rhs, ty))
      } else {
        val rhsC = coerceTo(ctx, insns, rhs, ty)
        match ty {
          case NDouble -> binFloatOp(ctx, insns, binOp, cur.value, rhsC.value)
          case _ -> binIntOp(ctx, insns, binOp, ty, cur.value, rhsC.value, line)
        }
      }
    }
  }
  if isRefNType(ty) {
    // ARC Rule 3: retain-new-before-release-old (self-assignment safe).
    ensureOwned(ctx, insns, newVal)
    val oldDest = freshTmp(ctx)
    insns.add(NLoad(dest = oldDest, ty = ty, ptr = NLocal(name = slot)))
    insns.add(NStore(ty = ty, value = newVal.value, ptr = NLocal(name = slot)))
    emitRelease(ctx, insns, NVal(ty = ty, value = NLocal(name = oldDest)))
    return
  }
  insns.add(NStore(ty = ty, value = newVal.value, ptr = NLocal(name = slot)))
}

/// `obj.field = v` / `obj.field op= v` (ARC Rule 3 for ref fields).
func lowerFieldAssign(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in Expr,
  fieldName: in String,
  op: in AssignOp,
  value: in Expr,
  line: in Int,
): Unit {
  val obj = lowerExpr(ctx, insns, recv)
  val ri = match recInfoOfType(ctx, obj.ty) {
    case Some(r) -> r
    case None -> panic("Lyric.LlvmCodegen: assignment target '." + fieldName + "' is not a record field")
  }
  val idx = recFieldIndex(ri, fieldName)
  if idx < 0 {
    panic("Lyric.LlvmCodegen: record '" + ri.irName + "' has no field '" + fieldName + "'")
  }
  val fieldTy = ri.fieldTys[idx]
  val structTy = match obj.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + idx), ty = NI32)))
  insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = obj.value, indices = fArgs))
  val rhs = lowerExpr(ctx, insns, value)
  val newVal = match op {
    case AssEq -> coerceTo(ctx, insns, rhs, fieldTy)
    case _ -> {
      val curDest = freshTmp(ctx)
      insns.add(NLoad(dest = curDest, ty = fieldTy, ptr = NLocal(name = fieldPtr)))
      val cur = NVal(ty = fieldTy, value = NLocal(name = curDest))
      val binOp = match op {
        case AssPlus -> BAdd
        case AssMinus -> BSub
        case AssStar -> BMul
        case AssSlash -> BDiv
        case AssPercent -> BMod
        case AssEq -> BAdd
      }
      if isStringNType(fieldTy) {
        lowerStringBinop(ctx, insns, binOp, cur, coerceTo(ctx, insns, rhs, fieldTy))
      } else {
        val rhsC = coerceTo(ctx, insns, rhs, fieldTy)
        match fieldTy {
          case NDouble -> binFloatOp(ctx, insns, binOp, cur.value, rhsC.value)
          case _ -> binIntOp(ctx, insns, binOp, fieldTy, cur.value, rhsC.value, line)
        }
      }
    }
  }
  if isRefNType(fieldTy) {
    // The field slot owns its value: retain the incoming value (or
    // transfer an owned temp), then release what the slot held.
    ensureOwned(ctx, insns, newVal)
    val oldDest = freshTmp(ctx)
    insns.add(NLoad(dest = oldDest, ty = fieldTy, ptr = NLocal(name = fieldPtr)))
    insns.add(NStore(ty = fieldTy, value = newVal.value, ptr = NLocal(name = fieldPtr)))
    emitRelease(ctx, insns, NVal(ty = fieldTy, value = NLocal(name = oldDest)))
    return
  }
  insns.add(NStore(ty = fieldTy, value = newVal.value, ptr = NLocal(name = fieldPtr)))
}

/// One statement, with its own temp-release region.
func lowerStmtScoped(ctx: in Ctx, insns: in List[NInsn], stmt: in Statement): Unit {
  pushTempScope(ctx)
  lowerStmt(ctx, insns, stmt)
  popTempScope(ctx, insns)
}

func lowerBlockStmts(ctx: in Ctx, insns: in List[NInsn], block: in Block): Unit {
  pushVarScope(ctx)
  var i = 0
  while i < block.statements.count {
    lowerStmtScoped(ctx, insns, block.statements[i])
    i = i + 1
  }
  popVarScope(ctx, insns)
}

/// Lower a block in value position: every statement runs, and a trailing
/// expression statement supplies the block's value.  A ref-typed value
/// leaves the block OWNED (retained if it borrowed from a block-local),
/// registered as a temp in the enclosing region.
func lowerBlockValue(ctx: in Ctx, insns: in List[NInsn], block: in Block): NVal {
  if block.statements.count == 0 {
    return NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
  pushVarScope(ctx)
  var i = 0
  while i < block.statements.count - 1 {
    lowerStmtScoped(ctx, insns, block.statements[i])
    i = i + 1
  }
  val last = block.statements[block.statements.count - 1]
  // var-mutation shape: the stage-0 seed cannot compile this arm's
  // statement sequence in a value-position match (the #4631 family of
  // stage-0 lowering gaps).
  var outV = NVal(ty = NVoid, value = NUndef(ty = NVoid))
  match last.kind {
    case SExpr(ex) -> {
      pushTempScope(ctx)
      val v = lowerExpr(ctx, insns, ex)
      if isRefNType(v.ty) {
        ensureOwned(ctx, insns, v)
      }
      popTempScope(ctx, insns)
      outV = v
    }
    case _ -> {
      lowerStmtScoped(ctx, insns, last)
    }
  }
  popVarScope(ctx, insns)
  registerTemp(ctx, outV)
  outV
}

// ─────────────────────────────────────────────────────────────────────────────
// §13. Function lowering and the package entry point.
// ─────────────────────────────────────────────────────────────────────────────
/// A fresh per-function view over the module-wide ctx: tickers,
/// globals, and the signature registry are shared (same underlying
/// lists/maps); variable scope, alloca hoisting, and loop stacks start
/// empty.
func freshFnCtx(mod: in Ctx, pkg: in String, retTy: in NType): Ctx {
  val slots: Map[String, String] = newMap()
  val types: Map[String, NType] = newMap()
  val curPkg: List[String] = newList()
  curPkg.add(pkg)
  val curRet: List[NType] = newList()
  curRet.add(retTy)
  Ctx(
    mainPkg = mod.mainPkg,
    tmpTicker = mod.tmpTicker,
    labelTicker = mod.labelTicker,
    strTicker = mod.strTicker,
    varSlots = slots,
    varTypes = types,
    allocas = newList(),
    loopBreak = newList(),
    loopCont = newList(),
    globals = mod.globals,
    sigs = mod.sigs,
    curPkg = curPkg,
    curRet = curRet,
    recordDefs = mod.recordDefs,
    unionDefs = mod.unionDefs,
    caseRefs = mod.caseRefs,
    enumDefs = mod.enumDefs,
    distinctDefs = mod.distinctDefs,
    scopeRefs = newList(),
    tempScopes = newList(),
    loopVarDepth = newList(),
    loopTempDepth = newList()
  )
}

func lowerFunction(modCtx: in Ctx, pkg: in String, fn: in FunctionDecl, irName: in String): NFunc {
  if fn.isAsync {
    panic(
      "N0099: async functions are not yet supported for --target native. Use --target dotnet or --target jvm for async programs."
    )
  }
  match fn.generics {
    case Some(_) -> panic("Lyric.LlvmCodegen: un-monomorphized generic function '" + fn.name + "' reached the native backend")
    case None -> {
    }
  }
  val retTy = retTypeToN(modCtx, fn.ret)
  val ctx = freshFnCtx(modCtx, pkg, retTy)
  val params: List[NParam] = newList()
  val body: List[NInsn] = newList()
  // Parameters land in allocas so `var`-style reads/writes and address
  // uniformity hold; mem2reg cleans this up at -O1+.  `in` params are
  // ARC borrows (Rule 5): never retained on entry or released on exit.
  var pi = 0
  while pi < fn.params.count {
    val p = fn.params[pi]
    match p.mode {
      case PMIn -> {
      }
      case _ -> panic("Lyric.LlvmCodegen: out/inout parameters are not yet supported for --target native")
    }
    val pty = typeToN(ctx, p.ty)
    params.add(NParam(name = "arg." + p.name, ty = pty))
    match pty {
      case NVoid -> {
        ctx.varTypes.add(p.name, NVoid)
      }
      case _ -> {
        val slot = p.name + ".slot." + freshTmp(ctx)
        ctx.allocas.add(NAlloca(dest = slot, ty = pty))
        body.add(NStore(ty = pty, value = NLocal(name = "arg." + p.name), ptr = NLocal(name = slot)))
        ctx.varSlots.add(p.name, slot)
        ctx.varTypes.add(p.name, pty)
      }
    }
    pi = pi + 1
  }
  pushVarScope(ctx)
  pushTempScope(ctx)
  val tail = match fn.body {
    case Some(fb) -> {
      match fb {
        case FBExpr(ex) -> lowerExpr(ctx, body, ex)
        case FBBlock(b) -> lowerBlockValue(ctx, body, b)
      }
    }
    case None -> panic("Lyric.LlvmCodegen: function '" + fn.name + "' has no body")
  }
  // Fall-off return: yield the trailing value (or void).  Ref-typed
  // tails transfer out (Rule 6) before the function scopes unwind.
  match retTy {
    case NVoid -> {
      releaseAllForReturn(ctx, body)
      body.add(NRetVoid)
    }
    case rt -> {
      match tail.ty {
        case NVoid -> {
          // The body ended with a terminator-producing construct (e.g.
          // every path returned explicitly); emit an unreachable
          // fall-off return of the zero value to keep the block closed.
          releaseAllForReturn(ctx, body)
          body.add(NRet(ty = rt, value = zeroValueOf(rt)))
        }
        case _ -> {
          val cv = coerceTo(ctx, body, tail, rt)
          if isRefNType(rt) {
            ensureOwned(ctx, body, cv)
          }
          releaseAllForReturn(ctx, body)
          body.add(NRet(ty = rt, value = cv.value))
        }
      }
    }
  }
  // Assemble: entry label, hoisted allocas, then the body.
  val insns: List[NInsn] = newList()
  insns.add(NLabel(name = "entry"))
  appendInsns(insns, ctx.allocas)
  appendInsns(insns, body)
  val attrs: List[String] = newList()
  val isPub = match fn.visibility { case Some(_) -> true; case None -> pkg == ctx.mainPkg }
  NFunc(
    name = irName,
    params = params,
    retTy = retTy,
    isPublic = isPub,
    isExtern = false,
    body = insns,
    attributes = attrs
  )
}

/// The fixed lyric-rt declarations every module carries.
func runtimeDecls(): List[NFunc] {
  val decls: List[NFunc] = newList()
  val sTy = lyricStringNType()
  decls.add(mkDecl1("lyric_retain", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_release", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_alloc", NPtr(pointee = NI8), NI64))
  decls.add(mkDecl3("lyric_panic_msg", NVoid, NPtr(pointee = NI8), NPtr(pointee = NI8), NI32))
  decls.add(mkDecl2("lyric_string_concat", sTy, sTy, sTy))
  decls.add(mkDecl1("lyric_string_len", NI64, sTy))
  decls.add(mkDecl2("lyric_string_eq", NI32, sTy, sTy))
  decls.add(mkDecl2("lyric_string_cmp", NI32, sTy, sTy))
  decls.add(mkDecl1("lyric_string_from_int", sTy, NI64))
  decls.add(mkDecl1("lyric_string_from_float", sTy, NDouble))
  decls.add(mkDecl1("lyric_string_from_bool", sTy, NI32))
  decls.add(mkDecl1("lyric_string_from_char", sTy, NI32))
  decls.add(mkDecl3("lyric_string_substring", sTy, sTy, NI64, NI64))
  decls.add(mkDecl1("lyric_string_to_cstring", NPtr(pointee = NI8), sTy))
  decls.add(mkDecl1("lyric_cstring_free", NVoid, NPtr(pointee = NI8)))
  decls
}

func mkParamList(tys: in List[NType]): List[NParam] {
  val ps: List[NParam] = newList()
  var i = 0
  while i < tys.count {
    ps.add(NParam(name = "a" + i.toString(), ty = tys[i]))
    i = i + 1
  }
  ps
}

func mkDeclN(name: in String, ret: in NType, tys: in List[NType]): NFunc {
  val noBody: List[NInsn] = newList()
  val noAttrs: List[String] = newList()
  NFunc(
    name = name,
    params = mkParamList(tys),
    retTy = ret,
    isPublic = true,
    isExtern = true,
    body = noBody,
    attributes = noAttrs
  )
}

func mkDecl1(name: in String, ret: in NType, t0: in NType): NFunc {
  val tys: List[NType] = newList()
  tys.add(t0)
  mkDeclN(name, ret, tys)
}

func mkDecl2(name: in String, ret: in NType, t0: in NType, t1: in NType): NFunc {
  val tys: List[NType] = newList()
  tys.add(t0)
  tys.add(t1)
  mkDeclN(name, ret, tys)
}

func mkDecl3(name: in String, ret: in NType, t0: in NType, t1: in NType, t2: in NType): NFunc {
  val tys: List[NType] = newList()
  tys.add(t0)
  tys.add(t1)
  tys.add(t2)
  mkDeclN(name, ret, tys)
}

func externDeclOf(ef: in ExternFuncDecl): NFunc {
  val tys: List[NType] = newList()
  var i = 0
  while i < ef.params.count {
    tys.add(typeExprToNType(ef.params[i].ty))
    i = i + 1
  }
  mkDeclN(ef.symbol, retTypeToNType(ef.ret), tys)
}

/// Synthesise the C-ABI `main` wrapper around the user's `func main`.
func synthCMain(mainPkg: in String, userMainRet: in NType, userMainIr: in String): NFunc {
  val params: List[NParam] = newList()
  params.add(NParam(name = "argc", ty = NI32))
  params.add(NParam(name = "argv", ty = NPtr(pointee = NPtr(pointee = NI8))))
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val noArgs: List[NArg] = newList()
  match userMainRet {
    case NI32 -> {
      body.add(NCall(dest = "code", retTy = NI32, fn = NGlobal(name = userMainIr), args = noArgs))
      body.add(NRet(ty = NI32, value = NLocal(name = "code")))
    }
    case NVoid -> {
      body.add(NCallVoid(fn = NGlobal(name = userMainIr), args = noArgs))
      body.add(NRet(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    }
    case _ -> panic("Lyric.LlvmCodegen: `func main` must return Int or Unit for --target native")
  }
  val attrs: List[String] = newList()
  NFunc(
    name = "main",
    params = params,
    retTy = NI32,
    isPublic = true,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

/// Lower a bundle of packages into one native module.  `units[0]` must
/// be the user's main package (its functions are all lowered and its
/// `func main` becomes the process entry point); the remaining units
/// carry the reachable slices of bundled stdlib packages.
pub func codegenNativeBundle(units: in List[CodegenUnit], triple: in String): NPackage {
  if units.count == 0 {
    panic("Lyric.LlvmCodegen: empty compilation bundle")
  }
  val mainPkg = units[0].pkgName
  val sigs = buildSigs(units)
  val emptySlots: Map[String, String] = newMap()
  val emptyTypes: Map[String, NType] = newMap()
  val emptyRecs: Map[String, NRecInfo] = newMap()
  val emptyUnions: Map[String, NUnionInfo] = newMap()
  val emptyCases: Map[String, NCaseRef] = newMap()
  val emptyEnums: Map[String, Int] = newMap()
  val emptyDistincts: Map[String, NDistinctInfo] = newMap()
  val ctx = Ctx(
    mainPkg = mainPkg,
    tmpTicker = newList(),
    labelTicker = newList(),
    strTicker = newList(),
    varSlots = emptySlots,
    varTypes = emptyTypes,
    allocas = newList(),
    loopBreak = newList(),
    loopCont = newList(),
    globals = newList(),
    sigs = sigs,
    curPkg = newList(),
    curRet = newList(),
    recordDefs = emptyRecs,
    unionDefs = emptyUnions,
    caseRefs = emptyCases,
    enumDefs = emptyEnums,
    distinctDefs = emptyDistincts,
    scopeRefs = newList(),
    tempScopes = newList(),
    loopVarDepth = newList(),
    loopTempDepth = newList()
  )
  val fns: List[NFunc] = newList()
  val types: List[NTypeDefn] = newList()
  val sFields: List[NType] = newList()
  sFields.add(NI32)
  sFields.add(NPtr(pointee = NI8))
  sFields.add(NI64)
  sFields.add(NI64)
  types.add(NTypeDefn(name = "LyricString", fields = sFields))
  registerHeapTypes(ctx, units, types, fns)
  val externDecls: List[NFunc] = newList()
  val declaredExterns: Map[String, Bool] = newMap()
  var di = 0
  val rtDecls = runtimeDecls()
  while di < rtDecls.count {
    externDecls.add(rtDecls[di])
    declaredExterns.add(rtDecls[di].name, true)
    di = di + 1
  }
  var mainRet = NVoid
  var mainIr = ""
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var ei = 0
    while ei < u.externs.count {
      val ef = u.externs[ei]
      if not declaredExterns.containsKey(ef.symbol) {
        declaredExterns.add(ef.symbol, true)
        externDecls.add(externDeclOf(ef))
      }
      ei = ei + 1
    }
    var fi = 0
    while fi < u.fns.count {
      val fn = u.fns[fi]
      val key = u.pkgName + "." + fn.name + "/" + fn.params.count.toString()
      val irName = match mapGet(sigs, key) { case Some(s) -> s.irName; case None -> u.pkgName + "." + fn.name }
      fns.add(lowerFunction(ctx, u.pkgName, fn, irName))
      if ui == 0 and fn.name == "main" and fn.params.count == 0 {
        mainRet = retTypeToNType(fn.ret)
        mainIr = irName
      }
      fi = fi + 1
    }
    ui = ui + 1
  }
  if mainIr.length > 0 {
    fns.add(synthCMain(mainPkg, mainRet, mainIr))
  }
  val libs: List[String] = newList()
  NPackage(
    name = mainPkg,
    triple = triple,
    types = types,
    globals = ctx.globals,
    functions = fns,
    externDecls = externDecls,
    nativeLibs = libs
  )
}

/// Single-file convenience entry (self-tests, ad-hoc compiles): every
/// function in `file` is lowered; there are no bundled dependencies.
pub func codegenNativePackage(file: in SourceFile, triple: in String): NPackage {
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile(dottedPkgName(file), file))
  codegenNativeBundle(units, triple)
}

/// Collect one source file's lowerable items into a CodegenUnit.
pub func unitOfFile(pkgName: in String, file: in SourceFile): CodegenUnit {
  val fns: List[FunctionDecl] = newList()
  val externs: List[ExternFuncDecl] = newList()
  val records: List[RecordDecl] = newList()
  val unions: List[UnionDecl] = newList()
  val enums: List[EnumDecl] = newList()
  val distincts: List[DistinctTypeDecl] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> fns.add(decl)
      case IExternFunc(decl) -> externs.add(decl)
      case IRecord(decl) -> {
        records.add(decl)
        collectRecordMethods(pkgName, decl, fns)
      }
      case IUnion(decl) -> unions.add(decl)
      case IEnum(decl) -> enums.add(decl)
      case IDistinctType(decl) -> distincts.add(decl)
      case ITypeAlias(_) -> {
      }
      case IExternType(_) -> {
      }
      case _ -> panic("Lyric.LlvmCodegen: this item form is not yet supported for --target native (Phase N2 lowers functions, extern funcs, records, unions, enums, and distinct types)")
    }
    i = i + 1
  }
  CodegenUnit(
    pkgName = pkgName,
    fns = fns,
    externs = externs,
    records = records,
    unions = unions,
    enums = enums,
    distincts = distincts
  )
}

/// Methods declared inside a record body desugar to package functions
/// with the explicit `self` receiver already in their parameter list
/// (D037); non-generic ones lower like any other function.  The
/// parser's synthesised receiver is typed `Self` — substitute the
/// concrete record reference so the native type mapping resolves it.
pub func collectRecordMethods(pkgName: in String, decl: in RecordDecl, fns: in List[FunctionDecl]): Unit {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> {
        match decl.generics {
          case Some(_) -> {
          }
          case None -> {
            match fn.generics {
              case Some(_) -> {
              }
              case None -> fns.add(substSelfInFn(fn, decl.name))
            }
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

func selfTypeRef(recordName: in String, span: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add(recordName)
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = span)), span = span)
}

func substSelfInType(te: in TypeExpr, recordName: in String): TypeExpr {
  match te.kind {
    case TSelf -> selfTypeRef(recordName, te.span)
    case TParen(inner) -> TypeExpr(kind = TParen(inner = substSelfInType(inner, recordName)), span = te.span)
    case _ -> te
  }
}

func substSelfInFn(fn: in FunctionDecl, recordName: in String): FunctionDecl {
  val newParams: List[Param] = newList()
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    newParams.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = substSelfInType(p.ty, recordName),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    i = i + 1
  }
  // var-mutation shape (#4631).
  var newRet: Option[TypeExpr] = None
  match fn.ret {
    case Some(r) -> {
      newRet = Some(value = substSelfInType(r, recordName))
    }
    case None -> {
    }
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = newParams,
    ret = newRet,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = fn.body,
    span = fn.span
  )
}

pub func dottedPkgName(file: in SourceFile): String {
  modulePathJoin(file.packageDecl.path.segments)
}
