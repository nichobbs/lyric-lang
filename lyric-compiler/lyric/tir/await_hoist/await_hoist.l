//! await_hoist.l - Lyric.Tir.AwaitHoist: await hoisting on TIR, the last middle-end pass (docs/70 §7.2, D504).
//!
//! A backend that lowers `await` to a state machine on a stack machine loses whatever is on the evaluation
//! stack when it suspends.  This pass leaves every `await` evaluating on an empty stack: where an operand list
//! (call arguments, a construction's fields, tuple, list and interpolation elements, an index, a range, a copy)
//! has an operand that contains an `await` and operands ahead of it, each operand up to and including that one
//! is bound, in evaluation order, to a fresh local ahead of the statement, and the expression reads the locals.
//!
//!     f(a, await g(), b)   becomes   val t0 = a;  val t1 = await g();  f(t0, t1, b)
//!
//! A short-circuit right-hand side, a branch of an `if` or `match` and a guard evaluate conditionally, so their
//! own preludes stay inside them (as blocks).  A `while` condition containing an `await` becomes a `loop` that
//! evaluates it on each turn.  An assignment to a field or an element binds the target's operands, then the
//! value.  A lambda or `spawn` body is a deferred computation and is not entered.
package Lyric.Tir.AwaitHoist

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build
import Lyric.Tir.Walk

record HCtx {
  nextNode: List[Int]
  nextLocal: List[Int]
}

func firstHoistNodeId(): Int {
  900000000
}

func firstHoistLocalId(): Int {
  1700000000
}

func hNode(c: in HCtx): NodeId {
  val n = c.nextNode[0]
  c.nextNode[0] = n + 1
  NodeId(id = n)
}

func hLocal(c: in HCtx, ty: in Ty): LocalDecl {
  val n = c.nextLocal[0]
  c.nextLocal[0] = n + 1
  LocalDecl(id = LocalId(id = n), name = "__lyric_hoist_" + toString(n), ty = ty, mutable = false)
}

/// Whether `e` contains an `await` that runs as part of evaluating it: not inside a lambda or a `spawn`.
func hasAwait(e: in TExpr): Bool {
  val found: List[Bool] = newList()
  found.add(false)
  val w = newWalker(pre = { x: TExpr -> awaitPre(x) }, post = { x: TExpr -> awaitPost(found, x) })
  walkExpr(w, e)
  found[0]
}

func awaitPre(x: in TExpr): Option[TExpr] {
  match x.kind {
    case XLambda(_, _, _) -> Some(value = x)
    case XSpawn(_) -> Some(value = x)
    case _ -> None
  }
}

func awaitPost(found: in List[Bool], x: in TExpr): TExpr {
  match x.kind {
    case XAwait(_) -> {
      found[0] = true
    }
    case _ -> ()
  }
  x
}

/// `e` bound to a fresh local ahead of the statement; the read of the local.
func bindTemp(c: in HCtx, acc: in List[TStmt], e: in TExpr): TExpr {
  val l = hLocal(c, e.ty)
  val pat = TPat(id = hNode(c), ty = e.ty, span = e.span, kind = TpBind(decl = l, inner = None))
  acc.add(TStmt(id = hNode(c), span = e.span, kind = TsLet(pat = pat, init = e)))
  TExpr(id = hNode(c), ty = e.ty, span = e.span, kind = XLocal(local = l.id))
}

/// A conditional part of an expression as a block of its own: its prelude stays inside it.
func inBlock(c: in HCtx, e: in TExpr): TExpr {
  if not hasAwait(e) {
    return e
  }
  val inner: List[TStmt] = newList()
  val v = norm(c, inner, e)
  TExpr(id = hNode(c), ty = e.ty, span = e.span, kind = XBlock(stmts = inner, tail = Some(value = v)))
}

/// The operands of `e` in evaluation order, and how to rebuild `e` from them, for the kinds whose operands share
/// the evaluation stack.
record Spine {
  ops: List[TExpr]
  rebuild: (List[TExpr]) -> TExprKind
}

