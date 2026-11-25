//! mono_expr.l - Lyric.Tir.Mono: the rewrite of a body (docs/70 §7.2, D500).
//!
//! One traversal serves both a non-generic body (nothing to substitute: its generic calls and
//! constructions become instances) and a generic body read at its arguments (`Subst`).  Every
//! type goes through `mTy`; a call, global, construction, field, case pattern and method index
//! that names a generic declaration is redirected to the instance the node's own types and type
//! arguments fix.
package Lyric.Tir.Mono

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build

func mLocal(c: in MCtx, s: in Subst, d: in LocalDecl): LocalDecl {
  LocalDecl(id = d.id, name = d.name, ty = mTy(c, s, d.ty), mutable = d.mutable)
}

func mLocals(c: in MCtx, s: in Subst, ds: in List[LocalDecl]): List[LocalDecl] {
  val res: List[LocalDecl] = newList()
  for d in ds {
    res.add(mLocal(c, s, d))
  }
  res
}

func mOptExpr(c: in MCtx, s: in Subst, o: in Option[TExpr]): Option[TExpr] {
  match o {
    case Some(e) -> Some(value = mExpr(c, s, e))
    case None -> None
  }
}

func mExprs(c: in MCtx, s: in Subst, xs: in List[TExpr]): List[TExpr] {
  val res: List[TExpr] = newList()
  for x in xs {
    res.add(mExpr(c, s, x))
  }
  res
}

func mHost(c: in MCtx, s: in Subst, m: in HostMemberRef): HostMemberRef {
  m.copy(
    owner = HostTypeRef(name = m.owner.name, args = mTys(c, s, m.owner.args)),
    params = mParamTys(c, s, m.params),
    ret = mTy(c, s, m.ret),
    typeArgs = mTys(c, s, m.typeArgs)
  )
}

/// The record or case symbol `sym` as the instance the type `ty` (read at `s`) fixes: a case of a
/// union applied to arguments is that union instance's case, a record applied to arguments the
/// record instance, anything else `sym`.
func instCtorSym(c: in MCtx, s: in Subst, sym: in SymbolId, ty: in Ty): SymbolId {
  match sTy(s, ty) {
    case TNamed(tsym, targs) -> {
      if targs.count == 0 {
        return sym
      }
      val a = iTys(c, targs)
      match mapGet(c.caseParent, sym.id) {
        case Some(parent) -> instCase(c, parent, sym, a)
        case None -> match instType(c, tsym, a) { case Some(i) -> i; case None -> sym }
      }
    }
    case _ -> sym
  }
}

/// The field `f` of a value of type `recvTy`: when that type is an instance of the field's owner the
/// owner is the instance.
func mField(c: in MCtx, s: in Subst, recvTy: in Ty, f: in FieldRef): FieldRef {
  match sTy(s, recvTy) {
    case TNamed(tsym, targs) -> if targs.count > 0 and symbolIdEq(tsym, f.owner) {
      match instType(c, tsym, iTys(c, targs)) {
        case Some(i) -> FieldRef(owner = i, name = f.name, index = f.index)
        case None -> f
      }
    } else {
      f
    }
    case _ -> f
  }
}

func mIndexKind(c: in MCtx, s: in Subst, recvTy: in Ty, how: in IndexKind): IndexKind {
  match how {
    case IkMethod(sym) -> match sTy(s, recvTy) {
      case TNamed(_, targs) -> match instCallee(c, sym, iTys(c, targs)) {
        case Some(i) -> IkMethod(sym = i)
        case None -> how
      }
      case _ -> how
    }
    case IkHost(m) -> IkHost(member = mHost(c, s, m))
    case _ -> how
  }
}

func mCallee(c: in MCtx, s: in Subst, callee: in Callee): Callee {
  match callee {
    case Direct(sym, targs) -> {
      val ta = mTys(c, s, targs)
      match instCallee(c, sym, ta) {
        case Some(i) -> Direct(sym = i, typeArgs = newList())
        case None -> Direct(sym = sym, typeArgs = ta)
      }
    }
    case Interface(iface, ifaceArgs, method, targs) -> {
      if ifaceArgs.count > 0 {
        noteUnresolved(c, "generic interface call")
      }
      Interface(iface = iface, ifaceArgs = mTys(c, s, ifaceArgs), method = method, typeArgs = mTys(c, s, targs))
    }
    case Indirect(fv) -> Indirect(fnValue = mExpr(c, s, fv))
    case Extern(m) -> Extern(member = mHost(c, s, m))
    case Intrinsic(_) -> callee
  }
}

