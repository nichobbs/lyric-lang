//! typechecker_old.l — `old(...)` placement check (T0080).
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// `old(e)` placement (T0080, #7731).  `old` names the value `e` had at
// function entry, and only a postcondition can compare against it: it is
// valid solely inside an `ensures:` clause — of a function, a method, an
// interface or extern signature, a protected `entry`/`func`, or an aspect
// (docs/08-contract-semantics.md §3, §4.4).  The contract elaborator
// snapshots exactly the `old` operands of `ensures:` clauses; any other
// `old` would otherwise survive to codegen, which has no lowering for it.
//
// `pos` is "" inside an `ensures:` clause and otherwise describes the
// enclosing position for the diagnostic.  `inOld` is true inside an `old`
// operand, which must itself be evaluable at entry: no nested `old`, no
// `result`.
pub func checkOldPlacement(diag: in List[Diagnostic], file: in SourceFile): Unit {
  var i = 0
  while i < file.items.count {
    oldItem(diag, file.items[i])
    i = i + 1
  }
}

func oldItem(diag: in List[Diagnostic], it: in Item): Unit {
  match it.kind {
    case IConst(decl) -> oldExpr(diag, "a `const` initializer", false, decl.init)
    case IVal(decl) -> oldExpr(diag, "a module-level `val` initializer", false, decl.init)
    case IFunc(decl) -> oldFunction(diag, decl)
    case IDistinctType(decl) -> oldDistinct(diag, decl)
    case IRecord(decl) -> oldRecord(diag, decl)
    case IExposedRec(decl) -> oldRecord(diag, decl)
    case IOpaque(decl) -> oldOpaque(diag, decl)
    case IProtected(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMField(pf) -> match pf {
            case PFVar(_, _, init, _, _, _) -> oldExprOpt(diag, "a protected field initializer", init)
            case PFLet(_, _, init, _, _, _) -> oldExprOpt(diag, "a protected field initializer", init)
            case PFImmutable(fd) -> oldField(diag, fd)
          }
          case PMInvariant(inv) -> oldExpr(diag, "a type `invariant:`", false, inv.expr)
          case PMEntry(ed) -> {
            oldParams(diag, ed.params)
            oldContracts(diag, ed.contracts)
            oldBody(diag, "an entry body", ed.body)
          }
          case PMFunc(fn) -> oldFunction(diag, fn)
        }
        i = i + 1
      }
    }
    case IInterface(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMSig(sig) -> {
            oldParams(diag, sig.params)
            oldContracts(diag, sig.contracts)
          }
          case IMFunc(fn) -> oldFunction(diag, fn)
          case IMAssoc(_) -> ()
        }
        i = i + 1
      }
    }
    case IImpl(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> oldFunction(diag, fn)
          case IMplAssoc(_) -> ()
        }
        i = i + 1
      }
    }
    case IWire(decl) -> {
      oldParams(diag, decl.params)
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case WMSingleton(_, _, init, _) -> oldExpr(diag, "a wire binding", false, init)
          case WMScoped(_, _, _, init, _) -> oldExpr(diag, "a wire binding", false, init)
          case WMBind(_, provider, _) -> oldExpr(diag, "a wire binding", false, provider)
          case WMLocal(_, _, init, _) -> oldExpr(diag, "a wire binding", false, init)
          case WMContributes(_, _, init, _, _, _) -> oldExpr(diag, "a wire binding", false, init)
          case WMConfigInst(cd, _) -> oldConfig(diag, cd)
          case WMInclude(_, _, adjustments, _, _) -> oldIncludeAdjustments(diag, adjustments)
          case WMProvided(_, _, _) -> ()
          case WMExpose(_, _) -> ()
          case WMOverridable(_, _) -> ()
        }
        i = i + 1
      }
    }
    case IExtern(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i].kind {
          case EMSig(sig) -> {
            oldParams(diag, sig.params)
            oldContracts(diag, sig.contracts)
          }
          case EMRecord(rd) -> oldRecord(diag, rd)
          case EMExposedRec(rd) -> oldRecord(diag, rd)
          case EMOpaque(od) -> oldOpaque(diag, od)
          case EMDistinctType(dd) -> oldDistinct(diag, dd)
          case EMUnion(_) -> ()
          case EMEnum(_) -> ()
          case EMTypeAlias(_) -> ()
        }
        i = i + 1
      }
    }
    case ITest(decl) -> oldBlock(diag, "a test body", false, decl.body)
    case IProperty(decl) -> {
      oldExprOpt(diag, "a property guard", decl.guardExpr)
      oldBlock(diag, "a property body", false, decl.body)
    }
    case IFixture(decl) -> oldExpr(diag, "a fixture initializer", false, decl.init)
    case IConfig(decl) -> oldConfig(diag, decl)
    case IAspect(decl) -> {
      oldContracts(diag, decl.contracts)
      match decl.around {
        case Some(ar) -> oldBlock(diag, "an aspect's `around` body", false, ar.body)
        case None -> ()
      }
    }
    case IExternFunc(decl) -> oldParams(diag, decl.params)
    // No expression positions: union/enum cases and field types, type
    // aliases, extern types and scope kinds carry only types and names.
    case ITypeAlias(_) -> ()
    case IUnion(_) -> ()
    case IEnum(_) -> ()
    case IScopeKind(_) -> ()
    case IExternType(_) -> ()
    case IError -> ()
  }
}