func spineOf(e: in TExpr): Option[Spine] {
  match e.kind {
    case XCall(callee, args) -> {
      val ops: List[TExpr] = newList()
      match callee {
        case Indirect(fv) -> ops.add(fv)
        case _ -> ()
      }
      for a in args {
        match a {
          case TArgIn(v) -> ops.add(v)
          case _ -> ()
        }
      }
      Some(value = Spine(ops = ops, rebuild = { xs: List[TExpr] -> rebuildCall(callee, args, xs) }))
    }
    case XConstruct(sym, fields) -> Some(
      value = Spine(
        ops = fields,
        rebuild = { xs: List[TExpr] -> XConstruct(sym = sym, fields = xs) }
      )
    )
    case XTuple(elems) -> Some(value = Spine(ops = elems, rebuild = { xs: List[TExpr] -> XTuple(elems = xs) }))
    case XListLit(elems) -> Some(value = Spine(ops = elems, rebuild = { xs: List[TExpr] -> XListLit(elems = xs) }))
    case XInterp(parts) -> Some(value = Spine(ops = parts, rebuild = { xs: List[TExpr] -> XInterp(parts = xs) }))
    case XIndex(recv, idx, how) -> {
      val ops: List[TExpr] = newList()
      ops.add(recv)
      ops.add(idx)
      Some(value = Spine(ops = ops, rebuild = { xs: List[TExpr] -> XIndex(recv = xs[0], idx = xs[1], how = how) }))
    }
    case XRange(lo, hi, inc) -> {
      val ops: List[TExpr] = newList()
      ops.add(lo)
      ops.add(hi)
      Some(value = Spine(ops = ops, rebuild = { xs: List[TExpr] -> XRange(lo = xs[0], hi = xs[1], inclusive = inc) }))
    }
    case XCopy(base, updates) -> {
      val ops: List[TExpr] = newList()
      ops.add(base)
      for u in updates {
        ops.add(u.value)
      }
      Some(value = Spine(ops = ops, rebuild = { xs: List[TExpr] -> rebuildCopy(updates, xs) }))
    }
    case _ -> None
  }
}

func rebuildCall(callee: in Callee, args: in List[TArg], xs: in List[TExpr]): TExprKind {
  var i = 0
  val cl: Callee = match callee { case Indirect(_) -> { i = 1; Indirect(fnValue = xs[0]) }; case _ -> callee }
  val res: List[TArg] = newList()
  for a in args {
    match a {
      case TArgIn(_) -> {
        res.add(TArgIn(value = xs[i]))
        i = i + 1
      }
      case _ -> res.add(a)
    }
  }
  XCall(callee = cl, args = res)
}

func rebuildCopy(updates: in List[TFieldUpdate], xs: in List[TExpr]): TExprKind {
  val us: List[TFieldUpdate] = newList()
  var i = 1
  for u in updates {
    us.add(TFieldUpdate(field = u.field, value = xs[i]))
    i = i + 1
  }
  XCopy(base = xs[0], updates = us)
}

