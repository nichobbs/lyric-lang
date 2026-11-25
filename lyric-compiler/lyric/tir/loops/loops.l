//! loops.l - Lyric.Tir.Loops: loop `invariant:` lowering on TIR (docs/70 §7.2, D510).
//!
//! A loop's `invariant:` clauses are `TsInvariant` statements at the head of its body.  As on the AST
//! (`Lyric.ContractElaborator`), each becomes `assert(clause, "LoopInvariantViolated: invariant <clause>")`, so the
//! clause is checked at the top of every iteration (the first checks the entry state, each later one that the body
//! re-established it), and again when the loop ends normally: the condition went false or the iterator ran out,
//! including a loop that never ran.  A `break` leaves with no obligation, and neither does a `while true`.  The checks
//! are not gated by the contracts switch (#7645).
//!
//! A `while` with invariants becomes a `loop` whose first statement is `if not cond { <exit checks>; break }`, which
//! keeps a `break` of the body from reaching the checks without a flag.  A `for` keeps its form: a `var` flag is set
//! before each `break` that leaves it, and the checks after it are guarded by `not flag`; a clause that reads a
//! name the loop pattern binds is checked only per iteration (#7381), the name being out of scope afterwards.
package Lyric.Tir.Loops

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build
import Lyric.Tir.Walk

record LCtx {
  nextNode: List[Int]
  nextLocal: List[Int]
}

func firstLoopNodeId(): Int {
  770000000
}

func firstLoopLocalId(): Int {
  1570000000
}

func lNode(c: in LCtx): NodeId {
  val n = c.nextNode[0]
  c.nextNode[0] = n + 1
  NodeId(id = n)
}

func lLocal(c: in LCtx, name: in String, ty: in Ty): LocalDecl {
  val n = c.nextLocal[0]
  c.nextLocal[0] = n + 1
  LocalDecl(id = LocalId(id = n), name = name, ty = ty, mutable = true)
}

func lRead(c: in LCtx, l: in LocalDecl, sp: in Span): TExpr {
  TExpr(id = lNode(c), ty = l.ty, span = sp, kind = XLocal(local = l.id))
}

func lStmt(c: in LCtx, sp: in Span, k: in TStmtKind): TStmt {
  TStmt(id = lNode(c), span = sp, kind = k)
}

func lBool(c: in LCtx, v: in Bool, sp: in Span): TExpr {
  TExpr(id = lNode(c), ty = tyBool(), span = sp, kind = XLit(lit = TLBool(value = v)))
}

func lNot(c: in LCtx, x: in TExpr): TExpr {
  val args: List[TArg] = newList()
  args.add(TArgIn(value = x))
  TExpr(id = lNode(c), ty = tyBool(), span = x.span, kind = XCall(callee = Intrinsic(op = IoNot), args = args))
}

/// `e` with every node renumbered, so a clause that stands at several places keeps node ids unique.
func renumber(c: in LCtx, e: in TExpr): TExpr {
  val w = newWalker(
    pre = { x: TExpr -> None },
    post = { x: TExpr -> TExpr(id = lNode(c), ty = x.ty, span = x.span, kind = x.kind) }
  )
  walkExpr(w, e)
}

/// `assert(cond, "LoopInvariantViolated: invariant <text>")` as a statement.
func assertStmt(c: in LCtx, cond: in TExpr, text: in String, sp: in Span): TStmt {
  val msg = TExpr(
    id = lNode(c),
    ty = tyString(),
    span = sp,
    kind = XLit(lit = TLString(text = "LoopInvariantViolated: invariant " + text))
  )
  val args: List[TArg] = newList()
  args.add(TArgIn(value = cond))
  args.add(TArgIn(value = msg))
  val call = TExpr(
    id = lNode(c),
    ty = tyUnit(),
    span = sp,
    kind = XCall(callee = Intrinsic(op = IoBuiltin(name = "assert")), args = args)
  )
  lStmt(c, sp, TsExpr(expr = call))
}

/// One loop invariant: the clause and its text.
record LoopInv {
  expr: TExpr
  text: String
}

/// The invariant clauses at the head of a loop body.
func invariantsOf(body: in TExpr): List[LoopInv] {
  val res: List[LoopInv] = newList()
  match body.kind {
    case XBlock(stmts, _) -> {
      for st in stmts {
        match st.kind {
          case TsInvariant(e, t) -> res.add(LoopInv(expr = e, text = t))
          case _ -> ()
        }
      }
    }
    case _ -> ()
  }
  res
}

func exitAsserts(c: in LCtx, invs: in List[LoopInv], sp: in Span): List[TStmt] {
  val res: List[TStmt] = newList()
  for inv in invs {
    res.add(assertStmt(c, renumber(c, inv.expr), inv.text, sp))
  }
  res
}

