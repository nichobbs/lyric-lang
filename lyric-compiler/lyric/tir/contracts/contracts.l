//! contracts.l - Lyric.Tir.Contracts: contract elaboration on TIR, the declaration step (docs/70 §7.2, D502).
//!
//! `elaborateFn` lowers a function's `requires:` and `ensures:` clauses into runtime `assert(cond, message)`
//! calls in its body, as `Lyric.ContractElaborator` does on the AST: the preconditions run first, an `old(e)` in
//! an `ensures:` is a snapshot taken before them, and every way out of the body (the tail value and a `return` at
//! any depth, outside lambdas) binds its value to a local, runs the postconditions with `result` read from it,
//! and then yields it.  The clauses stay on the `TFnDecl` for the verifier.  Caller-side checks (§10.2) are
//! phase 6; this is the callee's own part.
package Lyric.Tir.Contracts

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build

/// The traversal's state.  `fresh` renumbers every node it produces (a postcondition cloned per exit needs unique
/// node ids); `collectOld` makes the traversal gather each `old(e)` operand instead of rewriting; `oldLocals` and
/// `resultLocal` are what `old(..)` and `result` read in a clone; `exits` makes it rewrite returns.
record CCtx {
  nextNode: List[Int]
  nextLocal: List[Int]
  fresh: Bool
  collectOld: Bool
  olds: List[TExpr]
  oldLocals: List[LocalDecl]
  oldIdx: List[Int]
  resultLocal: Option[LocalDecl]
  exits: Option[ExitPlan]
}

/// What a `return` becomes: the postconditions (with their messages) run against the returned value.
record ExitPlan {
  posts: List[TExpr]
  messages: List[String]
  ret: Ty
  oldLocals: List[LocalDecl]
  span: Span
}

/// A type's construction checker (`__lyric_checked_T`, D505): the function, its declaration entry and the package
/// that declares both.
pub record CheckerRef {
  sym: SymbolId
  symEntry: TSymEntry
  pkg: String
}

/// The invariant-carrying types the bundle's checkers cover, by the type's `SymbolId`, and the package whose
/// function is being elaborated: the types of another package are checked where a value crosses the function's
/// boundary, those of its own only where it is written back (docs/08 §7.1).
pub record BoundaryCtx {
  checkers: Map[Int, CheckerRef]
  pkg: String
  /// The checkers the package's functions call, by function `SymbolId`: their entries join the package's own.
  used: Map[Int, CheckerRef]
}

func firstContractNodeId(): Int {
  700000000
}

func firstContractLocalId(): Int {
  1500000000
}

func newCCtx(nn: in List[Int]): CCtx {
  val nl: List[Int] = newList()
  nl.add(firstContractLocalId())
  val oi: List[Int] = newList()
  oi.add(0)
  CCtx(
    nextNode = nn,
    nextLocal = nl,
    fresh = false,
    collectOld = false,
    olds = newList(),
    oldLocals = newList(),
    oldIdx = oi,
    resultLocal = None,
    exits = None
  )
}

func cNid(c: in CCtx, id: in NodeId): NodeId {
  if c.fresh {
    val n = c.nextNode[0]
    c.nextNode[0] = n + 1
    NodeId(id = n)
  } else {
    id
  }
}

func newNode(c: in CCtx): NodeId {
  val n = c.nextNode[0]
  c.nextNode[0] = n + 1
  NodeId(id = n)
}

func newLocal(c: in CCtx, name: in String, ty: in Ty): LocalDecl {
  val n = c.nextLocal[0]
  c.nextLocal[0] = n + 1
  LocalDecl(id = LocalId(id = n), name = name, ty = ty, mutable = false)
}

func cOptExpr(c: in CCtx, o: in Option[TExpr]): Option[TExpr] {
  match o {
    case Some(e) -> Some(value = cExpr(c, e))
    case None -> None
  }
}

