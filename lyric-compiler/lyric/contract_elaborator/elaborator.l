// elaborator.l — Lyric.ContractElaborator
//
// Phase 5 §M5.2 stage 2.  The contract elaborator transforms a parsed
// SourceFile by inserting runtime contract checks (`assert(...)` calls)
// for `requires:` and `ensures:` clauses on each function.  The original
// `contracts` list on each FunctionDecl is preserved so the verifier and
// the contract-meta consumers can still see the source-level clauses.
//
// Mirrors the in-IL contract emission in
// compiler/src/Lyric.Emitter/Emitter.fs (see `emitContractCheck` around
// lines 1940 / 2698 / 2808): the bootstrap emitter runs every
// `CCRequires` clause as a runtime check before executing the body, and
// runs every `CCEnsures` clause at the function exit label after the
// result has been routed into the function's `ResultLocal`.  The
// elaborator produces a transformed AST where these checks appear as
// explicit `assert(cond)` statements at the corresponding source
// positions.
//
// Stage 2 scope (this file):
//
//   * `requires:` clauses — full elaboration.  An `assert(req)`
//     statement is prepended (in source order) to the body block of
//     every non-`@axiom` function with a body.
//
//   * `ensures:`  clauses — top-level shape only.  Each `SReturn(Some(e))`
//     and `SReturn(None)` directly under the function body block, plus
//     the trailing `SExpr` (implicit fall-off), is rewritten to bind the
//     produced value into a synthetic local `__lyric_result_<n>`, run
//     every `assert(<ensures with result -> __lyric_result_<n>>)`, then
//     yield (or `return`) the local.  Returns nested inside
//     `if` / `match` / `try` / loop bodies are not yet elaborated; the
//     bootstrap emitter still inserts a runtime check for them via the
//     exit-label routing, so the bootstrap remains correct.  Nested-
//     return elaboration is a follow-up stage.
//
//   * `@axiom` functions — skipped (axiom decls have no body, so there
//     is nothing to elaborate).
//
//   * Loop `invariant:` (`SInvariant`) — left as-is.  The verifier
//     consumes it; the bootstrap emitter does not insert runtime
//     checks for loop invariants, and neither does the elaborator.
//
//   * Protected-type entries (`PMEntry`) — deferred to a follow-up
//     stage.  Barrier (`when:`) checks and protected-type `invariant:`
//     clauses are emitted by the bootstrap directly in IL; the
//     self-host elaborator will lower them to `assert` statements once
//     it picks up the protected-type lowering as well.
//
// Public surface:
//
//   pub func elaborateFile(file: in SourceFile): SourceFile
//
//     Returns a new SourceFile with the requires/ensures elaboration
//     applied.  The input is not mutated.
//
//   pub func elaborateFunction(fn: in FunctionDecl): FunctionDecl
//
//     Per-function elaboration.  Useful when callers want to elaborate
//     a single FunctionDecl (e.g. an interface default method) without
//     wrapping it in a SourceFile.
//
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser


// ─────────────────────────────────────────────────────────────────────────────
// §1. Annotation predicates.
// ─────────────────────────────────────────────────────────────────────────────

func hasSimpleAnnotation(name: in String, anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return true
    }
    i = i + 1
  }
  false
}

func functionIsAxiom(fn: in FunctionDecl): Bool {
  hasSimpleAnnotation("axiom", fn.annotations)
}


// ─────────────────────────────────────────────────────────────────────────────
// §2. Synthetic-name counter.  The elaborator threads a `RenameCounter`
//     through each function so generated locals in nested scopes do not
//     collide.  The counter is reset per function — no two synthetic
//     names live in the same scope.
// ─────────────────────────────────────────────────────────────────────────────

pub record RenameCounter {
  next: Int
}

pub func newRenameCounter(): RenameCounter {
  RenameCounter(next = 0)
}

