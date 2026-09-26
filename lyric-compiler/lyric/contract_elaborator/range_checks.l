//! Runtime checks for inline range refinements (#7226).
//!
//! `Int range 0 ..= 9` (and the `Long`/`Double` forms) erases to its base
//! type in every backend; T0015 checks a literal initializer at compile time
//! and nothing checked anything else.  This pass makes the refinement a
//! runtime contract, with the bounds read exactly as T0015 reads them
//! (`..=` and `..= hi` inclusive, `..` half-open, `lo ..` open above):
//!
//!   * a refined parameter is checked on entry, before `requires:`;
//!   * a refined return type is checked like an `ensures:` clause;
//!   * a refined `val`/`var`/`let` is checked after its initializer, and a
//!     refined `var` (or `out`/`inout` parameter) after every assignment,
//!     compound assignments included.
//!
//! Assignments are resolved through a scope stack, so a pattern, loop,
//! catch or lambda binding of the same name shadows the refined one.
//! Failures read `RangeViolated: <owner> <what> must be in <type>`.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Fmt as Fmt

/// The range of a refined type expression, if it is one.
pub func refinedRangeOf(te: in TypeExpr): Option[RangeBound] {
  match te.kind {
    case TRefined(_, rb) -> Some(value = rb)
    case TParen(inner) -> refinedRangeOf(inner)
    case _ -> None
  }
}

/// `subject` satisfies `rb`: `lo <= subject` and `subject <= hi`
/// (`< hi` for a half-open range).
pub func rangeCondition(subject: in Expr, rb: in RangeBound, sp: in Span): Expr {
  match rb {
    case RBClosed(lo, hi) -> andExpr(cmpExpr(BGte, subject, lo, sp), cmpExpr(BLte, subject, hi, sp), sp)
    case RBHalfOpen(lo, hi, _) -> andExpr(cmpExpr(BGte, subject, lo, sp), cmpExpr(BLt, subject, hi, sp), sp)
    case RBLowerOpen(hi) -> cmpExpr(BLte, subject, hi, sp)
    case RBUpperOpen(lo) -> cmpExpr(BGte, subject, lo, sp)
  }
}

func cmpExpr(op: in BinOp, l: in Expr, r: in Expr, sp: in Span): Expr {
  mkExpr(EBinop(op = op, lhs = l, rhs = r), sp)
}

func andExpr(l: in Expr, r: in Expr, sp: in Span): Expr {
  mkExpr(EBinop(op = BAnd, lhs = l, rhs = r), sp)
}

func rangeMessage(owner: in String, what: in String, te: in TypeExpr): String {
  "RangeViolated: " + owner + " " + what + " must be in " + Fmt.typeStr(te)
}

/// Entry checks for refined parameters, in declaration order.
func paramRangeChecks(params: in List[Param], owner: in String): List[SpannedExpr] {
  val xs: List[SpannedExpr] = newList()
  var i = 0
  while i < params.count {
    val p = params[i]
    match refinedRangeOf(p.ty) {
      case Some(rb) -> xs.add(
        SpannedExpr(
          expr = rangeCondition(mkPath(p.name, p.ty.span), rb, p.ty.span),
          span = p.ty.span,
          message = rangeMessage(owner, "parameter " + p.name, p.ty)
        )
      )
      case None -> ()
    }
    i = i + 1
  }
  xs
}

/// The ensures-style check for a refined return type (`result` in range).
func returnRangeChecks(ret: in Option[TypeExpr], owner: in String): List[SpannedExpr] {
  val xs: List[SpannedExpr] = newList()
  match ret {
    case Some(te) -> match refinedRangeOf(te) {
      case Some(rb) -> xs.add(
        SpannedExpr(
          expr = rangeCondition(mkExpr(EResult, te.span), rb, te.span),
          span = te.span,
          message = rangeMessage(owner, "result", te)
        )
      )
      case None -> ()
    }
    case None -> ()
  }
  xs
}

/// True when anything in `params`/`ret`/`body` carries a range refinement,
/// so the elaborator must not take its nothing-to-do fast path.
pub func functionHasRangeRefinement(params: in List[Param], ret: in Option[TypeExpr], body: in Block): Bool {
  var i = 0
  while i < params.count {
    match refinedRangeOf(params[i].ty) {
      case Some(_) -> return true
      case None -> ()
    }
    i = i + 1
  }
  match ret {
    case Some(te) -> match refinedRangeOf(te) { case Some(_) -> return true; case None -> () }
    case None -> ()
  }
  val probe = RangeScope(frames = newList(), owner = "", found = false)
  val _ = rangeWalkBlock(body, probe)
  probe.found
}