func cExprs(c: in CCtx, xs: in List[TExpr]): List[TExpr] {
  val res: List[TExpr] = newList()
  for x in xs {
    res.add(cExpr(c, x))
  }
  res
}

func cArg(c: in CCtx, a: in TArg): TArg {
  match a {
    case TArgIn(v) -> TArgIn(value = cExpr(c, v))
    case TArgOut(p) -> TArgOut(place = cPlace(c, p))
    case TArgInout(p) -> TArgInout(place = cPlace(c, p))
  }
}

func cPlace(c: in CCtx, p: in TPlace): TPlace {
  val k: TPlaceKind = match p.kind {
    case PlLocal(_) -> p.kind
    case PlGlobal(_) -> p.kind
    case PlField(recv, f) -> PlField(recv = cExpr(c, recv), field = f)
    case PlIndex(recv, idx, how) -> PlIndex(recv = cExpr(c, recv), idx = cExpr(c, idx), how = how)
  }
  TPlace(ty = p.ty, kind = k)
}

func cCallee(c: in CCtx, callee: in Callee): Callee {
  match callee {
    case Indirect(fv) -> Indirect(fnValue = cExpr(c, fv))
    case _ -> callee
  }
}

func cPat(c: in CCtx, p: in TPat): TPat {
  val k: TPatKind = match p.kind {
    case TpBind(d, inner) -> TpBind(
      decl = d,
      inner = match inner {
        case Some(i) -> Some(value = cPat(c, i))
        case None -> None
      }
    )
    case TpCtor(sym, args) -> {
      val subs: List[TPat] = newList()
      for a in args {
        subs.add(cPat(c, a))
      }
      TpCtor(sym = sym, args = subs)
    }
    case TpRecord(sym, fields) -> {
      val fs: List[TFieldPat] = newList()
      for f in fields {
        fs.add(TFieldPat(field = f.field, pat = cPat(c, f.pat)))
      }
      TpRecord(sym = sym, fields = fs)
    }
    case TpTuple(elems) -> {
      val es: List[TPat] = newList()
      for e in elems {
        es.add(cPat(c, e))
      }
      TpTuple(elems = es)
    }
    case TpTypeTest(inner, ty) -> TpTypeTest(inner = cPat(c, inner), ty = ty)
    case TpOr(alts) -> {
      val altList: List[TPat] = newList()
      for a in alts {
        altList.add(cPat(c, a))
      }
      TpOr(alts = altList)
    }
    case _ -> p.kind
  }
  TPat(id = cNid(c, p.id), ty = p.ty, span = p.span, kind = k)
}

func cArms(c: in CCtx, arms: in List[TArm]): List[TArm] {
  val res: List[TArm] = newList()
  for a in arms {
    res.add(TArm(pat = cPat(c, a.pat), guard = cOptExpr(c, a.guard), body = cExpr(c, a.body)))
  }
  res
}