func mArg(c: in MCtx, s: in Subst, a: in TArg): TArg {
  match a {
    case TArgIn(v) -> TArgIn(value = mExpr(c, s, v))
    case TArgOut(p) -> TArgOut(place = mPlace(c, s, p))
    case TArgInout(p) -> TArgInout(place = mPlace(c, s, p))
  }
}

func mPlace(c: in MCtx, s: in Subst, p: in TPlace): TPlace {
  val k: TPlaceKind = match p.kind {
    case PlLocal(_) -> p.kind
    case PlGlobal(_) -> p.kind
    case PlField(recv, f) -> PlField(recv = mExpr(c, s, recv), field = mField(c, s, recv.ty, f))
    case PlIndex(recv, idx, how) -> PlIndex(
      recv = mExpr(c, s, recv),
      idx = mExpr(c, s, idx),
      how = mIndexKind(c, s, recv.ty, how)
    )
  }
  TPlace(ty = mTy(c, s, p.ty), kind = k)
}

func mConv(c: in MCtx, s: in Subst, k: in ConvKind): ConvKind {
  match k {
    case CvBoxToHost(h) -> CvBoxToHost(host = HostTypeRef(name = h.name, args = mTys(c, s, h.args)))
    case _ -> k
  }
}

func mLit(c: in MCtx, s: in Subst, e: in TExpr, owner: in SymbolId, index: in Int): TExprKind {
  if symbolIdEq(owner, s.owner) and index >= 0 and index < s.args.count {
    match s.args[index] {
      case TLen(n) -> return XLit(lit = TLInt(value = n.toLong()))
      case _ -> ()
    }
  }
  addDiag(
    c,
    "I0007",
    "a value-generic parameter " + toString(index) + " of " + symKey(c, owner) + " has no length in this instance",
    Some(value = owner)
  )
  e.kind
}

func mArms(c: in MCtx, s: in Subst, arms: in List[TArm]): List[TArm] {
  val res: List[TArm] = newList()
  for a in arms {
    res.add(TArm(pat = mPat(c, s, a.pat), guard = mOptExpr(c, s, a.guard), body = mExpr(c, s, a.body)))
  }
  res
}

func mPat(c: in MCtx, s: in Subst, p: in TPat): TPat {
  val k: TPatKind = match p.kind {
    case TpWild -> p.kind
    case TpBind(d, inner) -> TpBind(
      decl = mLocal(c, s, d),
      inner = match inner {
        case Some(i) -> Some(value = mPat(c, s, i))
        case None -> None
      }
    )
    case TpLit(_) -> p.kind
    case TpRange(_, _, _) -> p.kind
    case TpCtor(sym, args) -> {
      val subs: List[TPat] = newList()
      for a in args {
        subs.add(mPat(c, s, a))
      }
      TpCtor(sym = instCtorSym(c, s, sym, p.ty), args = subs)
    }
    case TpRecord(sym, fields) -> {
      val fs: List[TFieldPat] = newList()
      for f in fields {
        fs.add(TFieldPat(field = mField(c, s, p.ty, f.field), pat = mPat(c, s, f.pat)))
      }
      TpRecord(sym = instCtorSym(c, s, sym, p.ty), fields = fs)
    }
    case TpTuple(elems) -> {
      val es: List[TPat] = newList()
      for e in elems {
        es.add(mPat(c, s, e))
      }
      TpTuple(elems = es)
    }
    case TpTypeTest(inner, ty) -> TpTypeTest(inner = mPat(c, s, inner), ty = mTy(c, s, ty))
    case TpOr(alts) -> {
      val altList: List[TPat] = newList()
      for a in alts {
        altList.add(mPat(c, s, a))
      }
      TpOr(alts = altList)
    }
    case TpConst(_) -> p.kind
  }
  TPat(id = nid(c, s, p.id), ty = mTy(c, s, p.ty), span = p.span, kind = k)
}