// A name in scope, and the refined type it was declared with (`None` for an
// unrefined binding that shadows an outer refined one).
record RangeScope {
  frames: List[Map[String, Option[TypeExpr]]]
  owner: String
  var found: Bool
}

func pushFrame(sc: in RangeScope): Unit {
  val frame: Map[String, Option[TypeExpr]] = newMap()
  sc.frames.add(frame)
}

func popFrame(sc: in RangeScope): Unit {
  sc.frames.removeAt(sc.frames.count - 1)
}

func declare(sc: in RangeScope, name: in String, ty: in Option[TypeExpr]): Unit {
  if sc.frames.count == 0 {
    pushFrame(sc)
  }
  // A name may be redeclared in the same block (`var i = 0 ... var i = 0`);
  // the later declaration replaces the earlier one.
  val frame = sc.frames[sc.frames.count - 1]
  if frame.containsKey(name) {
    frame.remove(name)
  }
  frame.add(name, ty)
}

func declareUnrefined(sc: in RangeScope, names: in List[String]): Unit {
  var i = 0
  while i < names.count {
    declare(sc, names[i], None)
    i = i + 1
  }
}

func lookupRefined(sc: in RangeScope, name: in String): Option[TypeExpr] {
  var i = sc.frames.count - 1
  while i >= 0 {
    match mapGet(sc.frames[i], name) {
      case Some(entry) -> return entry
      case None -> ()
    }
    i = i - 1
  }
  None
}

/// Insert the binding and assignment checks into `body`.  `params` seed the
/// outermost scope (an `out`/`inout` refined parameter is checked after each
/// assignment too).
pub func insertRangeChecks(body: in Block, params: in List[Param], owner: in String): Block {
  val sc = RangeScope(frames = newList(), owner = owner, found = false)
  pushFrame(sc)
  var i = 0
  while i < params.count {
    val p = params[i]
    match refinedRangeOf(p.ty) {
      case Some(_) -> declare(sc, p.name, Some(value = p.ty))
      case None -> declare(sc, p.name, None)
    }
    i = i + 1
  }
  rangeWalkBlock(body, sc)
}

func checkStmt(name: in String, te: in TypeExpr, sc: in RangeScope, sp: in Span): Statement {
  sc.found = true
  match refinedRangeOf(te) {
    case Some(rb) -> mkAssertCall(rangeCondition(mkPath(name, sp), rb, sp), rangeMessage(sc.owner, name, te), sp)
    case None -> panic("Lyric.ContractElaborator: range check requested for an unrefined type")
  }
}

func rangeWalkBlock(blk: in Block, sc: in RangeScope): Block {
  pushFrame(sc)
  val outs: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    rangeWalkStmt(blk.statements[i], sc, outs)
    i = i + 1
  }
  popFrame(sc)
  Block(statements = outs, span = blk.span)
}

func refinedAnnotation(tyOpt: in Option[TypeExpr]): Option[TypeExpr] {
  match tyOpt {
    case Some(te) -> match refinedRangeOf(te) { case Some(_) -> Some(value = te); case None -> None }
    case None -> None
  }
}