/// The statements `st` becomes: itself rewritten, or, for a `return` of a body with postconditions, the binding of
/// its value, the postconditions and the `return` of the binding.
func cStmt(c: in CCtx, st: in TStmt): List[TStmt] {
  val emitted: List[TStmt] = newList()
  match st.kind {
    case TsReturn(v) -> match c.exits {
      case Some(plan) -> {
        val rv = cOptExpr(c, v)
        match rv {
          case Some(value) -> {
            val local = newLocal(c, "__lyric_result_" + toString(c.nextLocal[0]), plan.ret)
            emitted.add(bindStmt(c, local, value, st.span))
            for s in postAsserts(c, plan, Some(value = local)) {
              emitted.add(s)
            }
            emitted.add(
              TStmt(id = newNode(c), span = st.span, kind = TsReturn(value = Some(value = localRead(c, local, st.span))))
            )
          }
          case None -> {
            for s in postAsserts(c, plan, None) {
              emitted.add(s)
            }
            emitted.add(TStmt(id = newNode(c), span = st.span, kind = TsReturn(value = None)))
          }
        }
        return emitted
      }
      case None -> ()
    }
    case _ -> ()
  }
  val k: TStmtKind = match st.kind {
    case TsLet(pat, init) -> TsLet(pat = cPat(c, pat), init = cExpr(c, init))
    case TsVar(d, init) -> TsVar(decl = d, init = cOptExpr(c, init))
    case TsExpr(e) -> TsExpr(expr = cExpr(c, e))
    case TsReturn(v) -> TsReturn(value = cOptExpr(c, v))
    case TsBreak(_) -> st.kind
    case TsContinue(_) -> st.kind
    case TsThrow(e) -> TsThrow(expr = cExpr(c, e))
    case TsTry(body, catches, fin) -> {
      val cs: List[TCatch] = newList()
      for ct in catches {
        cs.add(TCatch(binding = ct.binding, exceptionType = ct.exceptionType, body = cExpr(c, ct.body)))
      }
      TsTry(body = cExpr(c, body), catches = cs, finallyBody = cOptExpr(c, fin))
    }
    case TsDefer(b) -> TsDefer(body = cExpr(c, b))
    case TsScope(b, body) -> TsScope(binding = b, body = cExpr(c, body))
    case TsFor(label, pat, iter, body) -> TsFor(
      label = label,
      pat = cPat(c, pat),
      iter = cExpr(c, iter),
      body = cExpr(c, body)
    )
    case TsWhile(label, cond, body) -> TsWhile(
      label = label,
      cond = cExpr(c, cond),
      body = cExpr(c, body)
    )
    case TsLoop(label, body) -> TsLoop(label = label, body = cExpr(c, body))
    case TsInvariant(e, t) -> TsInvariant(expr = cExpr(c, e), text = t)
  }
  emitted.add(TStmt(id = cNid(c, st.id), span = st.span, kind = k))
  emitted
}

