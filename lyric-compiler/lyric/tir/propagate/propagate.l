//! propagate.l - Lyric.Tir.Propagate: `?` lowering on TIR (docs/70 §7.2, D503).
//!
//! `XPropagate(e)` becomes a block that binds the operand and matches it: the success case yields its payload,
//! the failure case `return`s the failure rebuilt at the function's declared type (`Err(x)` of `Result[U, E]`,
//! `None` of `Option[U]`), as `Lyric.Propagate` does on the AST.  The monad is the operand's: a `Result` operand
//! needs a `Result` result with the same error type, an `Option` operand an `Option` result; a lambda's result is
//! its own function type's.  Any other use is reported and left as written (the checker rejects it with F0020).
//! Operand-position hoisting, which the stack-machine backends need, is the await-hoisting pass's job (§7.2).
package Lyric.Tir.Propagate

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build
import Lyric.Tir.Walk

/// The symbols the lowering names: the standard library's `Result` and `Option` and their cases.
pub record PropCases {
  resultSym: SymbolId
  okSym: SymbolId
  errSym: SymbolId
  optionSym: SymbolId
  someSym: SymbolId
  noneSym: SymbolId
}

/// The symbols of `Std.Core`'s `Result` and `Option` as `interner` knows them, or `None` when the compilation
/// never met one of them.
pub func propCasesOf(interner: in DefPathInterner): Option[PropCases] {
  val rs = match symbolIdOfKey(interner, "Std.Core::Result") { case Some(x) -> x; case None -> return None }
  val ok = match symbolIdOfKey(interner, "Std.Core::Result::Ok") { case Some(x) -> x; case None -> return None }
  val er = match symbolIdOfKey(interner, "Std.Core::Result::Err") { case Some(x) -> x; case None -> return None }
  val os = match symbolIdOfKey(interner, "Std.Core::Option") { case Some(x) -> x; case None -> return None }
  val sm = match symbolIdOfKey(interner, "Std.Core::Option::Some") { case Some(x) -> x; case None -> return None }
  val nn = match symbolIdOfKey(interner, "Std.Core::Option::None") { case Some(x) -> x; case None -> return None }
  Some(value = PropCases(resultSym = rs, okSym = ok, errSym = er, optionSym = os, someSym = sm, noneSym = nn))
}

record PCtx {
  cs: PropCases
  nextNode: List[Int]
  nextLocal: List[Int]
  diags: List[String]
}

func firstPropNodeId(): Int {
  800000000
}

func firstPropLocalId(): Int {
  1600000000
}

func pNode(c: in PCtx): NodeId {
  val n = c.nextNode[0]
  c.nextNode[0] = n + 1
  NodeId(id = n)
}

func pLocal(c: in PCtx, name: in String, ty: in Ty): LocalDecl {
  val n = c.nextLocal[0]
  c.nextLocal[0] = n + 1
  LocalDecl(id = LocalId(id = n), name = name, ty = ty, mutable = false)
}

func pRead(c: in PCtx, l: in LocalDecl, sp: in Span): TExpr {
  TExpr(id = pNode(c), ty = l.ty, span = sp, kind = XLocal(local = l.id))
}

func pBind(c: in PCtx, l: in LocalDecl, sp: in Span): TPat {
  TPat(id = pNode(c), ty = l.ty, span = sp, kind = TpBind(decl = l, inner = None))
}

func isNamed(t: in Ty, sym: in SymbolId): Bool {
  match t {
    case TNamed(s, _) -> symbolIdEq(s, sym)
    case _ -> false
  }
}

func argsOf(t: in Ty): List[Ty] {
  match t {
    case TNamed(_, a) -> a
    case _ -> newList()
  }
}

