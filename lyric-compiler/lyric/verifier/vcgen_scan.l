//! verifier/vcgen_scan.l — syntactic scans for yield and propagate.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// Fail closed: `what` cannot be modelled, so the path's obligation is
// `false` and the error says why.
func unsupportedWp(what: in String, sp: in Span): WpResult {
  val di: List[Diagnostic] = newList()
  di.add(errorDiagnostic("V0026", what + " is not yet supported by the verifier; the proof fails here", sp))
  val sg: List[SideGoal] = newList()
  val asList: List[Term] = newList()
  WpResult(wp = falseT(), sideGoals = sg, assumed = asList, diags = di)
}

// Each side goal of `src`, holding where `hyps` hold.
func guardSideGoals(src: in List[SideGoal], hyps: in List[Term], dst: in List[SideGoal]): Unit {
  var i = 0
  while i < src.count {
    val g = src[i]
    val t = if hyps.count == 0 { g.term } else { mkImplies(mkAnd(hyps), g.term) }
    dst.add(SideGoal(term = t, kind = g.kind, span = g.span))
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Goals for a single function.
// ─────────────────────────────────────────────────────────────────────────────
// True when a function body contains EYield (generator); WP/SP cannot model generator suspend/resume.
func funcBodyContainsYield(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(b) -> {
      match b {
        case FBExpr(expr) -> exprContainsYield(expr)
        case FBBlock(blk) -> blockContainsYield(blk)
      }
    }
    case None -> false
  }
}

func blockContainsYield(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYield(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtContainsYield(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprContainsYield(init)
        case LBLet(_, _, init) -> exprContainsYield(init)
        case LBVar(_, _, Some(init)) -> exprContainsYield(init)
        case LBVar(_, _, None) -> false
      }
    }
    case SAssign(target, _, value) -> exprContainsYield(target) or exprContainsYield(value)
    case SReturn(Some(e)) -> exprContainsYield(e)
    case SReturn(None) -> false
    case SThrow(e) -> exprContainsYield(e)
    case STry(body, catches, finally_) -> {
      if blockContainsYield(body) {
        return true
      }
      var ci = 0
      while ci < catches.count {
        if blockContainsYield(catches[ci].body) {
          return true
        }
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> blockContainsYield(fb)
        case None -> false
      }
    }
    case SDefer(body) -> blockContainsYield(body)
    case SScope(_, body) -> blockContainsYield(body)
    case SFor(_, _, iter, body) -> exprContainsYield(iter) or blockContainsYield(body)
    case SWhile(_, cond, body) -> exprContainsYield(cond) or blockContainsYield(body)
    case SLoop(_, body) -> blockContainsYield(body)
    case SInvariant(e) -> exprContainsYield(e)
    case SExpr(e) -> exprContainsYield(e)
    case SRule(lhs, rhs) -> exprContainsYield(lhs) or exprContainsYield(rhs)
    case _ -> false
  }
}