func mStmt(c: in MCtx, s: in Subst, st: in TStmt): TStmt {
  val k: TStmtKind = match st.kind {
    case TsLet(pat, init) -> TsLet(pat = mPat(c, s, pat), init = mExpr(c, s, init))
    case TsVar(d, init) -> TsVar(decl = mLocal(c, s, d), init = mOptExpr(c, s, init))
    case TsExpr(e) -> TsExpr(expr = mExpr(c, s, e))
    case TsReturn(v) -> TsReturn(value = mOptExpr(c, s, v))
    case TsBreak(_) -> st.kind
    case TsContinue(_) -> st.kind
    case TsThrow(e) -> TsThrow(expr = mExpr(c, s, e))
    case TsTry(body, catches, fin) -> {
      val cs: List[TCatch] = newList()
      for ct in catches {
        cs.add(
          TCatch(
            binding = match ct.binding { case Some(b) -> Some(value = mLocal(c, s, b)); case None -> None },
            exceptionType = ct.exceptionType,
            body = mExpr(c, s, ct.body)
          )
        )
      }
      TsTry(body = mExpr(c, s, body), catches = cs, finallyBody = mOptExpr(c, s, fin))
    }
    case TsDefer(b) -> TsDefer(body = mExpr(c, s, b))
    case TsScope(b, body) -> TsScope(
      binding = match b {
        case Some(d) -> Some(value = mLocal(c, s, d))
        case None -> None
      },
      body = mExpr(c, s, body)
    )
    case TsFor(label, pat, iter, body) -> TsFor(
      label = label,
      pat = mPat(c, s, pat),
      iter = mExpr(c, s, iter),
      body = mExpr(c, s, body)
    )
    case TsWhile(label, cond, body) -> TsWhile(
      label = label,
      cond = mExpr(c, s, cond),
      body = mExpr(c, s, body)
    )
    case TsLoop(label, body) -> TsLoop(label = label, body = mExpr(c, s, body))
    case TsInvariant(e) -> TsInvariant(expr = mExpr(c, s, e))
  }
  TStmt(id = nid(c, s, st.id), span = st.span, kind = k)
}