func isTrueLit(e: in TExpr): Bool {
  match e.kind {
    case XLit(TLBool(true)) -> true
    case _ -> false
  }
}

/// The locals a pattern binds.
func patLocals(p: in TPat, acc: in List[Int]): Unit {
  match p.kind {
    case TpBind(d, inner) -> {
      acc.add(d.id.id)
      match inner {
        case Some(i) -> patLocals(i, acc)
        case None -> ()
      }
    }
    case TpCtor(_, args) -> {
      for a in args {
        patLocals(a, acc)
      }
    }
    case TpRecord(_, fields) -> {
      for f in fields {
        patLocals(f.pat, acc)
      }
    }
    case TpTuple(elems) -> {
      for e in elems {
        patLocals(e, acc)
      }
    }
    case TpTypeTest(inner, _) -> patLocals(inner, acc)
    case TpOr(alts) -> {
      for a in alts {
        patLocals(a, acc)
      }
    }
    case _ -> ()
  }
}

func readsAnyLocal(e: in TExpr, ids: in List[Int]): Bool {
  val found: List[Bool] = newList()
  found.add(false)
  val w = newWalker(pre = { x: TExpr -> None }, post = { x: TExpr -> noteLocal(found, ids, x) })
  walkExpr(w, e)
  found[0]
}

func noteLocal(found: in List[Bool], ids: in List[Int], x: in TExpr): TExpr {
  match x.kind {
    case XLocal(l) -> if ids.contains(l.id) { found[0] = true }
    case _ -> ()
  }
  x
}

/// Whether a `break` with label `l` leaves the loop labelled `label`: an unlabelled one does at the loop's own level
/// (`topLevel`), a labelled one wherever it stands.
func breakLeaves(l: in Option[String], label: in Option[String], topLevel: in Bool): Bool {
  match l {
    case None -> topLevel
    case Some(n) -> match label { case Some(m) -> n == m; case None -> false }
  }
}

/// `body` with `flag = true` ahead of every `break` that leaves the loop; `found[0]` says whether there was one.  A
/// nested loop is entered with `topLevel` off (its unlabelled breaks are its own), a lambda not at all.
func markBreaks(
  c: in LCtx,
  flag: in LocalDecl,
  label: in Option[String],
  body: in TExpr,
  topLevel: in Bool,
  found: in List[Bool],
): TExpr {
  val w = Walker(
    pre = { x: TExpr -> match x.kind { case XLambda(_, _, _) -> Some(value = x); case _ -> None } },
    post = { x: TExpr -> x },
    preStmt = { st: TStmt -> markStmt(c, flag, label, st, topLevel, found) }
  )
  walkExpr(w, body)
}

func markStmt(
  c: in LCtx,
  flag: in LocalDecl,
  label: in Option[String],
  st: in TStmt,
  topLevel: in Bool,
  found: in List[Bool],
): Option[List[TStmt]] {
  match st.kind {
    case TsBreak(l) -> if breakLeaves(l, label, topLevel) {
      found[0] = true
      val set = TExpr(
        id = lNode(c),
        ty = tyUnit(),
        span = st.span,
        kind = XAssign(
          place = TPlace(ty = flag.ty, kind = PlLocal(local = flag.id)),
          op = AkSet,
          value = lBool(c, true, st.span)
        )
      )
      val res: List[TStmt] = newList()
      res.add(lStmt(c, st.span, TsExpr(expr = set)))
      res.add(st)
      Some(value = res)
    } else {
      None
    }
    case TsWhile(lb, cond, b) -> {
      val res: List[TStmt] = newList()
      res.add(
        TStmt(
          id = st.id,
          span = st.span,
          kind = TsWhile(label = lb, cond = cond, body = markBreaks(c, flag, label, b, false, found))
        )
      )
      Some(value = res)
    }
    case TsFor(lb, pat, iter, b) -> {
      val res: List[TStmt] = newList()
      res.add(
        TStmt(
          id = st.id,
          span = st.span,
          kind = TsFor(label = lb, pat = pat, iter = iter, body = markBreaks(c, flag, label, b, false, found))
        )
      )
      Some(value = res)
    }
    case TsLoop(lb, b) -> {
      val res: List[TStmt] = newList()
      res.add(
        TStmt(id = st.id, span = st.span, kind = TsLoop(label = lb, body = markBreaks(c, flag, label, b, false, found)))
      )
      Some(value = res)
    }
    case _ -> None
  }
}

func lowerBody(c: in LCtx, body: in TExpr): TExpr {
  walkExpr(loopWalker(c), body)
}

func loopWalker(c: in LCtx): Walker {
  Walker(pre = { x: TExpr -> None }, post = { x: TExpr -> x }, preStmt = { st: TStmt -> loopStmt(c, st) })
}