func cExpr(c: in CCtx, e: in TExpr): TExpr {
  // `old(e)`: gathered while collecting, a read of its snapshot in a clone.
  match e.kind {
    case XOld(inner) -> {
      if c.collectOld {
        c.olds.add(inner)
        return e
      }
      if c.oldLocals.count > 0 {
        val i = c.oldIdx[0]
        c.oldIdx[0] = i + 1
        return localRead(c, c.oldLocals[i], e.span)
      }
    }
    case XResult -> match c.resultLocal { case Some(l) -> return localRead(c, l, e.span); case None -> () }
    case _ -> ()
  }
  val k: TExprKind = match e.kind {
    case XLit(_) -> e.kind
    case XLocal(_) -> e.kind
    case XGlobal(_, _) -> e.kind
    case XValueParam(_, _) -> e.kind
    case XCall(callee, args) -> {
      val argList: List[TArg] = newList()
      for a in args {
        argList.add(cArg(c, a))
      }
      XCall(callee = cCallee(c, callee), args = argList)
    }
    case XConstruct(sym, fields) -> XConstruct(sym = sym, fields = cExprs(c, fields))
    case XField(recv, f) -> XField(recv = cExpr(c, recv), field = f)
    case XCopy(base, updates) -> {
      val us: List[TFieldUpdate] = newList()
      for u in updates {
        us.add(TFieldUpdate(field = u.field, value = cExpr(c, u.value)))
      }
      XCopy(base = cExpr(c, base), updates = us)
    }
    case XArrayCopy(inner) -> XArrayCopy(inner = cExpr(c, inner))
    case XZeroValue(_) -> e.kind
    case XIndex(recv, idx, how) -> XIndex(recv = cExpr(c, recv), idx = cExpr(c, idx), how = how)
    case XConvert(kind, inner) -> XConvert(kind = kind, inner = cExpr(c, inner))
    case XTuple(elems) -> XTuple(elems = cExprs(c, elems))
    case XListLit(elems) -> XListLit(elems = cExprs(c, elems))
    case XInterp(parts) -> XInterp(parts = cExprs(c, parts))
    case XRange(lo, hi, inc) -> XRange(lo = cExpr(c, lo), hi = cExpr(c, hi), inclusive = inc)
    case XShort(op, l, r) -> XShort(op = op, lhs = cExpr(c, l), rhs = cExpr(c, r))
    case XIf(cond, t, f) -> XIf(
      cond = cExpr(c, cond),
      thenBranch = cExpr(c, t),
      elseBranch = cOptExpr(c, f)
    )
    case XMatch(scrut, arms, exh) -> XMatch(
      scrutinee = cExpr(c, scrut),
      arms = cArms(c, arms),
      exhaustive = exh
    )
    case XBlock(stmts, tail) -> {
      val ss: List[TStmt] = newList()
      for st in stmts {
        for s2 in cStmt(c, st) {
          ss.add(s2)
        }
      }
      XBlock(stmts = ss, tail = cOptExpr(c, tail))
    }
    case XUnsafe(b) -> XUnsafe(body = cExpr(c, b))
    case XLambda(ps, caps, body) -> match c.exits {
      // A `return` inside a lambda leaves the lambda, not the function.
      case Some(_) -> e.kind
      case None -> XLambda(
        params = ps,
        captures = caps,
        body = cExpr(c, body)
      )
    }
    case XAwait(i) -> XAwait(inner = cExpr(c, i))
    case XSpawn(i) -> XSpawn(inner = cExpr(c, i))
    case XYield(i) -> XYield(inner = cExpr(c, i))
    case XPropagate(i) -> XPropagate(inner = cExpr(c, i))
    case XOld(i) -> XOld(inner = cExpr(c, i))
    case XResult -> e.kind
    case XForall(bs, w, body) -> XForall(
      binders = bs,
      whereExpr = cOptExpr(c, w),
      body = cExpr(c, body)
    )
    case XExists(bs, w, body) -> XExists(
      binders = bs,
      whereExpr = cOptExpr(c, w),
      body = cExpr(c, body)
    )
    case XAssign(p, op, v) -> XAssign(place = cPlace(c, p), op = op, value = cExpr(c, v))
  }
  TExpr(id = cNid(c, e.id), ty = e.ty, span = e.span, kind = k)
}

func localRead(c: in CCtx, l: in LocalDecl, sp: in Span): TExpr {
  TExpr(id = newNode(c), ty = l.ty, span = sp, kind = XLocal(local = l.id))
}

func bindStmt(c: in CCtx, l: in LocalDecl, init: in TExpr, sp: in Span): TStmt {
  val pat = TPat(id = newNode(c), ty = l.ty, span = sp, kind = TpBind(decl = l, inner = None))
  TStmt(id = newNode(c), span = sp, kind = TsLet(pat = pat, init = init))
}

/// `assert(cond, message)` as a statement.
func assertStmt(c: in CCtx, cond: in TExpr, message: in String, sp: in Span): TStmt {
  val msg = TExpr(id = newNode(c), ty = tyString(), span = sp, kind = XLit(lit = TLString(text = message)))
  val args: List[TArg] = newList()
  args.add(TArgIn(value = cond))
  args.add(TArgIn(value = msg))
  val call = TExpr(
    id = newNode(c),
    span = sp,
    ty = tyUnit(),
    kind = XCall(callee = Intrinsic(op = IoBuiltin(name = "assert")), args = args)
  )
  TStmt(id = newNode(c), span = sp, kind = TsExpr(expr = call))
}

