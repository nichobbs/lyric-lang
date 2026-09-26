package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// Loop-label resolution (#7349).  `loops` holds one entry per enclosing loop
// of the current function or lambda body, innermost last; an unlabelled loop
// is recorded as "" (a label is always a non-empty identifier).  A lambda, a
// `defer` body and a nested item start a fresh stack: control cannot leave
// them with `break`/`continue`.
pub func checkLoopLabels(diag: in List[Diagnostic], fn: in FunctionDecl): Unit {
  match fn.body {
    case None -> {
    }
    case Some(body) -> match body {
      case FBExpr(e) -> labelsExpr(diag, newList(), e)
      case FBBlock(b) -> labelsBlock(diag, newList(), b)
    }
  }
}

func labelOnStack(loops: in List[String], name: in String): Bool {
  var i = 0
  while i < loops.count {
    if loops[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

func labelsBlock(diag: in List[Diagnostic], loops: in List[String], blk: in Block): Unit {
  var i = 0
  while i < blk.statements.count {
    labelsStmt(diag, loops, blk.statements[i])
    i = i + 1
  }
}

func labelsLoopBody(
  diag: in List[Diagnostic],
  loops: in List[String],
  label: in Option[String],
  body: in Block,
  sp: in Span,
): Unit {
  val name = match label { case Some(l) -> l; case None -> "" }
  if name != "" and labelOnStack(loops, name) {
    diag.add(
      errorDiagnostic(
        "T0131",
        "loop label '" + name + "' is already used by an enclosing loop; rename one so `break " + name + "` / `continue " +
          name +
          "` names exactly one loop",
        sp
      )
    )
  }
  val inner: List[String] = newList()
  var i = 0
  while i < loops.count {
    inner.add(loops[i])
    i = i + 1
  }
  inner.add(name)
  labelsBlock(diag, inner, body)
}

func labelsJump(
  diag: in List[Diagnostic], loops: in List[String], kw: in String, label: in Option[String], sp: in Span
): Unit {
  match label {
    case None -> {
      if loops.count == 0 {
        diag.add(errorDiagnostic("T0130", "'" + kw + "' outside a loop", sp))
      }
    }
    case Some(l) -> {
      if not labelOnStack(loops, l) {
        diag.add(errorDiagnostic("T0130", "'" + kw + " " + l + "' does not name an enclosing loop", sp))
      }
    }
  }
}

func labelsStmt(diag: in List[Diagnostic], loops: in List[String], stmt: in Statement): Unit {
  match stmt.kind {
    case SBreak(label) -> labelsJump(diag, loops, "break", label, stmt.span)
    case SContinue(label) -> labelsJump(diag, loops, "continue", label, stmt.span)
    case SLoop(label, body) -> labelsLoopBody(diag, loops, label, body, stmt.span)
    case SFor(label, _, iter, body) -> {
      labelsExpr(diag, loops, iter)
      labelsLoopBody(diag, loops, label, body, stmt.span)
    }
    case SWhile(label, cond, body) -> {
      labelsExpr(diag, loops, cond)
      labelsLoopBody(diag, loops, label, body, stmt.span)
    }
    case SExpr(e) -> labelsExpr(diag, loops, e)
    case SThrow(e) -> labelsExpr(diag, loops, e)
    case SReturn(v) -> match v { case Some(e) -> labelsExpr(diag, loops, e); case None -> () }
    case SInvariant(e) -> labelsExpr(diag, loops, e)
    case SItem(_) -> ()
    case SAssign(t, _, v) -> {
      labelsExpr(diag, loops, t)
      labelsExpr(diag, loops, v)
    }
    case SLocal(binding) -> match binding {
      case LBVal(_, _, e) -> labelsExpr(diag, loops, e)
      case LBLet(_, _, e) -> labelsExpr(diag, loops, e)
      case LBVar(_, _, init) -> match init {
        case Some(e) -> labelsExpr(diag, loops, e)
        case None -> ()
      }
    }
    case STry(body, catches, finally_) -> {
      labelsBlock(diag, loops, body)
      var i = 0
      while i < catches.count {
        labelsBlock(diag, loops, catches[i].body)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> labelsBlock(diag, newList(), fb)
        case None -> ()
      }
    }
    case SDefer(b) -> labelsBlock(diag, newList(), b)
    case SScope(_, b) -> labelsBlock(diag, loops, b)
    case SRule(l, r) -> {
      labelsExpr(diag, loops, l)
      labelsExpr(diag, loops, r)
    }
  }
}

func labelsOptBody(diag: in List[Diagnostic], loops: in List[String], b: in ExprOrBlock): Unit {
  match b {
    case EOBExpr(e) -> labelsExpr(diag, loops, e)
    case EOBBlock(blk) -> labelsBlock(diag, loops, blk)
  }
}

func labelsExprs(diag: in List[Diagnostic], loops: in List[String], es: in List[Expr]): Unit {
  var i = 0
  while i < es.count {
    labelsExpr(diag, loops, es[i])
    i = i + 1
  }
}

func labelsExpr(diag: in List[Diagnostic], loops: in List[String], e: in Expr): Unit {
  match e.kind {
    case ELambda(_, body) -> labelsBlock(diag, newList(), body)
    case ELiteral(_) -> ()
    case EPath(_) -> ()
    case ESelf -> ()
    case EResult -> ()
    case EError -> ()
    case EYield(inner) -> labelsExpr(diag, loops, inner)
    case EParen(inner) -> labelsExpr(diag, loops, inner)
    case EAwait(inner) -> labelsExpr(diag, loops, inner)
    case ESpawn(inner) -> labelsExpr(diag, loops, inner)
    case EOld(inner) -> labelsExpr(diag, loops, inner)
    case EPropagate(inner) -> labelsExpr(diag, loops, inner)
    case ETry(inner) -> labelsExpr(diag, loops, inner)
    case EPrefix(_, inner) -> labelsExpr(diag, loops, inner)
    case ETuple(elems) -> labelsExprs(diag, loops, elems)
    case EList(elems) -> labelsExprs(diag, loops, elems)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> labelsExpr(diag, loops, se)
          case ISText(_) -> ()
        }
        i = i + 1
      }
    }
    case EBinop(_, l, r) -> {
      labelsExpr(diag, loops, l)
      labelsExpr(diag, loops, r)
    }
    case EAssign(t, _, v) -> {
      labelsExpr(diag, loops, t)
      labelsExpr(diag, loops, v)
    }
    case EMember(recv, _) -> labelsExpr(diag, loops, recv)
    case ETypeApp(f, _) -> labelsExpr(diag, loops, f)
    case EIndex(recv, idxs) -> {
      labelsExpr(diag, loops, recv)
      labelsExprs(diag, loops, idxs)
    }
    case ECall(f, args) -> {
      labelsExpr(diag, loops, f)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> labelsExpr(diag, loops, v)
          case CANamed(_, v, _) -> labelsExpr(diag, loops, v)
        }
        i = i + 1
      }
    }
    case ERange(rb) -> match rb {
      case RBClosed(a, b) -> {
        labelsExpr(diag, loops, a)
        labelsExpr(diag, loops, b)
      }
      case RBHalfOpen(a, b, _) -> {
        labelsExpr(diag, loops, a)
        labelsExpr(diag, loops, b)
      }
      case RBLowerOpen(a) -> labelsExpr(diag, loops, a)
      case RBUpperOpen(a) -> labelsExpr(diag, loops, a)
    }
    case EIf(c, t, eOpt, _) -> {
      labelsExpr(diag, loops, c)
      labelsOptBody(diag, loops, t)
      match eOpt {
        case Some(b) -> labelsOptBody(diag, loops, b)
        case None -> ()
      }
    }
    case EMatch(subj, arms) -> {
      labelsExpr(diag, loops, subj)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> labelsExpr(diag, loops, g)
          case None -> ()
        }
        labelsOptBody(diag, loops, arms[i].body)
        i = i + 1
      }
    }
    case EBlock(blk) -> labelsBlock(diag, loops, blk)
    case EUnsafe(blk) -> labelsBlock(diag, loops, blk)
    case EForall(_, w, body) -> {
      match w {
        case Some(we) -> labelsExpr(diag, loops, we)
        case None -> ()
      }
      labelsExpr(diag, loops, body)
    }
    case EExists(_, w, body) -> {
      match w {
        case Some(we) -> labelsExpr(diag, loops, we)
        case None -> ()
      }
      labelsExpr(diag, loops, body)
    }
  }
}