func loopStmt(c: in LCtx, st: in TStmt): Option[List[TStmt]] {
  val sp = st.span
  match st.kind {
    case TsInvariant(e, t) -> {
      val res: List[TStmt] = newList()
      res.add(assertStmt(c, e, t, sp))
      Some(value = res)
    }
    case TsWhile(label, cond, body) -> {
      val invs = invariantsOf(body)
      if invs.count == 0 {
        return None
      }
      val body2 = walkExpr(loopWalker(c), body)
      val res: List[TStmt] = newList()
      if isTrueLit(cond) {
        res.add(TStmt(id = st.id, span = sp, kind = TsWhile(label = label, cond = cond, body = body2)))
        return Some(value = res)
      }
      val exitStmts = exitAsserts(c, invs, sp)
      exitStmts.add(lStmt(c, sp, TsBreak(label = None)))
      val exitBlock = TExpr(id = lNode(c), ty = tyUnit(), span = sp, kind = XBlock(stmts = exitStmts, tail = None))
      val guard = TExpr(
        id = lNode(c),
        ty = tyUnit(),
        span = sp,
        kind = XIf(cond = lNot(c, cond), thenBranch = exitBlock, elseBranch = None)
      )
      val stmts: List[TStmt] = newList()
      stmts.add(lStmt(c, sp, TsExpr(expr = guard)))
      var tail: Option[TExpr] = None
      match body2.kind {
        case XBlock(bs, bt) -> {
          for b in bs {
            stmts.add(b)
          }
          tail = bt
        }
        case _ -> stmts.add(lStmt(c, sp, TsExpr(expr = body2)))
      }
      val newBody = TExpr(id = lNode(c), ty = tyUnit(), span = sp, kind = XBlock(stmts = stmts, tail = tail))
      res.add(TStmt(id = st.id, span = sp, kind = TsLoop(label = label, body = newBody)))
      Some(value = res)
    }
    case TsFor(label, pat, iter, body) -> {
      val invs = invariantsOf(body)
      if invs.count == 0 {
        return None
      }
      val body2 = walkExpr(loopWalker(c), body)
      val bound: List[Int] = newList()
      patLocals(pat, bound)
      val exitInvs: List[LoopInv] = newList()
      for inv in invs {
        if not readsAnyLocal(inv.expr, bound) {
          exitInvs.add(inv)
        }
      }
      val res: List[TStmt] = newList()
      if exitInvs.count == 0 {
        res.add(TStmt(id = st.id, span = sp, kind = TsFor(label = label, pat = pat, iter = iter, body = body2)))
        return Some(value = res)
      }
      val flag = lLocal(c, "__loop_broke", tyBool())
      val found: List[Bool] = newList()
      found.add(false)
      val body3 = markBreaks(c, flag, label, body2, true, found)
      if not found[0] {
        res.add(TStmt(id = st.id, span = sp, kind = TsFor(label = label, pat = pat, iter = iter, body = body2)))
        for a in exitAsserts(c, exitInvs, sp) {
          res.add(a)
        }
        return Some(value = res)
      }
      res.add(lStmt(c, sp, TsVar(decl = flag, init = Some(value = lBool(c, false, sp)))))
      res.add(TStmt(id = st.id, span = sp, kind = TsFor(label = label, pat = pat, iter = iter, body = body3)))
      val checks = exitAsserts(c, exitInvs, sp)
      val checkBlock = TExpr(id = lNode(c), ty = tyUnit(), span = sp, kind = XBlock(stmts = checks, tail = None))
      val guard = TExpr(
        id = lNode(c),
        ty = tyUnit(),
        span = sp,
        kind = XIf(cond = lNot(c, lRead(c, flag, sp)), thenBranch = checkBlock, elseBranch = None)
      )
      res.add(lStmt(c, sp, TsExpr(expr = guard)))
      Some(value = res)
    }
    case _ -> None
  }
}

/// `d` with the `invariant:` clauses of every loop of its body lowered; a declaration with no body is returned as it is.
pub func lowerLoopsFn(d: in TFnDecl, nextNode: in List[Int]): TFnDecl {
  val body = match d.body { case Some(b) -> b; case None -> return d }
  val nl: List[Int] = newList()
  nl.add(firstLoopLocalId())
  val c = LCtx(nextNode = nextNode, nextLocal = nl)
  d.copy(body = Some(value = lowerBody(c, body)))
}

/// `bundle` with the loop invariants lowered in every function of every package.
pub func lowerLoopsBundle(bundle: in List[PackageBuild]): List[PackageBuild] {
  val res: List[PackageBuild] = newList()
  for pb in bundle {
    val nn: List[Int] = newList()
    nn.add(firstLoopNodeId())
    val fns: List[TFnDecl] = newList()
    for f in pb.pkg.funcs {
      fns.add(lowerLoopsFn(f, nn))
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
