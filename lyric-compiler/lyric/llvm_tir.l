//! llvm_tir.l - Lyric.LlvmTir: the native backend's lowering of TIR (docs/70 §8,
//! phase 4a, D520).
//!
//! `lowerTirFunction` turns one monomorphic `TFnDecl` into an `NFunc`.  It reads
//! types from `TExpr.ty`, callees from `Callee` and conversions from `ConvKind`
//! and nothing else: no inference, no name lookup, no checker side table.  The
//! one thing it is handed that TIR does not carry is `TirLowerEnv.fnNames`, the
//! linkage table of docs/70 §9.5 for this slice: the IR symbol of each
//! `SymbolId` the bundle defines.
//!
//! A function this slice cannot lower is not an error: the result is
//! `Err(TirFallback)` naming the first construct that stopped it, and the
//! caller keeps the AST path's lowering of that function and counts the
//! fallback (§12.2).  Nothing is skipped silently.
//!
//! Linkage and attributes of the produced `NFunc` are the AST path's to supply
//! (the caller copies them from the function it replaces).
package Lyric.LlvmTir

import Std.Core
import Std.Collections
import Std.Encoding as Encoding
import Std.Environment as Environment
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.Symbols
import Lyric.Tir

/// Whether the TIR lowering is requested: `lyric build --target native
/// --via-tir` sets `LYRIC_NATIVE_VIA_TIR=1` for the build, and CI sets it
/// directly (docs/70 phase 4a, D520).
pub func viaTirRequested(): Bool {
  Environment.getVarOrDefault("LYRIC_NATIVE_VIA_TIR", "") == "1"
}

/// What the lowering needs beyond the declaration.
pub record TirLowerEnv {
  /// IR symbol of each declared function, keyed by `SymbolId.id`.
  fnNames: Map[Int, String]
  /// The package label a panic reports as its file, as the AST path does.
  panicFile: String
}

/// Why a function stayed on the AST path.
pub record TirFallback {
  sym: SymbolId
  reason: String
}

pub record TirLowered {
  fn: NFunc
  globals: List[NGlobalDef]
  /// Runtime declarations the body calls (`lyric_panic_msg`); the caller adds
  /// those the package lacks.
  externs: List[NFunc]
}

record Slot {
  ptr: String
  ty: NType
}

record LoopLabels {
  label: Option[String]
  breakL: String
  contL: String
}

record Val {
  ty: NType
  value: NValue
}

record LCtx {
  env: TirLowerEnv
  insns: List[NInsn]
  allocas: List[NInsn]
  globals: List[NGlobalDef]
  ticker: List[Int]
  cur: List[String]
  slots: Map[Int, Slot]
  loops: List[LoopLabels]
  problems: List[String]
  retTy: NType
}

func tmp(c: in LCtx): String {
  c.ticker.add(0)
  "t" + toString(c.ticker.count)
}

func newLabel(c: in LCtx, stem: in String): String {
  c.ticker.add(0)
  stem + "." + toString(c.ticker.count)
}

/// Open the block `name`; later phis name it as their incoming edge.
func startBlock(c: in LCtx, name: in String): Unit {
  c.insns.add(NLabel(name = name))
  c.cur.clear()
  c.cur.add(name)
}

func curBlock(c: in LCtx): String {
  c.cur[0]
}

func unitVal(): Val {
  Val(ty = NVoid, value = NUndef(ty = NVoid))
}

/// Record why the function cannot be lowered and hand back a placeholder so
/// lowering can continue to the end; the function is discarded afterwards.
func unsupported(c: in LCtx, why: in String): Val {
  c.problems.add(why)
  Val(ty = NI32, value = NUndef(ty = NI32))
}

func primN(k: in TPrimKind): NType {
  match k {
    case TPBool -> NI1
    case TPByte -> NI8
    case TPInt -> NI32
    case TPLong -> NI64
    case TPUInt -> NI32
    case TPULong -> NI64
    case TPNat -> NI64
    case TPFloat -> NFloat
    case TPDouble -> NDouble
    case TPChar -> NI32
    case TPString -> NVoid
    case TPUnit -> NVoid
  }
}

/// The LLVM type of a scalar `Ty`; None for anything this slice does not lower.
func tyToN(t: in Ty): Option[NType] {
  match t {
    case TPrim(k) -> match k { case TPString -> None; case _ -> Some(value = primN(k)) }
    case TRefined(u, _, _, _) -> tyToN(u)
    case TNever -> Some(value = NVoid)
    case _ -> None
  }
}