/// `e` with every `await` in it evaluating on an empty stack, the statements that must run first appended to `acc`.
func norm(c: in HCtx, acc: in List[TStmt], e: in TExpr): TExpr {
  if not hasAwait(e) {
    return e
  }
  match e.kind {
    case XAwait(inner) -> {
      val i = norm(c, acc, inner)
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XAwait(inner = i))
    }
    case XShort(op, l, r) -> {
      val nl = norm(c, acc, l)
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XShort(op = op, lhs = nl, rhs = inBlock(c, r)))
    }
    case XIf(cond, t, f) -> {
      val nc = norm(c, acc, cond)
      val nf: Option[TExpr] = match f { case Some(x) -> Some(value = inBlock(c, x)); case None -> None }
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XIf(cond = nc, thenBranch = inBlock(c, t), elseBranch = nf))
    }
    case XMatch(scrut, arms, exh) -> {
      val ns = norm(c, acc, scrut)
      val na: List[TArm] = newList()
      for a in arms {
        na.add(
          TArm(
            pat = a.pat,
            guard = match a.guard { case Some(g) -> Some(value = inBlock(c, g)); case None -> None },
            body = inBlock(c, a.body)
          )
        )
      }
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XMatch(scrutinee = ns, arms = na, exhaustive = exh))
    }
    case XBlock(stmts, tail) -> {
      val inner: List[TStmt] = newList()
      for st in stmts {
        normStmt(c, inner, st)
      }
      val nt: Option[TExpr] = match tail { case Some(t) -> Some(value = norm(c, inner, t)); case None -> None }
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XBlock(stmts = inner, tail = nt))
    }
    case XUnsafe(b) -> {
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XUnsafe(body = norm(c, acc, b)))
    }
    case XField(recv, f) -> {
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XField(recv = norm(c, acc, recv), field = f))
    }
    case XConvert(k, inner) -> {
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XConvert(kind = k, inner = norm(c, acc, inner)))
    }
    case XArrayCopy(inner) -> {
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XArrayCopy(inner = norm(c, acc, inner)))
    }
    case XYield(inner) -> {
      return TExpr(id = e.id, ty = e.ty, span = e.span, kind = XYield(inner = norm(c, acc, inner)))
    }
    case XAssign(p, op, v) -> {
      return normAssign(c, acc, e, p, op, v)
    }
    case _ -> ()
  }
  match spineOf(e) {
    case Some(sp) -> {
      var last = -1
      var i = 0
      while i < sp.ops.count {
        if hasAwait(sp.ops[i]) {
          last = i
        }
        i = i + 1
      }
      val xs: List[TExpr] = newList()
      var j = 0
      while j < sp.ops.count {
        if j <= last {
          val v = norm(c, acc, sp.ops[j])
          // The first operand of a list evaluates on an empty stack, so an awaiting one stays where it is.
          if j == 0 and last == 0 {
            xs.add(v)
          } else {
            xs.add(bindTemp(c, acc, v))
          }
        } else {
          xs.add(sp.ops[j])
        }
        j = j + 1
      }
      TExpr(id = e.id, ty = e.ty, span = e.span, kind = sp.rebuild(xs))
    }
    case None -> e
  }
}

func normAssign(c: in HCtx, acc: in List[TStmt], e: in TExpr, p: in TPlace, op: in AssignKind, v: in TExpr): TExpr {
  val place: TPlace = match p.kind {
    case PlField(recv, f) -> TPlace(
      ty = p.ty,
      kind = PlField(
        recv = bindTemp(c, acc, norm(c, acc, recv)),
        field = f
      )
    )
    case PlIndex(recv, idx, how) -> {
      val r = bindTemp(c, acc, norm(c, acc, recv))
      val i = bindTemp(c, acc, norm(c, acc, idx))
      TPlace(ty = p.ty, kind = PlIndex(recv = r, idx = i, how = how))
    }
    case _ -> p
  }
  val nv0 = norm(c, acc, v)
  val isLocal = match p.kind { case PlLocal(_) -> true; case _ -> false }
  val nv = if isLocal { nv0 } else { bindTemp(c, acc, nv0) }
  TExpr(id = e.id, ty = e.ty, span = e.span, kind = XAssign(place = place, op = op, value = nv))
}