func freshResultName(c: inout RenameCounter): String {
  val n = c.next
  c.next = n + 1
  "__lyric_result_" + toString(n)
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. AST builders.  All helpers in this section construct Expr / Stmt
//     fragments at the same `Span` as the source clause they correspond
//     to, so downstream diagnostics keep pointing at user code.
// ─────────────────────────────────────────────────────────────────────────────

func mkUnit(sp: in Span): Expr {
  mkExpr(ELiteral(lit = LUnit), sp)
}

// Returns true iff any expression in the list contains an EResult node.
func anyHaveResult(exprs: in List[Expr]): Bool {
  var i = 0
  while i < exprs.count {
    if exprContainsResult(exprs[i]) { return true }
    i = i + 1
  }
  false
}

func exprContainsResult(e: in Expr): Bool {
  match e.kind {
    case EResult -> true
    case ELiteral(_) -> false
    case EPath(_) -> false
    case ESelf -> false
    case EError -> false
    case EParen(inner) -> exprContainsResult(inner)
    case ETuple(exprs) -> anyHaveResult(exprs)
    case EList(exprs) -> anyHaveResult(exprs)
    case EIf(cond, thenBranch, elseOpt, _) -> {
      if exprContainsResult(cond) { return true }
      if eobContainsResult(thenBranch) { return true }
      match elseOpt {
        case Some(eb) -> eobContainsResult(eb)
        case None     -> false
      }
    }
    case ECall(fn, args) -> {
      if exprContainsResult(fn) { return true }
      var i = 0
      while i < args.count {
        val hasIt = match args[i] {
          case CAPositional(v)  -> exprContainsResult(v)
          case CANamed(_, v, _) -> exprContainsResult(v)
        }
        if hasIt { return true }
        i = i + 1
      }
      false
    }
    case EForall(_, whereOpt, body) -> {
      match whereOpt {
        case Some(w) -> if exprContainsResult(w) { return true }
        case None    -> {}
      }
      exprContainsResult(body)
    }
    case EExists(_, whereOpt, body) -> {
      match whereOpt {
        case Some(w) -> if exprContainsResult(w) { return true }
        case None    -> {}
      }
      exprContainsResult(body)
    }
    case _ -> false
  }
}

func eobContainsResult(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> exprContainsResult(e)
    case EOBBlock(body) -> {
      var i = 0
      while i < body.statements.count {
        match body.statements[i].kind {
          case SExpr(e)         -> if exprContainsResult(e) { return true }
          case SReturn(Some(e)) -> if exprContainsResult(e) { return true }
          case _                -> {}
        }
        i = i + 1
      }
      false
    }
  }
}

func mkPath(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}

func mkAssertCall(cond: in Expr, sp: in Span): Statement {
  val callee = mkPath("assert", sp)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = cond))
  val call = mkExpr(ECall(fn = callee, args = args), sp)
  mkStmt(SExpr(expr = call), sp)
}

// `let <name> = <init>` with type inferred.
func mkLetBinding(name: in String, init: in Expr, sp: in Span): Statement {
  val binding = LBLet(name = name, ty = None, init = init)
  mkStmt(SLocal(binding = binding), sp)
}


// ─────────────────────────────────────────────────────────────────────────────
// §4. `result` substitution.
//
//     `substResult(e, name)` returns a structural copy of `e` with every
//     `EResult` leaf rewritten to `EPath([name])`.  Identity-preserving
//     for the rest of the tree (we still allocate fresh records, but
//     each leaf retains its original `Span`).
// ─────────────────────────────────────────────────────────────────────────────

