//! llvm/codegen.l — Llvm.Codegen: AST → LLVM IR lowering (Phase N1).
//!
//! Walks parsed + middle-ended `SourceFile`s and produces an `NPackage`
//! for `Llvm.Lowering.lowerPackage`.  Phase N1 scope (scalar codegen,
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
//! Not yet lowered (each panics with a construct-naming message, per the
//! MSIL/JVM backend convention for backend gaps): records, unions,
//! enums, pattern matching, closures/lambdas, generics-after-mono
//! leftovers, `for`, `match`, module-level `val`, collections, async.
//! Records/unions + ARC retain/release insertion are Phase N2
//! (`llvm/arc.l`); until then the only heap values are strings, which
//! are allocated but never released (the plan's N1 sequencing — ARC
//! insertion rules land with N2.1).
package Llvm.Codegen

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Encoding as Encoding
import Lyric.Lexer
import Lyric.Parser
import Llvm.Types
import Llvm.Ir

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
        "Llvm.Codegen: type '" + n + "' is not yet supported for --target native (Phase N1 lowers scalars and String only)"
      )
    }
    case TGenericApp(head, args) -> {
      val n = lastSeg(head)
      if n == "NativePtr" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> return NPtr(pointee = typeExprToNType(inner))
          case TAValue(_) -> panic("Llvm.Codegen: NativePtr takes a type argument")
        }
      }
      panic("Llvm.Codegen: generic type '" + n + "' is not yet supported for --target native (Phase N1)")
    }
    case TUnit -> NVoid
    case TParen(inner) -> typeExprToNType(inner)
    case _ -> panic("Llvm.Codegen: this type form is not yet supported for --target native (Phase N1)")
  }
}

func retTypeToNType(ret: in Option[TypeExpr]): NType {
  match ret {
    case Some(te) -> typeExprToNType(te)
    case None -> NVoid
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
    }
  }
}

