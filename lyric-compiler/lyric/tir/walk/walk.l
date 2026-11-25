//! walk.l - Lyric.Tir.Walk: a rewriting traversal of TIR (docs/70 §7.2, D503).
//!
//! `walkExpr` rebuilds an expression bottom-up and offers each node to two hooks: `pre` sees a node before its
//! children and may replace it outright (the replacement is not visited again), `post` sees the node after its
//! children were rewritten and may replace it.  A pass that rewrites one node kind (`?` propagation, await hoisting)
//! writes the hook and leaves the traversal of the other thirty kinds here.
package Lyric.Tir.Walk

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir

pub record Walker {
  pre: (TExpr) -> Option[TExpr]
  post: (TExpr) -> TExpr
  /// Offered each statement of a block before it is walked: `Some(stmts)` replaces it with those statements (which
  /// the walk does not visit again), `None` walks it as usual.
  preStmt: (TStmt) -> Option[List[TStmt]] = { s: TStmt -> None }
}

func wOptExpr(w: in Walker, o: in Option[TExpr]): Option[TExpr] {
  match o {
    case Some(e) -> Some(value = walkExpr(w, e))
    case None -> None
  }
}

func wExprs(w: in Walker, xs: in List[TExpr]): List[TExpr] {
  val res: List[TExpr] = newList()
  for x in xs {
    res.add(walkExpr(w, x))
  }
  res
}

func wArg(w: in Walker, a: in TArg): TArg {
  match a {
    case TArgIn(v) -> TArgIn(value = walkExpr(w, v))
    case TArgOut(p) -> TArgOut(place = wPlace(w, p))
    case TArgInout(p) -> TArgInout(place = wPlace(w, p))
  }
}

func wPlace(w: in Walker, p: in TPlace): TPlace {
  val k: TPlaceKind = match p.kind {
    case PlLocal(_) -> p.kind
    case PlGlobal(_) -> p.kind
    case PlField(recv, f) -> PlField(recv = walkExpr(w, recv), field = f)
    case PlIndex(recv, idx, how) -> PlIndex(
      recv = walkExpr(w, recv),
      idx = walkExpr(w, idx),
      how = how
    )
  }
  TPlace(ty = p.ty, kind = k)
}

func wPat(w: in Walker, p: in TPat): TPat {
  val k: TPatKind = match p.kind {
    case TpBind(d, inner) -> TpBind(
      decl = d,
      inner = match inner {
        case Some(i) -> Some(value = wPat(w, i))
        case None -> None
      }
    )
    case TpCtor(sym, args) -> {
      val subs: List[TPat] = newList()
      for a in args {
        subs.add(wPat(w, a))
      }
      TpCtor(sym = sym, args = subs)
    }
    case TpRecord(sym, fields) -> {
      val fs: List[TFieldPat] = newList()
      for f in fields {
        fs.add(TFieldPat(field = f.field, pat = wPat(w, f.pat)))
      }
      TpRecord(sym = sym, fields = fs)
    }
    case TpTuple(elems) -> {
      val es: List[TPat] = newList()
      for e in elems {
        es.add(wPat(w, e))
      }
      TpTuple(elems = es)
    }
    case TpTypeTest(inner, ty) -> TpTypeTest(inner = wPat(w, inner), ty = ty)
    case TpOr(alts) -> {
      val altList: List[TPat] = newList()
      for a in alts {
        altList.add(wPat(w, a))
      }
      TpOr(alts = altList)
    }
    case _ -> p.kind
  }
  TPat(id = p.id, ty = p.ty, span = p.span, kind = k)
}

func wStmt(w: in Walker, st: in TStmt): TStmt {
  val k: TStmtKind = match st.kind {
    case TsLet(pat, init) -> TsLet(pat = wPat(w, pat), init = walkExpr(w, init))
    case TsVar(d, init) -> TsVar(decl = d, init = wOptExpr(w, init))
    case TsExpr(e) -> TsExpr(expr = walkExpr(w, e))
    case TsReturn(v) -> TsReturn(value = wOptExpr(w, v))
    case TsBreak(_) -> st.kind
    case TsContinue(_) -> st.kind
    case TsThrow(e) -> TsThrow(expr = walkExpr(w, e))
    case TsTry(body, catches, fin) -> {
      val cs: List[TCatch] = newList()
      for ct in catches {
        cs.add(TCatch(binding = ct.binding, exceptionType = ct.exceptionType, body = walkExpr(w, ct.body)))
      }
      TsTry(body = walkExpr(w, body), catches = cs, finallyBody = wOptExpr(w, fin))
    }
    case TsDefer(b) -> TsDefer(body = walkExpr(w, b))
    case TsScope(b, body) -> TsScope(binding = b, body = walkExpr(w, body))
    case TsFor(label, pat, iter, body) -> TsFor(
      label = label,
      pat = wPat(w, pat),
      iter = walkExpr(w, iter),
      body = walkExpr(w, body)
    )
    case TsWhile(label, cond, body) -> TsWhile(
      label = label,
      cond = walkExpr(w, cond),
      body = walkExpr(w, body)
    )
    case TsLoop(label, body) -> TsLoop(label = label, body = walkExpr(w, body))
    case TsInvariant(e, t) -> TsInvariant(expr = walkExpr(w, e), text = t)
  }
  TStmt(id = st.id, span = st.span, kind = k)
}