/// `st` with its expressions normalised, appended to `acc` after the statements they need.
func normStmt(c: in HCtx, acc: in List[TStmt], st: in TStmt): Unit {
  match st.kind {
    case TsLet(pat, init) -> {
      val v = norm(c, acc, init)
      acc.add(TStmt(id = st.id, span = st.span, kind = TsLet(pat = pat, init = v)))
    }
    case TsVar(d, init) -> match init {
      case Some(x) -> {
        val v = norm(c, acc, x)
        acc.add(TStmt(id = st.id, span = st.span, kind = TsVar(decl = d, init = Some(value = v))))
      }
      case None -> acc.add(st)
    }
    case TsExpr(x) -> {
      val v = norm(c, acc, x)
      acc.add(TStmt(id = st.id, span = st.span, kind = TsExpr(expr = v)))
    }
    case TsReturn(r) -> match r {
      case Some(x) -> {
        val v = norm(c, acc, x)
        acc.add(TStmt(id = st.id, span = st.span, kind = TsReturn(value = Some(value = v))))
      }
      case None -> acc.add(st)
    }
    case TsThrow(x) -> {
      val v = norm(c, acc, x)
      acc.add(TStmt(id = st.id, span = st.span, kind = TsThrow(expr = v)))
    }
    case TsTry(body, catches, fin) -> {
      val cs: List[TCatch] = newList()
      for ct in catches {
        cs.add(TCatch(binding = ct.binding, exceptionType = ct.exceptionType, body = inBlock(c, ct.body)))
      }
      val nf: Option[TExpr] = match fin { case Some(x) -> Some(value = inBlock(c, x)); case None -> None }
      acc.add(TStmt(id = st.id, span = st.span, kind = TsTry(body = inBlock(c, body), catches = cs, finallyBody = nf)))
    }
    case TsDefer(b) -> acc.add(TStmt(id = st.id, span = st.span, kind = TsDefer(body = inBlock(c, b))))
    case TsScope(b, body) -> acc.add(
      TStmt(id = st.id, span = st.span, kind = TsScope(binding = b, body = inBlock(c, body)))
    )
    case TsFor(label, pat, iter, body) -> {
      val it = norm(c, acc, iter)
      acc.add(TStmt(id = st.id, span = st.span, kind = TsFor(label = label, pat = pat, iter = it, body = inBlock(c, body))))
    }
    case TsWhile(label, cond, body) -> {
      if hasAwait(cond) {
        // `while cond body` re-evaluates cond each turn: loop { prelude; if cond' { body } else { break } }.
        val turn: List[TStmt] = newList()
        val nc = norm(c, turn, cond)
        val brk: List[TStmt] = newList()
        brk.add(TStmt(id = hNode(c), span = st.span, kind = TsBreak(label = None)))
        val leave = TExpr(id = hNode(c), ty = tyUnit(), span = st.span, kind = XBlock(stmts = brk, tail = None))
        val branch = TExpr(
          id = hNode(c),
          ty = tyUnit(),
          span = st.span,
          kind = XIf(cond = nc, thenBranch = inBlock(c, body), elseBranch = Some(value = leave))
        )
        turn.add(TStmt(id = hNode(c), span = st.span, kind = TsExpr(expr = branch)))
        val lbody = TExpr(id = hNode(c), ty = tyUnit(), span = st.span, kind = XBlock(stmts = turn, tail = None))
        acc.add(TStmt(id = st.id, span = st.span, kind = TsLoop(label = label, body = lbody)))
      } else {
        acc.add(TStmt(id = st.id, span = st.span, kind = TsWhile(label = label, cond = cond, body = inBlock(c, body))))
      }
    }
    case TsLoop(label, body) -> acc.add(
      TStmt(
        id = st.id,
        span = st.span,
        kind = TsLoop(label = label, body = inBlock(c, body))
      )
    )
    case _ -> acc.add(st)
  }
}

/// `d` with its body's awaits on an empty stack.  A function with no `await` is returned as it is.
pub func hoistAwaitsFn(d: in TFnDecl, nextNode: in List[Int]): TFnDecl {
  val body = match d.body { case Some(b) -> b; case None -> return d }
  if not hasAwait(body) {
    return d
  }
  val nl: List[Int] = newList()
  nl.add(firstHoistLocalId())
  val c = HCtx(nextNode = nextNode, nextLocal = nl)
  d.copy(body = Some(value = inBlock(c, body)))
}

/// `bundle` with `hoistAwaitsFn` applied to every function of every package.
pub func hoistAwaitsBundle(bundle: in List[PackageBuild]): List[PackageBuild] {
  val res: List[PackageBuild] = newList()
  for pb in bundle {
    val nn: List[Int] = newList()
    nn.add(firstHoistNodeId())
    val fns: List[TFnDecl] = newList()
    for f in pb.pkg.funcs {
      fns.add(hoistAwaitsFn(f, nn))
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