/// The postconditions of `plan` as assertions, each a fresh copy reading `result` from `result` and `old(..)` from
/// the snapshots.
func postAsserts(c: in CCtx, plan: in ExitPlan, result: in Option[LocalDecl]): List[TStmt] {
  val res: List[TStmt] = newList()
  // The snapshots were collected across all the clauses in order, so one index runs through the clauses of an exit.
  val oldIdx = newOldIdx()
  var i = 0
  while i < plan.posts.count {
    val sub = CCtx(
      nextNode = c.nextNode,
      nextLocal = c.nextLocal,
      fresh = true,
      collectOld = false,
      olds = newList(),
      oldLocals = plan.oldLocals,
      oldIdx = oldIdx,
      resultLocal = result,
      exits = None
    )
    val cond = cExpr(sub, plan.posts[i])
    res.add(assertStmt(c, cond, plan.messages[i], plan.posts[i].span))
    i = i + 1
  }
  res
}

func newOldIdx(): List[Int] {
  val oi: List[Int] = newList()
  oi.add(0)
  oi
}

/// The message of a violated clause: `PreconditionViolated: Owner.f requires x > 0`.
func violation(kind: in String, owner: in String, keyword: in String, text: in String): String {
  kind + ": " + owner + " " + keyword + " " + text
}

/// `owner` as the contract messages name a function: its DefPath key without the parameter list, `::` as `.`.
pub func ownerNameOf(key: in String): String {
  var cut = key.length
  var i = 0
  while i < key.length {
    if key.substring(i, 1) == "(" {
      cut = i
      i = key.length
    }
    i = i + 1
  }
  val head = key.substring(0, cut)
  var res = ""
  var j = 0
  while j < head.length {
    if j + 1 < head.length and head.substring(j, 2) == "::" {
      res = res + "."
      j = j + 2
    } else {
      res = res + head.substring(j, 1)
      j = j + 1
    }
  }
  res
}

func clauseText(texts: in List[String], i: in Int): String {
  if i < texts.count {
    texts[i]
  } else {
    "(clause " + toString(i + 1) + ")"
  }
}

/// `d` with its contracts lowered into its body.  A declaration with no body, no clause, or a generator is
/// returned as it is; `enabled` is false when the build turns contracts off (docs/63 Q-BP-009), which leaves the
/// body alone.  `owner` names the function in violation messages (`ownerNameOf` of its DefPath key).
pub func elaborateFn(d: in TFnDecl, owner: in String, enabled: in Bool): TFnDecl {
  val nn: List[Int] = newList()
  nn.add(firstContractNodeId())
  elaborateFnWith(d, owner, enabled, nn, None)
}