func isFloatTy(t: in Ty): Bool {
  match t {
    case TPrim(k) -> match k { case TPFloat -> true; case TPDouble -> true; case _ -> false }
    case TRefined(u, _, _, _) -> isFloatTy(u)
    case _ -> false
  }
}

func isUnsignedTy(t: in Ty): Bool {
  match t {
    case TPrim(k) -> match k { case TPByte -> true; case TPUInt -> true; case TPULong -> true; case _ -> false }
    case TRefined(u, _, _, _) -> isUnsignedTy(u)
    case _ -> false
  }
}

func bitsOf(t: in NType): Int {
  match t {
    case NI1 -> 1
    case NI8 -> 8
    case NI32 -> 32
    case NI64 -> 64
    case _ -> 0
  }
}

func isNever(t: in Ty): Bool {
  match t {
    case TNever -> true
    case _ -> false
  }
}

func zeroOf(t: in NType): NValue {
  match t {
    case NDouble -> NLitFloat(v = 0.0, ty = NDouble)
    case NFloat -> NLitFloat(v = 0.0, ty = NFloat)
    case _ -> NLitInt(v = 0i64, ty = t)
  }
}

func cString(c: in LCtx, text: in String): String {
  val bytes = Encoding.encodeUtf8(text)
  c.ticker.add(0)
  val gname = ".tcstr." + toString(c.ticker.count)
  c.globals.add(
    NGlobalDef(
      name = gname,
      linkage = "private unnamed_addr constant",
      tyStr = "[" + toString(bytes.length + 1) + " x i8]",
      initStr = "c\"" + escapeIrBytes(bytes) + "\\00\"",
      align = 1
    )
  )
  val ptr = tmp(c)
  c.insns.add(
    NBitcast(
      dest = ptr,
      fromTy = NPtr(pointee = NArray(elem = NI8, size = bytes.length + 1)),
      value = NGlobal(name = gname),
      toTy = NPtr(pointee = NI8)
    )
  )
  ptr
}

func emitPanic(c: in LCtx, msg: in String, line: in Int): Unit {
  val msgPtr = cString(c, msg)
  val filePtr = cString(c, c.env.panicFile)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = msgPtr)))
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = filePtr)))
  args.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
  c.insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = args))
  c.insns.add(NUnreachable)
  startBlock(c, newLabel(c, "dead"))
}

func divGuard(c: in LCtx, ty: in Ty, nty: in NType, a: in NValue, b: in NValue, line: in Int): Unit {
  val zero = tmp(c)
  c.insns.add(NICmp(dest = zero, pred = IEq, ty = nty, a = b, b = NLitInt(v = 0i64, ty = nty)))
  var bad = zero
  if not isUnsignedTy(ty) {
    val minLit = if bitsOf(nty) == 64 { -9223372036854775807i64 - 1i64 } else { -2147483648i64 }
    val isMin = tmp(c)
    c.insns.add(NICmp(dest = isMin, pred = IEq, ty = nty, a = a, b = NLitInt(v = minLit, ty = nty)))
    val isNeg1 = tmp(c)
    c.insns.add(NICmp(dest = isNeg1, pred = IEq, ty = nty, a = b, b = NLitInt(v = -1i64, ty = nty)))
    val ovf = tmp(c)
    c.insns.add(NAnd(dest = ovf, ty = NI1, a = NLocal(name = isMin), b = NLocal(name = isNeg1)))
    val both = tmp(c)
    c.insns.add(NOr(dest = both, ty = NI1, a = NLocal(name = zero), b = NLocal(name = ovf)))
    bad = both
  }
  val trapL = newLabel(c, "div.trap")
  val okL = newLabel(c, "div.ok")
  c.insns.add(NCondBr(cond = NLocal(name = bad), thenLabel = trapL, elseLabel = okL))
  startBlock(c, trapL)
  emitPanic(c, if isUnsignedTy(ty) { "integer division by zero" } else { "integer division by zero or overflow" }, line)
  c.insns.add(NBr(label = okL))
  startBlock(c, okL)
}

