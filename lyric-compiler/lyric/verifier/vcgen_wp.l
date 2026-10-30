//! verifier/vcgen_wp.l — weakest-precondition walk over statements and bindings.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// ─────────────────────────────────────────────────────────────────────────────
// §6. Contract translation helper.
// ─────────────────────────────────────────────────────────────────────────────
// A contract expression translated in three parts: the side conditions
// its evaluation must meet (a callee's `requires:`, an overflow bound), the
// facts its evaluation brings (a callee's `ensures:`), and its value.  The
// facts hold only where the side conditions do, so an obligation never
// uses them to prove its own side conditions: it is `sides and (facts =>
// value)` (#8102).
record ContractParts {
  sides: List[Term]
  facts: List[Term]
  value: Term
  diags: List[Diagnostic]
}

func translateContractParts(env: in VEnv, e: in Expr): ContractParts {
  val (r, diags) = translateExpr(env, e)
  ContractParts(sides = r.sideConds, facts = r.assumed, value = r.term, diags = diags)
}

// What proving the contract takes: `sides and (facts => value)`.
func partsObligation(p: in ContractParts): Term {
  val parts: List[Term] = newList()
  appendTermList(parts, p.sides)
  parts.add(if p.facts.count == 0 { p.value } else { mkImplies(mkAnd(p.facts), p.value) })
  mkAnd(parts)
}

// What assuming the contract gives, once it has been proved where it is
// assumed: its side conditions, its facts and its value.
func partsHyps(p: in ContractParts): List[Term] {
  val hyps: List[Term] = newList()
  appendTermList(hyps, p.sides)
  appendTermList(hyps, p.facts)
  hyps.add(p.value)
  hyps
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. WP result and side goals.
// ─────────────────────────────────────────────────────────────────────────────
pub record SideGoal {
  pub term: Term
  pub kind: GoalKind
  pub span: Span
}

pub record WpResult {
  pub wp: Term
  pub sideGoals: List[SideGoal]
  pub assumed: List[Term]
  pub diags: List[Diagnostic]
}

func emptyWpResult(wp: in Term): WpResult {
  val sg: List[SideGoal] = newList()
  val asList: List[Term] = newList()
  val di: List[Diagnostic] = newList()
  WpResult(wp = wp, sideGoals = sg, assumed = asList, diags = di)
}

func mergeWpResults(a: in WpResult, b: in WpResult, wp: in Term): WpResult {
  val sg: List[SideGoal] = newList()
  var i = 0
  while i < a.sideGoals.count {
    sg.add(a.sideGoals[i])
    i = i + 1
  }
  i = 0
  while i < b.sideGoals.count {
    sg.add(b.sideGoals[i])
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, a.assumed)
  appendTermList(asList, b.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, a.diags)
  appendTermList2(di, b.diags)
  WpResult(wp = wp, sideGoals = sg, assumed = asList, diags = di)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. WP over a function body.
// ─────────────────────────────────────────────────────────────────────────────
// WP over a single expression (for FBExpr), the value the path ends with.
func wpExpr(env: in VEnv, resultSort: in SortInfo, postcond: in Term, e: in Expr): WpResult {
  // A value with a `?` in it is a statement whose `?`s split the path.
  if exprHasPropagate(e) {
    val asStmts: List[Statement] = newList()
    asStmts.add(Statement(kind = SExpr(expr = e), span = e.span))
    return wpWalk(env, resultSort, postcond, asStmts, 0)
  }
  // An assignment nested in the expression is something `translateExpr`
  // cannot follow; fail closed rather than prove the postcondition of the
  // wrong state (#8102).
  if effectsOfExpr(env, e).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", e.span)
  }
  val (r, diags) = translateExpr(env, e)
  // A variable passed to an `out`/`inout` parameter holds its new value
  // when the postcondition is checked (#8102).
  val after = havocOutArgs(env, e)
  // Substitute result into postcond, at the declared result sort (#7848).
  val wp = finishPost(after.env, postcond, coerceTermAt(r.term, resultSort.sort, e.span, diags))
  val sideGoals: List[SideGoal] = newList()
  // A value reported untranslatable (V0033) keeps a goal failed even when
  // the postcondition does not mention it (#7874).
  if termIsPoisoned(r.term) {
    sideGoals.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = e.span))
  }
  var i = 0
  while i < r.sideConds.count {
    sideGoals.add(SideGoal(term = r.sideConds[i], kind = GKAssertion, span = e.span))
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, r.assumed)
  appendTermList(asList, after.hyps)
  WpResult(wp = wp, sideGoals = sideGoals, assumed = asList, diags = diags)
}