func oldOpaque(diag: in List[Diagnostic], decl: in OpaqueTypeDecl): Unit {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case OMField(fd) -> oldField(diag, fd)
      case OMInvariant(inv) -> oldExpr(diag, "a type `invariant:`", false, inv.expr)
    }
    i = i + 1
  }
}

func oldDistinct(diag: in List[Diagnostic], decl: in DistinctTypeDecl): Unit {
  match decl.rangeClause {
    case Some(rb) -> oldRange(diag, "a range subtype's bounds", false, rb)
    case None -> ()
  }
}

func oldIncludeAdjustments(diag: in List[Diagnostic], adjs: in List[IncludeAdjust]): Unit {
  var i = 0
  while i < adjs.count {
    match adjs[i] {
      case IAProvided(_, value, _) -> oldExpr(diag, "a wire `include` adjustment", false, value)
      case IAReplace(_, value, _) -> oldExpr(diag, "a wire `include` adjustment", false, value)
      case IAConfigOverride(_, fields, _) -> {
        var j = 0
        while j < fields.count {
          oldExpr(diag, "a wire `include` adjustment", false, fields[j].value)
          j = j + 1
        }
      }
      case IARemove(_, _) -> ()
      case IAReorder(_, _, _) -> ()
    }
    i = i + 1
  }
}

func oldRecord(diag: in List[Diagnostic], decl: in RecordDecl): Unit {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(fd) -> oldField(diag, fd)
      case RMInvariant(inv) -> oldExpr(diag, "a type `invariant:`", false, inv.expr)
      case RMFunc(fn) -> oldFunction(diag, fn)
    }
    i = i + 1
  }
}

func oldField(diag: in List[Diagnostic], fd: in FieldDecl): Unit {
  oldExprOpt(diag, "a field default", fd.dflt)
}

func oldConfig(diag: in List[Diagnostic], decl: in ConfigDecl): Unit {
  var i = 0
  while i < decl.fields.count {
    oldExprOpt(diag, "a config field default", decl.fields[i].default)
    i = i + 1
  }
}

func oldFunction(diag: in List[Diagnostic], fn: in FunctionDecl): Unit {
  oldParams(diag, fn.params)
  oldContracts(diag, fn.contracts)
  match fn.body {
    case Some(b) -> oldBody(diag, "a function body", b)
    case None -> ()
  }
}

func oldBody(diag: in List[Diagnostic], pos: in String, b: in FunctionBody): Unit {
  match b {
    case FBExpr(e) -> oldExpr(diag, pos, false, e)
    case FBBlock(blk) -> oldBlock(diag, pos, false, blk)
  }
}

func oldParams(diag: in List[Diagnostic], ps: in List[Param]): Unit {
  var i = 0
  while i < ps.count {
    oldExprOpt(diag, "a parameter default", ps[i].dflt)
    i = i + 1
  }
}

func oldContracts(diag: in List[Diagnostic], cs: in List[ContractClause]): Unit {
  var i = 0
  while i < cs.count {
    match cs[i] {
      case CCEnsures(e, _) -> oldExpr(diag, "", false, e)
      case CCRequires(e, _) -> oldExpr(diag, "a `requires:` clause", false, e)
      case CCWhen(e, _) -> oldExpr(diag, "a `when:` barrier", false, e)
      case CCDecreases(e, _) -> oldExpr(diag, "a `decreases:` measure", false, e)
      case CCRaises(_, _) -> ()
    }
    i = i + 1
  }
}