func icmpPred(op: in IntrinsicOp, unsigned: in Bool): Option[ICmpPred] {
  match op {
    case IoEq -> Some(value = IEq)
    case IoNeq -> Some(value = INe)
    case IoLt -> Some(value = if unsigned { IUlt } else { ISlt })
    case IoLte -> Some(value = if unsigned { IUle } else { ISle })
    case IoGt -> Some(value = if unsigned { IUgt } else { ISgt })
    case IoGte -> Some(value = if unsigned { IUge } else { ISge })
    case _ -> None
  }
}

func fcmpPred(op: in IntrinsicOp): Option[FCmpPred] {
  match op {
    case IoEq -> Some(value = FOeq)
    case IoNeq -> Some(value = FUne)
    case IoLt -> Some(value = FOlt)
    case IoLte -> Some(value = FOle)
    case IoGt -> Some(value = FOgt)
    case IoGte -> Some(value = FOge)
    case _ -> None
  }
}

func opName(op: in IntrinsicOp): String {
  match op {
    case IoBuiltin(n) -> "builtin " + n
    case _ -> "operator"
  }
}

/// A binary intrinsic on two scalars of type `ty`; the result is the node's
/// type (`resTy`), which differs from `ty` only for comparisons.
func lowerBinary(
  c: in LCtx, op: in IntrinsicOp, ty: in Ty, nty: in NType, a: in NValue, b: in NValue, line: in Int
): Val {
  val flt = isFloatTy(ty)
  val uns = isUnsignedTy(ty)
  match icmpPred(op, uns) {
    case Some(p) -> {
      val d = tmp(c)
      if flt {
        match fcmpPred(op) {
          case Some(fp) -> c.insns.add(NFCmp(dest = d, pred = fp, ty = nty, a = a, b = b))
          case None -> ()
        }
      } else {
        c.insns.add(NICmp(dest = d, pred = p, ty = nty, a = a, b = b))
      }
      return Val(ty = NI1, value = NLocal(name = d))
    }
    case None -> ()
  }
  val d = tmp(c)
  match op {
    case IoAdd -> c.insns.add(
      if flt { NFAdd(dest = d, ty = nty, a = a, b = b) } else { NAdd(dest = d, ty = nty, a = a, b = b) }
    )
    case IoSub -> c.insns.add(
      if flt { NFSub(dest = d, ty = nty, a = a, b = b) } else { NSub(dest = d, ty = nty, a = a, b = b) }
    )
    case IoMul -> c.insns.add(
      if flt { NFMul(dest = d, ty = nty, a = a, b = b) } else { NMul(dest = d, ty = nty, a = a, b = b) }
    )
    case IoDiv -> {
      if flt {
        c.insns.add(NFDiv(dest = d, ty = nty, a = a, b = b))
      } else {
        divGuard(c, ty, nty, a, b, line)
        c.insns.add(if uns { NUDiv(dest = d, ty = nty, a = a, b = b) } else { NSDiv(dest = d, ty = nty, a = a, b = b) })
      }
    }
    case IoMod -> {
      if flt {
        c.insns.add(NFRem(dest = d, ty = nty, a = a, b = b))
      } else {
        divGuard(c, ty, nty, a, b, line)
        c.insns.add(if uns { NURem(dest = d, ty = nty, a = a, b = b) } else { NSRem(dest = d, ty = nty, a = a, b = b) })
      }
    }
    case IoBitAnd -> c.insns.add(NAnd(dest = d, ty = nty, a = a, b = b))
    case IoBitOr -> c.insns.add(NOr(dest = d, ty = nty, a = a, b = b))
    case IoBitXor -> c.insns.add(NXor(dest = d, ty = nty, a = a, b = b))
    case _ -> return unsupported(c, "intrinsic " + opName(op))
  }
  Val(ty = nty, value = NLocal(name = d))
}

func lowerUnary(c: in LCtx, op: in IntrinsicOp, ty: in Ty, nty: in NType, a: in NValue): Val {
  val d = tmp(c)
  match op {
    case IoNeg -> {
      if isFloatTy(ty) {
        c.insns.add(NFNeg(dest = d, ty = nty, a = a))
      } else {
        c.insns.add(NSub(dest = d, ty = nty, a = zeroOf(nty), b = a))
      }
    }
    case IoNot -> c.insns.add(NXor(dest = d, ty = nty, a = a, b = NLitInt(v = 1i64, ty = nty)))
    case _ -> return unsupported(c, "unary intrinsic " + opName(op))
  }
  Val(ty = nty, value = NLocal(name = d))
}

