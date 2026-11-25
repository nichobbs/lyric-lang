//! unsigned.l - Lyric.Tir.Unsigned: the checked and corrected `ULong` conversions on TIR (docs/70 §7.2, D508).
//!
//! `w.toLong()`, `w.toDouble()` and `w.toFloat()` on a `ULong` (D278) are the built-ins `ULong.toLong`,
//! `ULong.toDouble` and `ULong.toFloat` in the TIR; a backend sees the same 64 bits as a `Long` and could not tell
//! the checked or corrected conversion from the plain one.  This pass rewrites each into the block the AST pass
//! (`Lyric.ContractElaborator.lowerOverflowChecks`) builds, with the plain reading of the bits as a `CvReinterpret`:
//!
//!   toLong    { val u = w; val s = reinterpret(u); if s < 0 { panic("ULong value is above Long.MaxValue and ...") }; s }
//!   toDouble  { val u = w; val s = reinterpret(u);
//!               if s >= 0 { s.toDouble() } else { (((s shr 1) and Long.MaxValue) or (s and 1)).toDouble() * 2.0 } }
//!
//! (`toFloat` likewise with `Float` and `2.0f32`: the value halved with its low bit folded in keeps the single
//! rounding exact.)  The conversions inside the block are on a `Long`, which every backend lowers.
package Lyric.Tir.Unsigned

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build
import Lyric.Tir.Walk

record UCtx {
  nextNode: List[Int]
  nextLocal: List[Int]
}

func firstUnsignedNodeId(): Int {
  750000000
}

func firstUnsignedLocalId(): Int {
  1550000000
}

func uNode(c: in UCtx): NodeId {
  val n = c.nextNode[0]
  c.nextNode[0] = n + 1
  NodeId(id = n)
}

func uLocal(c: in UCtx, name: in String, ty: in Ty): LocalDecl {
  val n = c.nextLocal[0]
  c.nextLocal[0] = n + 1
  LocalDecl(id = LocalId(id = n), name = name, ty = ty, mutable = false)
}

func uRead(c: in UCtx, l: in LocalDecl, sp: in Span): TExpr {
  TExpr(id = uNode(c), ty = l.ty, span = sp, kind = XLocal(local = l.id))
}

func uLet(c: in UCtx, l: in LocalDecl, init: in TExpr, sp: in Span): TStmt {
  val pat = TPat(id = uNode(c), ty = l.ty, span = sp, kind = TpBind(decl = l, inner = None))
  TStmt(id = uNode(c), span = sp, kind = TsLet(pat = pat, init = init))
}

func uCall(c: in UCtx, op: in IntrinsicOp, ty: in Ty, args: in List[TExpr], sp: in Span): TExpr {
  val targs: List[TArg] = newList()
  for a in args {
    targs.add(TArgIn(value = a))
  }
  TExpr(id = uNode(c), ty = ty, span = sp, kind = XCall(callee = Intrinsic(op = op), args = targs))
}

func uLong(c: in UCtx, v: in Long, sp: in Span): TExpr {
  TExpr(id = uNode(c), ty = TPrim(kind = TPLong), span = sp, kind = XLit(lit = TLInt(value = v)))
}