pub func wpBody(env: in VEnv, resultSort: in SortInfo, postcond: in Term, body: in FunctionBody): WpResult {
  match body {
    case FBExpr(e) -> wpExpr(env, resultSort, postcond, e)
    case FBBlock(blk) -> wpBlock(env, resultSort, postcond, blk.statements)
  }
}

// A function's or a lambda's body: a scope of its own (#8109).
pub func wpBlock(env: in VEnv, resultSort: in SortInfo, postcond: in Term, stmts: in List[Statement]): WpResult {
  wpWalk(envEnterScope(env, freshName(env, "scope")), resultSort, postcond, stmts, 0)
}

// The rest of the block after an expression statement or binding whose
// translation is `r`: its side conditions are side goals, its facts are
// facts, and the variables it passed out hold new values from here on.
func wpAfterExpr(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  e: in Expr,
  r: in TranslateResult,
  rDiags: in List[Diagnostic],
): WpResult {
  val after = havocOutArgs(env, e)
  val inner = wpWalk(after.env, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  // A value reported untranslatable (V0033) keeps a goal failed even when
  // the statement discards it (#7874).
  if termIsPoisoned(r.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = e.span))
  }
  var i = 0
  while i < r.sideConds.count {
    sg.add(SideGoal(term = r.sideConds[i], kind = GKAssertion, span = e.span))
    i = i + 1
  }
  i = 0
  while i < inner.sideGoals.count {
    sg.add(inner.sideGoals[i])
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, r.assumed)
  appendTermList(asList, after.hyps)
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, rDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