func loadLocal(ctx: in Ctx, insns: in List[NInsn], name: in String): NVal {
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Llvm.Codegen: unknown name '" + name + "' (module-level constants and non-local references are not yet supported for --target native)")
  }
  match ty {
    case NVoid -> NVal(ty = NVoid, value = NUndef(ty = NVoid))
    case _ -> {
      val slot = match mapGet(ctx.varSlots, name) {
        case Some(s) -> s
        case None -> panic("Llvm.Codegen: no storage slot for '" + name + "'")
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
    "Llvm.Codegen: mixed operand types '" + nTypeToIrString(a.ty) + "' and '" + nTypeToIrString(b.ty) +
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
      NVal(ty = retTy, value = NLocal(name = dest))
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
      panic("Llvm.Codegen: .toString() on this type is not yet supported for --target native (Phase N1)")
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
      if path.segments.count == 1 {
        return loadLocal(ctx, insns, path.segments[0])
      }
      panic(
        "Llvm.Codegen: qualified value reference '" + modulePathJoin(path.segments) +
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
    case EMatch(_, _) -> panic("Llvm.Codegen: 'match' is not yet supported for --target native (pattern matching is Phase N2)")
    case ELambda(_, _) -> panic("Llvm.Codegen: lambdas are not yet supported for --target native (closures are Phase N2)")
    case ETuple(_) -> panic("Llvm.Codegen: tuples are not yet supported for --target native (Phase N3)")
    case EList(_) -> panic("Llvm.Codegen: list literals are not yet supported for --target native (collections are Phase N2/N5)")
    case EIndex(_, _) -> panic("Llvm.Codegen: indexing is not yet supported for --target native (Phase N2)")
    case _ -> panic("Llvm.Codegen: this expression form is not yet supported for --target native (Phase N1)")
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
    case PreRef -> panic("Llvm.Codegen: function references (&f) are not yet supported for --target native (closures are Phase N2)")
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
      emitDivGuard(ctx, insns, ty, a, b, line)
      insns.add(NSDiv(dest = dest, ty = ty, a = a, b = b))
    }
    case BMod -> {
      emitDivGuard(ctx, insns, ty, a, b, line)
      insns.add(NSRem(dest = dest, ty = ty, a = a, b = b))
    }
    case _ -> panic("Llvm.Codegen: unexpected integer binop")
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
    case _ -> panic("Llvm.Codegen: unexpected float binop")
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
    case _ -> panic("Llvm.Codegen: unexpected comparison op")
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
    case _ -> panic("Llvm.Codegen: unexpected float comparison op")
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
    panic("Llvm.Codegen: mixed String/non-String operands (call .toString() explicitly)")
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
    case _ -> panic("Llvm.Codegen: this String operator is not yet supported for --target native")
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
  val v = lowerExpr(ctx, insns, receiver)
  if isStringNType(v.ty) {
    if memberName == "length" {
      val n = callRuntime(ctx, insns, "lyric_string_len", NI64, arg1(lyricStringNType(), v.value))
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
      return NVal(ty = NI32, value = NLocal(name = dest))
    }
    panic("Llvm.Codegen: String member '." + memberName + "' is not yet supported for --target native (Phase N1)")
  }
  panic(
    "Llvm.Codegen: member access '." + memberName + "' is not yet supported for --target native (records are Phase N2)"
  )
}

/// Scalar method-call receivers: `.and/.or/.xor/.shl/.shr`, the
/// conversion family, `.toString()`, and String's `.substring`.
/// Returns None when `recvName` is not a scalar method (the caller then
/// resolves it as a qualified static call).
func lowerScalarMethodCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  receiver: in Expr,
  name: in String,
  args: in List[CallArg],
  line: in Int,
): Option[NVal] {
  // Only value receivers reach here; package-qualified paths are
  // filtered by the caller.
  val v = lowerExpr(ctx, insns, receiver)
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
      insns.add(NAShr(dest = dest, ty = ty, a = v.value, b = bv))
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
      "Llvm.Codegen: call to '" + sig.irName + "' passes " + args.count.toString() +
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
          panic("Llvm.Codegen: named argument '" + argName + "' does not match a parameter of '" + sig.irName + "'")
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
      panic("Llvm.Codegen: no argument bound for parameter " + pi2.toString() + " of '" + sig.irName + "'")
    }
    val declTy = typeExprToNType(sig.paramTys[pi2])
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
    "Llvm.Codegen: cannot pass a '" + fromStr + "' where '" + wantStr + "' is expected (insert an explicit conversion)"
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
        match lowerScalarMethodCall(ctx, insns, receiver, memberName, args, line) {
          case Some(v) -> return v
          case None -> panic("Llvm.Codegen: method '." + memberName + "' on this receiver is not yet supported for --target native (Phase N1)")
        }
      }
    }
    case _ -> {
    }
  }
  // Static function call through the registry.
  val key = callKeyOf(fnExpr, args.count)
  if key.length == 0 {
    panic("Llvm.Codegen: indirect calls are not yet supported for --target native (closures are Phase N2)")
  }
  // Resolution order: self-package qualified, then the key as written.
  val selfKey = ctx.curPkg[0] + "." + key
  val sig = match mapGet(ctx.sigs, selfKey) {
    case Some(s) -> s
    case None -> {
      match mapGet(ctx.sigs, key) {
        case Some(s) -> s
        case None -> panic("Llvm.Codegen: cannot resolve call target '" + key + "' for --target native (the callee may be outside the bundled import closure)")
      }
    }
  }
  val callArgs = lowerCallArgs(ctx, insns, sig, args)
  val retTy = retTypeToNType(sig.retTy)
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NGlobal(name = sig.irName), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sig.irName), args = callArgs))
      NVal(ty = retTy, value = NLocal(name = dest))
    }
  }
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
  // the slot is typed after lowering the then-branch.
  match elseBranch {
    case Some(eb) -> {
      insns.add(NCondBr(cond = c.value, thenLabel = thenL, elseLabel = elseL))
      insns.add(NLabel(name = thenL))
      val thenInsns: List[NInsn] = newList()
      val tv = lowerExprOrBlock(ctx, thenInsns, thenBranch)
      appendInsns(insns, thenInsns)
      match tv.ty {
        case NVoid -> {
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = elseL))
          val ev = lowerExprOrBlock(ctx, insns, eb)
          val _ = ev
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = mergeL))
          NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
        case vty -> {
          val slot = "if.slot." + freshTmp(ctx)
          ctx.allocas.add(NAlloca(dest = slot, ty = vty))
          insns.add(NStore(ty = vty, value = tv.value, ptr = NLocal(name = slot)))
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = elseL))
          val ev = lowerExprOrBlock(ctx, insns, eb)
          val evc = coerceTo(ctx, insns, ev, vty)
          insns.add(NStore(ty = vty, value = evc.value, ptr = NLocal(name = slot)))
          insns.add(NBr(label = mergeL))
          insns.add(NLabel(name = mergeL))
          val dest = freshTmp(ctx)
          insns.add(NLoad(dest = dest, ty = vty, ptr = NLocal(name = slot)))
          NVal(ty = vty, value = NLocal(name = dest))
        }
      }
    }
    case None -> {
      insns.add(NCondBr(cond = c.value, thenLabel = thenL, elseLabel = mergeL))
      insns.add(NLabel(name = thenL))
      val tv = lowerExprOrBlock(ctx, insns, thenBranch)
      val _ = tv
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
          val v = match tyOpt { case Some(te) -> coerceTo(ctx, insns, v0, typeExprToNType(te)); case None -> v0 }
          match pat.kind {
            case PBinding(name, inner) -> {
              match inner {
                case Some(_) -> panic("Llvm.Codegen: nested binding patterns are not yet supported for --target native")
                case None -> bindLocal(ctx, insns, name, v)
              }
            }
            case PWildcard -> {
            }
            case _ -> panic("Llvm.Codegen: destructuring val patterns are not yet supported for --target native (Phase N2)")
          }
        }
        case LBLet(name, tyOpt, init) -> {
          val v0 = lowerExpr(ctx, insns, init)
          val v = match tyOpt { case Some(te) -> coerceTo(ctx, insns, v0, typeExprToNType(te)); case None -> v0 }
          bindLocal(ctx, insns, name, v)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              val v0 = lowerExpr(ctx, insns, init)
              val v = match tyOpt { case Some(te) -> coerceTo(ctx, insns, v0, typeExprToNType(te)); case None -> v0 }
              bindLocal(ctx, insns, name, v)
            }
            case None -> {
              match tyOpt {
                case Some(te) -> {
                  val ty = typeExprToNType(te)
                  val zero = zeroValueOf(ty)
                  bindLocal(ctx, insns, name, NVal(ty = ty, value = zero))
                }
                case None -> panic("Llvm.Codegen: 'var' without initializer needs a type annotation")
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
            case NVoid -> insns.add(NRetVoid)
            case rt -> {
              val cv = coerceTo(ctx, insns, nv, rt)
              insns.add(NRet(ty = rt, value = cv.value))
            }
          }
        }
        case None -> insns.add(NRetVoid)
      }
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SBreak(label) -> {
      match label {
        case Some(_) -> panic("Llvm.Codegen: labeled break is not yet supported for --target native")
        case None -> {
        }
      }
      if ctx.loopBreak.count == 0 {
        panic("Llvm.Codegen: 'break' outside a loop")
      }
      insns.add(NBr(label = ctx.loopBreak[ctx.loopBreak.count - 1]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SContinue(label) -> {
      match label {
        case Some(_) -> panic("Llvm.Codegen: labeled continue is not yet supported for --target native")
        case None -> {
        }
      }
      if ctx.loopCont.count == 0 {
        panic("Llvm.Codegen: 'continue' outside a loop")
      }
      insns.add(NBr(label = ctx.loopCont[ctx.loopCont.count - 1]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SWhile(label, cond, body) -> {
      match label {
        case Some(_) -> panic("Llvm.Codegen: labeled while is not yet supported for --target native")
        case None -> {
        }
      }
      val condL = freshLabel(ctx, "while.cond")
      val bodyL = freshLabel(ctx, "while.body")
      val exitL = freshLabel(ctx, "while.exit")
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = condL))
      val c = lowerExpr(ctx, insns, cond)
      insns.add(NCondBr(cond = c.value, thenLabel = bodyL, elseLabel = exitL))
      insns.add(NLabel(name = bodyL))
      ctx.loopBreak.add(exitL)
      ctx.loopCont.add(condL)
      lowerBlockStmts(ctx, insns, body)
      ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
      ctx.loopCont.removeAt(ctx.loopCont.count - 1)
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = exitL))
    }
    case SExpr(ex) -> {
      val _ = lowerExpr(ctx, insns, ex)
    }
    case SFor(_, _, _, _) -> panic("Llvm.Codegen: 'for' loops are not yet supported for --target native (Phase N2; use 'while')")
    case SLoop(_, _) -> panic("Llvm.Codegen: 'loop' is not yet supported for --target native (use 'while true')")
    case SThrow(_) -> panic("Llvm.Codegen: 'throw' is not supported for --target native (D-N-003: panics abort)")
    case STry(_, _, _) -> panic("Llvm.Codegen: try/catch is not supported for --target native (D-N-003: no unwinding)")
    case SDefer(_) -> panic("Llvm.Codegen: 'defer' is not yet supported for --target native (Phase 2, D-N-003)")
    case SInvariant(_) -> {
      // Loop invariants are proof obligations (lyric prove); they carry
      // no runtime lowering here.
    }
    case _ -> panic("Llvm.Codegen: this statement form is not yet supported for --target native (Phase N1)")
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
// miscompiles a value-position if/else whose other branch panics).
func assignTargetName(target: in Expr): String {
  match target.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        return path.segments[0]
      }
      panic("Llvm.Codegen: assignment to a qualified path is not yet supported for --target native")
    }
    case _ -> panic("Llvm.Codegen: assignment to this target form is not yet supported for --target native (fields are Phase N2)")
  }
}