func two(a: in TExpr, b: in TExpr): List[TExpr] {
  val xs: List[TExpr] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

func one(a: in TExpr): List[TExpr] {
  val xs: List[TExpr] = newList()
  xs.add(a)
  xs
}

func isUnsignedConversion(name: in String): Bool {
  name == "ULong.toLong" or name == "ULong.toDouble" or name == "ULong.toFloat"
}

/// The block that stands for `recv.<method>()` on a `ULong`, at the node's own type `ty`.
func lowerConversion(c: in UCtx, e: in TExpr, method: in String, recv: in TExpr): TExpr {
  val sp = e.span
  val u = uLocal(c, "__ulong_u", TPrim(kind = TPULong))
  val s = uLocal(c, "__ulong_s", TPrim(kind = TPLong))
  val stmts: List[TStmt] = newList()
  stmts.add(uLet(c, u, recv, sp))
  val bits = TExpr(
    id = uNode(c),
    ty = TPrim(kind = TPLong),
    span = sp,
    kind = XConvert(kind = CvReinterpret, inner = uRead(c, u, sp))
  )
  stmts.add(uLet(c, s, bits, sp))
  if method == "toLong" {
    val msg = TExpr(
      id = uNode(c),
      ty = tyString(),
      span = sp,
      kind = XLit(lit = TLString(text = "ULong value is above Long.MaxValue and does not fit in a Long"))
    )
    val boom = uCall(c, IoBuiltin(name = "panic"), TNever, one(msg), sp)
    val thenStmts: List[TStmt] = newList()
    thenStmts.add(TStmt(id = uNode(c), span = sp, kind = TsExpr(expr = boom)))
    val thenB = TExpr(id = uNode(c), ty = tyUnit(), span = sp, kind = XBlock(stmts = thenStmts, tail = None))
    val neg = uCall(c, IoLt, tyBool(), two(uRead(c, s, sp), uLong(c, 0i64, sp)), sp)
    val guard = TExpr(
      id = uNode(c),
      ty = tyUnit(),
      span = sp,
      kind = XIf(cond = neg, thenBranch = thenB, elseBranch = None)
    )
    stmts.add(TStmt(id = uNode(c), span = sp, kind = TsExpr(expr = guard)))
    return TExpr(id = e.id, ty = e.ty, span = sp, kind = XBlock(stmts = stmts, tail = Some(value = uRead(c, s, sp))))
  }
  val conv = "Long." + method
  val isFloat = method == "toFloat"
  val direct = uCall(c, IoBuiltin(name = conv), e.ty, one(uRead(c, s, sp)), sp)
  val shifted = uCall(
    c,
    IoBuiltin(name = "Long.shr"),
    TPrim(kind = TPLong),
    two(
      uRead(c, s, sp),
      TExpr(id = uNode(c), ty = tyInt(), span = sp, kind = XLit(lit = TLInt(value = 1i64)))
    ),
    sp
  )
  val masked = uCall(
    c,
    IoBuiltin(name = "Long.and"),
    TPrim(kind = TPLong),
    two(shifted, uLong(c, 9223372036854775807i64, sp)),
    sp
  )
  val low = uCall(c, IoBuiltin(name = "Long.and"), TPrim(kind = TPLong), two(uRead(c, s, sp), uLong(c, 1i64, sp)), sp)
  val halved = uCall(c, IoBuiltin(name = "Long.or"), TPrim(kind = TPLong), two(masked, low), sp)
  val converted = uCall(c, IoBuiltin(name = conv), e.ty, one(halved), sp)
  val twoLit = TExpr(id = uNode(c), ty = e.ty, span = sp, kind = XLit(lit = TLFloat(value = 2.0)))
  val doubled = uCall(c, IoMul, e.ty, two(converted, twoLit), sp)
  val nonNeg = uCall(c, IoGte, tyBool(), two(uRead(c, s, sp), uLong(c, 0i64, sp)), sp)
  val pick = TExpr(
    id = uNode(c),
    ty = e.ty,
    span = sp,
    kind = XIf(cond = nonNeg, thenBranch = direct, elseBranch = Some(value = doubled))
  )
  TExpr(id = e.id, ty = e.ty, span = sp, kind = XBlock(stmts = stmts, tail = Some(value = pick)))
}

func unsignedPost(c: in UCtx, e: in TExpr): TExpr {
  match e.kind {
    case XCall(callee, args) -> match callee {
      case Intrinsic(op) -> match op {
        case IoBuiltin(name) -> if isUnsignedConversion(name) and args.count == 1 {
          match args[0] {
            case TArgIn(recv) -> lowerConversion(c, e, name.substring(6, name.length - 6), recv)
            case _ -> e
          }
        } else {
          e
        }
        case _ -> e
      }
      case _ -> e
    }
    case _ -> e
  }
}

/// `d` with every `ULong` conversion of its body lowered; a declaration with no body is returned as it is.
pub func lowerUnsignedFn(d: in TFnDecl, nextNode: in List[Int]): TFnDecl {
  val body = match d.body { case Some(b) -> b; case None -> return d }
  val nl: List[Int] = newList()
  nl.add(firstUnsignedLocalId())
  val c = UCtx(nextNode = nextNode, nextLocal = nl)
  val w = Walker(pre = { e: TExpr -> None }, post = { e: TExpr -> unsignedPost(c, e) })
  d.copy(body = Some(value = walkExpr(w, body)))
}

/// `bundle` with the `ULong` conversions lowered in every function of every package.
pub func lowerUnsignedBundle(bundle: in List[PackageBuild]): List[PackageBuild] {
  val res: List[PackageBuild] = newList()
  for pb in bundle {
    val nn: List[Int] = newList()
    nn.add(firstUnsignedNodeId())
    val fns: List[TFnDecl] = newList()
    for f in pb.pkg.funcs {
      fns.add(lowerUnsignedFn(f, nn))
    }
    res.add(
      PackageBuild(
        pkg = TPackage(name = pb.pkg.name, symbols = pb.pkg.symbols, funcs = fns),
        failed = pb.failed,
        total = pb.total,
        built = pb.built,
        names = pb.names,
        cases = pb.cases,
        uncovered = pb.uncovered,
        sites = pb.sites
      )
    )
  }
  res
}