/// `elaborateFn` drawing its made-up node ids from `nextNode`, shared by every function of a package: node ids
/// are unique within a package.  `boundary` adds the public-boundary invariant checks of D507: each `in` or
/// `inout` parameter of another package's invariant-carrying type is checked on entry, and each `inout`/`out`
/// parameter and the result at every exit.  Those are system checks like the AST pass's, so they run when
/// `enabled` is false too (only the source `requires:`/`ensures:` clauses are gated).
pub func elaborateFnWith(
  d: in TFnDecl,
  owner: in String,
  enabled: in Bool,
  nextNode: in List[Int],
  boundary: in Option[BoundaryCtx],
): TFnDecl {
  val body = match d.body { case Some(b) -> b; case None -> return d }
  if d.isGenerator {
    return d
  }
  val c = newCCtx(nextNode)
  val sp = body.span
  val userPre: List[TExpr] = if enabled { d.preconds } else { newList() }
  val userPost: List[TExpr] = if enabled { d.postconds } else { newList() }
  val userPreTexts: List[String] = if enabled { d.precondTexts } else { newList() }
  val userPostTexts: List[String] = if enabled { d.postcondTexts } else { newList() }
  val entryChecks: List[TStmt] = newList()
  val exitPosts: List[TExpr] = newList()
  val exitMessages: List[String] = newList()
  match boundary {
    case Some(b) -> if d.isPublic and not owner.contains("__lyric_checked_") {
      boundaryChecks(c, d, owner, b, entryChecks, exitPosts, exitMessages)
    }
    case None -> ()
  }
  if userPre.count == 0 and userPost.count == 0 and entryChecks.count == 0 and exitPosts.count == 0 and d.invariants.count == 0 {
    return d
  }
  val stmts: List[TStmt] = newList()
  // `old(e)` snapshots come first, so they hold the state the call began with even when a precondition fails.
  val collect = CCtx(
    nextNode = c.nextNode,
    nextLocal = c.nextLocal,
    fresh = false,
    collectOld = true,
    olds = newList(),
    oldLocals = newList(),
    oldIdx = newOldIdx(),
    resultLocal = None,
    exits = None
  )
  for p in userPost {
    cExpr(collect, p)
  }
  val oldLocals: List[LocalDecl] = newList()
  var oi = 0
  while oi < collect.olds.count {
    val inner = collect.olds[oi]
    val l = newLocal(c, "__old_" + toString(oi), inner.ty)
    oldLocals.add(l)
    val fresh = CCtx(
      nextNode = c.nextNode,
      nextLocal = c.nextLocal,
      fresh = true,
      collectOld = false,
      olds = newList(),
      oldLocals = newList(),
      oldIdx = newOldIdx(),
      resultLocal = None,
      exits = None
    )
    stmts.add(bindStmt(c, l, cExpr(fresh, inner), sp))
    oi = oi + 1
  }
  // The boundary's entry checks come before any `requires:` (docs/08 §7.1).
  for st in entryChecks {
    stmts.add(st)
  }
  var pi = 0
  while pi < userPre.count {
    val clone = CCtx(
      nextNode = c.nextNode,
      nextLocal = c.nextLocal,
      fresh = true,
      collectOld = false,
      olds = newList(),
      oldLocals = newList(),
      oldIdx = newOldIdx(),
      resultLocal = None,
      exits = None
    )
    stmts.add(
      assertStmt(
        c,
        cExpr(clone, userPre[pi]),
        violation("PreconditionViolated", owner, "requires", clauseText(userPreTexts, pi)),
        userPre[pi].span
      )
    )
    pi = pi + 1
  }
  val messages: List[String] = newList()
  var mi = 0
  while mi < userPost.count {
    messages.add(violation("PostconditionViolated", owner, "ensures", clauseText(userPostTexts, mi)))
    mi = mi + 1
  }
  val posts: List[TExpr] = newList()
  for p in userPost {
    posts.add(p)
  }
  // The protected type's invariants are system checks like the boundary's: they run with contracts off too.
  var ii = 0
  while ii < d.invariants.count {
    posts.add(d.invariants[ii])
    messages.add(violation("InvariantViolated", owner, "invariant", clauseText(d.invariantTexts, ii)))
    ii = ii + 1
  }
  for p in exitPosts {
    posts.add(p)
  }
  for m in exitMessages {
    messages.add(m)
  }
  val plan = ExitPlan(posts = posts, messages = messages, ret = d.ret, oldLocals = oldLocals, span = sp)
  val walk = CCtx(
    nextNode = c.nextNode,
    nextLocal = c.nextLocal,
    fresh = false,
    collectOld = false,
    olds = newList(),
    oldLocals = newList(),
    oldIdx = newOldIdx(),
    resultLocal = None,
    exits = Some(value = plan)
  )
  val rewritten = cExpr(walk, body)
  var blockTy = d.ret
  var tail: Option[TExpr] = None
  match d.ret {
    case TNever -> {
      tail = Some(value = rewritten)
    }
    case TPrim(TPUnit) -> {
      stmts.add(TStmt(id = newNode(c), span = sp, kind = TsExpr(expr = rewritten)))
      for s in postAsserts(c, plan, None) {
        stmts.add(s)
      }
    }
    case _ -> match rewritten.ty {
      case TNever -> {
        blockTy = TNever
        tail = Some(value = rewritten)
      }
      case _ -> {
        val r = newLocal(c, "__lyric_result_tail", d.ret)
        stmts.add(bindStmt(c, r, rewritten, sp))
        for s in postAsserts(c, plan, Some(value = r)) {
          stmts.add(s)
        }
        tail = Some(value = localRead(c, r, sp))
      }
    }
  }
  val newBody = TExpr(id = newNode(c), ty = blockTy, span = sp, kind = XBlock(stmts = stmts, tail = tail))
  TFnDecl(
    sym = d.sym,
    typeParams = d.typeParams,
    params = d.params,
    ret = d.ret,
    isAsync = d.isAsync,
    preconds = d.preconds,
    postconds = d.postconds,
    body = Some(value = newBody),
    span = d.span,
    barrier = d.barrier,
    ownerParamCount = d.ownerParamCount,
    isGenerator = d.isGenerator,
    precondTexts = d.precondTexts,
    postcondTexts = d.postcondTexts,
    isPublic = d.isPublic,
    invariants = d.invariants,
    invariantTexts = d.invariantTexts
  )
}