func wpWalk(env: in VEnv, resultSort: in SortInfo, postcond: in Term, stmts: in List[Statement], idx: in Int): WpResult {
  if idx >= stmts.count {
    // Empty tail — postcond[result := unit].
    emptyWpResult(finishPost(env, postcond, unitTerm()))
  } else {
    val st = stmts[idx]
    // The end of a branch's scope: its bindings give way to the ones they
    // shadowed (#8109).
    match scopeEndOf(st) {
      case Some(scopeId) -> {
        return wpWalk(envExitScope(env, scopeId), resultSort, postcond, stmts, idx + 1)
      }
      case None -> ()
    }
    // A `?` splits the path where it runs (#8108).
    match propagateBindingOf(st) {
      case Some(pb) -> {
        return wpBindPropagate(env, resultSort, postcond, stmts, idx, pb, st.span)
      }
      case None -> ()
    }
    match hoistPropagates(env, st) {
      case Some(h) -> {
        if h.reason.length > 0 {
          val failDiags: List[Diagnostic] = newList()
          failDiags.add(untranslatableDiag(h.reason, st.span))
          val noGoals: List[SideGoal] = newList()
          val noFacts: List[Term] = newList()
          return WpResult(wp = falseT(), sideGoals = noGoals, assumed = noFacts, diags = failDiags)
        }
        val spliced: List[Statement] = newList()
        var si = 0
        while si < idx {
          spliced.add(stmts[si])
          si = si + 1
        }
        appendStmtList(spliced, h.stmts)
        si = idx + 1
        while si < stmts.count {
          spliced.add(stmts[si])
          si = si + 1
        }
        return wpWalk(env, resultSort, postcond, spliced, idx)
      }
      case None -> ()
    }
    match st.kind {
      case SReturn(Some(e)) -> {
        wpExpr(env, resultSort, postcond, e)
      }
      case SReturn(None) -> {
        emptyWpResult(finishPost(env, postcond, unitTerm()))
      }
      case SExpr(callExpr) -> {
        // Check if this is `assert(φ)`.
        match tryExtractAssert(callExpr) {
          case Some(argExpr) -> {
            // assert φ: add as side goal, assume φ for continuation.
            val (phiR, phiDiags) = translateExpr(env, argExpr)
            val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
            // Its side conditions are obligations too, and its facts prove
            // its value but never those side conditions (#8102).
            val phiParts = ContractParts(sides = phiR.sideConds, facts = phiR.assumed, value = phiR.term, diags = phiDiags)
            val sg: List[SideGoal] = newList()
            sg.add(SideGoal(term = partsObligation(phiParts), kind = GKAssertion, span = callExpr.span))
            var i = 0
            while i < inner.sideGoals.count {
              sg.add(inner.sideGoals[i])
              i = i + 1
            }
            val asList: List[Term] = newList()
            asList.add(phiR.term)
            appendTermList(asList, phiR.assumed)
            appendTermList(asList, inner.assumed)
            val di: List[Diagnostic] = newList()
            appendTermList2(di, phiDiags)
            appendTermList2(di, inner.diags)
            WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
          }
          case None -> {
            match tryExtractIf(callExpr) {
              // An `if` is walked branch by branch, so assignments in it
              // reach the rest of the block — and, when it ends the block,
              // its branches' values are the block's (#8102).
              case Some(ifTriple) -> {
                wpIfStmt(env, resultSort, postcond, stmts, idx, ifTriple.cond, ifTriple.thenBranch, ifTriple.elseBranchOpt, st.span)
              }
              case None -> {
                match callExpr.kind {
                  case EAssign(target, op, value) -> wpAssign(env, resultSort, postcond, stmts, idx, target, op, value, st.span)
                  case _ -> {
                    if idx + 1 >= stmts.count {
                      // Trailing expression in a block is the implicit return value (#3371).
                      wpExpr(env, resultSort, postcond, callExpr)
                    } else {
                      // An expression statement is evaluated for its effects:
                      // its obligations are side goals and its facts facts,
                      // whatever its form.  The verifier cannot follow an
                      // assignment or a jump inside one; skipping it would
                      // prove the rest of the block in the wrong state
                      // (#8102).
                      if hasEffectsOtherThanCalls(effectsOfExpr(env, callExpr)) {
                        unsupportedWp("an assignment or a jump inside an expression statement", callExpr.span)
                      } else {
                        val (stmtR, stmtDiags) = translateExpr(env, callExpr)
                        wpAfterExpr(env, resultSort, postcond, stmts, idx, callExpr, stmtR, stmtDiags)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      case SLocal(binding) -> {
        wpLocal(env, resultSort, postcond, stmts, idx, binding, st.span)
      }
      case SAssign(target, op, value) -> {
        wpAssign(env, resultSort, postcond, stmts, idx, target, op, value, st.span)
      }
      case SWhile(_, cond, body) -> {
        wpWhile(env, resultSort, postcond, stmts, idx, cond, body, st.span)
      }
      case SInvariant(_) -> {
        // SInvariant outside a loop is a user error (lyric-lang #418 §7).
        // Emit a diagnostic so the misplaced clause is surfaced, then
        // walk on so the rest of the body still gets verified.
        val rest = wpWalk(env, resultSort, postcond, stmts, idx + 1)
        val di: List[Diagnostic] = newList()
        di.add(
          warningDiagnostic("V0030", "invariant: clause outside loop head is ignored; move it onto a while/loop", st.span)
        )
        var k: Int = 0
        while k < rest.diags.count {
          di.add(rest.diags[k])
          k = k + 1
        }
        WpResult(wp = rest.wp, sideGoals = rest.sideGoals, assumed = rest.assumed, diags = di)
      }
      case _ -> {
        val di: List[Diagnostic] = newList()
        di.add(errorDiagnostic("V0026", "statement form not yet supported in M4.1 verifier; proof is unsound here", st.span))
        val sg: List[SideGoal] = newList()
        val asList: List[Term] = newList()
        WpResult(wp = falseT(), sideGoals = sg, assumed = asList, diags = di)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. WP statement helpers.
// ─────────────────────────────────────────────────────────────────────────────
// Try to extract `assert(<arg>)` from an expression.
func tryExtractAssert(e: in Expr): Option[Expr] {
  match e.kind {
    case ECall(fn, args) -> {
      if args.count == 1 {
        match fn.kind {
          case EPath(path) -> {
            if path.segments.count == 1 and path.segments[0] == "assert" {
              match args[0] {
                case CAPositional(v) -> Some(value = v)
                case CANamed(_, v, _) -> Some(value = v)
              }
            } else {
              None
            }
          }
          case _ -> None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// Auxiliary record for if-statement extraction.
record IfTriple {
  cond: Expr
  thenBranch: ExprOrBlock
  elseBranchOpt: Option[ExprOrBlock]
}

func tryExtractIf(e: in Expr): Option[IfTriple] {
  match e.kind {
    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      Some(value = IfTriple(cond = cond, thenBranch = thenBranch, elseBranchOpt = elseBranchOpt))
    }
    case _ -> None
  }
}

func wpIfStmt(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock],
  sp: in Span,
): WpResult {
  val (condR, condDiags) = translateExpr(env, cond)

  // Convert ExprOrBlock to statement list.
  val thenStmts = eobToStmts(thenBranch)
  val elseStmts = match elseBranchOpt {
    case Some(eb) -> eobToStmts(eb)
    case None -> {
      val empty: List[Statement] = newList()
      empty
    }
  }
  // Collect rest of the block.
  val rest: List[Statement] = newList()
  var ri = idx + 1
  while ri < stmts.count {
    rest.add(stmts[ri])
    ri = ri + 1
  }

  // Append rest to each branch.  Each branch is a scope, ended before the
  // rest so a binding it declares never reaches the rest (#8109).  With no
  // rest the branch ends the block and its last expression is the block's
  // value: nothing follows it to end the scope for.
  val thenScope = freshName(env, "scope")
  val elseScope = freshName(env, "scope")
  val thenFull: List[Statement] = newList()
  appendStmtList(thenFull, thenStmts)
  val elseFull: List[Statement] = newList()
  appendStmtList(elseFull, elseStmts)
  if rest.count > 0 {
    thenFull.add(scopeEndStmt(thenScope, sp))
    elseFull.add(scopeEndStmt(elseScope, sp))
  }
  appendStmtList(thenFull, rest)
  appendStmtList(elseFull, rest)

  val afterCond = havocOutArgs(env, cond)
  val thenR = wpWalk(envEnterScope(afterCond.env, thenScope), resultSort, postcond, thenFull, 0)
  val elseR = wpWalk(envEnterScope(afterCond.env, elseScope), resultSort, postcond, elseFull, 0)

  val notCond = mkNot(condR.term)
  // Guard branch side goals by their branch condition.
  val sg: List[SideGoal] = newList()
  var i = 0
  while i < condR.sideConds.count {
    sg.add(SideGoal(term = condR.sideConds[i], kind = GKAssertion, span = sp))
    i = i + 1
  }
  i = 0
  while i < thenR.sideGoals.count {
    val g = thenR.sideGoals[i]
    sg.add(SideGoal(term = mkImplies(condR.term, g.term), kind = g.kind, span = g.span))
    i = i + 1
  }
  i = 0
  while i < elseR.sideGoals.count {
    val g = elseR.sideGoals[i]
    sg.add(SideGoal(term = mkImplies(notCond, g.term), kind = g.kind, span = g.span))
    i = i + 1
  }

  // A branch's facts hold on that branch only: one branch's assertion or
  // a loop in it that never exits must not reach the other (#8102).
  val asList: List[Term] = newList()
  appendTermList(asList, condR.assumed)
  appendTermList(asList, afterCond.hyps)
  i = 0
  while i < thenR.assumed.count {
    asList.add(mkImplies(condR.term, thenR.assumed[i]))
    i = i + 1
  }
  i = 0
  while i < elseR.assumed.count {
    asList.add(mkImplies(notCond, elseR.assumed[i]))
    i = i + 1
  }
  val di: List[Diagnostic] = newList()
  appendTermList2(di, condDiags)
  appendTermList2(di, thenR.diags)
  appendTermList2(di, elseR.diags)
  WpResult(
    wp = TIte(cond = condR.term, thenT = thenR.wp, elseT = elseR.wp),
    sideGoals = sg,
    assumed = asList,
    diags = di
  )
}

func eobToStmts(eob: in ExprOrBlock): List[Statement] {
  match eob {
    case EOBBlock(b) -> b.statements
    case EOBExpr(e) -> {
      val lst: List[Statement] = newList()
      lst.add(Statement(kind = SExpr(expr = e), span = e.span))
      lst
    }
  }
}

func appendStmtList(dst: in List[Statement], src: in List[Statement]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

func wpLocal(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  binding: in LocalBinding,
  sp: in Span,
): WpResult {
  match binding {
    case LBVal(pat, ty, init) -> match simpleBindingName(pat) {
      case Some(name) -> wpBindInit(
        env,
        resultSort,
        postcond,
        stmts,
        idx,
        name,
        ty,
        init,
        false,
        noPatternBinders()
      )
      case None -> {
        // A destructuring pattern: the value is bound to a name of its
        // own, and each name the pattern binds to a value of its own —
        // the verifier does not model taking a value apart, and two
        // patterns' names must never share a value (#8109).
        val binders: List[String] = newList()
        collectPatternBinders(pat.kind, binders)
        wpBindInit(env, resultSort, postcond, stmts, idx, freshName(env, "pattern"), ty, init, false, binders)
      }
    }
    case LBLet(name, ty, init) -> wpBindInit(
      env,
      resultSort,
      postcond,
      stmts,
      idx,
      name,
      ty,
      init,
      false,
      noPatternBinders()
    )
    case LBVar(name, ty, Some(init)) -> wpBindInit(
      env,
      resultSort,
      postcond,
      stmts,
      idx,
      name,
      ty,
      init,
      true,
      noPatternBinders()
    )
    case LBVar(name, ty, None) -> {
      // Uninitialized var — bind to a fresh symbolic value of its declared
      // sort (an unannotated one is an integer, as before).  Its declared
      // range stays with it, for the values assigned to it (#7872).
      val info = match ty { case Some(t) -> sortOfTypeExprE(env, t); case None -> SortInfo(sort = SInt, range = RBKNone) }
      // The value is one of its own: the source name may be bound again
      // elsewhere in the function (#8102).
      val initial = freshVar(env, name, info.sort)
      val env2 = envSetMutable(envDeclare(name, initial, info, env), name, true)
      val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
      val asList: List[Term] = newList()
      // Read before any assignment it holds its type's zero, which need
      // not lie in its range (#8214): only its width holds.
      appendTermList(asList, intWidthHypothesesForTerm(initial, info))
      appendTermList(asList, inner.assumed)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = asList, diags = inner.diags)
    }
  }
}

// The name a `val` pattern binds when it binds the whole value to one.
func simpleBindingName(pat: in Pattern): Option[String] {
  match pat.kind {
    case PBinding(n, None) -> Some(value = n)
    case PParen(inner) -> simpleBindingName(inner)
    case _ -> None
  }
}

func noPatternBinders(): List[String] {
  val none: List[String] = newList()
  none
}

// `val`/`let`/`var name[: ty] = init`, then the rest of the block.  The
// initializer's side conditions — a callee's `requires:`, an overflow
// obligation — are side goals like an expression statement's (#7871).
// `patternBinders` are the names a destructuring pattern binds, each a
// value of its own.
func wpBindInit(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  name: in String,
  ty: in Option[TypeExpr],
  init: in Expr,
  mutable: in Bool,
  patternBinders: in List[String],
): WpResult {
  if effectsOfExpr(env, init).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", init.span)
  }
  val (initR, initDiags) = translateExpr(env, init)
  // Honor the declared type's range bound (#3854) instead of always
  // discarding it in favor of the inferred-from-init RBKNone sort — a
  // `val x: Percent = ...` binding must carry `0 <= x <= 100` forward.  An
  // unannotated binding takes its initializer's sort and width.
  val info = match ty {
    case Some(t) -> sortOfTypeExprE(env, t)
    case None -> SortInfo(sort = sortOf(initR.term), range = RBKNone, intBits = intBitsOfExpr(env, init))
  }
  val boundTerm = match ty {
    case Some(_) -> coerceTermAt(initR.term, info.sort, init.span, initDiags)
    case None -> initR.term
  }
  // The initializer's `out`/`inout` arguments change before the binding.
  val after = havocOutArgs(env, init)
  var env2 = envSetMutable(envDeclare(name, boundTerm, info, after.env), name, mutable)
  var pbi = 0
  while pbi < patternBinders.count {
    val binder = patternBinders[pbi]
    val binderInfo = SortInfo(sort = SUninterp(name = "binding"), range = RBKNone)
    env2 = envSetMutable(envDeclare(binder, freshVar(env, binder, binderInfo.sort), binderInfo, env2), binder, false)
    pbi = pbi + 1
  }
  val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  if termIsPoisoned(initR.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = init.span))
  }
  var i = 0
  while i < initR.sideConds.count {
    sg.add(SideGoal(term = initR.sideConds[i], kind = GKAssertion, span = init.span))
    i = i + 1
  }
  i = 0
  while i < inner.sideGoals.count {
    sg.add(inner.sideGoals[i])
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, initR.assumed)
  appendTermList(asList, after.hyps)
  appendTermList(asList, rangeHypothesesForTerm(boundTerm, info))
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, initDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// ─────────────────────────────────────────────────────────────────────────────
// §9a. Error propagation: `?` (#8108).
// ─────────────────────────────────────────────────────────────────────────────
// `e?` splits the path.  When `e` is an `Err`/`None` the function returns
// it there — `Err(e.error)` or `None` at the function's own result type, as
// `Lyric.Propagate` lowers it — and its `ensures:` must hold for that
// result; otherwise the path goes on with `e`'s payload.  A statement's
// `?`s are first given bindings of their own, in evaluation order
// (`hoistPropagates`): `val q = e?`, with everything evaluated before it
// bound before it too, so each split happens where the program would take
// it.  A `?` that runs only conditionally within its statement — in a
// branch of an `if` or `match` expression, the right operand of `and`,
// `or`, `implies` or `??`, a lambda — is not split and fails closed.
// A `val`/`var`/`let` binding of a name to `e?` with no `?` in `e`.
record PropagateBinding {
  name: String
  ty: Option[TypeExpr]
  inner: Expr
  mutable: Bool
}

func propagateBindingOf(st: in Statement): Option[PropagateBinding] {
  match st.kind {
    case SLocal(binding) -> match binding {
      case LBVal(pat, ty, init) -> match pat.kind {
        case PBinding(n, None) -> propagateBindingParts(
          n,
          ty,
          init,
          false
        )
        case _ -> None
      }
      case LBLet(n, ty, init) -> propagateBindingParts(n, ty, init, false)
      case LBVar(n, ty, Some(init)) -> propagateBindingParts(n, ty, init, true)
      case LBVar(_, _, None) -> None
    }
    case _ -> None
  }
}

func propagateBindingParts(
  name: in String, ty: in Option[TypeExpr], init: in Expr, mutable: in Bool
): Option[PropagateBinding] {
  match init.kind {
    case EPropagate(inner) -> {
      if exprHasPropagate(inner) {
        None
      } else {
        Some(value = PropagateBinding(name = name, ty = ty, inner = inner, mutable = mutable))
      }
    }
    case EParen(x) -> propagateBindingParts(name, ty, x, mutable)
    case _ -> None
  }
}

// `name = inner?`, then the rest of the block — on the path where `inner`
// is `Ok`/`Some`.
func wpBindPropagate(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  pb: in PropagateBinding,
  sp: in Span,
): WpResult {
  if effectsOfExpr(env, pb.inner).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", pb.inner.span)
  }
  val (innerR, innerDiags) = translateExpr(env, pb.inner)
  val t = innerR.term
  val innerSort = sortOf(t)
  val fnSort = resultSort.sort
  var reason = ""
  var okCond = trueT()
  var payload = t
  var exitValue = t
  if isResultSort(innerSort) {
    if not isResultSort(fnSort) {
      reason = "a `?` on a Result in a function that does not return a Result"
    } else if smtRenderSort(monadArgSort(innerSort, 1)) != smtRenderSort(monadArgSort(fnSort, 1)) {
      reason = "a `?` that converts its error from " + sortDisplay(monadArgSort(innerSort, 1)) + " to " +
        sortDisplay(monadArgSort(fnSort, 1))
    } else {
      okCond = mkIsOk(t)
      payload = mkResultValue(t)
      exitValue = mkMonadCtor("Err", termList1(mkResultError(t)), fnSort)
    }
  } else if isOptionSort(innerSort) {
    if not isOptionSort(fnSort) {
      reason = "a `?` on an Option in a function that does not return an Option"
    } else {
      okCond = mkIsSome(t)
      payload = mkOptionValue(t)
      val noArgs: List[Term] = newList()
      exitValue = mkMonadCtor("None", noArgs, fnSort)
    }
  } else {
    reason = "a `?` on a value the verifier does not know to be a Result or an Option (" + sortDisplay(innerSort) + ")"
  }
  if reason.length > 0 {
    val failDiags: List[Diagnostic] = newList()
    appendTermList2(failDiags, innerDiags)
    failDiags.add(untranslatableDiag(reason, sp))
    val noGoals: List[SideGoal] = newList()
    val noFacts: List[Term] = newList()
    return WpResult(wp = falseT(), sideGoals = noGoals, assumed = noFacts, diags = failDiags)
  }
  // The callee has returned on both paths: what it passed out has changed.
  val after = havocOutArgs(env, pb.inner)
  val info = match pb.ty {
    case Some(te) -> sortOfTypeExprE(env, te)
    case None -> SortInfo(sort = sortOf(payload), range = RBKNone)
  }
  val boundTerm = match pb.ty {
    case Some(_) -> coerceTermAt(payload, info.sort, pb.inner.span, innerDiags)
    case None -> payload
  }
  val env2 = envSetMutable(envDeclare(pb.name, boundTerm, info, after.env), pb.name, pb.mutable)
  val rest = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  // The early return: the function's postcondition of `Err(error)`/`None`.
  val exitWp = finishPost(after.env, postcond, exitValue)
  val sg: List[SideGoal] = newList()
  if termIsPoisoned(t) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = pb.inner.span))
  }
  var i = 0
  while i < innerR.sideConds.count {
    sg.add(SideGoal(term = innerR.sideConds[i], kind = GKAssertion, span = pb.inner.span))
    i = i + 1
  }
  guardSideGoals(rest.sideGoals, termList1(okCond), sg)
  val asList: List[Term] = newList()
  appendTermList(asList, innerR.assumed)
  appendTermList(asList, after.hyps)
  appendTermList(asList, guardTerms(okCond, rangeHypothesesForTerm(boundTerm, info)))
  appendTermList(asList, guardTerms(okCond, rest.assumed))
  val di: List[Diagnostic] = newList()
  appendTermList2(di, innerDiags)
  appendTermList2(di, rest.diags)
  val wp = mkAnd(termList2(mkImplies(okCond, rest.wp), mkImplies(mkNot(okCond), exitWp)))
  WpResult(wp = wp, sideGoals = sg, assumed = asList, diags = di)
}