func oldExprOpt(diag: in List[Diagnostic], pos: in String, eo: in Option[Expr]): Unit {
  match eo {
    case Some(e) -> oldExpr(diag, pos, false, e)
    case None -> ()
  }
}

func oldBlock(diag: in List[Diagnostic], pos: in String, inOld: in Bool, blk: in Block): Unit {
  var i = 0
  while i < blk.statements.count {
    oldStmt(diag, pos, inOld, blk.statements[i])
    i = i + 1
  }
}

func oldStmt(diag: in List[Diagnostic], pos: in String, inOld: in Bool, stmt: in Statement): Unit {
  match stmt.kind {
    case SBreak(_) -> ()
    case SContinue(_) -> ()
    case SLoop(_, body) -> oldBlock(diag, pos, inOld, body)
    case SFor(_, _, iter, body) -> {
      oldExpr(diag, pos, inOld, iter)
      oldBlock(diag, pos, inOld, body)
    }
    case SWhile(_, cond, body) -> {
      oldExpr(diag, pos, inOld, cond)
      oldBlock(diag, pos, inOld, body)
    }
    case SExpr(e) -> oldExpr(diag, pos, inOld, e)
    case SThrow(e) -> oldExpr(diag, pos, inOld, e)
    case SReturn(v) -> match v { case Some(e) -> oldExpr(diag, pos, inOld, e); case None -> () }
    // A loop invariant describes every iteration's head state, not the
    // function's entry state; a value it needs from entry is a `val` bound
    // before the loop.
    // A loop invariant describes each iteration's head state, never the
    // function's entry state, so it rejects `old` even when the loop sits in
    // a lambda inside an `ensures:` clause.
    case SInvariant(e) -> oldExpr(diag, "a loop `invariant:`", inOld, e)
    case SItem(it) -> oldItem(diag, it)
    case SAssign(t, _, v) -> {
      oldExpr(diag, pos, inOld, t)
      oldExpr(diag, pos, inOld, v)
    }
    case SLocal(binding) -> match binding {
      case LBVal(_, _, e) -> oldExpr(diag, pos, inOld, e)
      case LBLet(_, _, e) -> oldExpr(diag, pos, inOld, e)
      case LBVar(_, _, init) -> match init {
        case Some(e) -> oldExpr(diag, pos, inOld, e)
        case None -> ()
      }
    }
    case STry(body, catches, finally_) -> {
      oldBlock(diag, pos, inOld, body)
      var i = 0
      while i < catches.count {
        oldBlock(diag, pos, inOld, catches[i].body)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> oldBlock(diag, pos, inOld, fb)
        case None -> ()
      }
    }
    case SDefer(b) -> oldBlock(diag, pos, inOld, b)
    case SScope(_, b) -> oldBlock(diag, pos, inOld, b)
    case SRule(l, r) -> {
      oldExpr(diag, pos, inOld, l)
      oldExpr(diag, pos, inOld, r)
    }
  }
}

func oldOptBody(diag: in List[Diagnostic], pos: in String, inOld: in Bool, b: in ExprOrBlock): Unit {
  match b {
    case EOBExpr(e) -> oldExpr(diag, pos, inOld, e)
    case EOBBlock(blk) -> oldBlock(diag, pos, inOld, blk)
  }
}

func oldExprs(diag: in List[Diagnostic], pos: in String, inOld: in Bool, es: in List[Expr]): Unit {
  var i = 0
  while i < es.count {
    oldExpr(diag, pos, inOld, es[i])
    i = i + 1
  }
}

func oldRange(diag: in List[Diagnostic], pos: in String, inOld: in Bool, rb: in RangeBound): Unit {
  match rb {
    case RBClosed(a, b) -> {
      oldExpr(diag, pos, inOld, a)
      oldExpr(diag, pos, inOld, b)
    }
    case RBHalfOpen(a, b, _) -> {
      oldExpr(diag, pos, inOld, a)
      oldExpr(diag, pos, inOld, b)
    }
    case RBLowerOpen(a) -> oldExpr(diag, pos, inOld, a)
    case RBUpperOpen(a) -> oldExpr(diag, pos, inOld, a)
  }
}