func rangeWalkStmt(s: in Statement, sc: in RangeScope, acc: in List[Statement]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(pat, ty, init) -> {
        acc.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = rangeWalkExpr(init, sc))), s.span))
        val refined = refinedAnnotation(ty)
        match pat.kind {
          case PBinding(name, None) -> match refined {
            case Some(te) -> {
              declare(sc, name, Some(value = te))
              acc.add(checkStmt(name, te, sc, s.span))
            }
            case None -> declare(sc, name, None)
          }
          case _ -> declareUnrefined(sc, patternBoundNames(pat))
        }
      }
      case LBLet(name, ty, init) -> {
        acc.add(mkStmt(SLocal(binding = LBLet(name = name, ty = ty, init = rangeWalkExpr(init, sc))), s.span))
        match refinedAnnotation(ty) {
          case Some(te) -> {
            declare(sc, name, Some(value = te))
            acc.add(checkStmt(name, te, sc, s.span))
          }
          case None -> declare(sc, name, None)
        }
      }
      case LBVar(name, ty, initOpt) -> {
        val newInit: Option[Expr] = match initOpt { case Some(x) -> Some(value = rangeWalkExpr(x, sc)); case None -> None }
        acc.add(mkStmt(SLocal(binding = LBVar(name = name, ty = ty, init = newInit)), s.span))
        match refinedAnnotation(ty) {
          case Some(te) -> {
            declare(sc, name, Some(value = te))
            match initOpt {
              case Some(_) -> acc.add(checkStmt(name, te, sc, s.span))
              case None -> ()
            }
          }
          case None -> declare(sc, name, None)
        }
      }
    }
    case SAssign(target, op, value) -> {
      acc.add(mkStmt(SAssign(target = target, op = op, value = rangeWalkExpr(value, sc)), s.span))
      appendAssignCheck(target, sc, s.span, acc)
    }
    case SReturn(opt) -> match opt {
      case Some(v) -> acc.add(mkStmt(SReturn(value = Some(value = rangeWalkExpr(v, sc))), s.span))
      case None -> acc.add(s)
    }
    case SExpr(e) -> acc.add(mkStmt(SExpr(expr = rangeWalkExpr(e, sc)), s.span))
    case SFor(label, pat, iter, body) -> {
      val newIter = rangeWalkExpr(iter, sc)
      pushFrame(sc)
      declareUnrefined(sc, patternBoundNames(pat))
      val newBody = rangeWalkBlock(body, sc)
      popFrame(sc)
      acc.add(mkStmt(SFor(label = label, pat = pat, iter = newIter, body = newBody), s.span))
    }
    case SWhile(label, cond, body) -> acc.add(
      mkStmt(
        SWhile(
          label = label,
          cond = rangeWalkExpr(cond, sc),
          body = rangeWalkBlock(body, sc)
        ),
        s.span
      )
    )
    case SLoop(label, body) -> acc.add(mkStmt(SLoop(label = label, body = rangeWalkBlock(body, sc)), s.span))
    case SScope(b, body) -> acc.add(mkStmt(SScope(binding = b, body = rangeWalkBlock(body, sc)), s.span))
    case SDefer(body) -> acc.add(mkStmt(SDefer(body = rangeWalkBlock(body, sc)), s.span))
    case STry(body, catches, finally_) -> {
      val newBody = rangeWalkBlock(body, sc)
      val newCatches: List[CatchClause] = newList()
      var ci = 0
      while ci < catches.count {
        val c = catches[ci]
        pushFrame(sc)
        match c.bindName {
          case Some(n) -> declare(sc, n, None)
          case None -> ()
        }
        newCatches.add(
          CatchClause(typeName = c.typeName, bindName = c.bindName, body = rangeWalkBlock(c.body, sc), span = c.span)
        )
        popFrame(sc)
        ci = ci + 1
      }
      val newFinally = match finally_ { case Some(fb) -> Some(rangeWalkBlock(fb, sc)); case None -> None }
      acc.add(mkStmt(STry(body = newBody, catches = newCatches, finally_ = newFinally), s.span))
    }
    case _ -> acc.add(s)
  }
}

func appendAssignCheck(target: in Expr, sc: in RangeScope, sp: in Span, acc: in List[Statement]): Unit {
  match target.kind {
    case EPath(p) -> {
      if p.segments.count == 1 {
        match lookupRefined(sc, p.segments[0]) {
          case Some(te) -> acc.add(checkStmt(p.segments[0], te, sc, sp))
          case None -> ()
        }
      }
    }
    case _ -> ()
  }
}

func rangeWalkEob(eob: in ExprOrBlock, sc: in RangeScope): ExprOrBlock {
  match eob {
    case EOBExpr(x) -> EOBExpr(expr = rangeWalkExpr(x, sc))
    case EOBBlock(blk) -> EOBBlock(block = rangeWalkBlock(blk, sc))
  }
}

func rangeWalkArgs(args: in List[CallArg], sc: in RangeScope): List[CallArg] {
  val outs: List[CallArg] = newList()
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(n, v, sp) -> outs.add(CANamed(name = n, value = rangeWalkExpr(v, sc), span = sp))
      case CAPositional(v) -> outs.add(CAPositional(expr = rangeWalkExpr(v, sc)))
    }
    i = i + 1
  }
  outs
}