/// `{ checker(arg); true }`: a postcondition whose evaluation runs the checker (which panics on a violation).
func checkerHolds(c: in CCtx, ref: in CheckerRef, arg: in TExpr, sp: in Span): TExpr {
  val args: List[TArg] = newList()
  args.add(TArgIn(value = arg))
  val call = TExpr(
    id = newNode(c),
    ty = arg.ty,
    span = sp,
    kind = XCall(callee = Direct(sym = ref.sym, typeArgs = newList()), args = args)
  )
  val stmts: List[TStmt] = newList()
  stmts.add(TStmt(id = newNode(c), span = sp, kind = TsExpr(expr = call)))
  val yes = TExpr(id = newNode(c), ty = tyBool(), span = sp, kind = XLit(lit = TLBool(value = true)))
  TExpr(id = newNode(c), ty = tyBool(), span = sp, kind = XBlock(stmts = stmts, tail = Some(value = yes)))
}

func checkerOf(b: in BoundaryCtx, t: in Ty): Option[CheckerRef] {
  match t {
    case TNamed(s, targs) -> if targs.count == 0 { mapGet(b.checkers, s.id) } else { None }
    case _ -> None
  }
}

/// The public-boundary invariant checks of `d` (docs/08 §7.1, D507): the entry statements for each `in` or `inout`
/// parameter of another package's invariant-carrying type, and the postconditions (with messages) for each
/// `inout`/`out` parameter of any such type and for the result.  A type whose checker the bundle does not hold, a
/// generic type, and a value inside a container are not checked here.
func boundaryChecks(
  c: in CCtx,
  d: in TFnDecl,
  owner: in String,
  b: in BoundaryCtx,
  entry: in List[TStmt],
  posts: in List[TExpr],
  messages: in List[String],
): Unit {
  for p in d.params {
    match checkerOf(b, p.local.ty) {
      case Some(ref) -> {
        val foreign = ref.pkg != b.pkg
        val isOut = match p.mode { case TMOut -> true; case _ -> false }
        val written = match p.mode { case TMIn -> false; case _ -> true }
        if foreign and not isOut {
          val args: List[TArg] = newList()
          args.add(TArgIn(value = localRead(c, p.local, d.span)))
          val call = TExpr(
            id = newNode(c),
            ty = p.local.ty,
            span = d.span,
            kind = XCall(callee = Direct(sym = ref.sym, typeArgs = newList()), args = args)
          )
          entry.add(TStmt(id = newNode(c), span = d.span, kind = TsExpr(expr = call)))
          b.used.add(ref.sym.id, ref)
        }
        if written {
          posts.add(checkerHolds(c, ref, localRead(c, p.local, d.span), d.span))
          messages.add("InvariantViolated: " + owner + " parameter " + p.local.name)
          b.used.add(ref.sym.id, ref)
        }
      }
      case None -> ()
    }
  }
  match checkerOf(b, d.ret) {
    case Some(ref) -> {
      val res = TExpr(id = newNode(c), ty = d.ret, span = d.span, kind = XResult)
      posts.add(checkerHolds(c, ref, res, d.span))
      messages.add("InvariantViolated: " + owner + " result")
      b.used.add(ref.sym.id, ref)
    }
    case None -> ()
  }
}