func exprContainsYield(e: in Expr): Bool {
  match e.kind {
    case EYield(_) -> true
    case EParen(inner) -> exprContainsYield(inner)
    case EAwait(inner) -> exprContainsYield(inner)
    case ESpawn(inner) -> exprContainsYield(inner)
    case EPropagate(inner) -> exprContainsYield(inner)
    case ETry(inner) -> exprContainsYield(inner)
    case EOld(inner) -> exprContainsYield(inner)
    case EBlock(blk) -> blockContainsYield(blk)
    case EUnsafe(blk) -> blockContainsYield(blk)
    case EPrefix(_, operand) -> exprContainsYield(operand)
    case EBinop(_, lhs, rhs) -> exprContainsYield(lhs) or exprContainsYield(rhs)
    case EMember(receiver, _) -> exprContainsYield(receiver)
    case ETypeApp(fn, _) -> exprContainsYield(fn)
    case EAssign(target, _, value) -> exprContainsYield(target) or exprContainsYield(value)
    case ECall(fn, args) -> {
      if exprContainsYield(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(expr) -> expr }
        if exprContainsYield(argExpr) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(receiver, indices) -> {
      if exprContainsYield(receiver) {
        return true
      }
      var i = 0
      while i < indices.count {
        if exprContainsYield(indices[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETuple(exprs) -> {
      var i = 0
      while i < exprs.count {
        if exprContainsYield(exprs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        if exprContainsYield(exprs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(x) -> {
            if exprContainsYield(x) {
              return true
            }
          }
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
      false
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> exprContainsYield(lo) or exprContainsYield(hi)
        case RBHalfOpen(lo, hi, _) -> exprContainsYield(lo) or exprContainsYield(hi)
        case RBLowerOpen(hi) -> exprContainsYield(hi)
        case RBUpperOpen(lo) -> exprContainsYield(lo)
      }
    }
    case EForall(_, whereExpr, body, _) -> {
      val inWhere = match whereExpr { case Some(w) -> exprContainsYield(w); case None -> false }
      inWhere or exprContainsYield(body)
    }
    case EExists(_, whereExpr, body, _) -> {
      val inWhere = match whereExpr { case Some(w) -> exprContainsYield(w); case None -> false }
      inWhere or exprContainsYield(body)
    }
    case ELambda(_, body) -> blockContainsYield(body)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      if exprContainsYield(cond) {
        return true
      }
      if eobContainsYield(thenBranch) {
        return true
      }
      match elseBranch {
        case Some(eb) -> eobContainsYield(eb)
        case None -> false
      }
    }
    case EMatch(scrutinee, arms) -> {
      if exprContainsYield(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        if eobContainsYield(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func eobContainsYield(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(x) -> exprContainsYield(x)
    case EOBBlock(blk) -> blockContainsYield(blk)
  }
}

// Whether code contains a `?` anywhere, a lambda's body included (#8108).
func blockHasPropagate(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtHasPropagate(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtHasPropagate(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprHasPropagate(init)
        case LBLet(_, _, init) -> exprHasPropagate(init)
        case LBVar(_, _, Some(init)) -> exprHasPropagate(init)
        case LBVar(_, _, None) -> false
      }
    }
    case SAssign(target, _, value) -> exprHasPropagate(target) or exprHasPropagate(value)
    case SReturn(Some(e)) -> exprHasPropagate(e)
    case SReturn(None) -> false
    case SThrow(e) -> exprHasPropagate(e)
    case STry(body, catches, finally_) -> {
      if blockHasPropagate(body) {
        return true
      }
      var ci = 0
      while ci < catches.count {
        if blockHasPropagate(catches[ci].body) {
          return true
        }
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> blockHasPropagate(fb)
        case None -> false
      }
    }
    case SDefer(body) -> blockHasPropagate(body)
    case SScope(_, body) -> blockHasPropagate(body)
    case SFor(_, _, iter, body) -> exprHasPropagate(iter) or blockHasPropagate(body)
    case SWhile(_, cond, body) -> exprHasPropagate(cond) or blockHasPropagate(body)
    case SLoop(_, body) -> blockHasPropagate(body)
    case SInvariant(e) -> exprHasPropagate(e)
    case SExpr(e) -> exprHasPropagate(e)
    case SRule(lhs, rhs) -> exprHasPropagate(lhs) or exprHasPropagate(rhs)
    case _ -> false
  }
}

func exprHasPropagate(e: in Expr): Bool {
  match e.kind {
    case EPropagate(_) -> true
    case EYield(inner) -> exprHasPropagate(inner)
    case EParen(inner) -> exprHasPropagate(inner)
    case EAwait(inner) -> exprHasPropagate(inner)
    case ESpawn(inner) -> exprHasPropagate(inner)
    case ETry(inner) -> exprHasPropagate(inner)
    case EOld(inner) -> exprHasPropagate(inner)
    case EBlock(blk) -> blockHasPropagate(blk)
    case EUnsafe(blk) -> blockHasPropagate(blk)
    case EPrefix(_, operand) -> exprHasPropagate(operand)
    case EBinop(_, lhs, rhs) -> exprHasPropagate(lhs) or exprHasPropagate(rhs)
    case EMember(receiver, _) -> exprHasPropagate(receiver)
    case ETypeApp(fn, _) -> exprHasPropagate(fn)
    case EAssign(target, _, value) -> exprHasPropagate(target) or exprHasPropagate(value)
    case ECall(fn, args) -> {
      if exprHasPropagate(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(expr) -> expr }
        if exprHasPropagate(argExpr) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(receiver, indices) -> {
      if exprHasPropagate(receiver) {
        return true
      }
      var i = 0
      while i < indices.count {
        if exprHasPropagate(indices[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETuple(exprs) -> {
      var i = 0
      while i < exprs.count {
        if exprHasPropagate(exprs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        if exprHasPropagate(exprs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(x) -> {
            if exprHasPropagate(x) {
              return true
            }
          }
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
      false
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> exprHasPropagate(lo) or exprHasPropagate(hi)
        case RBHalfOpen(lo, hi, _) -> exprHasPropagate(lo) or exprHasPropagate(hi)
        case RBLowerOpen(hi) -> exprHasPropagate(hi)
        case RBUpperOpen(lo) -> exprHasPropagate(lo)
      }
    }
    case EForall(_, whereExpr, body, _) -> {
      val inWhere = match whereExpr { case Some(w) -> exprHasPropagate(w); case None -> false }
      inWhere or exprHasPropagate(body)
    }
    case EExists(_, whereExpr, body, _) -> {
      val inWhere = match whereExpr { case Some(w) -> exprHasPropagate(w); case None -> false }
      inWhere or exprHasPropagate(body)
    }
    case ELambda(_, body) -> blockHasPropagate(body)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      if exprHasPropagate(cond) {
        return true
      }
      if eobHasPropagate(thenBranch) {
        return true
      }
      match elseBranch {
        case Some(eb) -> eobHasPropagate(eb)
        case None -> false
      }
    }
    case EMatch(scrutinee, arms) -> {
      if exprHasPropagate(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        val inGuard = match arms[i].guard { case Some(g) -> exprHasPropagate(g); case None -> false }
        if inGuard or eobHasPropagate(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func eobHasPropagate(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(x) -> exprHasPropagate(x)
    case EOBBlock(blk) -> blockHasPropagate(blk)
  }
}