// Only the forms that can contain a statement block (and so a binding or an
// assignment) are rebuilt; any other expression is returned unchanged.
func rangeWalkExpr(e: in Expr, sc: in RangeScope): Expr {
  match e.kind {
    case EParen(inner) -> mkExpr(EParen(inner = rangeWalkExpr(inner, sc)), e.span)
    case EIf(cond, thenBranch, elseOpt, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseOpt {
        case Some(eb) -> Some(value = rangeWalkEob(eb, sc))
        case None -> None
      }
      mkExpr(
        EIf(
          cond = rangeWalkExpr(cond, sc),
          thenBranch = rangeWalkEob(thenBranch, sc),
          elseBranch = newElse,
          thenForm = thenForm
        ),
        e.span
      )
    }
    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        pushFrame(sc)
        declareUnrefined(sc, patternBoundNames(arm.pattern))
        newArms.add(MatchArm(pattern = arm.pattern, guard = arm.guard, body = rangeWalkEob(arm.body, sc), span = arm.span))
        popFrame(sc)
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = rangeWalkExpr(scrutinee, sc), arms = newArms), e.span)
    }
    case EBlock(blk) -> mkExpr(EBlock(block = rangeWalkBlock(blk, sc)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = rangeWalkBlock(blk, sc)), e.span)
    case ELambda(params, body) -> {
      pushFrame(sc)
      var i = 0
      while i < params.count {
        declare(sc, params[i].name, None)
        i = i + 1
      }
      val newBody = rangeWalkBlock(body, sc)
      popFrame(sc)
      mkExpr(ELambda(lambdaParams = params, body = newBody), e.span)
    }
    case ECall(fn, args) -> mkExpr(ECall(fn = rangeWalkExpr(fn, sc), args = rangeWalkArgs(args, sc)), e.span)
    case EAssign(target, op, value) -> {
      // An assignment in expression position: `{ target = value; check }`.
      val walkedValue = rangeWalkExpr(value, sc)
      val stmts: List[Statement] = newList()
      stmts.add(mkStmt(SAssign(target = target, op = op, value = walkedValue), e.span))
      val before = stmts.count
      appendAssignCheck(target, sc, e.span, stmts)
      if stmts.count == before {
        mkExpr(EAssign(target = target, op = op, value = walkedValue), e.span)
      } else {
        mkExpr(EBlock(block = Block(statements = stmts, span = e.span)), e.span)
      }
    }
    case EAwait(inner) -> mkExpr(EAwait(inner = rangeWalkExpr(inner, sc)), e.span)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = rangeWalkExpr(inner, sc)), e.span)
    case ETry(inner) -> mkExpr(ETry(inner = rangeWalkExpr(inner, sc)), e.span)
    case EPropagate(inner) -> mkExpr(EPropagate(inner = rangeWalkExpr(inner, sc)), e.span)
    case EBinop(op, l, r) -> mkExpr(EBinop(op = op, lhs = rangeWalkExpr(l, sc), rhs = rangeWalkExpr(r, sc)), e.span)
    case EPrefix(op, x) -> mkExpr(EPrefix(op = op, operand = rangeWalkExpr(x, sc)), e.span)
    case EMember(recv, n) -> mkExpr(EMember(receiver = rangeWalkExpr(recv, sc), memberName = n), e.span)
    // Every other form that holds a sub-expression is walked too, so an
    // assignment nested in a list, tuple, index or interpolation (a lambda
    // stored in a list, say) is checked like any other (#7398).
    case EList(xs) -> mkExpr(EList(exprs = rangeWalkExprs(xs, sc)), e.span)
    case ETuple(xs) -> mkExpr(ETuple(exprs = rangeWalkExprs(xs, sc)), e.span)
    case EIndex(recv, idxs) -> mkExpr(
      EIndex(receiver = rangeWalkExpr(recv, sc), indices = rangeWalkExprs(idxs, sc)),
      e.span
    )
    case EInterpolated(segs) -> {
      val walked: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(x) -> walked.add(ISExpr(expr = rangeWalkExpr(x, sc)))
          case ISText(t, sp) -> walked.add(ISText(text = t, span = sp))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = walked), e.span)
    }
    case ETypeApp(f, targs) -> mkExpr(ETypeApp(fn = rangeWalkExpr(f, sc), args = targs), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = rangeWalkExpr(inner, sc)), e.span)
    case ERange(rb) -> match rb {
      case RBClosed(lo, hi) -> mkExpr(
        ERange(
          bound = RBClosed(
            lo = rangeWalkExpr(lo, sc),
            hi = rangeWalkExpr(hi, sc)
          )
        ),
        e.span
      )
      case RBHalfOpen(lo, hi, bare) -> mkExpr(
        ERange(
          bound = RBHalfOpen(
            lo = rangeWalkExpr(lo, sc),
            hi = rangeWalkExpr(hi, sc),
            bareDotDot = bare
          )
        ),
        e.span
      )
      case RBLowerOpen(hi) -> mkExpr(ERange(bound = RBLowerOpen(hi = rangeWalkExpr(hi, sc))), e.span)
      case RBUpperOpen(lo) -> mkExpr(ERange(bound = RBUpperOpen(lo = rangeWalkExpr(lo, sc))), e.span)
    }
    // Leaves, and contract-only forms (`old`, quantifiers) that never hold
    // an assignment.
    case ELiteral(_) -> e
    case EPath(_) -> e
    case ESelf -> e
    case EResult -> e
    case EError -> e
    case EOld(_) -> e
    case EForall(_, _, _) -> e
    case EExists(_, _, _) -> e
  }
}

func rangeWalkExprs(xs: in List[Expr], sc: in RangeScope): List[Expr] {
  val walked: List[Expr] = newList()
  var i = 0
  while i < xs.count {
    walked.add(rangeWalkExpr(xs[i], sc))
    i = i + 1
  }
  walked
}