/// The construction checkers of `pkgs`, by the `SymbolId` of the non-generic type each checks: a function named
/// `__lyric_checked_T` of one parameter of type `T` (synthesized for each type that declares `invariant:`).
func collectCheckers(interner: in DefPathInterner, pkgs: in List[PackageBuild]): Map[Int, CheckerRef] {
  val found: Map[Int, CheckerRef] = newMap()
  for pb in pkgs {
    for f in pb.pkg.funcs {
      if f.params.count == 1 {
        val key = match defPathKeyOf(interner, f.sym) { case Some(k) -> k; case None -> "" }
        val simple = simpleNameOf(key)
        if simple.startsWith("__lyric_checked_") {
          match f.params[0].local.ty {
            case TNamed(ts, targs) -> if targs.count == 0 and not found.containsKey(ts.id) {
              for en in pb.pkg.symbols {
                if en.sym.id == f.sym.id and not found.containsKey(ts.id) {
                  found.add(ts.id, CheckerRef(sym = f.sym, symEntry = en, pkg = pb.pkg.name))
                }
              }
            }
            case _ -> ()
          }
        }
      }
    }
  }
  found
}

/// The last `::` segment of a DefPath key, without its parameter list.
func simpleNameOf(key: in String): String {
  val head = ownerNameOf(key)
  var cut = -1
  var i = 0
  while i < head.length {
    if head.substring(i, 1) == "." {
      cut = i
    }
    i = i + 1
  }
  if cut < 0 {
    head
  } else {
    head.substring(cut + 1, head.length - cut - 1)
  }
}

/// `bundle` with `elaborateFn` applied to every function of every package.
pub func elaborateBundle(
  interner: in DefPathInterner, bundle: in List[PackageBuild], enabled: in Bool
): List[PackageBuild] {
  elaborateBundleWith(interner, bundle, enabled, newList())
}

/// `elaborateBundle` with the public-boundary invariant checks of D507: the construction checkers come from
/// `bundle` and from `visible`, the other packages of the build the bundle's functions may cross into (the native
/// bridge elaborates its own packages and the standard library's separately).
pub func elaborateBundleWith(
  interner: in DefPathInterner,
  bundle: in List[PackageBuild],
  enabled: in Bool,
  visible: in List[PackageBuild],
): List[PackageBuild] {
  val all: List[PackageBuild] = newList()
  for pb in visible {
    all.add(pb)
  }
  for pb in bundle {
    all.add(pb)
  }
  val checkers = collectCheckers(interner, all)
  val res: List[PackageBuild] = newList()
  for pb in bundle {
    val fns: List[TFnDecl] = newList()
    val nextNode: List[Int] = newList()
    nextNode.add(firstContractNodeId())
    val ctx = BoundaryCtx(checkers = checkers, pkg = pb.pkg.name, used = newMap())
    for f in pb.pkg.funcs {
      val key = match defPathKeyOf(interner, f.sym) { case Some(k) -> k; case None -> "" }
      fns.add(elaborateFnWith(f, ownerNameOf(key), enabled, nextNode, Some(value = ctx)))
    }
    val syms: List[TSymEntry] = newList()
    val have: Map[Int, Bool] = newMap()
    for en in pb.pkg.symbols {
      syms.add(en)
      have.add(en.sym.id, true)
    }
    for k in mapKeys(ctx.used) {
      if not have.containsKey(k) {
        match mapGet(ctx.used, k) {
          case Some(ref) -> syms.add(ref.symEntry)
          case None -> ()
        }
      }
    }
    res.add(
      PackageBuild(
        pkg = TPackage(name = pb.pkg.name, symbols = syms, funcs = fns, impls = pb.pkg.impls),
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