func substResult(e: in Expr, name: in String): Expr {
  match e.kind {
    case EResult -> mkPath(name, e.span)
    case ELiteral(_) -> e
    case EPath(_) -> e
    case ESelf -> e
    case EError -> e
    case EParen(inner) ->
      mkExpr(EParen(inner = substResult(inner, name)), e.span)
    case ETuple(exprs) -> {
      val outs: List[Expr] = newList()
      var i = 0
      while i < exprs.count { outs.add(substResult(exprs[i], name)); i = i + 1 }
      mkExpr(ETuple(exprs = outs), e.span)
    }
    case EList(exprs) -> {
      val outs: List[Expr] = newList()
      var i = 0
      while i < exprs.count { outs.add(substResult(exprs[i], name)); i = i + 1 }
      mkExpr(EList(exprs = outs), e.span)
    }
    case EIf(cond, thenBranch, elseOpt, thenForm) -> {
      val newElse: Option[ExprOrBlock] =
        match elseOpt {
          case Some(eb) -> Some(value = substResultEob(eb, name))
          case None     -> None
        }
      mkExpr(EIf(
        cond = substResult(cond, name),
        thenBranch = substResultEob(thenBranch, name),
        elseBranch = newElse,
        thenForm = thenForm), e.span)
    }
    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val newGuard: Option[Expr] =
          match arm.guard {
            case Some(g) -> Some(value = substResult(g, name))
            case None    -> None
          }
        newArms.add(MatchArm(
          pattern = arm.pattern,
          guard   = newGuard,
          body    = substResultEob(arm.body, name),
          span    = arm.span))
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = substResult(scrutinee, name), arms = newArms), e.span)
    }
    case EAwait(inner) ->
      mkExpr(EAwait(inner = substResult(inner, name)), e.span)
    case EYield(inner) ->
      mkExpr(EYield(inner = substResult(inner, name)), e.span)
    case ESpawn(inner) ->
      mkExpr(ESpawn(inner = substResult(inner, name)), e.span)
    case ETry(inner) ->
      mkExpr(ETry(inner = substResult(inner, name)), e.span)
    case EOld(inner) ->
      mkExpr(EOld(inner = substResult(inner, name)), e.span)
    case EForall(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] =
        match whereOpt {
          case Some(w) -> Some(value = substResult(w, name))
          case None    -> None
        }
      mkExpr(EForall(
        binders   = binders,
        whereExpr = newWhere,
        body      = substResult(body, name)), e.span)
    }
    case EExists(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] =
        match whereOpt {
          case Some(w) -> Some(value = substResult(w, name))
          case None    -> None
        }
      mkExpr(EExists(
        binders   = binders,
        whereExpr = newWhere,
        body      = substResult(body, name)), e.span)
    }
    case ELambda(params, body) ->
      mkExpr(ELambda(lambdaParams = params, body = substResultBlock(body, name)), e.span)
    case ECall(fn, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(n, v, sp) -> newArgs.add(CANamed(name = n, value = substResult(v, name), span = sp))
          case CAPositional(v)   -> newArgs.add(CAPositional(expr = substResult(v, name)))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = substResult(fn, name), args = newArgs), e.span)
    }
    case ETypeApp(fn, ts) ->
      mkExpr(ETypeApp(fn = substResult(fn, name), args = ts), e.span)
    case EIndex(recv, indices) -> {
      val newIdx: List[Expr] = newList()
      var i = 0
      while i < indices.count { newIdx.add(substResult(indices[i], name)); i = i + 1 }
      mkExpr(EIndex(receiver = substResult(recv, name), indices = newIdx), e.span)
    }
    case EMember(recv, mname) ->
      mkExpr(EMember(receiver = substResult(recv, name), memberName = mname), e.span)
    case EPropagate(inner) ->
      mkExpr(EPropagate(inner = substResult(inner, name)), e.span)
    case EPrefix(op, x) ->
      mkExpr(EPrefix(op = op, operand = substResult(x, name)), e.span)
    case EBinop(op, l, r) ->
      mkExpr(EBinop(op = op, lhs = substResult(l, name), rhs = substResult(r, name)), e.span)
    case ERange(bound) ->
      mkExpr(ERange(bound = substResultRange(bound, name)), e.span)
    case EAssign(t, op, v) ->
      mkExpr(EAssign(target = substResult(t, name), op = op, value = substResult(v, name)), e.span)
    case EBlock(blk) ->
      mkExpr(EBlock(block = substResultBlock(blk, name)), e.span)
    case EUnsafe(blk) ->
      mkExpr(EUnsafe(block = substResultBlock(blk, name)), e.span)
    case EInterpolated(segs) -> {
      val outs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> outs.add(ISText(text = t, span = sp))
          case ISExpr(x)     -> outs.add(ISExpr(expr = substResult(x, name)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = outs), e.span)
    }
  }
}

func substResultEob(eob: in ExprOrBlock, name: in String): ExprOrBlock {
  match eob {
    case EOBExpr(x)    -> EOBExpr(expr = substResult(x, name))
    case EOBBlock(blk) -> EOBBlock(block = substResultBlock(blk, name))
  }
}

