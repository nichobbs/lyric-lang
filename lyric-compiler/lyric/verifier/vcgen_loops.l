//! verifier/vcgen_loops.l — assignments and while loops: invariants, havoc, effects of the body.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// `x = v` / `x op= v`, then the rest of the block.  A variable and an
// element of an array variable (`a[i] = v`, #8394) are the targets the
// verifier models: an array is a value (docs/01 §2.7), so a write to one
// binding is never seen through another, and the variable simply takes the
// array with that element replaced.  A record is a reference, and a write
// to one of its fields is seen through every alias of it, which the
// verifier has no heap to follow, so a field write fails closed rather than
// leave the proof reasoning about the old value (#8102).
func wpAssign(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  target: in Expr,
  op: in AssignOp,
  value: in Expr,
  sp: in Span,
): WpResult {
  match elementTarget(target) {
    case Some(et) -> return wpAssignElement(env, resultSort, postcond, stmts, idx, target, et, op, value, sp)
    case None -> ()
  }
  val name = match target.kind {
    case EPath(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
    case _ -> ""
  }
  if name.length == 0 {
    return unsupportedWp("an assignment to a field or to an element of anything but an array variable", target.span)
  }
  // A name no binding declares is a module-level `val`, which no assignment
  // reaches; one the walk lost track of must not be given a value (#8109).
  if not isSome(envLookup(name, env)) {
    return unsupportedWp("an assignment to '" + name + "', which no binding the verifier tracks declares", target.span)
  }
  if effectsOfExpr(env, value).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", value.span)
  }
  val (rhsR, rhsDiags) = translateExpr(env, value)
  // The right-hand side's side conditions are obligations, and so is a
  // compound assignment's overflow under checked arithmetic (#7871).
  val rhsSide: List[Term] = newList()
  appendTermList(rhsSide, rhsR.sideConds)
  val existing = match envLookup(name, env) { case Some(t) -> t; case None -> freshVar(env, name, SInt) }
  val rawCombined = assignedValue(env, existing, rhsR.term, op, target, sp, rhsSide, rhsDiags)
  // The assigned value takes the variable's sort (#7848).
  val combined = match envLookupSort(name, env) {
    case Some(si) -> coerceTermAt(rawCombined, si.sort, value.span, rhsDiags)
    case None -> rawCombined
  }
  val info = match envLookupSort(name, env) {
    case Some(si) -> si
    case None -> SortInfo(sort = sortOf(combined), range = RBKNone)
  }
  // The store is range-checked at run time, so a value outside the
  // variable's range is a panic the proof must exclude (#8143).
  match rangeObligationsForTerm(combined, info) {
    case Ok(obligations) -> appendTermList(rhsSide, afterFacts(rhsR.assumed, obligations))
    case Err(reason) -> rhsDiags.add(untranslatableDiag("the range of `" + name + "`: " + reason, sp))
  }
  // The right-hand side's `out`/`inout` arguments change before the store.
  val after = havocOutArgs(env, value)
  val env2 = envBindTerm(name, combined, info, after.env)
  val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  if termIsPoisoned(rhsR.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = value.span))
  }
  var si = 0
  while si < rhsSide.count {
    sg.add(SideGoal(term = rhsSide[si], kind = GKAssertion, span = sp))
    si = si + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, rhsR.assumed)
  appendTermList(asList, after.hyps)
  // A range-typed variable is range-checked after every assignment
  // (docs/01 §2.2), so the assigned value is in range from here on.
  appendTermList(asList, rangeHypothesesForTerm(combined, info))
  // The assignment's facts hold for the obligations of the statements after
  // it.
  guardSideGoals(inner.sideGoals, asList, sg)
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, rhsDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// The value an assignment stores: `rhs` for `=`, `existing op rhs` for a
// compound assignment, whose divisor and, under checked arithmetic,
// overflow obligations it adds to `sides`.  `target` gives the stored
// place's width.
func assignedValue(
  env: in VEnv,
  existing: in Term,
  rhs: in Term,
  op: in AssignOp,
  target: in Expr,
  sp: in Span,
  sides: in List[Term],
  diags: in List[Diagnostic],
): Term {
  val plain = match op { case AssEq -> true; case _ -> false }
  if plain {
    return rhs
  }
  val bin = match op {
    case AssPlus -> BOpAdd
    case AssMinus -> BOpSub
    case AssStar -> BOpMul
    case AssSlash -> BOpDiv
    case AssPercent -> BOpMod
    case _ -> BOpAdd
  }
  val combinedOp = match unifyOperands(existing, rhs) {
    case Ok(pair) -> TBuiltin(op = bin, args = termList2(pair.lhs, pair.rhs))
    case Err(reason) -> {
      diags.add(untranslatableDiag(reason, sp))
      poisonTerm(TBuiltin(op = bin, args = termList2(existing, rhs)))
    }
  }
  match combinedOp {
    case TBuiltin(_, dargs) -> appendTermList(sides, divisorSideConds(bin, dargs, intBitsOfExpr(env, target)))
    case _ -> ()
  }
  if env.checkedArithmetic {
    match combinedOp {
      case TBuiltin(_, cargs) -> {
        match sortOf(cargs[0]) {
          case SInt -> match bin {
            case BOpAdd | BOpSub | BOpMul -> appendTermList(
              sides,
              signedWidthBounds(combinedOp, overflowBitsOfExpr(env, target))
            )
            case _ -> ()
          }
          case SBitVec(w) -> appendTermList(sides, unsignedOverflowSideConds(bin, cargs[0], cargs[1], combinedOp, w))
          case _ -> ()
        }
      }
      case _ -> ()
    }
  }
  combinedOp
}