/// `e` rewritten by the hooks of `w`.
pub func walkExpr(w: in Walker, e: in TExpr): TExpr {
  match w.pre(e) {
    case Some(r) -> return r
    case None -> ()
  }
  val k: TExprKind = match e.kind {
    case XLit(_) -> e.kind
    case XLocal(_) -> e.kind
    case XGlobal(_, _) -> e.kind
    case XValueParam(_, _) -> e.kind
    case XCall(callee, args) -> {
      val argList: List[TArg] = newList()
      for a in args {
        argList.add(wArg(w, a))
      }
      val cl: Callee = match callee { case Indirect(fv) -> Indirect(fnValue = walkExpr(w, fv)); case _ -> callee }
      XCall(callee = cl, args = argList)
    }
    case XConstruct(sym, fields) -> XConstruct(sym = sym, fields = wExprs(w, fields))
    case XField(recv, f) -> XField(recv = walkExpr(w, recv), field = f)
    case XCopy(base, updates) -> {
      val us: List[TFieldUpdate] = newList()
      for u in updates {
        us.add(TFieldUpdate(field = u.field, value = walkExpr(w, u.value)))
      }
      XCopy(base = walkExpr(w, base), updates = us)
    }
    case XArrayCopy(inner) -> XArrayCopy(inner = walkExpr(w, inner))
    case XZeroValue(_) -> e.kind
    case XIndex(recv, idx, how) -> XIndex(
      recv = walkExpr(w, recv),
      idx = walkExpr(w, idx),
      how = how
    )
    case XConvert(kind, inner) -> XConvert(kind = kind, inner = walkExpr(w, inner))
    case XTuple(elems) -> XTuple(elems = wExprs(w, elems))
    case XListLit(elems) -> XListLit(elems = wExprs(w, elems))
    case XInterp(parts) -> XInterp(parts = wExprs(w, parts))
    case XRange(lo, hi, inc) -> XRange(lo = walkExpr(w, lo), hi = walkExpr(w, hi), inclusive = inc)
    case XShort(op, l, r) -> XShort(op = op, lhs = walkExpr(w, l), rhs = walkExpr(w, r))
    case XIf(cond, t, f) -> XIf(
      cond = walkExpr(w, cond),
      thenBranch = walkExpr(w, t),
      elseBranch = wOptExpr(w, f)
    )
    case XMatch(scrut, arms, exh) -> {
      val as1: List[TArm] = newList()
      for a in arms {
        as1.add(TArm(pat = wPat(w, a.pat), guard = wOptExpr(w, a.guard), body = walkExpr(w, a.body)))
      }
      XMatch(scrutinee = walkExpr(w, scrut), arms = as1, exhaustive = exh)
    }
    case XBlock(stmts, tail) -> {
      val ss: List[TStmt] = newList()
      for st in stmts {
        match w.preStmt(st) {
          case Some(repl) -> {
            for r in repl {
              ss.add(r)
            }
          }
          case None -> ss.add(wStmt(w, st))
        }
      }
      XBlock(stmts = ss, tail = wOptExpr(w, tail))
    }
    case XUnsafe(b) -> XUnsafe(body = walkExpr(w, b))
    case XLambda(ps, caps, body) -> XLambda(params = ps, captures = caps, body = walkExpr(w, body))
    case XAwait(i) -> XAwait(inner = walkExpr(w, i))
    case XSpawn(i) -> XSpawn(inner = walkExpr(w, i))
    case XYield(i) -> XYield(inner = walkExpr(w, i))
    case XPropagate(i) -> XPropagate(inner = walkExpr(w, i))
    case XOld(i) -> XOld(inner = walkExpr(w, i))
    case XResult -> e.kind
    case XForall(bs, wh, body) -> XForall(
      binders = bs,
      whereExpr = wOptExpr(w, wh),
      body = walkExpr(w, body)
    )
    case XExists(bs, wh, body) -> XExists(
      binders = bs,
      whereExpr = wOptExpr(w, wh),
      body = walkExpr(w, body)
    )
    case XAssign(p, op, v) -> XAssign(place = wPlace(w, p), op = op, value = walkExpr(w, v))
  }
  w.post(TExpr(id = e.id, ty = e.ty, span = e.span, kind = k))
}