func substResultBlock(blk: in Block, name: in String): Block {
  val outs: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    outs.add(substResultStmt(blk.statements[i], name))
    i = i + 1
  }
  Block(statements = outs, span = blk.span)
}

func substResultStmt(s: in Statement, name: in String): Statement {
  match s.kind {
    case SLocal(binding) ->
      mkStmt(SLocal(binding = substResultBinding(binding, name)), s.span)
    case SAssign(t, op, v) ->
      mkStmt(SAssign(target = substResult(t, name), op = op, value = substResult(v, name)), s.span)
    case SReturn(valOpt) -> {
      val newVal: Option[Expr] =
        match valOpt {
          case Some(v) -> Some(value = substResult(v, name))
          case None    -> None
        }
      mkStmt(SReturn(value = newVal), s.span)
    }
    case SBreak(_)    -> s
    case SContinue(_) -> s
    case SThrow(x)    -> mkStmt(SThrow(expr = substResult(x, name)), s.span)
    case STry(body, catches) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        newCatches.add(CatchClause(
          typeName = c.typeName,
          bindName = c.bindName,
          body     = substResultBlock(c.body, name),
          span     = c.span))
        i = i + 1
      }
      mkStmt(STry(body = substResultBlock(body, name), catches = newCatches), s.span)
    }
    case SDefer(body) ->
      mkStmt(SDefer(body = substResultBlock(body, name)), s.span)
    case SScope(label, body) ->
      mkStmt(SScope(binding = label, body = substResultBlock(body, name)), s.span)
    case SFor(label, pat, iter, body) ->
      mkStmt(SFor(
        label = label,
        pat   = pat,
        iter  = substResult(iter, name),
        body  = substResultBlock(body, name)), s.span)
    case SWhile(label, cond, body) ->
      mkStmt(SWhile(
        label = label,
        cond  = substResult(cond, name),
        body  = substResultBlock(body, name)), s.span)
    case SLoop(label, body) ->
      mkStmt(SLoop(label = label, body = substResultBlock(body, name)), s.span)
    case SInvariant(x) ->
      mkStmt(SInvariant(expr = substResult(x, name)), s.span)
    case SExpr(x) ->
      mkStmt(SExpr(expr = substResult(x, name)), s.span)
    case SRule(l, r) ->
      mkStmt(SRule(lhs = substResult(l, name), rhs = substResult(r, name)), s.span)
    case SItem(_) -> s
  }
}

func substResultBinding(b: in LocalBinding, name: in String): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = substResult(init, name))
    case LBLet(n, ty, init)   -> LBLet(name = n, ty = ty, init = substResult(init, name))
    case LBVar(n, ty, initOpt) -> {
      val newInit: Option[Expr] =
        match initOpt {
          case Some(x) -> Some(value = substResult(x, name))
          case None    -> None
        }
      LBVar(name = n, ty = ty, init = newInit)
    }
  }
}