// An element write's variable and indices: `a[i]` for an array or buffer
// variable `a`, `a[i][j]` (outermost index first) for an element of one of
// its elements.
record ElementTarget {
  name: String
  indices: List[Expr]
}

func elementTarget(target: in Expr): Option[ElementTarget] {
  match target.kind {
    case EParen(inner) -> elementTarget(inner)
    case EIndex(rawReceiver, indices) -> {
      if indices.count != 1 {
        return None
      }
      val receiver = withoutParens(rawReceiver)
      val outer: Option[ElementTarget] = match receiver.kind {
        case EPath(path) -> if path.segments.count == 1 {
          val none: List[Expr] = newList()
          Some(value = ElementTarget(name = path.segments[0], indices = none))
        } else {
          None
        }
        case EIndex(_, _) -> elementTarget(receiver)
        case _ -> None
      }
      match outer {
        case Some(o) -> {
          val all: List[Expr] = newList()
          for x in o.indices {
            all.add(x)
          }
          all.add(indices[0])
          Some(value = ElementTarget(name = o.name, indices = all))
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

func withoutParens(e: in Expr): Expr {
  match e.kind {
    case EParen(inner) -> withoutParens(inner)
    case _ -> e
  }
}

// `a[i] = v` / `a[i] op= v` on an array or buffer variable, and `a[i][j] = v`
// on an element of one of its array elements, then the rest of the block:
// each index must be in bounds (the write panics otherwise), the stored
// value must lie in the element type's range, and `a` takes the sequence
// with that element replaced, a nested write storing the changed inner
// array back into the outer one (#8394).  A buffer's copies are values of
// their own (docs/01 §2.7), so the store changes this variable alone.  An
// element type the verifier does not know (a binding a call initialises)
// may be a range type whose check it cannot state, so a write of a number
// into one fails closed; an annotation on the binding gives it (#8753).
func wpAssignElement(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  target: in Expr,
  et: in ElementTarget,
  op: in AssignOp,
  value: in Expr,
  sp: in Span,
): WpResult {
  val name = et.name
  if not isSome(envLookup(name, env)) {
    return unsupportedWp(
      "an assignment to an element of '" + name + "', which no binding the verifier tracks declares",
      target.span
    )
  }
  val info = match envLookupSort(name, env) { case Some(si) -> si; case None -> sortInfoNoRange(SInt) }
  // The sort info of each sequence the write goes through, outermost first.
  val levels: List[SortInfo] = newList()
  var levelInfo = info
  var li = 0
  while li < et.indices.count {
    if not isOwnedSequenceSort(levelInfo.sort) {
      return unsupportedWp(
        "an assignment to an element of anything but an array or buffer variable, or an array element of one",
        target.span
      )
    }
    levels.add(levelInfo)
    levelInfo = elementSortInfo(levelInfo)
    li = li + 1
  }
  val elemInfo = levelInfo
  val innermost = levels[levels.count - 1]
  if not elementTypeKnown(innermost) and sortMayCarryRange(elemInfo.sort) {
    return unsupportedWp(
      "an element write to '" + name +
        "', whose element type the verifier does not know (annotate the binding with its type)",
      target.span
    )
  }
  val arr = match envLookup(name, env) { case Some(t) -> t; case None -> freshVar(env, name, info.sort) }
  // The indices and the value are evaluated before the store; an index that
  // changes a variable, or a value that changes the sequence, leaves no single
  // state to store into.
  for ix in et.indices {
    val idxEff = effectsOfExpr(env, ix)
    if idxEff.assigned.count > 0 or idxEff.outArgs.count > 0 or idxEff.jumps.count > 0 {
      return unsupportedWp("an element index that assigns, passes `out`/`inout` or jumps", ix.span)
    }
  }
  val valueEff = effectsOfExpr(env, value)
  if valueEff.assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", value.span)
  }
  if valueEff.outArgs.contains(name) {
    return unsupportedWp("a value that changes the sequence it is stored into", value.span)
  }
  val diags: List[Diagnostic] = newList()
  val sides: List[Term] = newList()
  val idxAssumed: List[Term] = newList()
  // The sequence at each level and the index into it: `a`, then `a[i]`, ...
  val seqs: List[Term] = newList()
  val idxTerms: List[Term] = newList()
  var poisoned = false
  var current = arr
  for ix in et.indices {
    val (idxR, idxDiags) = translateExpr(env, ix)
    appendTermList2(diags, idxDiags)
    appendTermList(sides, idxR.sideConds)
    if termIsPoisoned(idxR.term) {
      poisoned = true
    }
    val indexTerm = if sortEq(sortOf(idxR.term), SInt) {
      idxR.term
    } else {
      diags.add(untranslatableDiag("an element index that is not a signed integer", ix.span))
      poisoned = true
      poisonTerm(idxR.term)
    }
    // An inner array has its type's length, as every element of the outer
    // one does.
    if seqs.count > 0 {
      appendTermList(idxAssumed, valueFactsForTerm(current, levels[seqs.count]))
    }
    // `0 <= i < a.length`, each level's own bounds check, which holds once
    // the indices before it have.
    val inRange = termList2(
      TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = 0i64), sort = SInt), indexTerm)),
      TBuiltin(op = BOpLt, args = termList2(indexTerm, lengthTerm(current)))
    )
    appendTermList(idxAssumed, idxR.assumed)
    appendTermList(sides, afterFacts(idxAssumed, termList1(mkAnd(inRange))))
    seqs.add(current)
    idxTerms.add(indexTerm)
    current = TBuiltin(op = BOpSliceIndex, args = termList2(current, indexTerm))
  }
  val (rhsR, rhsDiags) = translateExpr(env, value)
  appendTermList2(diags, rhsDiags)
  appendTermList(sides, rhsR.sideConds)
  val existing = current
  val rawCombined = assignedValue(env, existing, rhsR.term, op, target, sp, sides, diags)
  val combined = coerceTermAt(rawCombined, elemInfo.sort, value.span, diags)
  match rangeObligationsForTerm(combined, elemInfo) {
    case Ok(obligations) -> appendTermList(sides, afterFacts(rhsR.assumed, obligations))
    case Err(reason) -> diags.add(untranslatableDiag("the range of an element of `" + name + "`: " + reason, sp))
  }
  val after = havocOutArgs(env, value)
  var stored = combined
  var k = seqs.count - 1
  while k >= 0 {
    stored = TBuiltin(op = BOpSliceStore, args = termList3(seqs[k], idxTerms[k], stored))
    k = k - 1
  }
  val env2 = envBindTerm(name, stored, info, after.env)
  val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  if poisoned or termIsPoisoned(rhsR.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = target.span))
  }
  for side in sides {
    sg.add(SideGoal(term = side, kind = GKAssertion, span = sp))
  }
  val asList: List[Term] = newList()
  appendTermList(asList, idxAssumed)
  appendTermList(asList, rhsR.assumed)
  appendTermList(asList, after.hyps)
  guardSideGoals(inner.sideGoals, asList, sg)
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, diags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// Each invariant of a loop, translated in `env`: what proving all of them
// takes, and what assuming them gives (`ContractParts`).
record LoopInvariant {
  obligation: Term
  hyps: List[Term]
  facts: List[Term]
  diags: List[Diagnostic]
}