func oldExpr(diag: in List[Diagnostic], pos: in String, inOld: in Bool, e: in Expr): Unit {
  match e.kind {
    case EOld(inner) -> {
      if inOld {
        diag.add(
          errorDiagnostic(
            "T0080",
            "`old(...)` cannot be nested inside another `old(...)`: the enclosing `old` already evaluates its " +
              "whole operand at function entry",
            e.span
          )
        )
      } else if pos != "" {
        diag.add(
          errorDiagnostic(
            "T0080",
            "`old(...)` is only valid in an `ensures:` clause, not in " + pos +
              " (it names a value captured at function entry, which only a postcondition can refer to)",
            e.span
          )
        )
      }
      oldExpr(diag, pos, true, inner)
    }
    case EResult -> {
      if inOld {
        diag.add(
          errorDiagnostic(
            "T0080",
            "`result` cannot appear inside `old(...)`: the return value does not exist yet at function entry",
            e.span
          )
        )
      }
    }
    case ELambda(_, body) -> oldBlock(diag, pos, inOld, body)
    case ELiteral(_) -> ()
    case EPath(_) -> ()
    case ESelf -> ()
    case EError -> ()
    case EYield(inner) -> oldExpr(diag, pos, inOld, inner)
    case EParen(inner) -> oldExpr(diag, pos, inOld, inner)
    case EAwait(inner) -> oldExpr(diag, pos, inOld, inner)
    case ESpawn(inner) -> oldExpr(diag, pos, inOld, inner)
    case EPropagate(inner) -> oldExpr(diag, pos, inOld, inner)
    case ETry(inner) -> oldExpr(diag, pos, inOld, inner)
    case EPrefix(_, inner) -> oldExpr(diag, pos, inOld, inner)
    case ETuple(elems) -> oldExprs(diag, pos, inOld, elems)
    case EList(elems) -> oldExprs(diag, pos, inOld, elems)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> oldExpr(diag, pos, inOld, se)
          case ISText(_) -> ()
        }
        i = i + 1
      }
    }
    case EBinop(_, l, r) -> {
      oldExpr(diag, pos, inOld, l)
      oldExpr(diag, pos, inOld, r)
    }
    case EAssign(t, _, v) -> {
      oldExpr(diag, pos, inOld, t)
      oldExpr(diag, pos, inOld, v)
    }
    case EMember(recv, _) -> oldExpr(diag, pos, inOld, recv)
    case ETypeApp(f, _) -> oldExpr(diag, pos, inOld, f)
    case EIndex(recv, idxs) -> {
      oldExpr(diag, pos, inOld, recv)
      oldExprs(diag, pos, inOld, idxs)
    }
    case ECall(f, args) -> {
      oldExpr(diag, pos, inOld, f)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> oldExpr(diag, pos, inOld, v)
          case CANamed(_, v, _) -> oldExpr(diag, pos, inOld, v)
        }
        i = i + 1
      }
    }
    case ERange(rb) -> oldRange(diag, pos, inOld, rb)
    case EIf(c, t, eOpt, _) -> {
      oldExpr(diag, pos, inOld, c)
      oldOptBody(diag, pos, inOld, t)
      match eOpt {
        case Some(b) -> oldOptBody(diag, pos, inOld, b)
        case None -> ()
      }
    }
    case EMatch(subj, arms) -> {
      oldExpr(diag, pos, inOld, subj)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> oldExpr(diag, pos, inOld, g)
          case None -> ()
        }
        oldOptBody(diag, pos, inOld, arms[i].body)
        i = i + 1
      }
    }
    case EBlock(blk) -> oldBlock(diag, pos, inOld, blk)
    case EUnsafe(blk) -> oldBlock(diag, pos, inOld, blk)
    case EForall(_, w, body) -> {
      match w {
        case Some(we) -> oldExpr(diag, pos, inOld, we)
        case None -> ()
      }
      oldExpr(diag, pos, inOld, body)
    }
    case EExists(_, w, body) -> {
      match w {
        case Some(we) -> oldExpr(diag, pos, inOld, we)
        case None -> ()
      }
      oldExpr(diag, pos, inOld, body)
    }
  }
}