/// The block `e` (an `XPropagate` of `inner`) becomes, when the operand and the enclosing result agree.
func lowerOne(c: in PCtx, ret: in Ty, e: in TExpr, inner: in TExpr): TExpr {
  val sp = e.span
  val ot = inner.ty
  val oargs = argsOf(ot)
  val rargs = argsOf(ret)
  val isResult = isNamed(ot, c.cs.resultSym) and isNamed(ret, c.cs.resultSym) and oargs.count == 2 and rargs.count == 2 and
    tyEq(oargs[1], rargs[1])
  val isOption = isNamed(ot, c.cs.optionSym) and isNamed(ret, c.cs.optionSym) and oargs.count == 1 and rargs.count == 1
  if not isResult and not isOption {
    c.diags.add("`?` on " + renderTy(ot) + " in a function returning " + renderTy(ret) + " has no lowering")
    return e
  }
  val p = pLocal(c, "__lyric_prop", ot)
  val v = pLocal(c, "__lyric_ok", oargs[0])
  val arms: List[TArm] = newList()
  val okPat = if isResult { c.cs.okSym } else { c.cs.someSym }
  val vpats: List[TPat] = newList()
  vpats.add(pBind(c, v, sp))
  arms.add(
    TArm(
      pat = TPat(id = pNode(c), ty = ot, span = sp, kind = TpCtor(sym = okPat, args = vpats)),
      guard = None,
      body = pRead(c, v, sp)
    )
  )
  val failPats: List[TPat] = newList()
  val failFields: List[TExpr] = newList()
  var failSym = c.cs.noneSym
  if isResult {
    val x = pLocal(c, "__lyric_err", oargs[1])
    failPats.add(pBind(c, x, sp))
    failFields.add(pRead(c, x, sp))
    failSym = c.cs.errSym
  }
  val rets: List[TStmt] = newList()
  rets.add(
    TStmt(
      id = pNode(c),
      span = sp,
      kind = TsReturn(
        value = Some(value = TExpr(id = pNode(c), ty = ret, span = sp, kind = XConstruct(sym = failSym, fields = failFields)))
      )
    )
  )
  arms.add(
    TArm(
      pat = TPat(id = pNode(c), ty = ot, span = sp, kind = TpCtor(sym = failSym, args = failPats)),
      guard = None,
      body = TExpr(id = pNode(c), ty = TNever, span = sp, kind = XBlock(stmts = rets, tail = None))
    )
  )
  val m = TExpr(
    id = pNode(c),
    ty = e.ty,
    span = sp,
    kind = XMatch(scrutinee = pRead(c, p, sp), arms = arms, exhaustive = true)
  )
  val stmts: List[TStmt] = newList()
  stmts.add(TStmt(id = pNode(c), span = sp, kind = TsLet(pat = pBind(c, p, sp), init = inner)))
  TExpr(id = pNode(c), ty = e.ty, span = sp, kind = XBlock(stmts = stmts, tail = Some(value = m)))
}

func propPre(c: in PCtx, e: in TExpr): Option[TExpr] {
  match e.kind {
    case XLambda(ps, caps, body) -> match e.ty {
      case TFunc(_, r, _) -> Some(
        value = TExpr(id = e.id, ty = e.ty, span = e.span, kind = XLambda(params = ps, captures = caps, body = lowerBody(c, r, body)))
      )
      case _ -> None
    }
    case _ -> None
  }
}

func lowerBody(c: in PCtx, ret: in Ty, body: in TExpr): TExpr {
  val w = Walker(
    pre = { e: TExpr -> propPre(c, e) },
    post = { e: TExpr -> propPost(c, ret, e) }
  )
  walkExpr(w, body)
}

func propPost(c: in PCtx, ret: in Ty, e: in TExpr): TExpr {
  match e.kind {
    case XPropagate(inner) -> lowerOne(c, ret, e, inner)
    case _ -> e
  }
}

/// `d` with every `?` of its body lowered.  `diags` collects what could not be (an operand and a result of
/// different monads); a declaration with no body or a generator is returned as it is.
pub func lowerPropagateFn(d: in TFnDecl, cs: in PropCases, nextNode: in List[Int], diags: in List[String]): TFnDecl {
  val body = match d.body { case Some(b) -> b; case None -> return d }
  if d.isGenerator {
    return d
  }
  val nl: List[Int] = newList()
  nl.add(firstPropLocalId())
  val c = PCtx(cs = cs, nextNode = nextNode, nextLocal = nl, diags = diags)
  val lowered = lowerBody(c, d.ret, body)
  TFnDecl(
    sym = d.sym,
    typeParams = d.typeParams,
    params = d.params,
    ret = d.ret,
    isAsync = d.isAsync,
    preconds = d.preconds,
    postconds = d.postconds,
    body = Some(value = lowered),
    span = d.span,
    barrier = d.barrier,
    ownerParamCount = d.ownerParamCount,
    isGenerator = d.isGenerator,
    precondTexts = d.precondTexts,
    postcondTexts = d.postcondTexts
  )
}

/// The outcome of lowering a bundle: the packages and what could not be lowered.
pub record PropResult {
  pkgs: List[PackageBuild]
  diags: List[String]
}

/// `bundle` with `?` lowered in every function of every package.  A bundle whose compilation never met
/// `Result` or `Option` has no `?` to lower and is returned as it is.
pub func lowerPropagateBundle(interner: in DefPathInterner, bundle: in List[PackageBuild]): PropResult {
  val diags: List[String] = newList()
  val cs = match propCasesOf(interner) {
    case Some(x) -> x
    case None -> return PropResult(pkgs = bundle, diags = diags)
  }
  val res: List[PackageBuild] = newList()
  for pb in bundle {
    val nn: List[Int] = newList()
    nn.add(firstPropNodeId())
    val fns: List[TFnDecl] = newList()
    for f in pb.pkg.funcs {
      fns.add(lowerPropagateFn(f, cs, nn, diags))
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
  PropResult(pkgs = res, diags = diags)
}