func substResultRange(b: in RangeBound, name: in String): RangeBound {
  match b {
    case RBClosed(lo, hi)   -> RBClosed(lo = substResult(lo, name), hi = substResult(hi, name))
    case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = substResult(lo, name), hi = substResult(hi, name))
    case RBLowerOpen(hi)    -> RBLowerOpen(hi = substResult(hi, name))
    case RBUpperOpen(lo)    -> RBUpperOpen(lo = substResult(lo, name))
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// §5. Function-body elaboration.
//
//     `elaborateFunctionBody` produces a transformed `Block` with:
//       1. one `assert(req)` statement per `CCRequires` clause, prepended
//          in source order;
//       2. each top-level `SReturn(Some(e))` rewritten to
//          `let __lyric_result_<n> = e; <ensures asserts>; return
//          __lyric_result_<n>`;
//       3. each top-level `SReturn(None)` rewritten to `<ensures
//          asserts>; return`;
//       4. the trailing `SExpr(e)` (implicit fall-off) rewritten to
//          `let __lyric_result_<n> = e; <ensures asserts>;
//          __lyric_result_<n>`.
//
//     The clauses in `contracts` are scanned once into separate
//     `requires` / `ensures` lists; non-`requires` / non-`ensures`
//     clauses (`when:` / `decreases:` / `raises:`) are ignored —
//     these aren't run-time-checked by the bootstrap either.
// ─────────────────────────────────────────────────────────────────────────────

func collectRequires(contracts: in List[ContractClause]): List[Expr] {
  val xs: List[Expr] = newList()
  var i = 0
  while i < contracts.count {
    match contracts[i] {
      case CCRequires(e, _) -> xs.add(e)
      case _                -> {}
    }
    i = i + 1
  }
  xs
}

func collectEnsures(contracts: in List[ContractClause]): List[Expr] {
  val xs: List[Expr] = newList()
  var i = 0
  while i < contracts.count {
    match contracts[i] {
      case CCEnsures(e, _) -> xs.add(e)
      case _               -> {}
    }
    i = i + 1
  }
  xs
}

// Append `assert(<ensures with result -> name>)` statements for every
// ensures clause to `acc`, anchored at `sp`.
func appendEnsuresAsserts(
  acc:           in List[Statement],
  ensuresExprs:  in List[Expr],
  resultName:    in String,
  sp:            in Span
): Unit {
  var i = 0
  while i < ensuresExprs.count {
    val cond = substResult(ensuresExprs[i], resultName)
    acc.add(mkAssertCall(cond, sp))
    i = i + 1
  }
}

// Variant for `SReturn(None)` and other no-result paths: ensures
// clauses are inserted with `result` substituted by `()` if any clause
// references EResult.  This prevents dangling EResult nodes from reaching
// codegen when the type-checker does not reject `ensures: result == …`
// on a Unit-returning function.  Clauses that do not reference result
// are emitted directly without extra bindings.
func appendEnsuresAssertsNoResult(
  acc:           in List[Statement],
  ensuresExprs:  in List[Expr],
  sp:            in Span
): Unit {
  if ensuresExprs.count == 0 { return }
  val needUnit = anyHaveResult(ensuresExprs)
  val dummyName = "__lyric_result_unit"
  if needUnit { acc.add(mkLetBinding(dummyName, mkUnit(sp), sp)) }
  var i = 0
  while i < ensuresExprs.count {
    val cond = if needUnit { substResult(ensuresExprs[i], dummyName) } else { ensuresExprs[i] }
    acc.add(mkAssertCall(cond, sp))
    i = i + 1
  }
}

// Rewrite a top-level `SReturn(Some(e))` into:
//   let __lyric_result_<n> = e
//   <ensures asserts>
//   return __lyric_result_<n>
func rewriteReturnSome(
  e:            in Expr,
  ensuresExprs: in List[Expr],
  counter:      inout RenameCounter,
  sp:           in Span,
  acc:          in List[Statement]
): Unit {
  if ensuresExprs.count == 0 {
    acc.add(mkStmt(SReturn(value = Some(value = e)), sp))
    return
  }
  val name = freshResultName(counter)
  acc.add(mkLetBinding(name, e, sp))
  appendEnsuresAsserts(acc, ensuresExprs, name, sp)
  acc.add(mkStmt(SReturn(value = Some(value = mkPath(name, sp))), sp))
}

// Rewrite the trailing `SExpr(e)` of a non-Unit body block into:
//   let __lyric_result_<n> = e
//   <ensures asserts>
//   __lyric_result_<n>
func rewriteTrailingSExpr(
  e:            in Expr,
  ensuresExprs: in List[Expr],
  counter:      inout RenameCounter,
  sp:           in Span,
  acc:          in List[Statement]
): Unit {
  if ensuresExprs.count == 0 {
    acc.add(mkStmt(SExpr(expr = e), sp))
    return
  }
  val name = freshResultName(counter)
  acc.add(mkLetBinding(name, e, sp))
  appendEnsuresAsserts(acc, ensuresExprs, name, sp)
  acc.add(mkStmt(SExpr(expr = mkPath(name, sp)), sp))
}

// Process a single statement at the top level of the function body.
// `isLast` indicates whether this is the trailing statement of the
// outer function-body block (relevant for implicit fall-off rewriting).
func elaborateTopLevelStmt(
  s:            in Statement,
  isLast:       in Bool,
  ensuresExprs: in List[Expr],
  counter:      inout RenameCounter,
  acc:          in List[Statement]
): Unit {
  match s.kind {
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> rewriteReturnSome(e, ensuresExprs, counter, s.span, acc)
        case None    -> {
          appendEnsuresAssertsNoResult(acc, ensuresExprs, s.span)
          acc.add(s)
        }
      }
    }
    case SExpr(e) -> {
      if isLast {
        rewriteTrailingSExpr(e, ensuresExprs, counter, s.span, acc)
      } else {
        acc.add(s)
      }
    }
    case _ -> { acc.add(s) }
  }
}