func assignOp(k: in AssignKind): Option[IntrinsicOp] {
  match k {
    case AkSet -> None
    case AkAdd -> Some(value = IoAdd)
    case AkSub -> Some(value = IoSub)
    case AkMul -> Some(value = IoMul)
    case AkDiv -> Some(value = IoDiv)
    case AkMod -> Some(value = IoMod)
  }
}

func declareSlot(c: in LCtx, d: in LocalDecl): Option[Slot] {
  match tyToN(d.ty) {
    case None -> {
      c.problems.add("a local of type " + renderTy(d.ty))
      None
    }
    case Some(nt) -> match nt {
      case NVoid -> {
        c.problems.add("a local of type " + renderTy(d.ty))
        None
      }
      case _ -> {
        val name = "s" + toString(d.id.id) + "." + d.name
        c.allocas.add(NAlloca(dest = name, ty = nt))
        val slot = Slot(ptr = name, ty = nt)
        if c.slots.containsKey(d.id.id) {
          c.slots.remove(d.id.id)
        }
        c.slots.add(d.id.id, slot)
        Some(value = slot)
      }
    }
  }
}

func lowerExpr(c: in LCtx, e: in TExpr): Val {
  match e.kind {
    case XLit(lit) -> lowerLit(c, e, lit)
    case XLocal(id) -> match mapGet(c.slots, id.id) {
      case None -> unsupported(c, "a local with no slot")
      case Some(slot) -> {
        val d = tmp(c)
        c.insns.add(NLoad(dest = d, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
        Val(ty = slot.ty, value = NLocal(name = d))
      }
    }
    case XCall(callee, args) -> lowerCall(c, e, callee, args)
    case XConvert(kind, inner) -> lowerConvert(c, e, kind, inner)
    case XIf(cond, t, el) -> lowerIf(c, e, cond, t, el)
    case XBlock(stmts, tail) -> {
      for s in stmts {
        lowerStmt(c, s)
      }
      match tail {
        case Some(x) -> lowerExpr(c, x)
        case None -> unitVal()
      }
    }
    case XShort(op, l, r) -> lowerShort(c, op, l, r)
    case XAssign(place, op, value) -> lowerAssign(c, place, op, value)
    case _ -> unsupported(c, "expression " + exprKindName(e.kind))
  }
}

func exprKindName(k: in TExprKind): String {
  match k {
    case XLit(_) -> "XLit"
    case XLocal(_) -> "XLocal"
    case XGlobal(_, _) -> "XGlobal"
    case XCall(_, _) -> "XCall"
    case XConstruct(_, _) -> "XConstruct"
    case XField(_, _) -> "XField"
    case XIndex(_, _, _) -> "XIndex"
    case XConvert(_, _) -> "XConvert"
    case XTuple(_) -> "XTuple"
    case XListLit(_) -> "XListLit"
    case XInterp(_) -> "XInterp"
    case XRange(_, _, _) -> "XRange"
    case XShort(_, _, _) -> "XShort"
    case XIf(_, _, _) -> "XIf"
    case XMatch(_, _, _) -> "XMatch"
    case XBlock(_, _) -> "XBlock"
    case XUnsafe(_) -> "XUnsafe"
    case XLambda(_, _, _) -> "XLambda"
    case XAwait(_) -> "XAwait"
    case XSpawn(_) -> "XSpawn"
    case XYield(_) -> "XYield"
    case XPropagate(_) -> "XPropagate"
    case XOld(_) -> "XOld"
    case XResult -> "XResult"
    case XForall(_, _, _) -> "XForall"
    case XExists(_, _, _) -> "XExists"
    case XAssign(_, _, _) -> "XAssign"
  }
}

func lowerLit(c: in LCtx, e: in TExpr, lit: in TLit): Val {
  match lit {
    case TLUnit -> unitVal()
    case TLBool(b) -> Val(ty = NI1, value = NLitInt(v = if b { 1i64 } else { 0i64 }, ty = NI1))
    case TLChar(cp) -> Val(ty = NI32, value = NLitInt(v = cp.toLong(), ty = NI32))
    case TLString(_) -> unsupported(c, "a string literal")
    case TLInt(v) -> match tyToN(e.ty) {
      case None -> unsupported(c, "an integer literal of type " + renderTy(e.ty))
      case Some(nt) -> if isFloatTy(e.ty) {
        Val(ty = nt, value = NLitFloat(v = v.toDouble(), ty = nt))
      } else {
        Val(ty = nt, value = NLitInt(v = v, ty = nt))
      }
    }
    case TLFloat(v) -> match tyToN(e.ty) {
      case None -> unsupported(c, "a float literal of type " + renderTy(e.ty))
      case Some(nt) -> Val(ty = nt, value = NLitFloat(v = v, ty = nt))
    }
  }
}

func lowerCall(c: in LCtx, e: in TExpr, callee: in Callee, args: in List[TArg]): Val {
  val line = e.span.startPos.line
  match callee {
    case Intrinsic(op) -> {
      val ins: List[TExpr] = newList()
      for a in args {
        match a {
          case TArgIn(v) -> ins.add(v)
          case _ -> {
            c.problems.add("an out argument of an operator")
          }
        }
      }
      if ins.count == 2 {
        val a = lowerExpr(c, ins[0])
        val b = lowerExpr(c, ins[1])
        match tyToN(ins[0].ty) {
          case Some(nt) -> lowerBinary(c, op, ins[0].ty, nt, a.value, b.value, line)
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else if ins.count == 1 {
        val a = lowerExpr(c, ins[0])
        match tyToN(ins[0].ty) {
          case Some(nt) -> lowerUnary(c, op, ins[0].ty, nt, a.value)
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else {
        unsupported(c, "intrinsic " + opName(op))
      }
    }
    case Direct(sym, targs) -> {
      if targs.count > 0 {
        return unsupported(c, "a generic call")
      }
      match mapGet(c.env.fnNames, sym.id) {
        case None -> unsupported(c, "a call with no IR name (symbol #" + toString(sym.id) + ")")
        case Some(irName) -> {
          val nargs: List[NArg] = newList()
          for a in args {
            match a {
              case TArgIn(v) -> {
                val av = lowerExpr(c, v)
                match av.ty {
                  case NVoid -> c.problems.add("a Unit argument")
                  case _ -> nargs.add(NArg(ty = av.ty, value = av.value))
                }
              }
              case _ -> {
                c.problems.add("an out or inout argument")
              }
            }
          }
          match tyToN(e.ty) {
            case None -> unsupported(c, "a call returning " + renderTy(e.ty))
            case Some(rt) -> match rt {
              case NVoid -> {
                c.insns.add(NCallVoid(fn = NGlobal(name = irName), args = nargs))
                unitVal()
              }
              case _ -> {
                val d = tmp(c)
                c.insns.add(NCall(dest = d, retTy = rt, fn = NGlobal(name = irName), args = nargs))
                Val(ty = rt, value = NLocal(name = d))
              }
            }
          }
        }
      }
    }
    case _ -> unsupported(c, "a call through " + calleeKind(callee))
  }
}

func calleeKind(k: in Callee): String {
  match k {
    case Direct(_, _) -> "a direct callee"
    case Interface(_, _, _, _) -> "an interface method"
    case Indirect(_) -> "a function value"
    case Extern(_) -> "an extern member"
    case Intrinsic(_) -> "an intrinsic"
  }
}

func lowerConvert(c: in LCtx, e: in TExpr, kind: in ConvKind, inner: in TExpr): Val {
  match kind {
    case CvUnrefine -> lowerExpr(c, inner)
    case CvFromNever -> {
      val _ = lowerExpr(c, inner)
      match tyToN(e.ty) {
        case Some(nt) -> Val(ty = nt, value = NUndef(ty = nt))
        case None -> unsupported(c, "a conversion from Never to " + renderTy(e.ty))
      }
    }
    case CvWiden(_) -> {
      val v = lowerExpr(c, inner)
      match tyToN(e.ty) {
        case None -> unsupported(c, "a widening to " + renderTy(e.ty))
        case Some(to) -> lowerWiden(c, inner.ty, v, to)
      }
    }
    case _ -> unsupported(c, "a conversion")
  }
}

func lowerWiden(c: in LCtx, fromTy: in Ty, v: in Val, to: in NType): Val {
  val d = tmp(c)
  val fb = bitsOf(v.ty)
  val tb = bitsOf(to)
  if isFloatTy(fromTy) {
    match v.ty {
      case NFloat -> match to {
        case NDouble -> {
          c.insns.add(NFPExt(dest = d, value = v.value))
          return Val(ty = to, value = NLocal(name = d))
        }
        case _ -> ()
      }
      case _ -> ()
    }
    return unsupported(c, "a float conversion")
  }
  if fb == 0 {
    return unsupported(c, "a widening of a non-integer")
  }
  match to {
    case NDouble -> toFloat(c, fromTy, v, to, d)
    case NFloat -> toFloat(c, fromTy, v, to, d)
    case _ -> {
      if tb == fb {
        Val(ty = to, value = v.value)
      } else if tb > fb {
        if isUnsignedTy(fromTy) {
          c.insns.add(NZExt(dest = d, fromTy = v.ty, value = v.value, toTy = to))
        } else {
          c.insns.add(NSExt(dest = d, fromTy = v.ty, value = v.value, toTy = to))
        }
        Val(ty = to, value = NLocal(name = d))
      } else {
        unsupported(c, "a narrowing conversion")
      }
    }
  }
}

func toFloat(c: in LCtx, fromTy: in Ty, v: in Val, to: in NType, d: in String): Val {
  if isUnsignedTy(fromTy) {
    return unsupported(c, "an unsigned to float conversion")
  }
  c.insns.add(NSIToFP(dest = d, fromTy = v.ty, value = v.value, toTy = to))
  Val(ty = to, value = NLocal(name = d))
}

func lowerIf(c: in LCtx, e: in TExpr, cond: in TExpr, t: in TExpr, el: in Option[TExpr]): Val {
  val cv = lowerExpr(c, cond)
  val thenL = newLabel(c, "if.then")
  val elseL = newLabel(c, "if.else")
  val endL = newLabel(c, "if.end")
  c.insns.add(NCondBr(cond = cv.value, thenLabel = thenL, elseLabel = elseL))
  startBlock(c, thenL)
  val tv = lowerExpr(c, t)
  val thenEnd = curBlock(c)
  c.insns.add(NBr(label = endL))
  startBlock(c, elseL)
  val ev = match el { case Some(x) -> lowerExpr(c, x); case None -> unitVal() }
  val elseEnd = curBlock(c)
  c.insns.add(NBr(label = endL))
  startBlock(c, endL)
  match tyToN(e.ty) {
    case None -> unsupported(c, "an if of type " + renderTy(e.ty))
    case Some(nt) -> match nt {
      case NVoid -> unitVal()
      case _ -> {
        val d = tmp(c)
        val inc: List[NPhiIncoming] = newList()
        inc.add(NPhiIncoming(value = tv.value, label = thenEnd))
        inc.add(NPhiIncoming(value = ev.value, label = elseEnd))
        c.insns.add(NPhi(dest = d, ty = nt, incoming = inc))
        Val(ty = nt, value = NLocal(name = d))
      }
    }
  }
}

func lowerShort(c: in LCtx, op: in ShortOp, l: in TExpr, r: in TExpr): Val {
  val isAnd = match op {
    case ShAnd -> true
    case ShOr -> false
    case _ -> return unsupported(c, "a short-circuit operator")
  }
  val lv = lowerExpr(c, l)
  val lhsEnd = curBlock(c)
  val rhsL = newLabel(c, "sc.rhs")
  val endL = newLabel(c, "sc.end")
  if isAnd {
    c.insns.add(NCondBr(cond = lv.value, thenLabel = rhsL, elseLabel = endL))
  } else {
    c.insns.add(NCondBr(cond = lv.value, thenLabel = endL, elseLabel = rhsL))
  }
  startBlock(c, rhsL)
  val rv = lowerExpr(c, r)
  val rhsEnd = curBlock(c)
  c.insns.add(NBr(label = endL))
  startBlock(c, endL)
  val d = tmp(c)
  val inc: List[NPhiIncoming] = newList()
  inc.add(NPhiIncoming(value = NLitInt(v = if isAnd { 0i64 } else { 1i64 }, ty = NI1), label = lhsEnd))
  inc.add(NPhiIncoming(value = rv.value, label = rhsEnd))
  c.insns.add(NPhi(dest = d, ty = NI1, incoming = inc))
  Val(ty = NI1, value = NLocal(name = d))
}

func lowerAssign(c: in LCtx, place: in TPlace, op: in AssignKind, value: in TExpr): Val {
  match place.kind {
    case PlLocal(id) -> match mapGet(c.slots, id.id) {
      case None -> unsupported(c, "an assignment to a local with no slot")
      case Some(slot) -> {
        val rhs = lowerExpr(c, value)
        match assignOp(op) {
          case None -> c.insns.add(NStore(ty = slot.ty, value = rhs.value, ptr = NLocal(name = slot.ptr)))
          case Some(iop) -> {
            val cur = tmp(c)
            c.insns.add(NLoad(dest = cur, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
            val res = lowerBinary(c, iop, place.ty, slot.ty, NLocal(name = cur), rhs.value, value.span.startPos.line)
            c.insns.add(NStore(ty = slot.ty, value = res.value, ptr = NLocal(name = slot.ptr)))
          }
        }
        unitVal()
      }
    }
    case _ -> unsupported(c, "an assignment to a field, element or global")
  }
}

func lowerStmt(c: in LCtx, s: in TStmt): Unit {
  match s.kind {
    case TsExpr(x) -> {
      val _ = lowerExpr(c, x)
    }
    case TsVar(decl, init) -> match declareSlot(c, decl) {
      case None -> ()
      case Some(slot) -> {
        val v = match init { case Some(x) -> lowerExpr(c, x); case None -> Val(ty = slot.ty, value = zeroOf(slot.ty)) }
        c.insns.add(NStore(ty = slot.ty, value = v.value, ptr = NLocal(name = slot.ptr)))
      }
    }
    case TsLet(pat, init) -> match pat.kind {
      case TpWild -> {
        val _ = lowerExpr(c, init)
      }
      case TpBind(decl, inner) -> match inner {
        case Some(_) -> {
          c.problems.add("a binding with a sub-pattern")
        }
        case None -> match declareSlot(c, decl) {
          case None -> ()
          case Some(slot) -> {
            val v = lowerExpr(c, init)
            c.insns.add(NStore(ty = slot.ty, value = v.value, ptr = NLocal(name = slot.ptr)))
          }
        }
      }
      case _ -> {
        c.problems.add("a destructuring let")
      }
    }
    case TsReturn(value) -> {
      match value {
        case Some(x) -> {
          val v = lowerExpr(c, x)
          match c.retTy {
            case NVoid -> c.insns.add(NRetVoid)
            case rt -> c.insns.add(NRet(ty = rt, value = v.value))
          }
        }
        case None -> c.insns.add(NRetVoid)
      }
      startBlock(c, newLabel(c, "dead"))
    }
    case TsWhile(label, cond, body) -> {
      val condL = newLabel(c, "while.cond")
      val bodyL = newLabel(c, "while.body")
      val endL = newLabel(c, "while.end")
      c.insns.add(NBr(label = condL))
      startBlock(c, condL)
      val cv = lowerExpr(c, cond)
      c.insns.add(NCondBr(cond = cv.value, thenLabel = bodyL, elseLabel = endL))
      startBlock(c, bodyL)
      c.loops.add(LoopLabels(label = label, breakL = endL, contL = condL))
      val _ = lowerExpr(c, body)
      c.loops.removeAt(c.loops.count - 1)
      c.insns.add(NBr(label = condL))
      startBlock(c, endL)
    }
    case TsLoop(label, body) -> {
      val bodyL = newLabel(c, "loop.body")
      val endL = newLabel(c, "loop.end")
      c.insns.add(NBr(label = bodyL))
      startBlock(c, bodyL)
      c.loops.add(LoopLabels(label = label, breakL = endL, contL = bodyL))
      val _ = lowerExpr(c, body)
      c.loops.removeAt(c.loops.count - 1)
      c.insns.add(NBr(label = bodyL))
      startBlock(c, endL)
    }
    case TsBreak(label) -> jumpLoop(c, label, true)
    case TsContinue(label) -> jumpLoop(c, label, false)
    case _ -> {
      c.problems.add("statement " + stmtKindName(s.kind))
    }
  }
}

func stmtKindName(k: in TStmtKind): String {
  match k {
    case TsLet(_, _) -> "TsLet"
    case TsVar(_, _) -> "TsVar"
    case TsExpr(_) -> "TsExpr"
    case TsReturn(_) -> "TsReturn"
    case TsBreak(_) -> "TsBreak"
    case TsContinue(_) -> "TsContinue"
    case TsThrow(_) -> "TsThrow"
    case TsTry(_, _, _) -> "TsTry"
    case TsDefer(_) -> "TsDefer"
    case TsScope(_, _) -> "TsScope"
    case TsFor(_, _, _, _) -> "TsFor"
    case TsWhile(_, _, _) -> "TsWhile"
    case TsLoop(_, _) -> "TsLoop"
    case TsInvariant(_) -> "TsInvariant"
  }
}

func jumpLoop(c: in LCtx, label: in Option[String], isBreak: in Bool): Unit {
  var i = c.loops.count - 1
  while i >= 0 {
    val lp = c.loops[i]
    val hit = match label {
      case None -> true
      case Some(want) -> match lp.label { case Some(have) -> have == want; case None -> false }
    }
    if hit {
      c.insns.add(NBr(label = if isBreak { lp.breakL } else { lp.contL }))
      startBlock(c, newLabel(c, "dead"))
      return
    }
    i = i - 1
  }
  c.problems.add("a break or continue outside a loop")
}

func fallback(sym: in SymbolId, why: in String): Result[TirLowered, TirFallback] {
  Err(error = TirFallback(sym = sym, reason = why))
}

/// Lower `fn`, a monomorphic function with a body.  `Err` names the first
/// construct this slice does not cover; the caller keeps the AST path's
/// lowering of `fn` and counts the fallback.
pub func lowerTirFunction(env: in TirLowerEnv, fn: in TFnDecl): Result[TirLowered, TirFallback] {
  if fn.typeParams.count > 0 {
    return fallback(fn.sym, "a generic function")
  }
  if fn.isAsync {
    return fallback(fn.sym, "an async function")
  }
  if fn.preconds.count > 0 or fn.postconds.count > 0 {
    return fallback(fn.sym, "contracts (docs/70 phase 3c elaborates them)")
  }
  val irName = match mapGet(env.fnNames, fn.sym.id) {
    case Some(n) -> n
    case None -> return fallback(fn.sym, "no IR name for symbol #" + toString(fn.sym.id))
  }
  val body = match fn.body { case Some(b) -> b; case None -> return fallback(fn.sym, "no body") }
  val retTy = match tyToN(fn.ret) {
    case Some(t) -> t
    case None -> return fallback(fn.sym, "return type " + renderTy(fn.ret))
  }
  val c = LCtx(
    env = env,
    insns = newList(),
    allocas = newList(),
    globals = newList(),
    ticker = newList(),
    cur = newList(),
    slots = newMap(),
    loops = newList(),
    problems = newList(),
    retTy = retTy
  )
  c.cur.add("entry")
  val params: List[NParam] = newList()
  val stores: List[NInsn] = newList()
  for p in fn.params {
    match p.mode {
      case TMIn -> ()
      case _ -> return fallback(fn.sym, "an out or inout parameter")
    }
    val pt = match tyToN(p.local.ty) {
      case Some(t) -> t
      case None -> return fallback(fn.sym, "parameter type " + renderTy(p.local.ty))
    }
    match pt {
      case NVoid -> return fallback(fn.sym, "a Unit parameter")
      case _ -> ()
    }
    val pname = "a" + toString(p.local.id.id)
    params.add(NParam(name = pname, ty = pt))
    match declareSlot(c, p.local) {
      case Some(slot) -> stores.add(NStore(ty = pt, value = NLocal(name = pname), ptr = NLocal(name = slot.ptr)))
      case None -> ()
    }
  }
  val result = lowerExpr(c, body)
  match retTy {
    case NVoid -> c.insns.add(NRetVoid)
    case _ -> c.insns.add(NRet(ty = retTy, value = result.value))
  }
  if c.problems.count > 0 {
    return fallback(fn.sym, c.problems[0])
  }
  val all: List[NInsn] = newList()
  all.add(NLabel(name = "entry"))
  for a in c.allocas {
    all.add(a)
  }
  for s in stores {
    all.add(s)
  }
  for i in c.insns {
    all.add(i)
  }
  val externs: List[NFunc] = newList()
  if c.globals.count > 0 {
    val pargs: List[NParam] = newList()
    pargs.add(NParam(name = "m", ty = NPtr(pointee = NI8)))
    pargs.add(NParam(name = "f", ty = NPtr(pointee = NI8)))
    pargs.add(NParam(name = "l", ty = NI32))
    externs.add(
      NFunc(
        name = "lyric_panic_msg",
        params = pargs,
        retTy = NVoid,
        isPublic = true,
        isExtern = true,
        body = newList(),
        attributes = newList()
      )
    )
  }
  Ok(
    value = TirLowered(
      fn = NFunc(
        name = irName,
        params = params,
        retTy = retTy,
        isPublic = false,
        isExtern = false,
        body = all,
        attributes = newList()
      ),
      globals = c.globals,
      externs = externs
    )
  )
}