func mExpr(c: in MCtx, s: in Subst, e: in TExpr): TExpr {
  val k: TExprKind = match e.kind {
    case XLit(_) -> e.kind
    case XLocal(_) -> e.kind
    case XGlobal(sym, targs) -> {
      val ta = mTys(c, s, targs)
      match instCallee(c, sym, ta) {
        case Some(i) -> XGlobal(sym = i, typeArgs = newList())
        case None -> XGlobal(sym = sym, typeArgs = ta)
      }
    }
    case XValueParam(owner, index) -> mLit(c, s, e, owner, index)
    case XCall(callee, args) -> {
      val argList: List[TArg] = newList()
      for a in args {
        argList.add(mArg(c, s, a))
      }
      XCall(callee = mCallee(c, s, callee), args = argList)
    }
    case XConstruct(sym, fields) -> XConstruct(
      sym = instCtorSym(c, s, sym, e.ty),
      fields = mExprs(c, s, fields)
    )
    case XField(recv, f) -> XField(recv = mExpr(c, s, recv), field = mField(c, s, recv.ty, f))
    case XCopy(base, updates) -> {
      val us: List[TFieldUpdate] = newList()
      for u in updates {
        us.add(TFieldUpdate(field = mField(c, s, base.ty, u.field), value = mExpr(c, s, u.value)))
      }
      XCopy(base = mExpr(c, s, base), updates = us)
    }
    case XArrayCopy(inner) -> XArrayCopy(inner = mExpr(c, s, inner))
    case XZeroValue(ty) -> XZeroValue(ty = mTy(c, s, ty))
    case XIndex(recv, idx, how) -> XIndex(
      recv = mExpr(c, s, recv),
      idx = mExpr(c, s, idx),
      how = mIndexKind(c, s, recv.ty, how)
    )
    case XConvert(kind, inner) -> {
      val mi = mExpr(c, s, inner)
      val box = match kind { case CvBoxToHost(_) -> true; case _ -> false }
      // A generic body that boxes a `T` for a host parameter of that host type, read at `T` = that type, converts
      // a value to the type it has: the conversion is gone.  Only boxing can become an identity this way: the
      // other kinds change the type by their own rule (a widening, a wrap, an upcast to an interface), and
      // a substituted type never makes the two sides equal.
      if box and tyEq(mi.ty, mTy(c, s, e.ty)) {
        return mi
      }
      XConvert(kind = mConv(c, s, kind), inner = mi)
    }
    case XTuple(elems) -> XTuple(elems = mExprs(c, s, elems))
    case XListLit(elems) -> XListLit(elems = mExprs(c, s, elems))
    case XInterp(parts) -> XInterp(parts = mExprs(c, s, parts))
    case XRange(lo, hi, inc) -> XRange(lo = mExpr(c, s, lo), hi = mExpr(c, s, hi), inclusive = inc)
    case XShort(op, l, r) -> XShort(op = op, lhs = mExpr(c, s, l), rhs = mExpr(c, s, r))
    case XIf(cond, t, f) -> XIf(
      cond = mExpr(c, s, cond),
      thenBranch = mExpr(c, s, t),
      elseBranch = mOptExpr(c, s, f)
    )
    case XMatch(scrut, arms, exh) -> XMatch(
      scrutinee = mExpr(c, s, scrut),
      arms = mArms(c, s, arms),
      exhaustive = exh
    )
    case XBlock(stmts, tail) -> {
      val ss: List[TStmt] = newList()
      for st in stmts {
        ss.add(mStmt(c, s, st))
      }
      XBlock(stmts = ss, tail = mOptExpr(c, s, tail))
    }
    case XUnsafe(b) -> XUnsafe(body = mExpr(c, s, b))
    case XLambda(ps, caps, body) -> XLambda(
      params = mLocals(c, s, ps),
      captures = caps,
      body = mExpr(c, s, body)
    )
    case XAwait(i) -> XAwait(inner = mExpr(c, s, i))
    case XSpawn(i) -> XSpawn(inner = mExpr(c, s, i))
    case XYield(i) -> XYield(inner = mExpr(c, s, i))
    case XPropagate(i) -> XPropagate(inner = mExpr(c, s, i))
    case XOld(i) -> XOld(inner = mExpr(c, s, i))
    case XResult -> e.kind
    case XForall(bs, w, body) -> XForall(
      binders = mLocals(c, s, bs),
      whereExpr = mOptExpr(c, s, w),
      body = mExpr(c, s, body)
    )
    case XExists(bs, w, body) -> XExists(
      binders = mLocals(c, s, bs),
      whereExpr = mOptExpr(c, s, w),
      body = mExpr(c, s, body)
    )
    case XAssign(p, op, v) -> XAssign(place = mPlace(c, s, p), op = op, value = mExpr(c, s, v))
  }
  TExpr(id = nid(c, s, e.id), ty = mTy(c, s, e.ty), span = e.span, kind = k)
}

func mParamDecl(c: in MCtx, s: in Subst, p: in TParamDecl): TParamDecl {
  TParamDecl(local = mLocal(c, s, p.local), mode = p.mode, dflt = mOptExpr(c, s, p.dflt))
}

/// `d` read at `s` and named `sym`: the declaration of an instance (generic parameters substituted,
/// every node renumbered) or of a non-generic function (nothing substituted).
func mFnDecl(c: in MCtx, s: in Subst, sym: in SymbolId, d: in TFnDecl): TFnDecl {
  c.cur[0] = sym.id
  val ps: List[TParamDecl] = newList()
  for p in d.params {
    ps.add(mParamDecl(c, s, p))
  }
  TFnDecl(
    sym = sym,
    typeParams = newList(),
    params = ps,
    ret = mTy(c, s, d.ret),
    isAsync = d.isAsync,
    preconds = mExprs(c, s, d.preconds),
    postconds = mExprs(c, s, d.postconds),
    body = mOptExpr(c, s, d.body),
    span = d.span,
    barrier = mOptExpr(c, s, d.barrier),
    ownerParamCount = 0,
    isGenerator = d.isGenerator,
    isPublic = d.isPublic,
    invariants = mExprs(c, s, d.invariants),
    invariantTexts = d.invariantTexts
  )
}