func elaborateFunctionBody(
  contracts: in List[ContractClause],
  body:      in Block,
  counter:   inout RenameCounter
): Block {
  val requiresExprs = collectRequires(contracts)
  val ensuresExprs  = collectEnsures(contracts)

  val outs: List[Statement] = newList()

  // (1) Prepend requires asserts at the body's start span.
  var ri = 0
  while ri < requiresExprs.count {
    outs.add(mkAssertCall(requiresExprs[ri], body.span))
    ri = ri + 1
  }

  // (2) / (3) / (4): walk top-level statements.
  var si = 0
  while si < body.statements.count {
    val isLast = si == body.statements.count - 1
    elaborateTopLevelStmt(body.statements[si], isLast, ensuresExprs, counter, outs)
    si = si + 1
  }

  Block(statements = outs, span = body.span)
}

// Wrap an `FBExpr(e)` into a block so the same elaboration pipeline can
// run.  The resulting block contains a single `SExpr(e)` statement; the
// trailing-fall-off case in `elaborateTopLevelStmt` handles the rewrite.
func wrapExprBody(e: in Expr): Block {
  val stmts: List[Statement] = newList()
  stmts.add(mkStmt(SExpr(expr = e), e.span))
  Block(statements = stmts, span = e.span)
}


// ─────────────────────────────────────────────────────────────────────────────
// §6. Top-level driver.  `elaborateFunction` rebuilds a FunctionDecl
//     with an elaborated body; `elaborateFile` walks every item and
//     elaborates each `IFunc`.  Other item kinds (records, unions,
//     interfaces, …) are passed through unchanged for now; protected-
//     type entries and interface default methods are picked up in a
//     follow-up stage.
// ─────────────────────────────────────────────────────────────────────────────

pub func elaborateFunction(fn: in FunctionDecl): FunctionDecl {
  // @axiom functions have no body — nothing to elaborate.
  if functionIsAxiom(fn) { return fn }

  // Functions without a body (signatures, externs) — pass through.
  match fn.body {
    case None -> { return fn }
    case _    -> {}
  }

  // No clauses → nothing to do; preserve identity of the input record.
  val hasReq = collectRequires(fn.contracts).count > 0
  val hasEns = collectEnsures(fn.contracts).count > 0
  if not hasReq and not hasEns { return fn }

  var counter = newRenameCounter()
  val newBody: FunctionBody =
    match fn.body {
      case Some(b) ->
        match b {
          case FBBlock(blk) -> FBBlock(block = elaborateFunctionBody(fn.contracts, blk, counter))
          case FBExpr(e)    -> FBBlock(block = elaborateFunctionBody(fn.contracts, wrapExprBody(e), counter))
        }
      case None -> FBExpr(expr = mkExpr(EError, fn.span))   // unreachable per the early return above
    }

  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility  = fn.visibility,
    isAsync     = fn.isAsync,
    name        = fn.name,
    generics    = fn.generics,
    params      = fn.params,
    ret         = fn.ret,
    whereClause = fn.whereClause,
    contracts   = fn.contracts,
    body        = Some(value = newBody),
    span        = fn.span)
}

func elaborateItem(it: in Item): Item {
  match it.kind {
    case IFunc(fn) ->
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility  = it.visibility,
        kind        = IFunc(decl = elaborateFunction(fn)),
        span        = it.span)
    case _ -> it
  }
}

pub func elaborateFile(file: in SourceFile): SourceFile {
  val newItems: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    newItems.add(elaborateItem(file.items[i]))
    i = i + 1
  }
  SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span)
}