func translateInvariants(env: in VEnv, invExprs: in List[Expr]): LoopInvariant {
  val obligations: List[Term] = newList()
  val hyps: List[Term] = newList()
  val facts: List[Term] = newList()
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < invExprs.count {
    val parts = translateContractParts(env, invExprs[i])
    obligations.add(partsObligation(parts))
    appendTermList(hyps, partsHyps(parts))
    appendTermList(facts, parts.facts)
    appendTermList2(diags, parts.diags)
    i = i + 1
  }
  LoopInvariant(obligation = mkAnd(obligations), hyps = hyps, facts = facts, diags = diags)
}

func termsWith(xs: in List[Term], ys: in List[Term]): List[Term] {
  val joined: List[Term] = newList()
  appendTermList(joined, xs)
  appendTermList(joined, ys)
  joined
}

// `while cond { invariant: inv; body }`, then the rest of the block, by the
// loop rule (#8102):
//
//   - establish: `inv` holds on entry;
//   - the condition's side conditions hold wherever it is evaluated — on
//     entry, under `inv`, and after any iteration: in a state where every
//     variable the loop may change (an assignment's target, an `out` or
//     `inout` argument) holds an arbitrary value of its type and `inv`
//     holds;
//   - preserve: in that arbitrary state, `inv and cond` and the body's
//     effects give `inv` again, evaluated in the state the body ends in;
//   - the body's own side goals hold under `inv and cond` in that state;
//   - the rest of the block runs in an arbitrary such state where `inv and
//     not cond` holds.
//
// A `return` (or `?`) in the body leaves the loop with a value the
// invariant says nothing about, so it fails closed, as `break` and
// `continue` do (#7396).
func wpWhile(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  cond: in Expr,
  body: in Block,
  sp: in Span,
): WpResult {
  // Partition SInvariant stmts from real body.
  val invExprs: List[Expr] = newList()
  val realStmts: List[Statement] = newList()
  var i = 0
  while i < body.statements.count {
    match body.statements[i].kind {
      case SInvariant(ie) -> invExprs.add(ie)
      case _ -> realStmts.add(body.statements[i])
    }
    i = i + 1
  }
  // A `?` (or any other jump) in the condition leaves the function from
  // inside the loop test, a path the loop rule does not cover (#8143).
  if effectsOfExpr(env, cond).jumps.count > 0 {
    return unsupportedWp("a `?` or another jump in a loop condition", cond.span)
  }
  val sg: List[SideGoal] = newList()
  val di: List[Diagnostic] = newList()

  // On entry.
  val invEntry = translateInvariants(env, invExprs)
  appendTermList2(di, invEntry.diags)
  sg.add(SideGoal(term = invEntry.obligation, kind = GKLoopEstablish, span = sp))
  val (condEntryR, condEntryDiags) = translateExpr(env, cond)
  appendTermList2(di, condEntryDiags)
  // The condition's own facts (a callee's `ensures:`) hold only once its
  // side conditions do, so they never guard those side conditions.
  val entryHyps: List[Term] = newList()
  appendTermList(entryHyps, invEntry.hyps)
  val condEntrySides: List[SideGoal] = newList()
  i = 0
  while i < condEntryR.sideConds.count {
    condEntrySides.add(SideGoal(term = condEntryR.sideConds[i], kind = GKAssertion, span = cond.span))
    i = i + 1
  }
  guardSideGoals(condEntrySides, entryHyps, sg)

  // An arbitrary iteration: everything the body or the condition may
  // change holds a value of its own.
  val bodyEffects = effectsOfStmts(env, realStmts)
  val changed = effectsChanged(bodyEffects)
  addNames(changed, effectsChanged(effectsOfExpr(env, cond)))
  val havoc = havocVars(env, changed, "loop")
  val envH = havoc.env
  val invH = translateInvariants(envH, invExprs)
  val (condHR, _) = translateExpr(envH, cond)
  val iterHyps: List[Term] = newList()
  appendTermList(iterHyps, havoc.hyps)
  appendTermList(iterHyps, invH.hyps)
  val condIterSides: List[SideGoal] = newList()
  i = 0
  while i < condHR.sideConds.count {
    condIterSides.add(SideGoal(term = condHR.sideConds[i], kind = GKAssertion, span = cond.span))
    i = i + 1
  }
  guardSideGoals(condIterSides, iterHyps, sg)

  // The condition's own `out`/`inout` arguments change as it is evaluated.
  val afterCond = havocOutArgs(envH, cond)
  val bodyHyps = termsWith(iterHyps, condHR.assumed)
  appendTermList(bodyHyps, afterCond.hyps)
  bodyHyps.add(condHR.term)

  if bodyEffects.jumps.contains("return") {
    di.add(
      errorDiagnostic(
        "V0026",
        "a `return` or `?` inside a loop body is not yet supported by the verifier; the proof fails here",
        sp
      )
    )
    sg.add(SideGoal(term = falseT(), kind = GKLoopPreserve, span = sp))
  } else {
    // Preserve: the invariant at the end of the body, over the values the
    // body leaves — each changed variable is a placeholder `finishPost`
    // replaces at every path's end.
    val finals: List[FinalSlot] = newList()
    var envP = envH
    i = 0
    while i < changed.count {
      match envLookupSort(changed[i], envH) {
        case Some(vinfo) -> {
          val placeholder = freshName(env, changed[i] + "!final")
          finals.add(FinalSlot(varName = changed[i], placeholder = placeholder))
          envP = envBindTerm(changed[i], TVar(name = placeholder, sort = vinfo.sort), vinfo, envP)
        }
        case None -> ()
      }
      i = i + 1
    }
    val invFinal = translateInvariants(envP, invExprs)
    val preservePost = invFinal.obligation
    // The body ends with a unit statement, so its last real statement is
    // walked as a statement — an `if` or a call there changes state — and
    // never taken for a value.
    val bodyStmts: List[Statement] = newList()
    appendStmtList(bodyStmts, realStmts)
    bodyStmts.add(Statement(kind = SExpr(expr = Expr(kind = ELiteral(lit = LUnit), span = body.span)), span = body.span))
    // The body is a scope of its own: a binding it declares shadows a
    // variable the invariant speaks of only inside it (#8109).
    val bodyEnv = envEnterScope(envWithFinals(afterCond.env, finals), freshName(env, "scope"))
    val bodyWp = wpWalk(bodyEnv, resultSort, preservePost, bodyStmts, 0)
    appendTermList2(di, bodyWp.diags)
    val preserveHyps = termsWith(bodyHyps, bodyWp.assumed)
    sg.add(SideGoal(term = mkImplies(mkAnd(preserveHyps), bodyWp.wp), kind = GKLoopPreserve, span = sp))
    guardSideGoals(bodyWp.sideGoals, bodyHyps, sg)
  }

  // After the loop.
  val exitHyps: List[Term] = newList()
  appendTermList(exitHyps, iterHyps)
  appendTermList(exitHyps, condHR.assumed)
  appendTermList(exitHyps, afterCond.hyps)
  exitHyps.add(mkNot(condHR.term))
  val rest: List[Statement] = newList()
  var ri = idx + 1
  while ri < stmts.count {
    rest.add(stmts[ri])
    ri = ri + 1
  }
  val inner = wpWalk(afterCond.env, resultSort, postcond, rest, 0)
  guardSideGoals(inner.sideGoals, exitHyps, sg)
  appendTermList2(di, invH.diags)
  appendTermList2(di, inner.diags)

  val asList: List[Term] = newList()
  appendTermList(asList, condEntryR.assumed)
  appendTermList(asList, invEntry.hyps)
  appendTermList(asList, exitHyps)
  appendTermList(asList, inner.assumed)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// `for x in a { invariant: ι; S }` over an array, slice or buffer `a`, by
// the loop rule over a hidden index (docs/15 §5.3).  The loop iterates the
// value `a` has when it starts (docs/01 §2.7), so `a` is bound once to a
// hidden name no statement of the body can reach, and the loop is the
// `while` over that binding:
//
//   val s = a
//   var k = 0
//   while k < s.length {
//     invariant: 0 <= k and k <= s.length
//     invariant: ι
//     val x = s[k]
//     S
//     k = k + 1
//   }
//
// The hidden index cannot be named, so `ι` speaks of the variables in scope
// around the loop; it is evaluated before `x` is bound.  The pattern binds
// as a `val` does.  A `for` over any other value (a range, a `List`, a
// `Map`) fails closed (V0026), as do `break` and `continue` in the body,
// which a `while` does not follow either (#8394).
func wpFor(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  pat: in Pattern,
  iter: in Expr,
  body: in Block,
  sp: in Span,
): WpResult {
  val (iterR, _) = translateExpr(env, iter)
  if not isElementSequenceSort(sortOf(iterR.term)) {
    return unsupportedWp("a `for` loop over a value other than an array, slice or buffer", iter.span)
  }
  val seqName = freshName(env, "for!seq")
  val idxName = freshName(env, "for!k")
  val seqE = forPathExpr(seqName, sp)
  val idxE = forPathExpr(idxName, sp)
  val lenE = Expr(kind = EMember(receiver = seqE, memberName = "length"), span = sp)
  val zeroE = forIntExpr(0i64, sp)
  val inRange = Expr(
    kind = EBinop(
      op = BAnd,
      lhs = Expr(kind = EBinop(op = BLte, lhs = zeroE, rhs = idxE), span = sp),
      rhs = Expr(kind = EBinop(op = BLte, lhs = idxE, rhs = lenE), span = sp)
    ),
    span = sp
  )
  val loopStmts: List[Statement] = newList()
  loopStmts.add(Statement(kind = SInvariant(expr = inRange), span = sp))
  val realStmts: List[Statement] = newList()
  for st in body.statements {
    match st.kind {
      case SInvariant(_) -> loopStmts.add(st)
      case _ -> realStmts.add(st)
    }
  }
  val elementE = Expr(kind = EIndex(receiver = seqE, indices = forExprList(idxE)), span = sp)
  loopStmts.add(Statement(kind = SLocal(binding = LBVal(pat = pat, ty = None, init = elementE)), span = sp))
  appendStmtList(loopStmts, realStmts)
  val stepE = Expr(kind = EBinop(op = BAdd, lhs = idxE, rhs = forIntExpr(1i64, sp)), span = sp)
  loopStmts.add(Statement(kind = SAssign(target = idxE, op = AssEq, value = stepE), span = sp))
  val condE = Expr(kind = EBinop(op = BLt, lhs = idxE, rhs = lenE), span = sp)

  val spliced: List[Statement] = newList()
  var i = 0
  while i < idx {
    spliced.add(stmts[i])
    i = i + 1
  }
  val seqPat = Pattern(kind = PBinding(name = seqName, inner = None), span = sp)
  spliced.add(Statement(kind = SLocal(binding = LBVal(pat = seqPat, ty = None, init = iter)), span = iter.span))
  spliced.add(
    Statement(kind = SLocal(binding = LBVar(name = idxName, ty = None, init = Some(value = zeroE))), span = sp)
  )
  spliced.add(
    Statement(
      kind = SWhile(label = None, cond = condE, body = Block(statements = loopStmts, span = body.span)),
      span = sp
    )
  )
  i = idx + 1
  while i < stmts.count {
    spliced.add(stmts[i])
    i = i + 1
  }
  wpWalk(env, resultSort, postcond, spliced, idx)
}

func forPathExpr(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp)
}

func forIntExpr(n: in Long, sp: in Span): Expr {
  Expr(kind = ELiteral(lit = LInt(value = n, suffix = NoIntSuffix, raw = toString(n))), span = sp)
}

func forExprList(e: in Expr): List[Expr] {
  val xs: List[Expr] = newList()
  xs.add(e)
  xs
}