func lowerAssign(
  ctx: in Ctx, insns: in List[NInsn], target: in Expr, op: in AssignOp, value: in Expr, line: in Int
): Unit {
  val name = assignTargetName(target)
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Llvm.Codegen: assignment to unknown variable '" + name + "'")
  }
  val slot = match mapGet(ctx.varSlots, name) {
    case Some(s) -> s
    case None -> panic("Llvm.Codegen: no storage slot for '" + name + "'")
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
  insns.add(NStore(ty = ty, value = newVal.value, ptr = NLocal(name = slot)))
}

func lowerBlockStmts(ctx: in Ctx, insns: in List[NInsn], block: in Block): Unit {
  var i = 0
  while i < block.statements.count {
    lowerStmt(ctx, insns, block.statements[i])
    i = i + 1
  }
}

/// Lower a block in value position: every statement runs, and a trailing
/// expression statement supplies the block's value.
func lowerBlockValue(ctx: in Ctx, insns: in List[NInsn], block: in Block): NVal {
  if block.statements.count == 0 {
    return NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
  var i = 0
  while i < block.statements.count - 1 {
    lowerStmt(ctx, insns, block.statements[i])
    i = i + 1
  }
  val last = block.statements[block.statements.count - 1]
  match last.kind {
    case SExpr(ex) -> lowerExpr(ctx, insns, ex)
    case _ -> {
      lowerStmt(ctx, insns, last)
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
  }
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
    curRet = curRet
  )
}

func lowerFunction(modCtx: in Ctx, pkg: in String, fn: in FunctionDecl, irName: in String): NFunc {
  if fn.isAsync {
    panic(
      "N0099: async functions are not yet supported for --target native. Use --target dotnet or --target jvm for async programs."
    )
  }
  match fn.generics {
    case Some(_) -> panic("Llvm.Codegen: un-monomorphized generic function '" + fn.name + "' reached the native backend")
    case None -> {
    }
  }
  val retTy = retTypeToNType(fn.ret)
  val ctx = freshFnCtx(modCtx, pkg, retTy)
  val params: List[NParam] = newList()
  val body: List[NInsn] = newList()
  // Parameters land in allocas so `var`-style reads/writes and address
  // uniformity hold; mem2reg cleans this up at -O1+.
  var pi = 0
  while pi < fn.params.count {
    val p = fn.params[pi]
    match p.mode {
      case PMIn -> {
      }
      case _ -> panic("Llvm.Codegen: out/inout parameters are not yet supported for --target native")
    }
    val pty = typeExprToNType(p.ty)
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
  val tail = match fn.body {
    case Some(fb) -> {
      match fb {
        case FBExpr(ex) -> lowerExpr(ctx, body, ex)
        case FBBlock(b) -> lowerBlockValue(ctx, body, b)
      }
    }
    case None -> panic("Llvm.Codegen: function '" + fn.name + "' has no body")
  }
  // Fall-off return: yield the trailing value (or void).
  match retTy {
    case NVoid -> body.add(NRetVoid)
    case rt -> {
      match tail.ty {
        case NVoid -> {
          // The body ended with a terminator-producing construct (e.g.
          // every path returned explicitly); emit an unreachable
          // fall-off return of the zero value to keep the block closed.
          body.add(NRet(ty = rt, value = zeroValueOf(rt)))
        }
        case _ -> {
          val cv = coerceTo(ctx, body, tail, rt)
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
    case _ -> panic("Llvm.Codegen: `func main` must return Int or Unit for --target native")
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
    panic("Llvm.Codegen: empty compilation bundle")
  }
  val mainPkg = units[0].pkgName
  val sigs = buildSigs(units)
  val emptySlots: Map[String, String] = newMap()
  val emptyTypes: Map[String, NType] = newMap()
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
    curRet = newList()
  )
  val fns: List[NFunc] = newList()
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
  val types: List[NTypeDefn] = newList()
  val sFields: List[NType] = newList()
  sFields.add(NI32)
  sFields.add(NPtr(pointee = NI8))
  sFields.add(NI64)
  sFields.add(NI64)
  types.add(NTypeDefn(name = "LyricString", fields = sFields))
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
  val fns: List[FunctionDecl] = newList()
  val externs: List[ExternFuncDecl] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> fns.add(decl)
      case IExternFunc(decl) -> externs.add(decl)
      case ITypeAlias(_) -> {
      }
      case IExternType(_) -> {
      }
      case _ -> panic("Llvm.Codegen: this item form is not yet supported for --target native (Phase N1 lowers functions and extern funcs)")
    }
    i = i + 1
  }
  val units: List[CodegenUnit] = newList()
  units.add(CodegenUnit(pkgName = dottedPkgName(file), fns = fns, externs = externs))
  codegenNativeBundle(units, triple)
}

pub func dottedPkgName(file: in SourceFile): String {
  modulePathJoin(file.packageDecl.path.segments)
}
